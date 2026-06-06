#!/usr/bin/env bash
# =============================================================================
# n8n AI Stack Deployer
# =============================================================================
# Enterprise n8n + AI stack (Qdrant, MinIO, LLM APIs) with Docker Compose, nginx, SSL, SRE
# Author: MartiPE
# Version: 1.0.0
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

if [[ ${EUID:-0} -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        echo "[INFO] Elevating to root with sudo..."
        exec sudo bash "$0" "$@"
    fi
    echo "[ERROR] This script must be run as root or with sudo."
    exit 1
fi

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================

readonly APP_NAME="n8n-enterprise"
readonly SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEPLOY_USER="${SUDO_USER:-root}"
BASE_DIR="/opt/n8n"
BACKUP_DIR="/opt/backups/n8n"
# Non-root sudo installs use the invoking user's home directory.
if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    DEPLOY_USER="${SUDO_USER}"
    BASE_DIR="/home/${DEPLOY_USER}/n8n"
    BACKUP_DIR="${BASE_DIR}/backups"
fi
LOG_DIR="/var/log/n8n"
LOG_FILE="${LOG_DIR}/deployer.log"
ENV_FILE="${BASE_DIR}/.env"
COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
# Reverse proxies in front of n8n (nginx only when Cloudflare is DNS-only / grey cloud).
N8N_PROXY_HOPS="${N8N_PROXY_HOPS:-1}"
readonly NGINX_SITE="/etc/nginx/sites-available/n8n.conf"
readonly NGINX_ENABLED="/etc/nginx/sites-enabled/n8n.conf"
readonly BACKUP_SCRIPT="/usr/local/bin/n8n-backup.sh"
SECRETS_DIR="${BASE_DIR}/secrets"
RELEASE_FILE="${BASE_DIR}/.n8n-release"
ENV_TEMPLATE="${BASE_DIR}/.env.example"

if [[ -d "${SCRIPT_DIR}/deployer-lib" ]]; then
    for _deployer_lib in "${SCRIPT_DIR}"/deployer-lib/*.sh; do
        # shellcheck disable=SC1090
        [[ -f "$_deployer_lib" ]] && source "$_deployer_lib"
    done
    unset _deployer_lib
fi

# Color codes
readonly RED='\033[0;31m'
readonly GRN='\033[0;32m'
readonly YEL='\033[1;33m'
readonly BLU='\033[0;34m'
readonly CYN='\033[0;36m'
readonly MAG='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# =============================================================================
# GLOBAL VARIABLES (with defaults)
# =============================================================================

DOMAIN="${DOMAIN:-}"
SUBDOMAIN="${SUBDOMAIN:-n8n}"
ENABLE_QDRANT="${ENABLE_QDRANT:-true}"
ENABLE_MINIO="${ENABLE_MINIO:-true}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
ENABLE_NGINX_RATE_LIMIT="${ENABLE_NGINX_RATE_LIMIT:-false}"
NGINX_RATE_LIMIT="${NGINX_RATE_LIMIT:-30}"
ENABLE_N8N_CSP="${ENABLE_N8N_CSP:-false}"
N8N_RUNNERS_ENABLED="${N8N_RUNNERS_ENABLED:-false}"
SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASS=""
SMTP_SENDER=""
SSL_EMAIL=""
N8N_ADMIN_PASS=""
POSTGRES_PASSWORD=""
REDIS_PASSWORD=""
FQDN=""
ENCRYPTION_KEY=""
BACKUP_ENABLED=true
AUTO_SSL=true
WORKERS=1
LOG_LEVEL="INFO"
OPENAI_API_KEY=""
CLAUDE_API_KEY=""
GEMINI_API_KEY=""
AI_ROUTER_MODE="api_only"
AI_PRIMARY="openai"
AI_SECONDARY="gemini"
AI_COST_MODE="balanced"
ENABLE_MONITORING=false
MINIO_PASSWORD=""
MINIO_ROOT_USER="admin"
POSTGRES_VERSION="16"
REDIS_VERSION="7"
N8N_VERSION="${N8N_VERSION:-2.23.2}"
MINIO_VERSION="${MINIO_VERSION:-RELEASE.2025-09-07T16-13-09Z}"
PROMETHEUS_VERSION="v3.4.2"
GRAFANA_VERSION="12.0.2"
QDRANT_VERSION="v1.15.2"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Ensure log directory exists before writing
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE" 2>/dev/null || true
    
    # Write to log file
    echo "${timestamp} [${level}] ${message}" >> "$LOG_FILE"
    
    # Print to stdout with colors
    case "$level" in
        INFO)  echo -e "${BLU}[INFO]${NC}  ${message}" ;;
        OK)    echo -e "${GRN}[OK]${NC}   ${message}" ;;
        WARN)  echo -e "${YEL}[WARN]${NC}  ${message}" ;;
        ERROR) echo -e "${RED}[ERROR]${NC} ${message}" ;;
        DEBUG) [[ "$LOG_LEVEL" == "DEBUG" ]] && echo -e "${MAG}[DEBUG]${NC} ${message}" ;;
    esac
}

die() {
    log ERROR "$*"
    exit 1
}

# Enhanced error handler with stack trace
error_handler() {
    local line_no=$1
    local error_code=$2
    log ERROR "Error occurred in script at line ${line_no}, exit code: ${error_code}"
    log ERROR "Call stack:"
    local i=0
    while caller $i >/dev/null 2>&1; do
        log ERROR "  $(caller $i)"
        ((i++))
    done
    exit "$error_code"
}

# =============================================================================
# PRE-INSTALLATION CHECKS
# =============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root"
    fi
    log OK "Running as root"
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
    else
        die "Cannot determine OS version"
    fi
    
    case "$ID" in
        ubuntu|debian)
            log OK "Detected ${ID} ${VERSION_ID}"
            ;;
        *)
            die "Unsupported OS: ${ID}. Only Ubuntu/Debian are supported"
            ;;
    esac
}

check_dependencies() {
    log INFO "Checking and installing dependencies..."
    
    export DEBIAN_FRONTEND=noninteractive
    
    local deps=(
        curl
        wget
        jq
        unzip
        tar
        ca-certificates
        gnupg
        lsb-release
        software-properties-common
        openssl
        cron
        ufw
        apt-transport-https
        nginx
        certbot
        python3-certbot-nginx
        fail2ban
        rsync
        bc
    )
    
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null && ! dpkg -l "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log INFO "Installing missing dependencies: ${missing[*]}"
        apt-get update -y
        apt-get install -y "${missing[@]}"
    else
        log OK "All dependencies already installed"
    fi
}

check_resources() {
    log INFO "Checking system resources..."
    
    local mem_total
    mem_total=$(free -m | awk '/^Mem:/{print $2}')
    if [[ "$mem_total" -lt 1024 ]]; then
        log WARN "Low memory detected: ${mem_total}MB. Recommended: 2GB+"
    fi
    
    local disk_avail
    mkdir -p "$BASE_DIR" 2>/dev/null || true
    disk_avail=$(df -BG "${BASE_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    if [[ "$disk_avail" -lt 10 ]]; then
        log WARN "Low disk space: ${disk_avail}GB available. Recommended: 20GB+"
    fi
    
    log OK "Resource check complete"
}

# =============================================================================
# DOCKER INSTALLATION
# =============================================================================

install_docker() {
    if command -v docker &>/dev/null; then
        log OK "Docker already installed: $(docker --version)"
        return 0
    fi
    
    log INFO "Installing Docker Engine..."
    
    # Add Docker GPG key
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || die "Failed to download Docker GPG key"
    chmod a+r /etc/apt/keyrings/docker.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list
    
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || die "Failed to install Docker"
    
    # Enable and start Docker
    systemctl enable docker
    systemctl start docker
    
    # Configure Docker daemon
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'DOCKEREOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    },
    "storage-driver": "overlay2",
    "live-restore": true
}
DOCKEREOF
    
    systemctl restart docker
    
    log OK "Docker installed successfully"
}

# =============================================================================
# DIRECTORY & PERMISSIONS
# =============================================================================

ensure_dirs() {
    log INFO "Creating directory structure..."
    
    mkdir -p "$BASE_DIR" "$BACKUP_DIR" "$LOG_DIR"
    mkdir -p "$(dirname "$LOG_FILE")"
    if declare -F ensure_secrets_dir >/dev/null; then
        ensure_secrets_dir
    else
        mkdir -p "$SECRETS_DIR" && chmod 700 "$SECRETS_DIR"
    fi
    if declare -F install_deployer_libs >/dev/null; then
        install_deployer_libs
    fi
    
    chmod 750 "$BASE_DIR" "$BACKUP_DIR" "$LOG_DIR"
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"

    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        chown -R "$SUDO_USER:$SUDO_USER" "$BASE_DIR" "$BACKUP_DIR" || true
    fi
    if declare -F setup_logrotate >/dev/null; then
        setup_logrotate
    fi
    
    log OK "Directory structure created"
}

# =============================================================================
# INPUT VALIDATION & GATHERING
# =============================================================================

validate_domain() {
    local domain="$1"
    if [[ ! "$domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]?(\.[a-zA-Z]{2,})+$ ]]; then
        return 1
    fi
    return 0
}

validate_email() {
    local email="$1"
    if [[ ! "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        return 1
    fi
    return 0
}

validate_password() {
    local pass="$1"
    if [[ ${#pass} -lt 12 ]]; then
        return 1
    fi
    return 0
}

ask_inputs() {
    echo ""
    echo -e "${CYN}========================================${NC}"
    echo -e "${CYN}  n8n Enterprise Installation${NC}"
    echo -e "${CYN}========================================${NC}"
    echo ""
    
    while [[ -z "$DOMAIN" ]]; do
        read -r -p "Domain (e.g., example.com): " DOMAIN
    done
    if ! validate_domain "$DOMAIN"; then
        die "Invalid domain format: ${DOMAIN}"
    fi
    
    # Subdomain
    read -r -p "Subdomain [n8n]: " SUBDOMAIN
    SUBDOMAIN="${SUBDOMAIN:-n8n}"
    
    # SSL Email
    while [[ -z "$SSL_EMAIL" ]]; do
        read -r -p "SSL Certificate Email: " SSL_EMAIL
        if ! validate_email "$SSL_EMAIL"; then
            log ERROR "Invalid email format. Please try again."
            SSL_EMAIL=""
        fi
    done
    
    # Owner password (used when creating the first n8n user on initial UI setup)
    while [[ -z "$N8N_ADMIN_PASS" ]]; do
        read -r -s -p "n8n owner password for first login setup (min 12 chars): " N8N_ADMIN_PASS
        echo
        if ! validate_password "$N8N_ADMIN_PASS"; then
            log ERROR "Password must be at least 12 characters"
            N8N_ADMIN_PASS=""
        fi
    done
    
    # PostgreSQL Password
    while [[ -z "$POSTGRES_PASSWORD" ]]; do
        read -r -s -p "PostgreSQL Password (min 12 chars): " POSTGRES_PASSWORD
        echo
        if ! validate_password "$POSTGRES_PASSWORD"; then
            log ERROR "Password must be at least 12 characters"
            POSTGRES_PASSWORD=""
        fi
    done
    
    # Redis Password
    while [[ -z "$REDIS_PASSWORD" ]]; do
        read -r -s -p "Redis Password (min 12 chars): " REDIS_PASSWORD
        echo
        if ! validate_password "$REDIS_PASSWORD"; then
            log ERROR "Password must be at least 12 characters"
            REDIS_PASSWORD=""
        fi
    done

    read -r -p "AI Router Mode [api_only]: " AI_ROUTER_MODE
    AI_ROUTER_MODE="${AI_ROUTER_MODE:-api_only}"

    read -r -p "Primary AI provider [openai]: " AI_PRIMARY
    AI_PRIMARY="${AI_PRIMARY:-openai}"

    read -r -p "Secondary AI provider [gemini]: " AI_SECONDARY
    AI_SECONDARY="${AI_SECONDARY:-gemini}"

    read -r -p "AI Cost Mode [balanced]: " AI_COST_MODE
    AI_COST_MODE="${AI_COST_MODE:-balanced}"

    read -r -p "n8n Enterprise License Key (optional): " N8N_LICENSE_KEY

    read -r -p "OpenAI API Key (optional): " OPENAI_API_KEY
    read -r -p "Claude API Key (optional): " CLAUDE_API_KEY
    read -r -p "Gemini API Key (optional): " GEMINI_API_KEY

    read -r -p "Worker replicas [3]: " N8N_WORKER_REPLICAS
    N8N_WORKER_REPLICAS="${N8N_WORKER_REPLICAS:-3}"

    read -r -p "Enable monitoring stack (Prometheus/Grafana) [no]: " ENABLE_MONITORING
    ENABLE_MONITORING="${ENABLE_MONITORING:-false}"
    if [[ "$ENABLE_MONITORING" =~ ^[Yy](es)?$ ]]; then
        ENABLE_MONITORING=true
    else
        ENABLE_MONITORING=false
    fi

    if [[ -z "$MINIO_PASSWORD" ]]; then
        MINIO_PASSWORD=$(openssl rand -hex 24)
        log OK "Generated MinIO root password"
    fi

    FQDN="${SUBDOMAIN}.${DOMAIN}"
    
    echo ""
    log INFO "Configuration summary:"
    echo "  - FQDN: ${FQDN}"
    echo "  - SSL Email: ${SSL_EMAIL}"
    echo "  - n8n URL: https://${FQDN}"
    echo "  - AI Router Mode: ${AI_ROUTER_MODE}"
    echo "  - AI Primary: ${AI_PRIMARY}"
    echo "  - AI Secondary: ${AI_SECONDARY}"
    echo "  - AI Cost Mode: ${AI_COST_MODE}"
    echo "  - Monitoring: ${ENABLE_MONITORING}"
    echo ""
}

# Non-interactive mode for automation
ask_inputs_non_interactive() {
    if [[ -z "$DOMAIN" ]] || [[ -z "$SSL_EMAIL" ]] || [[ -z "$N8N_ADMIN_PASS" ]] || \
       [[ -z "$POSTGRES_PASSWORD" ]] || [[ -z "$REDIS_PASSWORD" ]]; then
        die "Non-interactive mode requires: DOMAIN, SSL_EMAIL, N8N_ADMIN_PASS, POSTGRES_PASSWORD, REDIS_PASSWORD"
    fi
    
    AI_ROUTER_MODE="${AI_ROUTER_MODE:-api_only}"
    AI_PRIMARY="${AI_PRIMARY:-openai}"
    AI_SECONDARY="${AI_SECONDARY:-gemini}"
    AI_COST_MODE="${AI_COST_MODE:-balanced}"
    ENABLE_MONITORING="${ENABLE_MONITORING:-false}"
    N8N_LICENSE_KEY="${N8N_LICENSE_KEY:-}"
    MINIO_PASSWORD="${MINIO_PASSWORD:-$(openssl rand -hex 24)}"
    N8N_WORKER_REPLICAS="${N8N_WORKER_REPLICAS:-3}"
    
    if ! validate_domain "$DOMAIN"; then
        die "Invalid DOMAIN format"
    fi
    
    if ! validate_email "$SSL_EMAIL"; then
        die "Invalid SSL_EMAIL format"
    fi
    
    if ! validate_password "$N8N_ADMIN_PASS"; then
        die "N8N_ADMIN_PASS must be at least 12 characters"
    fi
    
    if ! validate_password "$POSTGRES_PASSWORD"; then
        die "POSTGRES_PASSWORD must be at least 12 characters"
    fi
    
    if ! validate_password "$REDIS_PASSWORD"; then
        die "REDIS_PASSWORD must be at least 12 characters"
    fi
    
    SUBDOMAIN="${SUBDOMAIN:-n8n}"
    FQDN="${SUBDOMAIN}.${DOMAIN}"
    
    log INFO "Running in non-interactive mode"
    log INFO "FQDN: ${FQDN}"
}

# =============================================================================
# ENVIRONMENT FILE GENERATION
# =============================================================================

load_encryption_key_from_volume() {
    if ! docker volume inspect n8n_data &>/dev/null 2>&1; then
        return 1
    fi

    local config_json key=""
    config_json=$(docker run --rm -v n8n_data:/data alpine cat /data/config 2>/dev/null || true)
    if [[ -z "$config_json" ]]; then
        return 1
    fi

    if command -v jq &>/dev/null; then
        key=$(echo "$config_json" | jq -r '.encryptionKey // empty' 2>/dev/null || true)
    else
        key=$(echo "$config_json" | sed -n 's/.*"encryptionKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    fi

    if [[ -n "$key" ]]; then
        ENCRYPTION_KEY="$key"
        log OK "Using encryption key from n8n_data volume (config file)"
        return 0
    fi
    return 1
}

load_encryption_key_from_backups() {
    local backup_env key=""
    backup_env=$(ls -1t "${BACKUP_DIR}"/env_*.bak 2>/dev/null | head -n 1 || true)
    if [[ -z "$backup_env" ]]; then
        return 1
    fi
    key=$(grep '^N8N_ENCRYPTION_KEY=' "$backup_env" 2>/dev/null | cut -d= -f2- || true)
    if [[ -n "$key" ]]; then
        ENCRYPTION_KEY="$key"
        log OK "Using encryption key from backup: ${backup_env}"
        return 0
    fi
    return 1
}

read_env_var() {
    local key="$1"
    local default="${2:-}"
    local value=""
    if [[ -f "$ENV_FILE" ]]; then
        value=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- | head -n 1 || true)
    fi
    if [[ -n "$value" ]]; then
        echo "$value"
    else
        echo "$default"
    fi
}

load_existing_configuration() {
    if [[ ! -f "$ENV_FILE" ]]; then
        die "No existing install at ${ENV_FILE}. Run: $0 install or install-auto"
    fi

    log INFO "Loading configuration from ${ENV_FILE}"

    FQDN=$(read_env_var "FQDN" "")
    N8N_HOST=$(read_env_var "N8N_HOST" "")
    FQDN="${FQDN:-$N8N_HOST}"
    DOMAIN=$(read_env_var "DOMAIN" "${DOMAIN}")
    SUBDOMAIN=$(read_env_var "SUBDOMAIN" "${SUBDOMAIN}")
    if [[ -z "$FQDN" ]]; then
        FQDN="${SUBDOMAIN}.${DOMAIN}"
    else
        if [[ "$FQDN" == *.* ]]; then
            SUBDOMAIN="${FQDN%%.*}"
            DOMAIN="${FQDN#*.}"
        fi
    fi

    SSL_EMAIL=$(read_env_var "SSL_EMAIL" "")
    POSTGRES_PASSWORD=$(read_env_var "POSTGRES_PASSWORD" "")
    REDIS_PASSWORD=$(read_env_var "REDIS_PASSWORD" "")
    N8N_ADMIN_PASS=$(read_env_var "N8N_ADMIN_PASS" "")
    N8N_PROXY_HOPS=$(read_env_var "N8N_PROXY_HOPS" "${N8N_PROXY_HOPS}")
    N8N_WORKER_REPLICAS=$(read_env_var "N8N_WORKER_REPLICAS" "3")
    N8N_VERSION=$(read_env_var "N8N_VERSION" "${N8N_VERSION}")
    ENABLE_MONITORING=$(read_env_var "ENABLE_MONITORING" "false")
    OPENAI_API_KEY=$(read_env_var "OPENAI_API_KEY" "")
    CLAUDE_API_KEY=$(read_env_var "CLAUDE_API_KEY" "")
    GEMINI_API_KEY=$(read_env_var "GEMINI_API_KEY" "")
    AI_ROUTER_MODE=$(read_env_var "AI_ROUTER_MODE" "api_only")
    AI_PRIMARY=$(read_env_var "AI_PRIMARY" "openai")
    AI_SECONDARY=$(read_env_var "AI_SECONDARY" "gemini")
    AI_COST_MODE=$(read_env_var "AI_COST_MODE" "balanced")
    N8N_LICENSE_KEY=$(read_env_var "N8N_LICENSE_KEY" "")
    MINIO_PASSWORD=$(read_env_var "MINIO_ROOT_PASSWORD" "")
    MINIO_PASSWORD="${MINIO_PASSWORD:-$(read_env_var "MINIO_PASSWORD" "")}"
    MINIO_ROOT_USER=$(read_env_var "MINIO_ROOT_USER" "admin")
    ENABLE_QDRANT=$(read_env_var "ENABLE_QDRANT" "true")
    ENABLE_MINIO=$(read_env_var "ENABLE_MINIO" "true")
    ENABLE_NGINX_RATE_LIMIT=$(read_env_var "ENABLE_NGINX_RATE_LIMIT" "false")
    NGINX_RATE_LIMIT=$(read_env_var "NGINX_RATE_LIMIT" "${NGINX_RATE_LIMIT}")
    BACKUP_RETENTION_DAYS=$(read_env_var "BACKUP_RETENTION_DAYS" "7")
    SMTP_HOST=$(read_env_var "N8N_SMTP_HOST" "")
    SMTP_PORT=$(read_env_var "N8N_SMTP_PORT" "587")
    SMTP_USER=$(read_env_var "N8N_SMTP_USER" "")
    SMTP_PASS=$(read_env_var "N8N_SMTP_PASS" "")
    SMTP_SENDER=$(read_env_var "N8N_SMTP_SENDER" "")

    [[ -n "$POSTGRES_PASSWORD" ]] || die "POSTGRES_PASSWORD missing in ${ENV_FILE}"
    [[ -n "$REDIS_PASSWORD" ]] || die "REDIS_PASSWORD missing in ${ENV_FILE}"

    log OK "Target FQDN: ${FQDN}"
}

resolve_encryption_key() {
    ENCRYPTION_KEY=""
    local env_key volume_key=""

    env_key=$(read_env_var "N8N_ENCRYPTION_KEY" "")
    load_encryption_key_from_volume || true
    volume_key="$ENCRYPTION_KEY"

    if [[ -n "$volume_key" ]]; then
        if [[ -n "$env_key" && "$env_key" != "$volume_key" ]]; then
            log WARN "N8N_ENCRYPTION_KEY in .env differs from n8n_data volume; using volume key"
        fi
        ENCRYPTION_KEY="$volume_key"
        return 0
    fi

    if [[ -n "$env_key" ]]; then
        ENCRYPTION_KEY="$env_key"
        log INFO "Encryption key loaded from ${ENV_FILE}"
        return 0
    fi

    load_encryption_key_from_backups || true

    if [[ -z "$ENCRYPTION_KEY" ]]; then
        ENCRYPTION_KEY=$(openssl rand -hex 32)
        log WARN "No existing encryption key found; generated a new one (first install only)"
    fi
}

apply_runtime_fixes() {
    log INFO "Applying runtime fixes (encryption key + listen port 5678)..."
    fix_n8n_config_listen_port 5678
}

generate_env() {
    log INFO "Generating environment configuration..."
    resolve_encryption_key
    apply_runtime_fixes

    local smtp_block=""
    if [[ -n "$SMTP_HOST" ]]; then
        smtp_block="
# SMTP (optional)
N8N_EMAIL_MODE=smtp
N8N_SMTP_HOST=${SMTP_HOST}
N8N_SMTP_PORT=${SMTP_PORT}
N8N_SMTP_USER=${SMTP_USER}
N8N_SMTP_PASS=${SMTP_PASS}
N8N_SMTP_SENDER=${SMTP_SENDER}"
    fi
    
    cat > "$ENV_FILE" <<EOF
# =============================================================================
# n8n Enterprise Environment Configuration
# Generated: $(date -Iseconds)
# =============================================================================

# General Configuration (public URL: https://<FQDN> — set N8N_PROXY_HOPS for Cloudflare)
FQDN=${FQDN}
N8N_HOST=${FQDN}
# Listen inside container (must match Docker 127.0.0.1:5678:5678 and nginx upstream)
N8N_LISTEN_ADDRESS=0.0.0.0
N8N_PORT=5678
N8N_PROTOCOL=https
WEBHOOK_URL=https://${FQDN}/
N8N_EDITOR_BASE_URL=https://${FQDN}
N8N_PROXY_HOPS=${N8N_PROXY_HOPS}
OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true
N8N_REINSTALL_MISSING_PACKAGES=false

# Database Configuration
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=postgres
DB_POSTGRESDB_PORT=5432
DB_POSTGRESDB_DATABASE=n8n
DB_POSTGRESDB_USER=n8n
DB_POSTGRESDB_PASSWORD=${POSTGRES_PASSWORD}

# Redis Queue Configuration
QUEUE_BULL_REDIS_HOST=redis
QUEUE_BULL_REDIS_PORT=6379
QUEUE_BULL_REDIS_PASSWORD=${REDIS_PASSWORD}

# Compose-compatible aliases
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}

# Security
N8N_ENCRYPTION_KEY=${ENCRYPTION_KEY}

# Execution Settings
EXECUTIONS_MODE=queue
N8N_DEFAULT_BINARY_DATA_MODE=database
EXECUTIONS_TIMEOUT=300
EXECUTIONS_TIMEOUT_MAX=600

# Advanced Settings
N8N_SECURE_COOKIE=true
N8N_LOG_LEVEL=info
N8N_LOG_OUTPUT=console
N8N_METRICS=true
N8N_DIAGNOSTICS_ENABLED=false

# Timezone
GENERIC_TIMEZONE=UTC

# AI Configuration
AI_ROUTER_MODE=${AI_ROUTER_MODE}
AI_PRIMARY=${AI_PRIMARY}
AI_SECONDARY=${AI_SECONDARY}
AI_COST_MODE=${AI_COST_MODE}
ENABLE_MONITORING=${ENABLE_MONITORING}

# Optional AI API keys
OPENAI_API_KEY=${OPENAI_API_KEY}
CLAUDE_API_KEY=${CLAUDE_API_KEY}
GEMINI_API_KEY=${GEMINI_API_KEY}

# MinIO
MINIO_ROOT_USER=${MINIO_ROOT_USER}
MINIO_ROOT_PASSWORD=${MINIO_PASSWORD}

# Qdrant Vector Database
QDRANT_URL=http://qdrant:6333

# Enterprise
N8N_LICENSE_KEY=${N8N_LICENSE_KEY}
N8N_WORKER_REPLICAS=${N8N_WORKER_REPLICAS}

ENABLE_QDRANT=${ENABLE_QDRANT}
ENABLE_MINIO=${ENABLE_MINIO}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS}
${smtp_block}
EOF
    
    chmod 600 "$ENV_FILE"
    if declare -F sync_secrets_from_env >/dev/null; then
        sync_secrets_from_env
    fi
    log OK "Environment file generated: ${ENV_FILE}"
}

compose_profiles_args() {
    COMPOSE_PROFILE_ARGS=()
    [[ "${ENABLE_QDRANT:-true}" == "true" ]] && COMPOSE_PROFILE_ARGS+=(--profile ai)
    [[ "${ENABLE_MINIO:-true}" == "true" ]] && COMPOSE_PROFILE_ARGS+=(--profile storage)
    [[ "${ENABLE_MONITORING:-false}" == "true" ]] && COMPOSE_PROFILE_ARGS+=(--profile observe)
}

load_compose_profile_flags() {
    if [[ -f "$ENV_FILE" ]]; then
        ENABLE_QDRANT=$(read_env_var "ENABLE_QDRANT" "${ENABLE_QDRANT:-true}")
        ENABLE_MINIO=$(read_env_var "ENABLE_MINIO" "${ENABLE_MINIO:-true}")
        ENABLE_MONITORING=$(read_env_var "ENABLE_MONITORING" "${ENABLE_MONITORING:-false}")
    fi
    compose_profiles_args
}

docker_compose() {
    load_compose_profile_flags
    docker compose "${COMPOSE_PROFILE_ARGS[@]}" "$@"
}

# Find install dir when BASE_DIR default (/opt/n8n) differs from actual path (/home/user/n8n)
resolve_install_base_dir() {
    local dir
    for dir in \
        "${N8N_BASE_DIR:-}" \
        "${BASE_DIR}" \
        "/home/${SUDO_USER:-}/n8n" \
        "/opt/n8n"; do
        [[ -z "$dir" || "$dir" == "/home//n8n" ]] && continue
        if [[ -f "${dir}/docker-compose.yml" || -f "${dir}/.env" ]]; then
            BASE_DIR="$dir"
            ENV_FILE="${BASE_DIR}/.env"
            COMPOSE_FILE="${BASE_DIR}/docker-compose.yml"
            SECRETS_DIR="${BASE_DIR}/secrets"
            RELEASE_FILE="${BASE_DIR}/.n8n-release"
            ENV_TEMPLATE="${BASE_DIR}/.env.example"
            if [[ "$BASE_DIR" == /home/* ]]; then
                BACKUP_DIR="${BASE_DIR}/backups"
            fi
            log INFO "Using install directory: ${BASE_DIR}"
            return 0
        fi
    done
    return 1
}

force_remove_n8n_stack() {
    log INFO "Force-removing n8n containers and volumes..."
    local c v
    for c in n8n n8n-postgres n8n-redis n8n-qdrant n8n-minio; do
        docker rm -f "$c" 2>/dev/null || true
    done
    docker ps -aq --filter "name=n8n-n8n-worker" 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
    docker ps -aq --filter "name=n8n-" 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
    for v in n8n_data n8n_postgres_data n8n_redis_data n8n_qdrant_data n8n_minio_data n8n_grafana_data; do
        docker volume rm -f "$v" 2>/dev/null || true
    done
    docker network rm n8n_network 2>/dev/null || true
}

# Require an existing install (auto-detect /home/user/n8n vs /opt/n8n)
require_install() {
    check_root
    resolve_install_base_dir || die "No n8n install found. Run install or set N8N_BASE_DIR=/path/to/n8n"
    cd "$BASE_DIR" || die "Cannot cd ${BASE_DIR}"
}

load_install_config() {
    if [[ -f "$ENV_FILE" ]]; then
        load_existing_configuration
    fi
    load_deploy_env
}

# Menu/CLI wrapper: failures return to menu instead of exiting the script
run_menu_action() {
    set +e
    "$@"
    local _rc=$?
    set -e
    if [[ $_rc -ne 0 ]]; then
        log WARN "Command finished with exit code ${_rc}"
    fi
    return 0
}

run_backup_manual() {
    require_install
    load_install_config
    if [[ ! -x "$BACKUP_SCRIPT" ]]; then
        log INFO "Backup script missing; creating it (idempotent)..."
        setup_backup_system
    fi
    [[ -x "$BACKUP_SCRIPT" ]] || die "Backup script not available at ${BACKUP_SCRIPT}"
    "$BACKUP_SCRIPT"
}

preflight_menu() {
    check_root
    resolve_install_base_dir 2>/dev/null || true
    preflight_stack
}

validate_menu() {
    require_install
    load_install_config
    validate_stack
}

ai_test_menu() {
    require_install
    load_install_config
    ai_test
}

# =============================================================================
# MONITORING CONFIGURATION
# =============================================================================

generate_monitoring_config() {
    log INFO "Generating Prometheus configuration..."
    cat > "${BASE_DIR}/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'n8n'
    metrics_path: /metrics
    static_configs:
      - targets: ['n8n:5678']

  - job_name: 'minio'
    metrics_path: /minio/prometheus/metrics
    static_configs:
      - targets: ['minio:9000']

  - job_name: 'qdrant'
    metrics_path: /metrics
    static_configs:
      - targets: ['qdrant:6333']
EOF
}

# =============================================================================
# DOCKER COMPOSE CONFIGURATION
# =============================================================================

generate_compose() {
    log INFO "Generating Docker Compose configuration..."
    
    cat > "$COMPOSE_FILE" <<EOF
# =============================================================================
# n8n Enterprise Stack - Docker Compose
# Stack compose — managed by n8n-deployer.sh v1.0.0
# =============================================================================

services:
  # ---------------------------------------------------------------------------
  # PostgreSQL Database
  # ---------------------------------------------------------------------------
  postgres:
    image: postgres:${POSTGRES_VERSION}-alpine
    container_name: n8n-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: "n8n"
      POSTGRES_USER: "n8n"
      POSTGRES_PASSWORD: "${POSTGRES_PASSWORD}"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - n8n_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n -d n8n"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 256M

  # ---------------------------------------------------------------------------
  # Redis Cache & Queue
  # ---------------------------------------------------------------------------
  redis:
    image: redis:${REDIS_VERSION}-alpine
    container_name: n8n-redis
    restart: unless-stopped
    command:
      - redis-server
      - "--requirepass"
      - "${REDIS_PASSWORD}"
      - "--maxmemory"
      - "256mb"
      - "--maxmemory-policy"
      - "noeviction"
      - "--appendonly"
      - "yes"
    volumes:
      - redis_data:/data
    networks:
      - n8n_network
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"${REDIS_PASSWORD}\" --no-auth-warning ping | grep -q PONG"]
      interval: 10s
      timeout: 3s
      retries: 5
      start_period: 10s
    deploy:
      resources:
        limits:
          memory: 512M
        reservations:
          memory: 128M

  # ---------------------------------------------------------------------------
  # Qdrant Vector Database
  # ---------------------------------------------------------------------------
  qdrant:
    profiles: ["ai"]
    image: qdrant/qdrant:${QDRANT_VERSION}
    container_name: n8n-qdrant
    restart: unless-stopped
    volumes:
      - qdrant_data:/qdrant/storage
    networks:
      - n8n_network
    healthcheck:
      test: ["CMD-SHELL", "if command -v curl >/dev/null 2>&1; then curl -fsS http://127.0.0.1:6333/health >/dev/null; elif command -v wget >/dev/null 2>&1; then wget --spider -q http://127.0.0.1:6333/health >/dev/null; else exit 0; fi"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

  # ---------------------------------------------------------------------------
  # n8n Worker
  # ---------------------------------------------------------------------------
  n8n-worker:
    image: n8nio/n8n:${N8N_VERSION}
    command: worker
    restart: unless-stopped
    env_file:
      - "${ENV_FILE}"
    environment:
      - "DB_TYPE=postgresdb"
      - "DB_POSTGRESDB_HOST=postgres"
      - "DB_POSTGRESDB_PORT=5432"
      - "DB_POSTGRESDB_DATABASE=n8n"
      - "DB_POSTGRESDB_USER=n8n"
      - "N8N_ENCRYPTION_KEY_FILE=/secrets/encryption_key"
      - "DB_POSTGRESDB_PASSWORD_FILE=/secrets/postgres_password"
      - "QUEUE_BULL_REDIS_HOST=redis"
      - "QUEUE_BULL_REDIS_PORT=6379"
      - "QUEUE_BULL_REDIS_PASSWORD_FILE=/secrets/redis_password"
      - "EXECUTIONS_MODE=queue"
      - "N8N_LISTEN_ADDRESS=0.0.0.0"
      - "N8N_HOST=${FQDN}"
      - "N8N_PORT=5678"
      - "N8N_PROTOCOL=https"
      - "WEBHOOK_URL=https://${FQDN}/"
      - "N8N_EDITOR_BASE_URL=https://${FQDN}"
      - "N8N_PROXY_HOPS=${N8N_PROXY_HOPS}"
      - "N8N_DEFAULT_BINARY_DATA_MODE=database"
      - "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true"
      - "N8N_REINSTALL_MISSING_PACKAGES=false"
      - "N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}"
    volumes:
      - ${SECRETS_DIR}:/secrets:ro
      - n8n_data:/home/node/.n8n
    security_opt:
      - no-new-privileges:true
    networks:
      - n8n_network
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "pgrep -f '[n]8n worker' >/dev/null || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  # ---------------------------------------------------------------------------
  # n8n Automation Platform
  # ---------------------------------------------------------------------------
  n8n:
    image: n8nio/n8n:${N8N_VERSION}
    container_name: n8n
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    env_file:
      - "${ENV_FILE}"
    environment:
      - "DB_TYPE=postgresdb"
      - "DB_POSTGRESDB_HOST=postgres"
      - "DB_POSTGRESDB_PORT=5432"
      - "DB_POSTGRESDB_DATABASE=n8n"
      - "DB_POSTGRESDB_USER=n8n"
      - "N8N_ENCRYPTION_KEY_FILE=/secrets/encryption_key"
      - "DB_POSTGRESDB_PASSWORD_FILE=/secrets/postgres_password"
      - "QUEUE_BULL_REDIS_HOST=redis"
      - "QUEUE_BULL_REDIS_PORT=6379"
      - "QUEUE_BULL_REDIS_PASSWORD_FILE=/secrets/redis_password"
      - "N8N_LISTEN_ADDRESS=0.0.0.0"
      - "N8N_HOST=${FQDN}"
      - "N8N_PORT=5678"
      - "N8N_PROTOCOL=https"
      - "WEBHOOK_URL=https://${FQDN}/"
      - "N8N_EDITOR_BASE_URL=https://${FQDN}"
      - "N8N_PROXY_HOPS=${N8N_PROXY_HOPS}"
      - "N8N_DEFAULT_BINARY_DATA_MODE=database"
      - "N8N_SECURE_COOKIE=true"
      - "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true"
      - "N8N_REINSTALL_MISSING_PACKAGES=false"
      - "N8N_RUNNERS_ENABLED=${N8N_RUNNERS_ENABLED}"
      - "EXECUTIONS_MODE=queue"
      - "N8N_LOG_LEVEL=info"
      - "N8N_METRICS=true"
      - "NODE_ENV=production"
    volumes:
      - ${SECRETS_DIR}:/secrets:ro
      - n8n_data:/home/node/.n8n
    security_opt:
      - no-new-privileges:true
    networks:
      - n8n_network
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
    if [[ "${ENABLE_QDRANT:-true}" == "true" ]]; then
      cat >> "$COMPOSE_FILE" <<EOF
      qdrant:
        condition: service_started
EOF
    fi
    cat >> "$COMPOSE_FILE" <<EOF
    healthcheck:
      test: ["CMD-SHELL", "node -e \"require('http').get('http://127.0.0.1:5678/healthz',(r)=>{process.exit(r.statusCode===200?0:1)}).on('error',()=>process.exit(1))\""]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s
    deploy:
      resources:
        limits:
          memory: 2G
        reservations:
          memory: 512M
      restart_policy:
        condition: on-failure
        delay: 5s
        max_attempts: 3
        window: 120s

  minio:
    profiles: ["storage"]
    image: minio/minio:${MINIO_VERSION}
    container_name: n8n-minio
    command: server /data --console-address ":9001"
    env_file:
      - "${ENV_FILE}"
    environment:
      - "MINIO_ROOT_USER=${MINIO_ROOT_USER}"
      - "MINIO_ROOT_PASSWORD=${MINIO_PASSWORD}"
    volumes:
      - minio_data:/data
    networks:
      - n8n_network
    healthcheck:
      test: ["CMD-SHELL", "if command -v wget >/dev/null 2>&1; then wget --spider -q http://127.0.0.1:9000/minio/health/live; elif command -v curl >/dev/null 2>&1; then curl -fsS http://127.0.0.1:9000/minio/health/live >/dev/null; else exit 1; fi"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
EOF

    if [[ "$ENABLE_MONITORING" == "true" ]]; then
      cat >> "$COMPOSE_FILE" <<EOF

  prometheus:
    profiles: ["observe"]
    image: prom/prometheus:${PROMETHEUS_VERSION}
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
    ports:
      - "127.0.0.1:9090:9090"
    networks:
      - n8n_network
    depends_on:
      - n8n

  grafana:
    profiles: ["observe"]
    image: grafana/grafana:${GRAFANA_VERSION}
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
    networks:
      - n8n_network
    depends_on:
      - prometheus
EOF
    fi

    cat >> "$COMPOSE_FILE" <<EOF

# =============================================================================
# VOLUMES
# =============================================================================
volumes:
  postgres_data:
    name: n8n_postgres_data
  redis_data:
    name: n8n_redis_data
  n8n_data:
    name: n8n_data
  minio_data:
    name: n8n_minio_data
  qdrant_data:
    name: n8n_qdrant_data
  grafana_data:
    name: n8n_grafana_data

# =============================================================================
# NETWORKS
# =============================================================================
networks:
  n8n_network:
    name: n8n_network
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16
EOF
    
    log OK "Docker Compose file generated: ${COMPOSE_FILE}"
}

# =============================================================================
# NGINX CONFIGURATION
# =============================================================================

generate_nginx_bootstrap() {
    log INFO "Generating nginx bootstrap (HTTP only, for ACME)..."
    
    cat > "$NGINX_SITE" <<EOF
# n8n bootstrap — HTTP only until SSL certificates exist

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream n8n_backend {
    server 127.0.0.1:5678;
    keepalive 32;
}

server {
    listen 80;
    server_name ${FQDN};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://n8n_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF

    ln -sf "$NGINX_SITE" "$NGINX_ENABLED" 2>/dev/null || true
    mkdir -p /var/www/certbot

    if nginx -t; then
        systemctl enable nginx 2>/dev/null || true
        systemctl restart nginx
        log OK "nginx bootstrap applied (HTTP)"
    else
        die "nginx bootstrap configuration test failed"
    fi
}

generate_nginx() {
    if [[ ! -f "/etc/letsencrypt/live/${FQDN}/fullchain.pem" ]]; then
        log WARN "SSL certificate not found; keeping HTTP bootstrap config"
        generate_nginx_bootstrap
        return 0
    fi

    log INFO "Generating nginx configuration..."

    local nginx_rate_limit_block=""
    if [[ "${ENABLE_NGINX_RATE_LIMIT}" == "true" ]]; then
        nginx_rate_limit_block="limit_req_zone \$binary_remote_addr zone=n8n_webhook_limit:10m rate=${NGINX_RATE_LIMIT}r/s;"
    fi
    
    # Create nginx site configuration
    cat > "$NGINX_SITE" <<EOF
# =============================================================================
# n8n Enterprise - nginx Configuration
# =============================================================================

${nginx_rate_limit_block}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

upstream n8n_backend {
    server 127.0.0.1:5678;
    keepalive 32;
}

# HTTP to HTTPS redirect
server {
    listen 80;
    server_name ${FQDN};
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
        try_files \$uri =404;
    }
    
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS Server
server {
    listen 443 ssl;
    http2 on;
    server_name ${FQDN};
    
    # SSL Configuration
    ssl_certificate /etc/letsencrypt/live/${FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:50m;
    ssl_session_tickets off;
    
    # Modern SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    
    # Security Headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
EOF
    if [[ "${ENABLE_N8N_CSP}" == "true" ]]; then
      cat >> "$NGINX_SITE" <<EOF
    add_header Content-Security-Policy "default-src 'self' https: data: blob: 'unsafe-inline' 'unsafe-eval'" always;
EOF
    fi
    cat >> "$NGINX_SITE" <<EOF
    
    client_max_body_size 100M;
    client_body_timeout 300s;
    proxy_connect_timeout 75s;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    # Editor + API: no rate limit (parallel /assets/*.js and /rest/* break limit_req → 503)
    location / {
        proxy_pass http://n8n_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_buffering off;
    }

    location /webhook/ {
EOF
    if [[ "${ENABLE_NGINX_RATE_LIMIT}" == "true" ]]; then
      cat >> "$NGINX_SITE" <<EOF
        limit_req zone=n8n_webhook_limit burst=100 nodelay;
EOF
    fi
    cat >> "$NGINX_SITE" <<EOF
        proxy_pass http://n8n_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }

    location = /healthz {
        proxy_pass http://n8n_backend/healthz;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        access_log off;
    }
    
    # Metrics (localhost only)
    location /metrics {
        allow 127.0.0.1;
        deny all;
        proxy_pass http://n8n_backend;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }
}
EOF
    
    # Enable site
    ln -sf "$NGINX_SITE" "$NGINX_ENABLED" 2>/dev/null || true
    
    # Test and reload nginx
    if nginx -t; then
        systemctl reload nginx
        log OK "nginx configuration applied"
    else
        die "nginx configuration test failed"
    fi
}

# =============================================================================
# SSL CERTIFICATE
# =============================================================================

install_ssl() {
    if [[ "$AUTO_SSL" != "true" ]]; then
        log WARN "Auto SSL disabled. Please configure manually."
        return 0
    fi
    
    log INFO "Installing SSL certificate for ${FQDN}..."
    
    mkdir -p /var/www/certbot
    generate_nginx_bootstrap

    local certbot_extra=()
    if [[ ! -d "/etc/letsencrypt/live/${FQDN}" ]]; then
        certbot_extra+=(--agree-tos)
    else
        log INFO "Existing certificate found for ${FQDN}; skipping forced renewal"
    fi

    # Webroot requires nginx running (bootstrap config serves ACME challenges)
    if certbot certonly --webroot -w /var/www/certbot \
        -d "$FQDN" \
        --non-interactive \
        --email "$SSL_EMAIL" \
        --rsa-key-size 4096 \
        "${certbot_extra[@]}"; then
        
        log OK "SSL certificate obtained successfully (webroot)"
        setup_certbot_renewal
        generate_nginx
        return 0
    fi

    log WARN "Webroot issuance failed; retrying with standalone (nginx stopped)..."
    systemctl stop nginx

    if certbot certonly --standalone \
        -d "$FQDN" \
        --non-interactive \
        --email "$SSL_EMAIL" \
        --rsa-key-size 4096 \
        "${certbot_extra[@]}"; then
        
        log OK "SSL certificate obtained (standalone mode)"
        setup_certbot_renewal
        systemctl start nginx
        generate_nginx
        return 0
    fi

    log ERROR "SSL certificate installation failed"
    systemctl start nginx || true
    return 1
}

setup_certbot_renewal() {
    log INFO "Setting up automatic SSL renewal..."
    
    # Create renewal hook
    cat > /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh <<'EOF'
#!/bin/bash
systemctl reload nginx
EOF
    chmod +x /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh
    
    # Add cron job for renewal
    local cron_job="0 0,12 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx'"
    
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        log OK "SSL renewal cron job added"
    fi
}

# =============================================================================
# BACKUP SYSTEM
# =============================================================================

setup_backup_system() {
    if [[ "$BACKUP_ENABLED" != "true" ]]; then
        log INFO "Backup system disabled"
        return 0
    fi
    
    log INFO "Setting up automated backup system..."
    
    # Create backup script
    cat > "$BACKUP_SCRIPT" <<EOF
#!/bin/bash
# =============================================================================
# n8n Backup Script
# =============================================================================

set -euo pipefail

BACKUP_DIR="${BACKUP_DIR}"
ENV_FILE="${ENV_FILE}"
DATE=\$(date +%Y%m%d_%H%M%S)
RETENTION_DAYS=${BACKUP_RETENTION_DAYS}

# Create backup directory
mkdir -p "\$BACKUP_DIR"

echo "Starting n8n backup..."

# Stop n8n container for consistent backup
docker stop n8n >/dev/null 2>&1 || true

# Backup PostgreSQL
echo "Backing up PostgreSQL..."
docker exec n8n-postgres pg_dump -U n8n n8n | gzip > "\${BACKUP_DIR}/postgres_\${DATE}.sql.gz"

# Backup Redis
echo "Backing up Redis..."
REDIS_PASS="\$(grep -E '^(REDIS_PASSWORD|QUEUE_BULL_REDIS_PASSWORD)=' "\$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)"
if [[ -z "\$REDIS_PASS" ]]; then
    echo "Redis password not found in environment file"
    exit 1
fi
docker exec n8n-redis redis-cli -a "\$REDIS_PASS" --no-auth-warning SAVE >/dev/null 2>&1
docker cp n8n-redis:/data/dump.rdb "\${BACKUP_DIR}/redis_\${DATE}.rdb"

# Backup n8n data
echo "Backing up n8n data..."
docker cp n8n:/home/node/.n8n "\${BACKUP_DIR}/n8n_data_\${DATE}" || true

# Backup environment file
cp "\$ENV_FILE" "\${BACKUP_DIR}/env_\${DATE}.bak"

# Start n8n container
docker start n8n >/dev/null 2>&1 || true

# Create tar archive
cd "\$BACKUP_DIR"
tar -czf "n8n_backup_\${DATE}.tar.gz" \
    "postgres_\${DATE}.sql.gz" \
    "redis_\${DATE}.rdb" \
    "env_\${DATE}.bak" \
    "n8n_data_\${DATE}" 2>/dev/null || tar -czf "n8n_backup_\${DATE}.tar.gz" \
    "postgres_\${DATE}.sql.gz" \
    "redis_\${DATE}.rdb" \
    "env_\${DATE}.bak"
find "\$BACKUP_DIR" -maxdepth 1 \( -name "postgres_\${DATE}.sql.gz" -o -name "redis_\${DATE}.rdb" -o -name "env_\${DATE}.bak" -o -name "n8n_data_\${DATE}" \) -delete 2>/dev/null || true

# Cleanup old backups
find "\$BACKUP_DIR" -name "n8n_backup_*.tar.gz" -mtime +\${RETENTION_DAYS} -delete

echo "Backup completed: n8n_backup_\${DATE}.tar.gz"
EOF
    
    chmod +x "$BACKUP_SCRIPT"
    
    # Add to crontab (daily at 2 AM)
    local cron_job="0 2 * * * ${BACKUP_SCRIPT}"
    if ! crontab -l 2>/dev/null | grep -q "n8n-backup"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
        log OK "Backup cron job added (daily at 2 AM)"
    fi
}

# =============================================================================
# FIREWALL CONFIGURATION
# =============================================================================

configure_firewall() {
    log INFO "Configuring firewall (UFW)..."
    
    # Check if ufw is active
    if systemctl is-active --quiet ufw; then
        # Allow SSH
        ufw allow 22/tcp
        
        # Allow HTTP/HTTPS (n8n is bound to 127.0.0.1:5678, not exposed publicly)
        ufw allow 80/tcp
        ufw allow 443/tcp
        
        log OK "UFW rules configured"
    else
        log WARN "UFW is not active. Consider enabling it for security."
    fi
}

# =============================================================================
# FAIL2BAN CONFIGURATION
# =============================================================================

configure_fail2ban() {
    log INFO "Configuring Fail2Ban..."
    
    if ! command -v fail2ban-server &>/dev/null; then
        log WARN "Fail2Ban not installed, skipping..."
        return 0
    fi
    
    # Create n8n jail configuration
    cat > /etc/fail2ban/jail.local <<'EOF'
[n8n]
enabled = true
port = 443
filter = n8n
logpath = /var/log/nginx/access.log
maxretry = 10
bantime = 1800
findtime = 900
action = iptables-multiport[name=n8n, port="http,https", protocol=tcp]
EOF
    
    cat > /etc/fail2ban/filter.d/n8n.conf <<'EOF'
[Definition]
failregex = ^<HOST> -.*"(GET|POST) /(login|signin).*" (401|403)
ignoreregex = /rest/oauth2-credential/|/webhook/
EOF
    
    systemctl restart fail2ban
    log OK "Fail2Ban configured for n8n"
}

# =============================================================================
# MONITORING & HEALTH CHECKS
# =============================================================================

generate_healthcheck_script() {
    log INFO "Generating n8n healthcheck script..."

    mkdir -p /usr/local/bin
    cat > /usr/local/bin/n8n-healthcheck.sh <<'EOF'
#!/bin/bash

# n8n Health Check Script

set -euo pipefail

find_container() {
    local service=$1

    docker ps --format '{{.Names}}' | grep -E "^(${service}|n8n_${service}|n8n-${service}(-[0-9]+)?|${service}(-[0-9]+)?)$" | head -n 1
}

check_service() {
    local service=$1
    local container

    container=$(find_container "$service") || {
        echo "MISSING"
        return 1
    }

    if [[ "$service" == "qdrant" ]]; then
        if command -v curl >/dev/null 2>&1 && curl -fsS http://127.0.0.1:6333/health >/dev/null 2>&1; then
            echo "OK"
            return 0
        fi
        if docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null | grep -q '^running$'; then
            echo "OK"
            return 0
        fi
        echo "UNHEALTHY"
        return 1
    fi

    local status
    status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "none")

    case "$status" in
        healthy)
            echo "OK"
            return 0
            ;;
        starting)
            echo "STARTING"
            return 1
            ;;
        unhealthy)
            echo "UNHEALTHY"
            return 1
            ;;
        none)
            echo "UNKNOWN"
            return 1
            ;;
        *)
            echo "${status^^}"
            return 1
            ;;
    esac
}

postgres_status=$(check_service postgres)
redis_status=$(check_service redis)
qdrant_status=$(check_service qdrant)
minio_status=$(check_service minio)
n8n_status=$(check_service n8n)

echo "n8n Stack Health Status:"
echo "  PostgreSQL: $postgres_status"
echo "  Redis: $redis_status"
echo "  Qdrant: $qdrant_status"
echo "  MinIO: $minio_status"
echo "  n8n: $n8n_status"

if [[ "$postgres_status" == "OK" ]] && [[ "$redis_status" == "OK" ]] && [[ "$n8n_status" == "OK" ]]; then
    exit 0
else
    exit 1
fi
EOF

    chmod +x /usr/local/bin/n8n-healthcheck.sh
}

run_inline_healthcheck() {
    local service container status

    find_container() {
        local service=$1
        docker ps --format '{{.Names}}' | grep -E "^(${service}|n8n_${service}|n8n-${service}(-[0-9]+)?|${service}(-[0-9]+)?)$" | head -n 1
    }

    check_service() {
        local service=$1
        local container

        container=$(find_container "$service") || {
            echo "MISSING"
            return 1
        }

        if [[ "$service" == "qdrant" ]]; then
            if command -v curl >/dev/null 2>&1 && curl -fsS http://127.0.0.1:6333/health >/dev/null 2>&1; then
                echo "OK"
                return 0
            fi
            if docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null | grep -q '^running$'; then
                echo "OK"
                return 0
            fi
            echo "UNHEALTHY"
            return 1
        fi

        status=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo "none")
        case "$status" in
            healthy)
                echo "OK"
                return 0
                ;;
            starting)
                echo "STARTING"
                return 1
                ;;
            unhealthy)
                echo "UNHEALTHY"
                return 1
                ;;
            none)
                echo "UNKNOWN"
                return 1
                ;;
            *)
                echo "${status^^}"
                return 1
                ;;
        esac
    }

    local postgres_status redis_status qdrant_status minio_status n8n_status
    postgres_status=$(check_service postgres)
    redis_status=$(check_service redis)
    qdrant_status=$(check_service qdrant)
    minio_status=$(check_service minio)
    n8n_status=$(check_service n8n)

    echo "n8n Stack Health Status:"
    echo "  PostgreSQL: $postgres_status"
    echo "  Redis: $redis_status"
    echo "  Qdrant: $qdrant_status"
    echo "  MinIO: $minio_status"
    echo "  n8n: $n8n_status"

    if [[ "$postgres_status" == "OK" ]] && [[ "$redis_status" == "OK" ]] && [[ "$n8n_status" == "OK" ]]; then
        return 0
    fi
    return 1
}

setup_monitoring() {
    log INFO "Setting up monitoring..."

    generate_healthcheck_script
    
    local cron_job="*/5 * * * * /usr/local/bin/n8n-healthcheck.sh >> /var/log/n8n/health.log 2>&1"
    if ! crontab -l 2>/dev/null | grep -q "n8n-healthcheck"; then
        (crontab -l 2>/dev/null; echo "$cron_job") | crontab -
    fi
    
    log OK "Monitoring system configured"
}

# =============================================================================
# AI SUPPORT
# =============================================================================

ai_test() {
    if [[ -f "${ENV_FILE:-}" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "$ENV_FILE" 2>/dev/null || true
        set +a
    fi
    if declare -F load_ai_keys_from_secrets >/dev/null; then
        load_ai_keys_from_secrets
    fi
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        if curl -s https://api.openai.com/v1/models \
            -H "Authorization: Bearer ${OPENAI_API_KEY}" | jq -e '.data[0].id' >/dev/null 2>&1; then
            log OK "OpenAI API key is valid"
            return 0
        fi
        log ERROR "OpenAI API key validation failed"
        return 1
    fi

    log WARN "OPENAI_API_KEY not configured. Set OPENAI_API_KEY in the environment or .env file."
    return 1
}

# =============================================================================
# ENCRYPTION KEY SYNC (recover from volume / backups)
# =============================================================================

fix_n8n_config_listen_port() {
    local target_port="${1:-5678}"
    if ! docker volume inspect n8n_data &>/dev/null 2>&1; then
        log INFO "n8n_data volume not present yet (skipped; normal before first deploy_stack)"
        return 0
    fi
    if ! docker run --rm -v n8n_data:/data alpine test -f /data/config 2>/dev/null; then
        return 0
    fi
    docker run --rm -v n8n_data:/data alpine sh -c "
        apk add --no-cache jq >/dev/null 2>&1 || exit 1
        jq '.port = ${target_port}' /data/config > /data/config.tmp && mv /data/config.tmp /data/config
    " 2>/dev/null && log OK "Updated port in n8n_data config -> ${target_port}" || \
        log WARN "Could not patch n8n_data/config (jq missing or unexpected JSON shape)"
}

sync_listen_port() {
    log INFO "Forcing n8n to listen on port 5678 (nginx upstream)..."
    require_install
    load_install_config
    apply_runtime_fixes
    generate_env
    generate_compose
    docker_compose up -d --force-recreate n8n n8n-worker
    wait_for_n8n_upstream 120
    systemctl reload nginx 2>/dev/null || true
}

install_deployer_to_base() {
    local dest="${BASE_DIR}/n8n-deployer.sh"
    local libs_dest="${BASE_DIR}/deployer-lib"
    cp -f "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")" "$dest" 2>/dev/null || true
    chmod +x "$dest" 2>/dev/null || true
    if [[ -d "${SCRIPT_DIR}/deployer-lib" ]]; then
        mkdir -p "$libs_dest"
        cp -a "${SCRIPT_DIR}/deployer-lib/." "$libs_dest/"
    fi
}

sync_encryption_key() {
    log INFO "Syncing N8N_ENCRYPTION_KEY with existing n8n data..."
    require_install
    reconfigure_stack
}

# =============================================================================
# REVERSE PROXY (before stack — correct WEBHOOK_URL / OAuth URLs from first boot)
# =============================================================================

setup_reverse_proxy() {
    if [[ "$AUTO_SSL" == "true" ]]; then
        install_ssl
    else
        generate_nginx_bootstrap
        log WARN "AUTO_SSL=false: using HTTP bootstrap. Set WEBHOOK_URL to match how users reach n8n."
    fi
}

# =============================================================================
# DEPLOYMENT
# =============================================================================

load_deploy_env() {
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        N8N_WORKER_REPLICAS=$(grep -E '^N8N_WORKER_REPLICAS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
    fi
    N8N_WORKER_REPLICAS="${N8N_WORKER_REPLICAS:-3}"
}

verify_docker_hub_image() {
    local repo="$1"
    local tag="$2"
    local hint="$3"
    if curl -fsS "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}/" >/dev/null 2>&1; then
        log OK "Docker image verified: ${repo}:${tag}"
        return 0
    fi
    die "Docker tag ${repo}:${tag} not found on Docker Hub. ${hint}"
}

verify_stack_image_tags() {
    verify_docker_hub_image "n8nio/n8n" "${N8N_VERSION}" \
        "Set N8N_VERSION to a valid release (e.g. 2.23.2)."
    verify_docker_hub_image "minio/minio" "${MINIO_VERSION}" \
        "Set MINIO_VERSION to a valid RELEASE tag (e.g. RELEASE.2025-09-07T16-13-09Z)."
}

wait_for_n8n_upstream() {
    local max_wait="${1:-120}"
    local waited=0
    log INFO "Waiting for n8n on http://127.0.0.1:5678/healthz (max ${max_wait}s)..."
    while [[ $waited -lt $max_wait ]]; do
        if check_n8n_upstream; then
            log OK "n8n upstream healthy"
            return 0
        fi
        if docker logs n8n --tail 5 2>&1 | grep -q 'Mismatching encryption keys'; then
            log ERROR "Encryption key mismatch — run: $0 reconfigure"
            return 1
        fi
        sleep 5
        ((waited+=5))
        echo -n "."
    done
    echo ""
    log ERROR "n8n did not become healthy in time"
    docker logs n8n --tail 30 2>&1 || true
    return 1
}

deploy_stack() {
    log INFO "Deploying n8n stack..."
    
    cd "$BASE_DIR"
    load_deploy_env
    apply_runtime_fixes
    verify_stack_image_tags

    log INFO "Validating Docker Compose configuration..."
    if ! docker_compose config >/dev/null 2>&1; then
        die "Docker Compose configuration invalid"
    fi

    log INFO "Pulling latest Docker images..."
    local pull_rc=0
    docker_compose pull >>"$LOG_FILE" 2>&1 || pull_rc=$?
    if [[ $pull_rc -ne 0 ]]; then
        log WARN "docker compose pull reported errors (see ${LOG_FILE}); continuing with up --pull always"
    else
        log OK "Docker images pulled"
    fi

    log INFO "Starting containers (workers: ${N8N_WORKER_REPLICAS})..."
    if ! docker_compose up -d --pull always --scale "n8n-worker=${N8N_WORKER_REPLICAS}"; then
        log ERROR "docker compose up failed — check: docker compose --profile ai --profile storage ps -a"
        docker_compose ps -a 2>&1 | tee -a "$LOG_FILE" || true
        die "Failed to start stack in ${BASE_DIR}"
    fi
    log OK "Containers started"
    
    wait_for_n8n_upstream 180 || return 1

    apply_runtime_fixes

    if docker_compose ps | grep -q "Up"; then
        log OK "Stack deployed successfully"
        if systemctl is-active --quiet nginx 2>/dev/null; then
            systemctl reload nginx 2>/dev/null || true
        fi
        if docker logs n8n --tail 10 2>&1 | grep -qE 'ready on .*, port 443'; then
            log WARN "n8n still reports port 443 — run: $0 sync-listen-port"
        fi
    else
        log ERROR "Stack deployment failed"
        docker_compose logs n8n --tail 50 2>&1 || true
        return 1
    fi
}

# =============================================================================
# RECONFIGURE (re-apply deployer config on existing server — recommended after upgrade)
# =============================================================================

reconfigure_stack() {
    log INFO "Reconfiguring n8n stack (v${SCRIPT_VERSION})..."
    check_root
    resolve_install_base_dir || die "No existing install. Run install first."
    ensure_dirs
    install_deployer_to_base
    cd "$BASE_DIR"
    load_existing_configuration
    resolve_encryption_key
    apply_runtime_fixes

    if declare -F preflight_stack >/dev/null; then
        preflight_stack || log WARN "Preflight reported issues (continuing)"
    fi

    generate_env
    if [[ "$ENABLE_MONITORING" == "true" ]]; then
        generate_monitoring_config
    fi
    generate_compose

    if [[ -f "/etc/letsencrypt/live/${FQDN}/fullchain.pem" ]]; then
        generate_nginx
    elif [[ "$AUTO_SSL" == "true" ]]; then
        install_ssl || generate_nginx_bootstrap
    else
        generate_nginx_bootstrap
    fi

    deploy_stack || die "deploy_stack failed — see ${LOG_FILE}"

    if declare -F save_release_snapshot >/dev/null; then
        save_release_snapshot
    fi
    if declare -F validate_stack >/dev/null; then
        validate_stack || true
    fi

    if [[ "$BACKUP_ENABLED" == "true" ]] && [[ ! -x "$BACKUP_SCRIPT" ]]; then
        setup_backup_system
    fi

    configure_firewall

    echo ""
    log OK "Reconfigure complete"
    echo -e "  ${BOLD}URL:${NC} https://${FQDN}"
    echo -e "  ${BOLD}Health:${NC} curl -fsS http://127.0.0.1:5678/healthz"
    docker_compose ps
}

# =============================================================================
# STATUS & LOGS
# =============================================================================

status_stack() {
    echo ""
    echo -e "${CYN}========================================${NC}"
    echo -e "${CYN}  n8n Stack Status${NC}"
    echo -e "${CYN}========================================${NC}"
    echo ""

    require_install
    docker_compose ps
    
    echo ""
    echo "Resource Usage:"
    docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null || log WARN "No container stats (stack stopped?)"
    
    echo ""
    echo "Health Status:"
    if [[ ! -x "/usr/local/bin/n8n-healthcheck.sh" ]]; then
        log INFO "Healthcheck script missing; generating fallback healthcheck script."
        generate_healthcheck_script
    fi

    if [[ -x "/usr/local/bin/n8n-healthcheck.sh" ]]; then
        local health_output
        health_output=$(/usr/local/bin/n8n-healthcheck.sh 2>&1 || true)
        if [[ -n "$health_output" ]]; then
            echo "$health_output"
            return
        fi

        local fallback_output
        fallback_output=$(run_inline_healthcheck 2>&1 || true)
        if [[ -n "$fallback_output" ]]; then
            echo "$fallback_output"
            return
        fi

        log INFO "Healthcheck script produced no output; inline healthcheck fallback also produced no output."
        return
    fi

    run_inline_healthcheck || true
}

logs_stack() {
    require_install
    docker_compose logs -f --tail=100
}

# =============================================================================
# UPDATE & MAINTENANCE
# =============================================================================

update_stack() {
    log INFO "Updating n8n stack..."
    require_install
    load_install_config
    apply_runtime_fixes

    if declare -F save_release_snapshot >/dev/null; then
        save_release_snapshot
    fi
    
    if [[ "$BACKUP_ENABLED" == "true" ]] && [[ -x "$BACKUP_SCRIPT" ]]; then
        log INFO "Creating pre-update backup..."
        "$BACKUP_SCRIPT" || die "Backup failed; aborting update"
    fi
    
    log INFO "Pulling latest images..."
    docker_compose pull >>"$LOG_FILE" 2>&1 || log WARN "pull had errors; continuing"
    
    generate_compose
    if declare -F sync_secrets_from_env >/dev/null; then
        sync_secrets_from_env
    fi
    log INFO "Recreating containers..."
    docker_compose up -d --pull always --scale "n8n-worker=${N8N_WORKER_REPLICAS}" || die "docker compose up failed"
    wait_for_n8n_upstream 180 || true
    if declare -F save_release_snapshot >/dev/null; then
        save_release_snapshot
    fi
    
    log OK "Update complete"
}

check_n8n_upstream() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 5 "http://127.0.0.1:5678/healthz" >/dev/null 2>&1
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget --spider -q --timeout=5 "http://127.0.0.1:5678/healthz" 2>/dev/null
        return $?
    fi
    return 1
}

doctor_stack() {
    log INFO "Diagnosing 502 Bad Gateway (nginx -> n8n upstream)..."
    echo ""

    require_install
    [[ -f "$COMPOSE_FILE" ]] || die "Compose file not found: ${COMPOSE_FILE}"
    load_install_config

    echo "=== nginx ==="
    if systemctl is-active --quiet nginx 2>/dev/null; then
        log OK "nginx is running"
    else
        log ERROR "nginx is not running"
        systemctl start nginx 2>/dev/null || true
    fi
    if nginx -t 2>&1; then
        log OK "nginx configuration syntax OK"
    else
        log ERROR "nginx configuration invalid (fix before continuing)"
    fi
    if [[ -f "$NGINX_SITE" ]]; then
        echo "  Site file: ${NGINX_SITE}"
        grep -E 'upstream|server 127|proxy_pass' "$NGINX_SITE" 2>/dev/null | head -5 || true
    fi
    echo ""

    echo "=== Docker stack ==="
    docker_compose ps 2>/dev/null || true
    echo ""

    echo "=== Port 5678 on host (nginx must reach this) ==="
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp | grep -E ':5678\b' || log WARN "Nothing listening on port 5678"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tlnp 2>/dev/null | grep 5678 || log WARN "Nothing listening on port 5678"
    fi
    echo ""

    echo "=== n8n upstream health (http://127.0.0.1:5678/healthz) ==="
    if check_n8n_upstream; then
        log OK "n8n responds on 127.0.0.1:5678"
        echo ""
        echo "Upstream is healthy. If you still see 502, reload nginx:"
        echo "  sudo systemctl reload nginx"
        return 0
    fi

    log ERROR "n8n is NOT reachable on 127.0.0.1:5678 — this causes nginx 502"
    if docker logs n8n --tail 15 2>&1 | grep -qE 'ready on .*, port 443'; then
        log ERROR "n8n listens on port 443 inside the container (persisted config or compose override)."
        log ERROR "Fix: cd ${BASE_DIR} && sudo bash $0 sync-listen-port"
    fi
    if docker logs n8n --tail 30 2>&1 | grep -q 'Mismatching encryption keys'; then
        log ERROR "N8N_ENCRYPTION_KEY in ${ENV_FILE} does not match n8n_data volume config."
        log ERROR "Fix: run: sudo bash $0 reconfigure"
    fi
    echo ""

    local n8n_state
    n8n_state=$(docker inspect -f '{{.State.Status}}' n8n 2>/dev/null || echo "missing")
    log INFO "Container n8n state: ${n8n_state}"

    if [[ "$n8n_state" == "missing" ]] || [[ "$n8n_state" == "exited" ]]; then
        log INFO "Starting stack..."
        docker_compose up -d --scale "n8n-worker=${N8N_WORKER_REPLICAS}"
    fi

    echo ""
    echo "=== Last 40 lines: n8n logs ==="
    docker logs n8n --tail 40 2>&1 || true
    echo ""

    log INFO "Waiting up to 120s for n8n to become healthy..."
    local waited=0
    while [[ $waited -lt 120 ]]; do
        if check_n8n_upstream; then
            log OK "n8n is up after ${waited}s"
            systemctl reload nginx 2>/dev/null || true
            log OK "nginx reloaded. Try https://${FQDN:-n8n.example.com} again."
            return 0
        fi
        sleep 5
        ((waited+=5))
        echo -n "."
    done
    echo ""

    log ERROR "n8n still down. Common fixes:"
    echo "  1. Recreate: cd ${BASE_DIR} && sudo bash $0 reconfigure"
    echo "  2. Check stack: cd ${BASE_DIR} && sudo docker compose --profile ai --profile storage ps"
    echo "  3. Full reconfigure: sudo bash $0 reconfigure"
    echo "  4. Repair: $0 repair"
    return 1
}

repair_stack() {
    log INFO "Repairing n8n stack..."
    require_install
    load_install_config
    apply_runtime_fixes
    
    # Restart Docker
    log INFO "Restarting Docker service..."
    systemctl restart docker
    sleep 5
    
    # Restart nginx
    log INFO "Restarting nginx..."
    systemctl restart nginx
    
    # Recreate stack (no -v: keep volumes/credentials)
    log INFO "Recreating stack..."
    docker_compose up -d --force-recreate --scale "n8n-worker=${N8N_WORKER_REPLICAS}"
    
    wait_for_n8n_upstream 120 || true
    systemctl reload nginx 2>/dev/null || true

    log INFO "Checking SSL certificates..."
    certbot renew --quiet || true
    
    if check_n8n_upstream; then
        log OK "Repair complete — n8n upstream healthy"
    else
        log ERROR "Repair finished but n8n still not responding. Run: $0 reconfigure"
        docker logs n8n --tail 50 2>&1 || true
        return 1
    fi
}

# =============================================================================
# UNINSTALL
# =============================================================================

uninstall_stack() {
    check_root
    log WARN "This will remove all n8n data and configurations!"
    local confirm="${N8N_UNINSTALL_CONFIRM:-}"
    if [[ "$confirm" != "YES" ]]; then
        read -r -p "Are you sure? Type 'YES' to confirm: " confirm
    fi

    if [[ "$confirm" != "YES" ]]; then
        log INFO "Uninstall cancelled"
        return 0
    fi

    log INFO "Uninstalling n8n stack..."

    if ! resolve_install_base_dir; then
        log WARN "No install found (no docker-compose.yml or .env); cleaning containers/volumes by name"
        force_remove_n8n_stack
    else
        cd "$BASE_DIR" || die "Cannot cd ${BASE_DIR}"
        if [[ -f "$COMPOSE_FILE" ]]; then
            load_compose_profile_flags
            log INFO "Stopping stack (profiles: ${COMPOSE_PROFILE_ARGS[*]:-core only})..."
            if ! docker_compose down -v --remove-orphans; then
                log WARN "docker compose down failed; forcing cleanup"
                force_remove_n8n_stack
            fi
        else
            force_remove_n8n_stack
        fi

        if [[ -d "$BASE_DIR" ]]; then
            log INFO "Removing ${BASE_DIR} (including secrets and .env)..."
            find "$BASE_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        fi
    fi

    rm -f "$NGINX_ENABLED" 2>/dev/null || true
    rm -f "$NGINX_SITE" 2>/dev/null || true
    rm -f "$BACKUP_SCRIPT" 2>/dev/null || true
    rm -f /usr/local/bin/n8n-healthcheck.sh 2>/dev/null || true
    rm -f /etc/logrotate.d/n8n-deployer 2>/dev/null || true

    if crontab -l 2>/dev/null | grep -q "n8n"; then
        crontab -l 2>/dev/null | grep -v "n8n" | crontab - 2>/dev/null || true
    fi

    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || true
    fi

    log OK "Uninstall complete"
    echo "  Removed stack under: ${BASE_DIR:-unknown}"
    echo "  Repo/script in /opt/n8n-deployer was NOT deleted (only runtime install)"
}

# =============================================================================
# MAIN MENU
# =============================================================================

show_banner() {
    echo -e "${CYN}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║     n8n AI Stack Deployer v${SCRIPT_VERSION}                    ║"
    echo "║     Docker + PostgreSQL + Redis + nginx + SSL             ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

show_usage() {
    show_banner
    echo ""
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  install              Install n8n stack (interactive)"
    echo "  install-auto         Install with environment variables (non-interactive)"
    echo "  reconfigure          Re-apply deployer config on existing server (recommended)"
    echo "  preflight            Pre-deploy checks (DNS, disk, encryption key)"
    echo "  validate             Post-deploy health checks"
    echo "  restore [file]       Restore from backup archive"
    echo "  rollback             Roll back n8n image from .n8n-release"
    echo "  export-env-template  Write .env.example"
    echo "  version              Show stack versions"
    echo "  test-oauth           Print OAuth/webhook URLs"
    echo "  test-webhook         Test public URL (not 502)"
    echo "  status               Show stack status"
    echo "  logs                 Show container logs"
    echo "  update               Update stack to latest version"
    echo "  doctor               Diagnose nginx 502 / upstream n8n"
    echo "  sync-encryption-key  Fix N8N_ENCRYPTION_KEY mismatch with n8n_data volume"
    echo "  sync-listen-port     Fix n8n still listening on 443 instead of 5678"
    echo "  repair               Repair stack (restart services)"
    echo "  backup               Run manual backup"
    echo "  ai-test              Validate configured OpenAI API key"
    echo "  uninstall            Remove stack completely (type YES; or N8N_UNINSTALL_CONFIRM=YES)"
    echo "  menu                 Show interactive menu"
    echo ""
    echo "Environment Variables (for install-auto):"
    echo "  DOMAIN               Domain name (e.g., example.com)"
    echo "  SUBDOMAIN            Subdomain (default: n8n)"
    echo "  SSL_EMAIL            Email for SSL certificates"
    echo "  N8N_ADMIN_PASS       Owner password for first UI setup (min 12 chars)"
    echo "  N8N_PROXY_HOPS       Reverse-proxy hops (default: 1, DNS-only Cloudflare)"
    echo "  POSTGRES_PASSWORD    PostgreSQL password (min 12 chars)"
    echo "  REDIS_PASSWORD       Redis password (min 12 chars)"
    echo "  OPENAI_API_KEY       OpenAI API key (optional)"
    echo "  CLAUDE_API_KEY       Claude API key (optional)"
    echo "  GEMINI_API_KEY       Gemini API key (optional)"
    echo "  N8N_LICENSE_KEY      n8n enterprise license key (optional)"
    echo "  N8N_WORKER_REPLICAS  Worker replicas (default: 3)"
    echo "  AI_ROUTER_MODE       AI routing mode (default: api_only)"
    echo "  AI_PRIMARY           Primary AI provider (default: openai)"
    echo "  AI_SECONDARY         Secondary AI provider (default: gemini)"
    echo "  AI_COST_MODE         AI cost mode (default: balanced)"
    echo "  ENABLE_MONITORING    Enable monitoring stack (default: false)"
    echo "  N8N_VERSION          n8n Docker tag (default: 2.23.2, see https://hub.docker.com/r/n8nio/n8n/tags)"
    echo "  MINIO_VERSION        MinIO Docker tag (default: RELEASE.2025-09-07T16-13-09Z)"
    echo "  BACKUP_ENABLED       Enable backups (default: true)"
    echo "  AUTO_SSL             Enable auto SSL (default: true)"
    echo "  N8N_BASE_DIR         Override install path (default: /opt/n8n or /home/USER/n8n)"
    echo "  N8N_UNINSTALL_CONFIRM=YES  Non-interactive uninstall"
    echo ""
    echo "Examples:"
    echo "  $0 install"
    echo "  sudo $0 reconfigure"
    echo "  sudo $0 preflight && sudo $0 validate"
    echo "  DOMAIN=example.com SUBDOMAIN=n8n SSL_EMAIL=admin@example.com ... $0 install-auto"
    echo ""
}

menu() {
    while true; do
        show_banner
        echo ""
        echo "Main Menu:"
        echo "  1) Install n8n Stack"
        echo "  2) Show Status"
        echo "  3) View Logs"
        echo "  4) Update Stack"
        echo "  5) Repair Stack"
        echo "  9) Reconfigure Stack"
        echo " 10) Preflight checks"
        echo " 11) Validate stack"
        echo "  6) Run Backup"
        echo "  7) Test AI connection"
        echo "  8) Uninstall"
        echo "  0) Exit"
        echo ""
        
        read -r -p "Select option: " choice
        
        case "$choice" in
            1) run_menu_action install_flow ;;
            2) run_menu_action status_stack ;;
            3) run_menu_action logs_stack ;;
            4) run_menu_action update_stack ;;
            5) run_menu_action repair_stack ;;
            9) run_menu_action reconfigure_stack ;;
            10) run_menu_action preflight_menu ;;
            11) run_menu_action validate_menu ;;
            6) run_menu_action run_backup_manual ;;
            7) run_menu_action ai_test_menu ;;
            8) run_menu_action uninstall_stack ;;
            0) 
                echo "Goodbye!"
                exit 0
                ;;
            *) 
                log ERROR "Invalid option"
                ;;
        esac
        
        echo ""
        read -r -p "Press Enter to continue..."
    done
}

# =============================================================================
# INSTALL FLOW
# =============================================================================

install_flow() {
    check_root
    check_os
    check_dependencies

    # Idempotent: existing install → reconfigure (safe to re-run)
    if resolve_install_base_dir 2>/dev/null && [[ -f "$ENV_FILE" ]]; then
        log INFO "Existing install at ${BASE_DIR}; running idempotent reconfigure"
        reconfigure_stack
        return 0
    fi

    log INFO "Starting n8n installation..."
    check_resources
    ask_inputs
    ensure_dirs
    install_docker
    generate_env
    if [[ "$ENABLE_MONITORING" == "true" ]]; then
        generate_monitoring_config
    fi
    if declare -F preflight_stack >/dev/null; then preflight_stack || true; fi
    generate_compose
    setup_reverse_proxy
    deploy_stack || die "deploy_stack failed — see ${LOG_FILE}"
    save_release_snapshot 2>/dev/null || true
    validate_stack 2>/dev/null || true

    if [[ "$BACKUP_ENABLED" == "true" ]]; then
        setup_backup_system
    fi
    install_deployer_to_base
    export_env_template 2>/dev/null || true

    configure_firewall
    configure_fail2ban
    setup_monitoring
    
    echo ""
    echo -e "${GRN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GRN}║           INSTALLATION COMPLETE!                           ║${NC}"
    echo -e "${GRN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BOLD}n8n URL:${NC}        https://${FQDN}"
    echo -e "  ${BOLD}API Endpoint:${NC} https://${FQDN}/rest"
    echo -e "  ${BOLD}OAuth callback:${NC} https://${FQDN}/rest/oauth2-credential/callback"
    echo -e "  ${BOLD}Proxy hops:${NC}    N8N_PROXY_HOPS=${N8N_PROXY_HOPS} (use 2 if Cloudflare proxy/orange cloud is enabled)"
    echo ""
    echo "  Next steps:"
    echo "    1. Open https://${FQDN}"
    echo "    2. Create the owner account (use the password you chose at install)"
    echo "    3. In Google/Meta consoles, register redirect/webhook URLs with this FQDN"
    echo "    4. If using AI, verify keys with: $0 ai-test"
    echo ""
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

main() {
    # Parse command line arguments
    case "${1:-menu}" in
        install)
            check_root
            check_os
            check_dependencies
            if resolve_install_base_dir 2>/dev/null && [[ -f "$ENV_FILE" ]]; then
                log INFO "Existing install at ${BASE_DIR}; running idempotent reconfigure"
                reconfigure_stack
                exit 0
            fi
            ensure_dirs
            install_docker
            ask_inputs
            generate_env
            if [[ "$ENABLE_MONITORING" == "true" ]]; then
                generate_monitoring_config
            fi
            if declare -F preflight_stack >/dev/null; then preflight_stack || true; fi
            generate_compose
            setup_reverse_proxy
            deploy_stack || die "deploy_stack failed — see ${LOG_FILE}"
            save_release_snapshot 2>/dev/null || true
            validate_stack 2>/dev/null || true
            if [[ "$BACKUP_ENABLED" == "true" ]]; then
                setup_backup_system
            fi
            install_deployer_to_base
            export_env_template 2>/dev/null || true
            configure_firewall
            configure_fail2ban
            setup_monitoring
            ;;
        install-auto)
            check_root
            check_os
            check_dependencies
            if resolve_install_base_dir 2>/dev/null && [[ -f "$ENV_FILE" ]]; then
                log INFO "Existing install at ${BASE_DIR}; running idempotent reconfigure"
                reconfigure_stack
                exit 0
            fi
            ensure_dirs
            install_docker
            ask_inputs_non_interactive
            generate_env
            if [[ "$ENABLE_MONITORING" == "true" ]]; then
                generate_monitoring_config
            fi
            if declare -F preflight_stack >/dev/null; then preflight_stack || true; fi
            generate_compose
            setup_reverse_proxy
            deploy_stack || die "deploy_stack failed — see ${LOG_FILE}"
            save_release_snapshot 2>/dev/null || true
            validate_stack 2>/dev/null || true
            if [[ "$BACKUP_ENABLED" == "true" ]]; then
                setup_backup_system
            fi
            install_deployer_to_base
            configure_firewall
            configure_fail2ban
            setup_monitoring
            ;;
        reconfigure)
            reconfigure_stack
            ;;
        preflight)
            check_root
            resolve_install_base_dir 2>/dev/null || true
            preflight_stack
            ;;
        validate)
            require_install
            load_install_config
            validate_stack
            ;;
        restore)
            restore_stack "${2:-}"
            ;;
        rollback)
            rollback_stack
            ;;
        export-env-template)
            resolve_install_base_dir 2>/dev/null || true
            export_env_template
            ;;
        version|versions)
            resolve_install_base_dir 2>/dev/null || true
            show_version
            ;;
        test-oauth)
            resolve_install_base_dir 2>/dev/null || true
            test_oauth_urls
            ;;
        test-webhook)
            require_install
            load_install_config
            test_webhook
            ;;
        status)
            status_stack
            ;;
        logs)
            logs_stack
            ;;
        update)
            update_stack
            ;;
        repair)
            repair_stack
            ;;
        doctor)
            doctor_stack
            ;;
        sync-encryption-key)
            sync_encryption_key
            ;;
        sync-listen-port)
            sync_listen_port
            ;;
        backup)
            run_backup_manual
            ;;
        ai-test)
            require_install
            load_install_config
            ai_test
            ;;
        uninstall)
            uninstall_stack
            ;;
        menu)
            menu
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            echo "Unknown command: $1"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"