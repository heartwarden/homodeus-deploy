#!/bin/bash
set -euo pipefail

# Homodeus Deployment Restore Script
# Usage: ./restore.sh [service] [backup_date] [backup_password]

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${HOME}/backups"
SECRETS_DIR="${HOME}/.local/share/homodeus-secrets"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

# Parse arguments
SERVICE="${1:-}"
BACKUP_DATE="${2:-}"
BACKUP_PASSWORD="${3:-}"

if [ -z "$SERVICE" ]; then
    echo "Available services: matrix, piefed, both, secrets"
    read -p "Which service to restore: " SERVICE
fi

if [ -z "$BACKUP_DATE" ]; then
    echo "Available backup dates:"
    ls "$BACKUP_DIR"/*.gpg 2>/dev/null | sed 's/.*_\([0-9]\{8\}_[0-9]\{6\}\).*/\1/' | sort -u || echo "No backups found"
    read -p "Enter backup date (YYYYMMDD_HHMMSS): " BACKUP_DATE
fi

if [ -z "$BACKUP_PASSWORD" ]; then
    read -sp "Enter backup decryption password: " BACKUP_PASSWORD
    echo
fi

log_info "=========================================="
log_info "Homodeus Restore Script v${VERSION}"
log_info "=========================================="
log_info "Service: $SERVICE"
log_info "Date: $BACKUP_DATE"
log_info "=========================================="

# Verify backup files exist
verify_backups() {
    local service=$1
    local date=$2

    log_step "Verifying backup files for $service..."

    case $service in
        matrix)
            if [ ! -f "$BACKUP_DIR/matrix_db_${date}.sql.gz.gpg" ]; then
                log_error "Matrix database backup not found: matrix_db_${date}.sql.gz.gpg"
                exit 1
            fi
            if [ ! -f "$BACKUP_DIR/matrix_data_${date}.tar.gz.gpg" ]; then
                log_error "Matrix data backup not found: matrix_data_${date}.tar.gz.gpg"
                exit 1
            fi
            ;;
        piefed)
            if [ ! -f "$BACKUP_DIR/piefed_db_${date}.sql.gz.gpg" ]; then
                log_error "PieFed database backup not found: piefed_db_${date}.sql.gz.gpg"
                exit 1
            fi
            if [ ! -f "$BACKUP_DIR/piefed_data_${date}.tar.gz.gpg" ]; then
                log_error "PieFed data backup not found: piefed_data_${date}.tar.gz.gpg"
                exit 1
            fi
            ;;
        secrets)
            if [ ! -f "$BACKUP_DIR/secrets_${date}.tar.gz.gpg" ]; then
                log_error "Secrets backup not found: secrets_${date}.tar.gz.gpg"
                exit 1
            fi
            ;;
    esac

    log_info "✓ Backup files verified"
}

# Test backup decryption
test_decryption() {
    local file="$1"
    log_info "Testing decryption of $file..."

    if ! echo "$BACKUP_PASSWORD" | gpg --batch --yes --passphrase-fd 0 --decrypt "$file" > /dev/null 2>&1; then
        log_error "Failed to decrypt backup file. Check password."
        exit 1
    fi

    log_info "✓ Decryption test successful"
}

# Stop services
stop_services() {
    local service=$1

    log_step "Stopping $service services..."

    case $service in
        matrix)
            if [ -d "$HOME/containers/matrix" ]; then
                cd "$HOME/containers/matrix"
                podman-compose down || true
            fi
            ;;
        piefed)
            if [ -d "$HOME/containers/piefed" ]; then
                cd "$HOME/containers/piefed"
                podman-compose down || true
            fi
            ;;
        both)
            stop_services matrix
            stop_services piefed
            ;;
    esac

    log_info "✓ Services stopped"
}

# Restore secrets
restore_secrets() {
    local date=$1

    log_step "Restoring secrets..."

    # Backup current secrets
    if [ -d "$SECRETS_DIR" ]; then
        mv "$SECRETS_DIR" "${SECRETS_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    mkdir -p "$SECRETS_DIR"

    echo "$BACKUP_PASSWORD" | gpg --batch --yes --passphrase-fd 0 \
        --decrypt "$BACKUP_DIR/secrets_${date}.tar.gz.gpg" | \
        tar xzf - -C "$SECRETS_DIR"

    chmod 700 "$SECRETS_DIR"
    chmod 600 "$SECRETS_DIR"/*

    log_info "✓ Secrets restored"
}

# Restore Matrix service
restore_matrix() {
    local date=$1

    log_step "Restoring Matrix service..."

    cd "$HOME/containers/matrix"

    # Backup current data
    if [ -d "data" ]; then
        mv data "data.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # Restore data directory
    log_info "Restoring Matrix data directory..."
    echo "$BACKUP_PASSWORD" | gpg --batch --yes --passphrase-fd 0 \
        --decrypt "$BACKUP_DIR/matrix_data_${date}.tar.gz.gpg" | \
        tar xzf -

    # Start only postgres for database restore
    log_info "Starting PostgreSQL container..."
    podman-compose up -d postgres
    sleep 15

    # Load database password
    source "$SECRETS_DIR/matrix.env"

    # Drop and recreate database
    log_info "Recreating Matrix database..."
    podman-compose exec postgres \
        bash -c "PGPASSWORD='${MATRIX_POSTGRES_PASSWORD}' dropdb -U synapse synapse --if-exists"
    podman-compose exec postgres \
        bash -c "PGPASSWORD='${MATRIX_POSTGRES_PASSWORD}' createdb -U synapse synapse"

    # Restore database
    log_info "Restoring Matrix database..."
    echo "$BACKUP_PASSWORD" | gpg --batch --yes --passphrase-fd 0 \
        --decrypt "$BACKUP_DIR/matrix_db_${date}.sql.gz.gpg" | \
        gunzip | \
        podman-compose exec -T postgres \
        bash -c "PGPASSWORD='${MATRIX_POSTGRES_PASSWORD}' psql -U synapse synapse"

    # Start all services
    log_info "Starting all Matrix services..."
    podman-compose up -d

    log_info "✓ Matrix restore complete"
}

# Restore PieFed service
restore_piefed() {
    local date=$1

    log_step "Restoring PieFed service..."

    cd "$HOME/containers/piefed"

    # Backup current data
    if [ -d "data" ]; then
        mv data "data.backup.$(date +%Y%m%d_%H%M%S)"
    fi

    # Restore data directory
    log_info "Restoring PieFed data directory..."
    echo "$BACKUP_PASSWORD" | gpg --batch --yes --passphrase-fd 0 \
        --decrypt "$BACKUP_DIR/piefed_data_${date}.tar.gz.gpg" | \
        tar xzf -

    # Start only postgres for database restore
    log_info "Starting PostgreSQL container..."
    podman-compose up -d postgres
    sleep 15

    # Load database password
    source "$SECRETS_DIR/piefed.env"

    # Drop and recreate database
    log_info "Recreating PieFed database..."
    podman-compose exec postgres \
        bash -c "PGPASSWORD='${PIEFED_POSTGRES_PASSWORD}' dropdb -U piefed piefed --if-exists"
    podman-compose exec postgres \
        bash -c "PGPASSWORD='${PIEFED_POSTGRES_PASSWORD}' createdb -U piefed piefed"

    # Restore database
    log_info "Restoring PieFed database..."
    echo "$BACKUP_PASSWORD" | gpg --batch --yes --passphrase-fd 0 \
        --decrypt "$BACKUP_DIR/piefed_db_${date}.sql.gz.gpg" | \
        gunzip | \
        podman-compose exec -T postgres \
        bash -c "PGPASSWORD='${PIEFED_POSTGRES_PASSWORD}' psql -U piefed piefed"

    # Start all services
    log_info "Starting all PieFed services..."
    podman-compose up -d

    log_info "✓ PieFed restore complete"
}

# Verify restoration
verify_services() {
    local service=$1

    log_step "Verifying $service services..."

    case $service in
        matrix)
            # Wait for Matrix to start
            sleep 30
            if curl -s http://localhost:8008/_matrix/client/versions > /dev/null; then
                log_info "✓ Matrix is responding"
            else
                log_warn "⚠ Matrix may still be starting up"
            fi
            ;;
        piefed)
            # Wait for PieFed to start
            sleep 30
            if curl -s http://localhost:8080/ > /dev/null; then
                log_info "✓ PieFed is responding"
            else
                log_warn "⚠ PieFed may still be starting up"
            fi
            ;;
        both)
            verify_services matrix
            verify_services piefed
            ;;
    esac
}

# Main restore function
main() {
    # Verify prerequisites
    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        exit 1
    fi

    case $SERVICE in
        secrets)
            verify_backups secrets "$BACKUP_DATE"
            test_decryption "$BACKUP_DIR/secrets_${BACKUP_DATE}.tar.gz.gpg"
            restore_secrets "$BACKUP_DATE"
            ;;
        matrix)
            verify_backups matrix "$BACKUP_DATE"
            test_decryption "$BACKUP_DIR/matrix_db_${BACKUP_DATE}.sql.gz.gpg"

            # Always restore secrets first for Matrix
            if [ -f "$BACKUP_DIR/secrets_${BACKUP_DATE}.tar.gz.gpg" ]; then
                restore_secrets "$BACKUP_DATE"
            fi

            stop_services matrix
            restore_matrix "$BACKUP_DATE"
            verify_services matrix
            ;;
        piefed)
            verify_backups piefed "$BACKUP_DATE"
            test_decryption "$BACKUP_DIR/piefed_db_${BACKUP_DATE}.sql.gz.gpg"

            # Always restore secrets first for PieFed
            if [ -f "$BACKUP_DIR/secrets_${BACKUP_DATE}.tar.gz.gpg" ]; then
                restore_secrets "$BACKUP_DATE"
            fi

            stop_services piefed
            restore_piefed "$BACKUP_DATE"
            verify_services piefed
            ;;
        both)
            verify_backups matrix "$BACKUP_DATE"
            verify_backups piefed "$BACKUP_DATE"
            test_decryption "$BACKUP_DIR/matrix_db_${BACKUP_DATE}.sql.gz.gpg"

            # Restore secrets first
            if [ -f "$BACKUP_DIR/secrets_${BACKUP_DATE}.tar.gz.gpg" ]; then
                restore_secrets "$BACKUP_DATE"
            fi

            stop_services both
            restore_matrix "$BACKUP_DATE"
            restore_piefed "$BACKUP_DATE"
            verify_services both
            ;;
        *)
            log_error "Invalid service: $SERVICE. Use: matrix, piefed, both, or secrets"
            exit 1
            ;;
    esac

    echo ""
    log_info "=========================================="
    log_info "       RESTORE COMPLETE!"
    log_info "=========================================="
    log_info "Service: $SERVICE"
    log_info "Backup date: $BACKUP_DATE"

    if [[ "$SERVICE" == "matrix" ]] || [[ "$SERVICE" == "both" ]]; then
        log_info ""
        log_info "Matrix: http://localhost:8008/_matrix/client/versions"
        log_info "Check logs: cd ~/containers/matrix && podman-compose logs"
    fi

    if [[ "$SERVICE" == "piefed" ]] || [[ "$SERVICE" == "both" ]]; then
        log_info ""
        log_info "PieFed: http://localhost:8080/"
        log_info "Check logs: cd ~/containers/piefed && podman-compose logs"
    fi

    log_info ""
    log_info "Next steps:"
    log_info "1. Verify all services are working correctly"
    log_info "2. Check application logs for any errors"
    log_info "3. Test user functionality"
    log_info "4. Remove backup directories if restore is successful"
    log_info ""
    log_warn "Backup directories saved with .backup suffix"
    log_warn "Remove them manually once you verify the restore"
    log_info "=========================================="
}

# Run main function
main "$@"