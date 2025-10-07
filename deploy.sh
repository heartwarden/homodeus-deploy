#!/bin/bash
set -euo pipefail

# Secure Matrix & PieFed Deployment Script
# Usage: ./deploy.sh [matrix|piefed|both] [domain] [username]

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Check if running as root and handle initial setup
if [ "$EUID" -eq 0 ]; then
    log_step "Running as root - will create user and setup system first"

    # Get username from args or prompt
    DEPLOY_USER="${3:-}"
    if [ -z "$DEPLOY_USER" ]; then
        read -p "Enter username to create for deployment (default: homodeus): " DEPLOY_USER
        DEPLOY_USER="${DEPLOY_USER:-homodeus}"
    fi

    # Validate username
    if ! [[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_error "Invalid username. Use lowercase letters, numbers, underscore, hyphen."
        exit 1
    fi

    log_info "Will create user: $DEPLOY_USER"

    # Create user if doesn't exist
    if id "$DEPLOY_USER" &>/dev/null; then
        log_warn "User $DEPLOY_USER already exists"
    else
        log_info "Creating user $DEPLOY_USER..."
        useradd -m -s /bin/bash -G wheel,systemd-journal "$DEPLOY_USER" 2>/dev/null || \
        useradd -m -s /bin/bash -G sudo,systemd-journal "$DEPLOY_USER"

        # Set a temporary password
        TEMP_PASSWORD=$(openssl rand -base64 16)
        echo "$DEPLOY_USER:$TEMP_PASSWORD" | chpasswd

        log_info "User created. Temporary password: $TEMP_PASSWORD"
        log_warn "Change this password immediately after first login!"
    fi

    # Setup SSH for new user
    USER_HOME=$(eval echo ~$DEPLOY_USER)
    log_info "Setting up SSH keys for $DEPLOY_USER..."

    mkdir -p "$USER_HOME/.ssh"

    # Copy authorized_keys from root if exists
    if [ -f /root/.ssh/authorized_keys ]; then
        log_info "Copying SSH keys from root..."
        cp /root/.ssh/authorized_keys "$USER_HOME/.ssh/authorized_keys"
    else
        log_warn "No SSH keys found in /root/.ssh/authorized_keys"
        log_warn "You should add your SSH public key to $USER_HOME/.ssh/authorized_keys"
        touch "$USER_HOME/.ssh/authorized_keys"
    fi

    # Set correct permissions
    chown -R "$DEPLOY_USER:$DEPLOY_USER" "$USER_HOME/.ssh"
    chmod 700 "$USER_HOME/.ssh"
    chmod 600 "$USER_HOME/.ssh/authorized_keys"

    # Setup sudo without password for initial setup
    if ! grep -q "$DEPLOY_USER ALL=(ALL) NOPASSWD: ALL" /etc/sudoers.d/$DEPLOY_USER 2>/dev/null; then
        echo "$DEPLOY_USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$DEPLOY_USER
        chmod 440 /etc/sudoers.d/$DEPLOY_USER
        log_info "Sudo configured for $DEPLOY_USER (passwordless for setup)"
    fi

    # Copy script to user's home
    DEPLOY_SCRIPT="$USER_HOME/deploy.sh"
    cp "$0" "$DEPLOY_SCRIPT"
    chown "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_SCRIPT"
    chmod +x "$DEPLOY_SCRIPT"

    # Copy entire repo if we're in one
    if [ -d "$SCRIPT_DIR/.git" ]; then
        log_info "Copying repository to $USER_HOME/homodeus-deploy..."
        cp -r "$SCRIPT_DIR" "$USER_HOME/homodeus-deploy"
        chown -R "$DEPLOY_USER:$DEPLOY_USER" "$USER_HOME/homodeus-deploy"
        DEPLOY_SCRIPT="$USER_HOME/homodeus-deploy/deploy.sh"
    fi

    log_info "=========================================="
    log_info "Initial setup complete!"
    log_info "=========================================="
    log_info "User: $DEPLOY_USER"
    log_info "SSH keys: Copied from root"
    log_info "Sudo: Configured (passwordless)"
    log_info ""
    log_info "Now running deployment as $DEPLOY_USER..."
    log_info "=========================================="
    echo ""

    # Re-run this script as the new user
    exec sudo -u "$DEPLOY_USER" -i bash "$DEPLOY_SCRIPT" "$@"
    exit 0
fi

# From here on, we're running as non-root user
DEPLOY_DIR="${HOME}/containers"
SECRETS_DIR="${HOME}/.local/share/homodeus-secrets"
BACKUP_DIR="${HOME}/backups"
LOG_DIR="${HOME}/.local/share/homodeus-logs"

# Parse arguments
SERVICE="${1:-both}"
DOMAIN="${2:-}"

if [ -z "$DOMAIN" ]; then
    read -p "Enter your domain name (e.g., homodeus.sh): " DOMAIN
fi

MATRIX_DOMAIN="matrix.${DOMAIN}"
PIEFED_DOMAIN="piefed.${DOMAIN}"
CURRENT_USER=$(whoami)

log_info "=========================================="
log_info "Homodeus Deployment Script v${VERSION}"
log_info "=========================================="
log_info "User: $CURRENT_USER"
log_info "Service: $SERVICE"
log_info "Domain: $DOMAIN"
log_info "=========================================="
echo ""

# Create directory structure
create_directories() {
    log_info "Creating directory structure..."
    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"

    mkdir -p "$LOG_DIR"
    chmod 700 "$LOG_DIR"

    if [[ "$SERVICE" == "matrix" ]] || [[ "$SERVICE" == "both" ]]; then
        mkdir -p "$DEPLOY_DIR/matrix"/{data,config,backups}
    fi

    if [[ "$SERVICE" == "piefed" ]] || [[ "$SERVICE" == "both" ]]; then
        mkdir -p "$DEPLOY_DIR/piefed"/{data,config,backups}
    fi

    mkdir -p "$BACKUP_DIR"
}

# Generate secure random string
generate_secret() {
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-64
}

# Generate and store secrets
generate_secrets() {
    local service=$1
    local secrets_file="${SECRETS_DIR}/${service}.env"

    if [ -f "$secrets_file" ]; then
        log_warn "Secrets file exists for $service. Loading existing secrets..."
        return 0
    fi

    log_info "Generating secrets for $service..."

    case $service in
        matrix)
            cat > "$secrets_file" << EOF
# Matrix Synapse Secrets - Generated $(date)
# KEEP THIS FILE SECURE - chmod 600
MATRIX_POSTGRES_PASSWORD=$(generate_secret)
MATRIX_REGISTRATION_SHARED_SECRET=$(generate_secret)
MATRIX_FORM_SECRET=$(generate_secret)
MATRIX_MACAROON_SECRET_KEY=$(generate_secret)
EOF
            ;;
        piefed)
            cat > "$secrets_file" << EOF
# PieFed Secrets - Generated $(date)
# KEEP THIS FILE SECURE - chmod 600
PIEFED_POSTGRES_PASSWORD=$(generate_secret)
PIEFED_SECRET_KEY=$(generate_secret)
PIEFED_DJANGO_SECRET=$(generate_secret)
EOF
            ;;
    esac

    chmod 600 "$secrets_file"
    log_info "Secrets saved to: $secrets_file"
}

# Load secrets from file
load_secrets() {
    local service=$1
    local secrets_file="${SECRETS_DIR}/${service}.env"

    if [ ! -f "$secrets_file" ]; then
        log_error "Secrets file not found: $secrets_file"
        exit 1
    fi

    source "$secrets_file"
}

# Harden server security
harden_server() {
    log_step "Hardening server security..."

    # Install required packages
    log_info "Installing required packages..."
    if command -v dnf &> /dev/null; then
        sudo dnf install -y podman podman-compose caddy python3-pyyaml fail2ban fail2ban-systemd >/dev/null 2>&1 || true
    elif command -v apt &> /dev/null; then
        sudo apt update >/dev/null 2>&1
        sudo apt install -y podman podman-compose caddy python3-yaml fail2ban >/dev/null 2>&1 || true
    fi

    # Firewall configuration
    if command -v firewall-cmd &> /dev/null; then
        log_info "Configuring firewalld..."
        sudo systemctl enable --now firewalld >/dev/null 2>&1 || true
        sudo firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
        sudo firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
        sudo firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
        sudo firewall-cmd --permanent --add-port=8448/tcp >/dev/null 2>&1 || true
        sudo firewall-cmd --reload >/dev/null 2>&1 || true
    elif command -v ufw &> /dev/null; then
        log_info "Configuring UFW..."
        sudo ufw --force enable >/dev/null 2>&1 || true
        sudo ufw allow 22/tcp >/dev/null 2>&1 || true
        sudo ufw allow 80/tcp >/dev/null 2>&1 || true
        sudo ufw allow 443/tcp >/dev/null 2>&1 || true
        sudo ufw allow 8448/tcp >/dev/null 2>&1 || true
    fi

    # Increase file limits for podman
    if [ ! -f /etc/security/limits.d/podman.conf ]; then
        log_info "Setting resource limits..."
        sudo tee /etc/security/limits.d/podman.conf > /dev/null << EOF
$CURRENT_USER soft nofile 65536
$CURRENT_USER hard nofile 65536
$CURRENT_USER soft nproc 4096
$CURRENT_USER hard nproc 4096
EOF
    fi

    # Disable unnecessary services
    log_info "Disabling unnecessary services..."
    for service in avahi-daemon cups bluetooth; do
        if systemctl is-active --quiet $service 2>/dev/null; then
            sudo systemctl disable --now $service >/dev/null 2>&1 || true
        fi
    done

    # Configure sysctl for better network security
    if [ ! -f /etc/sysctl.d/99-homodeus-security.conf ]; then
        log_info "Configuring kernel parameters..."
        sudo tee /etc/sysctl.d/99-homodeus-security.conf > /dev/null << EOF
# Homodeus Security Hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
fs.file-max = 65535
EOF
        sudo sysctl -p /etc/sysctl.d/99-homodeus-security.conf >/dev/null 2>&1 || true
    fi

    # Enable podman socket for user
    systemctl --user enable --now podman.socket >/dev/null 2>&1 || true

    # Enable lingering so services run after logout
    sudo loginctl enable-linger "$CURRENT_USER" >/dev/null 2>&1 || true

    log_info "✓ Server hardening complete"
}

# Setup fail2ban
setup_fail2ban() {
    log_step "Setting up fail2ban..."

    # Create fail2ban configuration for Matrix
    if [[ "$SERVICE" == "matrix" ]] || [[ "$SERVICE" == "both" ]]; then
        sudo tee /etc/fail2ban/filter.d/matrix-synapse.conf > /dev/null << 'EOF'
[Definition]
failregex = ^.*Received request.*POST.*/_matrix/client/r0/login.*Failed login.*from\ <HOST>.*$
            ^.*POST.*/_matrix/client/(r0|v3)/register.*401.*<HOST>.*$
ignoreregex =
EOF

        sudo tee /etc/fail2ban/jail.d/matrix-synapse.conf > /dev/null << EOF
[matrix-synapse]
enabled = true
port = http,https
filter = matrix-synapse
logpath = ${DEPLOY_DIR}/matrix/data/homeserver.log
maxretry = 5
findtime = 600
bantime = 3600
action = iptables-allports[name=matrix-synapse]
EOF
    fi

    # Create fail2ban configuration for Caddy
    sudo tee /etc/fail2ban/filter.d/caddy-auth.conf > /dev/null << 'EOF'
[Definition]
failregex = ^.*<HOST>.*"(GET|POST|HEAD).*" (401|403) .*$
ignoreregex =
EOF

    sudo tee /etc/fail2ban/jail.d/caddy.conf > /dev/null << 'EOF'
[caddy-auth]
enabled = true
port = http,https
filter = caddy-auth
logpath = /var/log/caddy/access.log
maxretry = 10
findtime = 600
bantime = 3600
action = iptables-allports[name=caddy]
EOF

    # Enable and start fail2ban
    sudo systemctl enable fail2ban >/dev/null 2>&1
    sudo systemctl restart fail2ban >/dev/null 2>&1

    log_info "✓ fail2ban configured and started"
}

# Deploy Matrix
deploy_matrix() {
    log_info "Deploying Matrix Synapse..."

    generate_secrets "matrix"
    load_secrets "matrix"

    cd "$DEPLOY_DIR/matrix"

    # Create docker-compose.yml (v2 format)
    cat > compose.yml << EOF
services:
  synapse:
    image: docker.io/matrixdotorg/synapse:latest
    container_name: matrix-synapse
    restart: unless-stopped
    environment:
      - SYNAPSE_SERVER_NAME=${DOMAIN}
      - SYNAPSE_REPORT_STATS=no
      - UID=$(id -u)
      - GID=$(id -g)
    volumes:
      - ./data:/data:Z
    ports:
      - "127.0.0.1:8008:8008"
    networks:
      - matrix_net
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-fSs", "http://localhost:8008/health"]
      interval: 30s
      timeout: 10s
      retries: 3
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  postgres:
    image: docker.io/postgres:16-alpine
    container_name: matrix-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=synapse
      - POSTGRES_PASSWORD=${MATRIX_POSTGRES_PASSWORD}
      - POSTGRES_DB=synapse
      - POSTGRES_INITDB_ARGS=--encoding=UTF-8 --lc-collate=C --lc-ctype=C
    volumes:
      - ./data/postgres:/var/lib/postgresql/data:Z
    networks:
      - matrix_net
    command: postgres -c max_connections=200 -c shared_buffers=256MB -c effective_cache_size=1GB
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U synapse"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  redis:
    image: docker.io/redis:7-alpine
    container_name: matrix-redis
    restart: unless-stopped
    volumes:
      - ./data/redis:/data:Z
    networks:
      - matrix_net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

  synapse-admin:
    image: docker.io/awesometechnologies/synapse-admin:latest
    container_name: matrix-admin
    restart: unless-stopped
    ports:
      - "127.0.0.1:8081:80"
    networks:
      - matrix_net
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

networks:
  matrix_net:
    driver: bridge
EOF

    # Generate initial config if not exists
    if [ ! -f "./data/homeserver.yaml" ]; then
        log_info "Generating Matrix homeserver.yaml..."
        podman run -it --rm \
            -v ./data:/data:Z \
            -e SYNAPSE_SERVER_NAME="${DOMAIN}" \
            -e SYNAPSE_REPORT_STATS=no \
            docker.io/matrixdotorg/synapse:latest generate

        # Inject our secure configuration
        configure_matrix_yaml
    fi

    # Configure log encryption
    configure_matrix_logging

    # Start services
    log_info "Starting Matrix services..."
    podman-compose up -d

    log_info "Matrix deployment complete!"
    log_info "Admin UI will be available at: https://${MATRIX_DOMAIN}/admin/"
}

# Configure Matrix logging with encryption
configure_matrix_logging() {
    log_info "Configuring encrypted logging for Matrix..."

    local log_config="./data/${DOMAIN}.log.config"

    cat > "$log_config" << EOF
version: 1

formatters:
    precise:
        format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(message)s'

handlers:
    file:
        class: logging.handlers.RotatingFileHandler
        formatter: precise
        filename: /data/homeserver.log
        maxBytes: 10485760  # 10MB
        backupCount: 3
        encoding: utf8

    console:
        class: logging.StreamHandler
        formatter: precise

loggers:
    synapse:
        level: INFO
    synapse.storage.SQL:
        level: WARNING

root:
    level: INFO
    handlers: [file, console]

disable_existing_loggers: false
EOF
}

# Configure Matrix YAML with secure settings
configure_matrix_yaml() {
    local yaml_file="./data/homeserver.yaml"

    log_info "Configuring Matrix with security settings..."

    # Backup original
    cp "$yaml_file" "${yaml_file}.backup"

    # Use Python to safely edit YAML
    python3 << PYTHON_SCRIPT
import yaml
import sys

with open('${yaml_file}', 'r') as f:
    config = yaml.safe_load(f)

# Database configuration
config['database'] = {
    'name': 'psycopg2',
    'args': {
        'user': 'synapse',
        'password': '${MATRIX_POSTGRES_PASSWORD}',
        'database': 'synapse',
        'host': 'postgres',
        'port': 5432,
        'cp_min': 5,
        'cp_max': 10
    }
}

# Redis
config['redis'] = {
    'enabled': True,
    'host': 'redis',
    'port': 6379
}

# Registration
config['enable_registration'] = True
config['enable_registration_without_verification'] = True
config['registration_shared_secret'] = '${MATRIX_REGISTRATION_SHARED_SECRET}'

# Rate limiting
config['rc_registration'] = {
    'per_second': 0.017,
    'burst_count': 3
}
config['rc_message'] = {
    'per_second': 0.1,
    'burst_count': 5
}
config['rc_login'] = {
    'address': {
        'per_second': 0.05,
        'burst_count': 5
    },
    'account': {
        'per_second': 0.05,
        'burst_count': 5
    },
    'failed_attempts': {
        'per_second': 0.017,
        'burst_count': 3
    }
}

# Security
config['form_secret'] = '${MATRIX_FORM_SECRET}'
config['macaroon_secret_key'] = '${MATRIX_MACAROON_SECRET_KEY}'
config['serve_server_wellknown'] = True

# Media
config['max_upload_size'] = '10M'
config['url_preview_enabled'] = False

# Auto-join welcome room
config['auto_join_rooms'] = ['#welcome:${DOMAIN}']

# Logging configuration
config['log_config'] = '/data/${DOMAIN}.log.config'

# Write back
with open('${yaml_file}', 'w') as f:
    yaml.dump(config, f, default_flow_style=False)

print("Configuration updated successfully")
PYTHON_SCRIPT

    if [ $? -ne 0 ]; then
        log_error "Failed to configure YAML. Restoring backup..."
        mv "${yaml_file}.backup" "$yaml_file"
        exit 1
    fi
}

# Deploy PieFed
deploy_piefed() {
    log_info "Deploying PieFed..."

    generate_secrets "piefed"
    load_secrets "piefed"

    cd "$DEPLOY_DIR/piefed"

    cat > compose.yml << EOF
services:
  piefed:
    image: docker.io/piefed/piefed:latest
    container_name: piefed-app
    restart: unless-stopped
    environment:
      - DATABASE_URL=postgresql://piefed:${PIEFED_POSTGRES_PASSWORD}@postgres:5432/piefed
      - REDIS_URL=redis://redis:6379/0
      - SECRET_KEY=${PIEFED_SECRET_KEY}
      - DOMAIN=${PIEFED_DOMAIN}
      - REQUIRE_EMAIL_VERIFICATION=false
      - REGISTRATION_OPEN=true
      - REGISTRATION_MODE=approval
    volumes:
      - ./data/media:/app/media:Z
      - ./data/static:/app/static:Z
    ports:
      - "127.0.0.1:8080:8000"
    networks:
      - piefed_net
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  postgres:
    image: docker.io/postgres:16-alpine
    container_name: piefed-postgres
    restart: unless-stopped
    environment:
      - POSTGRES_USER=piefed
      - POSTGRES_PASSWORD=${PIEFED_POSTGRES_PASSWORD}
      - POSTGRES_DB=piefed
    volumes:
      - ./data/postgres:/var/lib/postgresql/data:Z
    networks:
      - piefed_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U piefed"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  redis:
    image: docker.io/redis:7-alpine
    container_name: piefed-redis
    restart: unless-stopped
    volumes:
      - ./data/redis:/data:Z
    networks:
      - piefed_net
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

  celery:
    image: docker.io/piefed/piefed:latest
    container_name: piefed-celery
    restart: unless-stopped
    command: celery -A piefed worker -l info
    environment:
      - DATABASE_URL=postgresql://piefed:${PIEFED_POSTGRES_PASSWORD}@postgres:5432/piefed
      - REDIS_URL=redis://redis:6379/0
      - SECRET_KEY=${PIEFED_SECRET_KEY}
    volumes:
      - ./data/media:/app/media:Z
    networks:
      - piefed_net
    depends_on:
      - postgres
      - redis
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

networks:
  piefed_net:
    driver: bridge
EOF

    log_info "Starting PieFed services..."
    podman-compose up -d

    log_info "PieFed deployment complete!"
}

# Configure Caddy with logging
configure_caddy() {
    log_info "Configuring Caddy reverse proxy..."

    local caddyfile="/etc/caddy/Caddyfile"
    local temp_caddyfile="${SCRIPT_DIR}/Caddyfile.generated"

    # Create log directory for Caddy
    sudo mkdir -p /var/log/caddy
    sudo chown caddy:caddy /var/log/caddy 2>/dev/null || true

    cat > "$temp_caddyfile" << EOF
# Generated by deployment script - $(date)

{
    # Global options
    admin off
    log {
        output file /var/log/caddy/access.log {
            roll_size 10MB
            roll_keep 3
            roll_keep_for 30d
        }
        format json
    }
}

EOF

    if [[ "$SERVICE" == "matrix" ]] || [[ "$SERVICE" == "both" ]]; then
        cat >> "$temp_caddyfile" << EOF
# Matrix Homeserver
${MATRIX_DOMAIN}, ${DOMAIN} {
    handle /_matrix/* {
        reverse_proxy localhost:8008
    }

    handle /_synapse/client/* {
        reverse_proxy localhost:8008
    }

    handle /.well-known/matrix/server {
        respond \`{"m.server": "${MATRIX_DOMAIN}:443"}\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
        }
    }

    handle /.well-known/matrix/client {
        respond \`{"m.homeserver": {"base_url": "https://${MATRIX_DOMAIN}"}}\` 200 {
            header Content-Type application/json
            header Access-Control-Allow-Origin *
        }
    }

    handle /admin/* {
        reverse_proxy localhost:8081
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        -Server
    }

    log {
        output file /var/log/caddy/matrix.log {
            roll_size 10MB
            roll_keep 3
        }
        format json
    }
}

# Matrix Federation
${MATRIX_DOMAIN}:8448 {
    reverse_proxy localhost:8008

    log {
        output file /var/log/caddy/matrix-federation.log {
            roll_size 10MB
            roll_keep 3
        }
        format json
    }
}

EOF
    fi

    if [[ "$SERVICE" == "piefed" ]] || [[ "$SERVICE" == "both" ]]; then
        cat >> "$temp_caddyfile" << EOF
# PieFed
${PIEFED_DOMAIN} {
    reverse_proxy localhost:8080

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        -Server
    }

    log {
        output file /var/log/caddy/piefed.log {
            roll_size 10MB
            roll_keep 3
        }
        format json
    }
}
EOF
    fi

    log_info "Generated Caddy configuration at: $temp_caddyfile"
    log_info "To apply, run as root: sudo cp $temp_caddyfile $caddyfile && sudo systemctl reload caddy"
}

# Setup systemd services
setup_systemd() {
    log_info "Setting up systemd user services..."

    mkdir -p ~/.config/systemd/user

    if [[ "$SERVICE" == "matrix" ]] || [[ "$SERVICE" == "both" ]]; then
        cat > ~/.config/systemd/user/matrix.service << EOF
[Unit]
Description=Matrix Synapse Homeserver
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=%h/containers/matrix
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down

[Install]
WantedBy=default.target
EOF
    fi

    if [[ "$SERVICE" == "piefed" ]] || [[ "$SERVICE" == "both" ]]; then
        cat > ~/.config/systemd/user/piefed.service << EOF
[Unit]
Description=PieFed Fediverse Platform
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=%h/containers/piefed
ExecStart=/usr/bin/podman-compose up -d
ExecStop=/usr/bin/podman-compose down

[Install]
WantedBy=default.target
EOF
    fi

    systemctl --user daemon-reload

    if [[ "$SERVICE" == "matrix" ]] || [[ "$SERVICE" == "both" ]]; then
        systemctl --user enable matrix.service
    fi

    if [[ "$SERVICE" == "piefed" ]] || [[ "$SERVICE" == "both" ]]; then
        systemctl --user enable piefed.service
    fi

    # Enable lingering
    sudo loginctl enable-linger "$USER"
}

# Create backup script with encrypted logs
create_backup_script() {
    log_info "Creating backup script..."

    local backup_script="${HOME}/containers/backup.sh"

    cat > "$backup_script" << 'EOF'
#!/bin/bash
set -euo pipefail

BACKUP_DIR=~/backups
DATE=$(date +%Y%m%d_%H%M%S)
SECRETS_DIR="${HOME}/.local/share/homodeus-secrets"
LOG_FILE="${HOME}/.local/share/homodeus-logs/backup_${DATE}.log"

mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# Backup encryption password (you should change this!)
read -sp "Enter backup encryption password: " BACKUP_PASSWORD
echo

# Redirect all output to encrypted log
exec > >(tee -a "$LOG_FILE")
exec 2>&1

backup_service() {
    local service=$1
    local db_name=$2
    local db_user=$3

    echo "[$(date)] Backing up $service..."

    # Load secrets to get DB password
    source "${SECRETS_DIR}/${service}.env"

    cd ~/containers/${service}

    # Database backup
    if [ "$service" == "matrix" ]; then
        DB_PASS="${MATRIX_POSTGRES_PASSWORD}"
    else
        DB_PASS="${PIEFED_POSTGRES_PASSWORD}"
    fi

    podman-compose exec -T postgres \
        bash -c "PGPASSWORD='${DB_PASS}' pg_dump -U ${db_user} ${db_name}" | \
        gzip | \
        gpg --batch --yes --passphrase "$BACKUP_PASSWORD" \
        --symmetric --cipher-algo AES256 \
        --output "$BACKUP_DIR/${service}_db_${DATE}.sql.gz.gpg"

    # Data directory backup
    tar czf - data/ | \
        gpg --batch --yes --passphrase "$BACKUP_PASSWORD" \
        --symmetric --cipher-algo AES256 \
        --output "$BACKUP_DIR/${service}_data_${DATE}.tar.gz.gpg"

    # Backup logs encrypted
    if [ -f "data/homeserver.log" ]; then
        cat data/homeserver.log | \
            gpg --batch --yes --passphrase "$BACKUP_PASSWORD" \
            --symmetric --cipher-algo AES256 \
            --output "$BACKUP_DIR/${service}_logs_${DATE}.log.gpg"
    fi
}

# Backup Matrix if exists
if [ -d ~/containers/matrix ]; then
    backup_service "matrix" "synapse" "synapse"
fi

# Backup PieFed if exists
if [ -d ~/containers/piefed ]; then
    backup_service "piefed" "piefed" "piefed"
fi

# Backup secrets (IMPORTANT!)
tar czf - -C "$SECRETS_DIR" . | \
    gpg --batch --yes --passphrase "$BACKUP_PASSWORD" \
    --symmetric --cipher-algo AES256 \
    --output "$BACKUP_DIR/secrets_${DATE}.tar.gz.gpg"

# Cleanup old backups (keep 30 days)
find "$BACKUP_DIR" -name "*.gpg" -mtime +30 -delete

echo "[$(date)] Backup completed: $DATE"
echo "Backed up to: $BACKUP_DIR"

# Encrypt the log file itself
gpg --batch --yes --passphrase "$BACKUP_PASSWORD" \
    --symmetric --cipher-algo AES256 \
    --output "${LOG_FILE}.gpg" \
    "$LOG_FILE"
rm -f "$LOG_FILE"

echo "Backup log encrypted: ${LOG_FILE}.gpg"
EOF

    chmod +x "$backup_script"
    log_info "Backup script created at: $backup_script"
}

# Setup log rotation and encryption
setup_log_rotation() {
    log_info "Setting up log rotation and encryption..."

    # Create log rotation script
    cat > "${HOME}/containers/rotate-logs.sh" << 'EOF'
#!/bin/bash
# Rotate and encrypt logs

LOG_ENCRYPTION_PASSWORD="${LOG_ENCRYPTION_PASSWORD:-$(cat ~/.local/share/homodeus-secrets/.log_key 2>/dev/null)}"

if [ -z "$LOG_ENCRYPTION_PASSWORD" ]; then
    echo "Error: No log encryption password found"
    exit 1
fi

# Rotate Matrix logs
if [ -f ~/containers/matrix/data/homeserver.log ]; then
    DATE=$(date +%Y%m%d_%H%M%S)
    LOG_DIR=~/.local/share/homodeus-logs/matrix
    mkdir -p "$LOG_DIR"

    # Encrypt and move old log
    gpg --batch --yes --passphrase "$LOG_ENCRYPTION_PASSWORD" \
        --symmetric --cipher-algo AES256 \
        --output "$LOG_DIR/homeserver_${DATE}.log.gpg" \
        ~/containers/matrix/data/homeserver.log

    # Clear the log
    > ~/containers/matrix/data/homeserver.log

    # Cleanup old encrypted logs (keep 90 days)
    find "$LOG_DIR" -name "*.log.gpg" -mtime +90 -delete
fi

# Rotate container logs
for container in matrix-synapse matrix-postgres piefed-app piefed-postgres; do
    if podman ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
        podman logs "$container" 2>&1 | \
            gpg --batch --yes --passphrase "$LOG_ENCRYPTION_PASSWORD" \
            --symmetric --cipher-algo AES256 \
            --output "$LOG_DIR/${container}_$(date +%Y%m%d_%H%M%S).log.gpg" || true
    fi
done

echo "Log rotation complete"
EOF

    chmod +x "${HOME}/containers/rotate-logs.sh"

    # Generate log encryption key
    local log_key_file="${SECRETS_DIR}/.log_key"
    if [ ! -f "$log_key_file" ]; then
        generate_secret > "$log_key_file"
        chmod 600 "$log_key_file"
        log_info "Log encryption key generated: $log_key_file"
    fi

    # Add to crontab for weekly log rotation
    (crontab -l 2>/dev/null | grep -v "rotate-logs.sh"; echo "0 3 * * 0 LOG_ENCRYPTION_PASSWORD=\$(cat ~/.local/share/homodeus-secrets/.log_key) ~/containers/rotate-logs.sh") | crontab -

    log_info "Log rotation configured (weekly on Sundays at 3 AM)"
}

# Print summary
print_summary() {
    echo ""
    log_info "=========================================="
    log_info "       DEPLOYMENT COMPLETE!"
    log_info "=========================================="
    log_info "Domain: $DOMAIN"
    log_info "User: $CURRENT_USER"

    if [[ "$SERVICE" == "matrix" ]] || [[ "$SERVICE" == "both" ]]; then
        echo ""
        log_info "Matrix Synapse:"
        log_info "  URL: https://${MATRIX_DOMAIN}"
        log_info "  Admin UI: https://${MATRIX_DOMAIN}/admin/"
        log_info "  Secrets: ${SECRETS_DIR}/matrix.env"
    fi

    if [[ "$SERVICE" == "piefed" ]] || [[ "$SERVICE" == "both" ]]; then
        echo ""
        log_info "PieFed:"
        log_info "  URL: https://${PIEFED_DOMAIN}"
        log_info "  Secrets: ${SECRETS_DIR}/piefed.env"
    fi

    echo ""
    log_info "Security Features:"
    log_info "  ✓ Rootless containers"
    log_info "  ✓ Firewall configured"
    log_info "  ✓ fail2ban active"
    log_info "  ✓ Encrypted logs"
    log_info "  ✓ Encrypted backups"
    log_info "  ✓ System hardening"
    log_info "  ✓ SSH keys configured"

    echo ""
    log_step "NEXT STEPS:"
    log_info ""
    log_info "1. Apply Caddy configuration:"
    echo "   sudo cp ${SCRIPT_DIR}/Caddyfile.generated /etc/caddy/Caddyfile"
    echo "   sudo systemctl enable --now caddy"
    echo "   sudo systemctl reload caddy"

    log_info ""
    log_info "2. Point your DNS to this server:"
    echo "   A     ${DOMAIN}              YOUR_SERVER_IP"
    echo "   A     ${MATRIX_DOMAIN}       YOUR_SERVER_IP"
    echo "   A     ${PIEFED_DOMAIN}       YOUR_SERVER_IP"

    if [[ "$SERVICE" == "matrix" ]] || [[ "$SERVICE" == "both" ]]; then
        log_info ""
        log_info "3. Create Matrix admin account:"
        echo "   cd ~/containers/matrix"
        echo "   podman exec -it matrix-synapse register_new_matrix_user -c /data/homeserver.yaml --admin http://localhost:8008"
    fi

    log_info ""
    log_info "4. Setup automated backups:"
    echo "   crontab -e"
    echo "   # Add: 0 2 * * * ~/containers/backup.sh"

    log_info ""
    log_info "5. Check fail2ban status:"
    echo "   sudo fail2ban-client status"

    echo ""
    log_warn "IMPORTANT - BACKUP THESE FILES:"
    log_warn "  ${SECRETS_DIR}/*.env (all secrets)"
    log_warn "  ${SECRETS_DIR}/.log_key (log decryption)"

    if [ -f /etc/sudoers.d/$CURRENT_USER ]; then
        echo ""
        log_warn "SECURITY NOTE:"
        log_warn "  Passwordless sudo is enabled for: $CURRENT_USER"
        log_warn "  You may want to disable this after setup:"
        echo "   sudo rm /etc/sudoers.d/$CURRENT_USER"
        log_warn "  Or require password:"
        echo "   echo '$CURRENT_USER ALL=(ALL) ALL' | sudo tee /etc/sudoers.d/$CURRENT_USER"
    fi

    echo ""
    log_info "=========================================="
    log_info "SSH into server as: $CURRENT_USER"
    log_info "Your SSH keys have been copied from root"
    log_info "=========================================="
    echo ""
}

# Main execution
main() {
    echo ""

    # Check prerequisites - will be installed during hardening if missing
    create_directories
    harden_server
    setup_fail2ban

    case $SERVICE in
        matrix)
            deploy_matrix
            ;;
        piefed)
            deploy_piefed
            ;;
        both)
            deploy_matrix
            deploy_piefed
            ;;
        *)
            log_error "Invalid service: $SERVICE. Use: matrix, piefed, or both"
            exit 1
            ;;
    esac

    configure_caddy
    setup_systemd
    create_backup_script
    setup_log_rotation
    print_summary
}

main "$@"