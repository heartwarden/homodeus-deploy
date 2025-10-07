#!/bin/bash
set -euo pipefail

# Homodeus Health Check Script
# Usage: ./health-check.sh [--verbose] [--json] [--service matrix|piefed|all]

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
VERBOSE=false
JSON_OUTPUT=false
CHECK_SERVICE="all"
TIMEOUT=10

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --verbose|-v)
            VERBOSE=true
            shift
            ;;
        --json|-j)
            JSON_OUTPUT=true
            shift
            ;;
        --service|-s)
            CHECK_SERVICE="$2"
            shift 2
            ;;
        --timeout|-t)
            TIMEOUT="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--verbose] [--json] [--service matrix|piefed|all] [--timeout seconds]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Logging functions
log_info() {
    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${GREEN}[INFO]${NC} $1"
    fi
}

log_warn() {
    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${YELLOW}[WARN]${NC} $1"
    fi
}

log_error() {
    if [ "$JSON_OUTPUT" = false ]; then
        echo -e "${RED}[ERROR]${NC} $1"
    fi
}

log_debug() {
    if [ "$VERBOSE" = true ] && [ "$JSON_OUTPUT" = false ]; then
        echo -e "${BLUE}[DEBUG]${NC} $1"
    fi
}

# Health check results
declare -A HEALTH_RESULTS
OVERALL_STATUS="healthy"

# Add result to health check
add_result() {
    local component="$1"
    local status="$2"
    local message="$3"

    HEALTH_RESULTS["$component"]="$status:$message"

    if [ "$status" != "healthy" ]; then
        OVERALL_STATUS="unhealthy"
    fi

    if [ "$VERBOSE" = true ] || [ "$status" != "healthy" ]; then
        case $status in
            healthy)
                log_info "✓ $component: $message"
                ;;
            warning)
                log_warn "⚠ $component: $message"
                ;;
            critical)
                log_error "✗ $component: $message"
                ;;
        esac
    fi
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check HTTP endpoint
check_http() {
    local url="$1"
    local expected_code="${2:-200}"
    local name="$3"

    log_debug "Checking HTTP endpoint: $url"

    if curl -s -f -m "$TIMEOUT" -o /dev/null -w "%{http_code}" "$url" | grep -q "^$expected_code$"; then
        add_result "$name" "healthy" "HTTP $expected_code OK"
        return 0
    else
        add_result "$name" "critical" "HTTP endpoint unreachable or wrong status code"
        return 1
    fi
}

# Check container status
check_container() {
    local container_name="$1"
    local component_name="$2"

    log_debug "Checking container: $container_name"

    if ! command_exists podman; then
        add_result "$component_name" "critical" "Podman not available"
        return 1
    fi

    local status
    status=$(podman inspect "$container_name" --format='{{.State.Status}}' 2>/dev/null || echo "not_found")

    case $status in
        running)
            add_result "$component_name" "healthy" "Container running"
            return 0
            ;;
        exited)
            add_result "$component_name" "critical" "Container exited"
            return 1
            ;;
        not_found)
            add_result "$component_name" "critical" "Container not found"
            return 1
            ;;
        *)
            add_result "$component_name" "warning" "Container status: $status"
            return 1
            ;;
    esac
}

# Check database connectivity
check_database() {
    local container_name="$1"
    local db_name="$2"
    local db_user="$3"
    local component_name="$4"

    log_debug "Checking database: $db_name in $container_name"

    if ! podman exec "$container_name" pg_isready -U "$db_user" -d "$db_name" >/dev/null 2>&1; then
        add_result "$component_name" "critical" "Database not ready"
        return 1
    fi

    # Check if we can connect and run a simple query
    if ! podman exec "$container_name" psql -U "$db_user" -d "$db_name" -c "SELECT 1;" >/dev/null 2>&1; then
        add_result "$component_name" "critical" "Database connection failed"
        return 1
    fi

    add_result "$component_name" "healthy" "Database responding"
    return 0
}

# Check Redis connectivity
check_redis() {
    local container_name="$1"
    local component_name="$2"

    log_debug "Checking Redis: $container_name"

    if ! podman exec "$container_name" redis-cli ping | grep -q "PONG"; then
        add_result "$component_name" "critical" "Redis not responding"
        return 1
    fi

    add_result "$component_name" "healthy" "Redis responding"
    return 0
}

# Check disk space
check_disk_space() {
    local path="$1"
    local component_name="$2"
    local warning_threshold="${3:-80}"
    local critical_threshold="${4:-90}"

    log_debug "Checking disk space: $path"

    if [ ! -d "$path" ]; then
        add_result "$component_name" "warning" "Directory not found: $path"
        return 1
    fi

    local usage
    usage=$(df "$path" | tail -1 | awk '{print $5}' | sed 's/%//')

    if [ "$usage" -ge "$critical_threshold" ]; then
        add_result "$component_name" "critical" "Disk usage ${usage}% (critical: >${critical_threshold}%)"
        return 1
    elif [ "$usage" -ge "$warning_threshold" ]; then
        add_result "$component_name" "warning" "Disk usage ${usage}% (warning: >${warning_threshold}%)"
        return 1
    else
        add_result "$component_name" "healthy" "Disk usage ${usage}%"
        return 0
    fi
}

# Check memory usage
check_memory() {
    log_debug "Checking system memory"

    local total_mem
    local free_mem
    local usage_percent

    total_mem=$(free -m | awk '/^Mem:/ {print $2}')
    free_mem=$(free -m | awk '/^Mem:/ {print $7}')
    usage_percent=$(( (total_mem - free_mem) * 100 / total_mem ))

    if [ "$usage_percent" -ge 95 ]; then
        add_result "system_memory" "critical" "Memory usage ${usage_percent}%"
        return 1
    elif [ "$usage_percent" -ge 85 ]; then
        add_result "system_memory" "warning" "Memory usage ${usage_percent}%"
        return 1
    else
        add_result "system_memory" "healthy" "Memory usage ${usage_percent}%"
        return 0
    fi
}

# Check load average
check_load() {
    log_debug "Checking system load"

    local load_1min
    local cpu_cores

    load_1min=$(uptime | awk -F'load average:' '{print $2}' | awk '{print $1}' | sed 's/,//')
    cpu_cores=$(nproc)

    # Convert to integer for comparison (multiply by 100)
    local load_int
    load_int=$(echo "$load_1min * 100" | bc 2>/dev/null || echo "0")
    local threshold_warning=$((cpu_cores * 150))  # 1.5 * cores
    local threshold_critical=$((cpu_cores * 200)) # 2.0 * cores

    if [ "$load_int" -ge "$threshold_critical" ]; then
        add_result "system_load" "critical" "Load average ${load_1min} (cores: ${cpu_cores})"
        return 1
    elif [ "$load_int" -ge "$threshold_warning" ]; then
        add_result "system_load" "warning" "Load average ${load_1min} (cores: ${cpu_cores})"
        return 1
    else
        add_result "system_load" "healthy" "Load average ${load_1min} (cores: ${cpu_cores})"
        return 0
    fi
}

# Check fail2ban status
check_fail2ban() {
    log_debug "Checking fail2ban"

    if ! command_exists fail2ban-client; then
        add_result "fail2ban" "warning" "fail2ban not installed"
        return 1
    fi

    if ! sudo fail2ban-client status >/dev/null 2>&1; then
        add_result "fail2ban" "critical" "fail2ban not running"
        return 1
    fi

    local banned_count
    banned_count=$(sudo fail2ban-client status | grep -o "Banned: [0-9]*" | awk '{sum += $2} END {print sum+0}')

    add_result "fail2ban" "healthy" "Active, ${banned_count} IPs banned"
    return 0
}

# Check Caddy status
check_caddy() {
    log_debug "Checking Caddy"

    if ! systemctl is-active --quiet caddy 2>/dev/null; then
        add_result "caddy" "critical" "Caddy service not running"
        return 1
    fi

    add_result "caddy" "healthy" "Service running"
    return 0
}

# Check Matrix health
check_matrix() {
    log_info "Checking Matrix Synapse..."

    # Check if Matrix directory exists
    if [ ! -d "$HOME/containers/matrix" ]; then
        add_result "matrix_deployment" "warning" "Matrix not deployed"
        return 1
    fi

    # Check containers
    check_container "matrix-synapse" "matrix_synapse"
    check_container "matrix-postgres" "matrix_postgres"
    check_container "matrix-redis" "matrix_redis"
    check_container "matrix-admin" "matrix_admin"

    # Check databases and services
    check_database "matrix-postgres" "synapse" "synapse" "matrix_database"
    check_redis "matrix-redis" "matrix_redis_connectivity"

    # Check HTTP endpoints
    check_http "http://localhost:8008/_matrix/client/versions" "200" "matrix_api"
    check_http "http://localhost:8081/" "200" "matrix_admin_ui"

    # Check disk space
    check_disk_space "$HOME/containers/matrix/data" "matrix_data_disk"

    # Check Matrix-specific metrics
    check_matrix_federation
}

# Check Matrix federation
check_matrix_federation() {
    log_debug "Checking Matrix federation"

    # Try to get federation version - this doesn't require authentication
    if curl -s -m "$TIMEOUT" "http://localhost:8008/_matrix/federation/v1/version" | grep -q "server"; then
        add_result "matrix_federation" "healthy" "Federation endpoint responding"
    else
        add_result "matrix_federation" "warning" "Federation endpoint not responding"
    fi
}

# Check PieFed health
check_piefed() {
    log_info "Checking PieFed..."

    # Check if PieFed directory exists
    if [ ! -d "$HOME/containers/piefed" ]; then
        add_result "piefed_deployment" "warning" "PieFed not deployed"
        return 1
    fi

    # Check containers
    check_container "piefed-app" "piefed_app"
    check_container "piefed-postgres" "piefed_postgres"
    check_container "piefed-redis" "piefed_redis"
    check_container "piefed-celery" "piefed_celery"

    # Check databases and services
    check_database "piefed-postgres" "piefed" "piefed" "piefed_database"
    check_redis "piefed-redis" "piefed_redis_connectivity"

    # Check HTTP endpoints
    check_http "http://localhost:8080/" "200" "piefed_web"

    # Check disk space
    check_disk_space "$HOME/containers/piefed/data" "piefed_data_disk"
}

# Check system health
check_system() {
    log_info "Checking system health..."

    check_memory
    check_load
    check_disk_space "/" "system_root_disk"
    check_disk_space "$HOME" "system_home_disk"
    check_fail2ban
    check_caddy
}

# Generate JSON output
output_json() {
    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"overall_status\": \"$OVERALL_STATUS\","
    echo "  \"checks\": {"

    local first=true
    for component in "${!HEALTH_RESULTS[@]}"; do
        if [ "$first" = false ]; then
            echo ","
        fi
        first=false

        local status="${HEALTH_RESULTS[$component]%%:*}"
        local message="${HEALTH_RESULTS[$component]#*:}"

        echo -n "    \"$component\": {"
        echo -n "\"status\": \"$status\", "
        echo -n "\"message\": \"$message\""
        echo -n "}"
    done

    echo ""
    echo "  }"
    echo "}"
}

# Generate text summary
output_summary() {
    echo ""
    echo "=========================================="
    echo "Health Check Summary"
    echo "=========================================="
    echo "Overall Status: $OVERALL_STATUS"
    echo "Timestamp: $(date)"
    echo ""

    local healthy_count=0
    local warning_count=0
    local critical_count=0

    for component in "${!HEALTH_RESULTS[@]}"; do
        local status="${HEALTH_RESULTS[$component]%%:*}"
        case $status in
            healthy) ((healthy_count++)) ;;
            warning) ((warning_count++)) ;;
            critical) ((critical_count++)) ;;
        esac
    done

    echo "Results:"
    echo "  ✓ Healthy: $healthy_count"
    echo "  ⚠ Warning: $warning_count"
    echo "  ✗ Critical: $critical_count"
    echo ""

    if [ "$critical_count" -gt 0 ]; then
        echo "Critical Issues:"
        for component in "${!HEALTH_RESULTS[@]}"; do
            local status="${HEALTH_RESULTS[$component]%%:*}"
            local message="${HEALTH_RESULTS[$component]#*:}"
            if [ "$status" = "critical" ]; then
                echo "  ✗ $component: $message"
            fi
        done
        echo ""
    fi

    if [ "$warning_count" -gt 0 ]; then
        echo "Warnings:"
        for component in "${!HEALTH_RESULTS[@]}"; do
            local status="${HEALTH_RESULTS[$component]%%:*}"
            local message="${HEALTH_RESULTS[$component]#*:}"
            if [ "$status" = "warning" ]; then
                echo "  ⚠ $component: $message"
            fi
        done
        echo ""
    fi

    echo "=========================================="
}

# Main execution
main() {
    if [ "$JSON_OUTPUT" = false ]; then
        log_info "Homodeus Health Check v${VERSION}"
        log_info "Checking service: $CHECK_SERVICE"
        echo ""
    fi

    # Run health checks based on service selection
    case $CHECK_SERVICE in
        matrix)
            check_matrix
            check_system
            ;;
        piefed)
            check_piefed
            check_system
            ;;
        all)
            check_matrix
            check_piefed
            check_system
            ;;
        *)
            log_error "Invalid service: $CHECK_SERVICE. Use: matrix, piefed, or all"
            exit 1
            ;;
    esac

    # Output results
    if [ "$JSON_OUTPUT" = true ]; then
        output_json
    else
        output_summary
    fi

    # Exit with appropriate code
    if [ "$OVERALL_STATUS" = "healthy" ]; then
        exit 0
    else
        exit 1
    fi
}

# Run main function
main "$@"