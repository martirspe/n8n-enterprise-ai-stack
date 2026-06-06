# Auxiliary commands: version, templates, OAuth/webhook tests, logrotate

export_env_template() {
    if declare -F resolve_install_base_dir >/dev/null; then
        resolve_install_base_dir 2>/dev/null || true
    fi
    ensure_dirs
    cat > "$ENV_TEMPLATE" <<'EOF'
# n8n Community Stack — copy to .env and fill values (never commit .env)
DOMAIN=example.com
SUBDOMAIN=n8n
SSL_EMAIL=admin@example.com
POSTGRES_PASSWORD=
REDIS_PASSWORD=
N8N_PROXY_HOPS=1
N8N_WORKER_REPLICAS=3
N8N_VERSION=2.23.2
ENABLE_QDRANT=true
ENABLE_MINIO=false
ENABLE_MONITORING=false
BACKUP_RETENTION_DAYS=7
# Optional AI keys (used by n8n AI nodes via env_file)
# OPENAI_API_KEY=
# CLAUDE_API_KEY=
# GEMINI_API_KEY=
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
    if declare -F resolve_install_base_dir >/dev/null; then
        resolve_install_base_dir 2>/dev/null || true
    fi
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
    if declare -F resolve_install_base_dir >/dev/null; then
        resolve_install_base_dir 2>/dev/null || true
    fi
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

# Audit .env before migrate/reconfigure (obsolete keys from pre-1.0.2 installs)
doctor_config() {
    if declare -F resolve_install_base_dir >/dev/null; then
        resolve_install_base_dir 2>/dev/null || true
    fi

    local env_path="${ENV_FILE:-}"
    [[ -f "$env_path" ]] || die "No .env found at ${env_path:-<unset>}. Run install or set N8N_BASE_DIR."

    local -a obsolete_keys=(
        N8N_ADMIN_PASS
        AI_ROUTER_MODE
        AI_PRIMARY
        AI_SECONDARY
        AI_COST_MODE
        N8N_LICENSE_KEY
        N8N_RUNNERS_ENABLED
    )
    local -a recommended_keys=(
        DOMAIN
        SUBDOMAIN
        SSL_EMAIL
    )
    local -a stale_secret_files=(
        openai_api_key
        claude_api_key
        gemini_api_key
    )

    local issues=0
    local secrets_dir="${SECRETS_DIR:-${BASE_DIR}/secrets}"

    echo ""
    echo "=== doctor-config: ${env_path} ==="
    echo ""

    local key line val
    for key in "${obsolete_keys[@]}"; do
        line=$(grep -E "^${key}=" "$env_path" 2>/dev/null | head -n 1 || true)
        if [[ -n "$line" ]]; then
            if [[ ${#line} -gt 72 ]]; then
                line="${line:0:68}..."
            fi
            log WARN "Obsolete variable: ${line}"
            ((issues++)) || true
        fi
    done

    for key in "${recommended_keys[@]}"; do
        val=$(grep -E "^${key}=" "$env_path" 2>/dev/null | cut -d= -f2- | head -n 1 || true)
        if [[ -z "$val" ]]; then
            log WARN "Missing recommended: ${key} (certbot / reconfigure need it)"
            ((issues++)) || true
        fi
    done

    if [[ -d "$secrets_dir" ]]; then
        local secret_name
        for secret_name in "${stale_secret_files[@]}"; do
            if [[ -f "${secrets_dir}/${secret_name}" ]]; then
                log WARN "Stale secret file: ${secrets_dir}/${secret_name} (API keys belong in .env only since 1.0.2)"
                ((issues++)) || true
            fi
        done
        if [[ -f "${secrets_dir}/minio_password" ]]; then
            val=$(grep -E '^ENABLE_MINIO=' "$env_path" 2>/dev/null | cut -d= -f2- | head -n 1 || true)
            if [[ "${val,,}" == "false" ]]; then
                log WARN "Stale secret file: ${secrets_dir}/minio_password (ENABLE_MINIO=false)"
                ((issues++)) || true
            fi
        fi
    fi

    echo ""
    if [[ $issues -eq 0 ]]; then
        log OK "No obsolete entries found — safe to run reconfigure"
        return 0
    fi

    log INFO "Found ${issues} item(s) to clean up"
    echo ""
    echo "Recommended steps:"
    echo "  1. sudo bash n8n-deployer.sh reconfigure"
    echo "     (regenerates .env without obsolete variables; adds DOMAIN/SUBDOMAIN/SSL_EMAIL if known)"
    echo "  2. Remove stale files under ${secrets_dir}/ if listed above"
    echo "  3. sudo bash n8n-deployer.sh doctor-config   # verify again"
    return 1
}
