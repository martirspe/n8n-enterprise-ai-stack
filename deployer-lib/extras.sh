# Auxiliary commands: version, templates, OAuth/webhook tests, logrotate

export_env_template() {
    ensure_dirs
    cat > "$ENV_TEMPLATE" <<'EOF'
# n8n AI Stack — copy to .env and fill values (never commit .env)
DOMAIN=example.com
SUBDOMAIN=n8n
SSL_EMAIL=admin@example.com
POSTGRES_PASSWORD=
REDIS_PASSWORD=
N8N_PROXY_HOPS=1
N8N_WORKER_REPLICAS=3
N8N_VERSION=2.23.2
ENABLE_MONITORING=false
ENABLE_QDRANT=true
ENABLE_MINIO=true
BACKUP_RETENTION_DAYS=7
# Optional SMTP (owner invites / password reset)
# N8N_EMAIL_MODE=smtp
# N8N_SMTP_HOST=
# N8N_SMTP_PORT=587
# N8N_SMTP_USER=
# N8N_SMTP_PASS=
# N8N_SMTP_SENDER=
EOF
    chmod 644 "$ENV_TEMPLATE"
    log OK "Template written: ${ENV_TEMPLATE}"
}

show_version() {
    echo "n8n AI Stack Deployer v${SCRIPT_VERSION}"
    echo "  Base dir:    ${BASE_DIR}"
    echo "  n8n image:   n8nio/n8n:${N8N_VERSION}"
    echo "  Postgres:    ${POSTGRES_VERSION}-alpine"
    echo "  Redis:       ${REDIS_VERSION}-alpine"
    if [[ -f "$RELEASE_FILE" ]]; then
        echo "  Last release snapshot:"
        sed 's/^/    /' "$RELEASE_FILE"
    fi
    if [[ -f "$COMPOSE_FILE" ]]; then
        if declare -F docker_compose >/dev/null; then
            cd "$BASE_DIR" && docker_compose ps 2>/dev/null || true
        else
            cd "$BASE_DIR" && docker compose ps 2>/dev/null || true
        fi
    fi
}

test_oauth_urls() {
    if [[ -f "$ENV_FILE" ]]; then
        load_existing_configuration
    fi
    FQDN="${FQDN:-$(read_env_var FQDN "")}"
    [[ -n "$FQDN" ]] || die "FQDN not set"
    echo "Register these URLs in Google Cloud / Meta Developer Console:"
    echo "  OAuth callback: https://${FQDN}/rest/oauth2-credential/callback"
    echo "  Editor:         https://${FQDN}"
    echo "  WEBHOOK_URL:    https://${FQDN}/"
    echo "  N8N_PROXY_HOPS: ${N8N_PROXY_HOPS:-1} (use 2 if Cloudflare orange-cloud proxy)"
}

test_webhook() {
    if [[ -f "$ENV_FILE" ]]; then
        load_existing_configuration
    fi
    local base="https://${FQDN}/"
    log INFO "Testing webhook base (expect 404/405, not 502): ${base}"
    local code
    code=$(curl -k -sS -o /dev/null -w '%{http_code}' --max-time 15 "${base}" || echo "000")
    echo "HTTP ${code}"
    if [[ "$code" == "502" || "$code" == "000" ]]; then
        log ERROR "Bad gateway or timeout — run: $0 doctor"
        return 1
    fi
    log OK "Origin reachable (not 502)"
}

setup_logrotate() {
    cat > /etc/logrotate.d/n8n-deployer <<EOF
${LOG_FILE} {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    create 640 root adm
}
EOF
    log OK "Logrotate configured for ${LOG_FILE}"
}

install_deployer_libs() {
    local src_dir="${SCRIPT_DIR}/deployer-lib"
    local dest="${BASE_DIR}/deployer-lib"
    if [[ -d "$src_dir" ]] && [[ "$src_dir" != "$dest" ]]; then
        mkdir -p "$dest"
        cp -a "${src_dir}/." "$dest/"
        log OK "Deployer libraries installed to ${dest}"
    fi
}
