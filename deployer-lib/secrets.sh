# Secrets management (files + Docker mounts; no secrets in compose interpolation)

SECRETS_DIR="${SECRETS_DIR:-${BASE_DIR}/secrets}"

ensure_secrets_dir() {
    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"
    if [[ -n "${SUDO_USER:-}" ]] && [[ "$SUDO_USER" != "root" ]]; then
        chown "$SUDO_USER:$SUDO_USER" "$SECRETS_DIR" 2>/dev/null || true
    fi
}

write_secret_file() {
    local name="$1"
    local value="$2"
    local path="${SECRETS_DIR}/${name}"
    printf '%s' "$value" > "$path"
    chmod 600 "$path"
}

sync_secrets_from_env() {
    ensure_secrets_dir
    log INFO "Syncing secrets to ${SECRETS_DIR} (chmod 600)..."

    [[ -n "${ENCRYPTION_KEY:-}" ]] && write_secret_file "encryption_key" "$ENCRYPTION_KEY"
    [[ -n "${POSTGRES_PASSWORD:-}" ]] && write_secret_file "postgres_password" "$POSTGRES_PASSWORD"
    [[ -n "${REDIS_PASSWORD:-}" ]] && write_secret_file "redis_password" "$REDIS_PASSWORD"
    if [[ -n "${MINIO_PASSWORD:-}" ]]; then
        write_secret_file "minio_password" "$MINIO_PASSWORD"
    fi
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then
        write_secret_file "openai_api_key" "$OPENAI_API_KEY"
    fi
    if [[ -n "${CLAUDE_API_KEY:-}" ]]; then
        write_secret_file "claude_api_key" "$CLAUDE_API_KEY"
    fi
    if [[ -n "${GEMINI_API_KEY:-}" ]]; then
        write_secret_file "gemini_api_key" "$GEMINI_API_KEY"
    fi

    log OK "Secret files updated"
}

read_secret_file() {
    local name="$1"
    local path="${SECRETS_DIR}/${name}"
    if [[ -f "$path" ]]; then
        cat "$path"
    fi
}

load_ai_keys_from_secrets() {
    ensure_secrets_dir
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
        OPENAI_API_KEY=$(read_secret_file "openai_api_key" || true)
    fi
    if [[ -z "${CLAUDE_API_KEY:-}" ]]; then
        CLAUDE_API_KEY=$(read_secret_file "claude_api_key" || true)
    fi
    if [[ -z "${GEMINI_API_KEY:-}" ]]; then
        GEMINI_API_KEY=$(read_secret_file "gemini_api_key" || true)
    fi
}

# Docker Compose fragment: volume + env _FILE paths (sourced into service blocks)
compose_secrets_volumes() {
    cat <<EOF
    volumes:
      - ${SECRETS_DIR}:/secrets:ro
EOF
}

compose_secret_env_files() {
    cat <<'EOF'
      - "N8N_ENCRYPTION_KEY_FILE=/secrets/encryption_key"
      - "DB_POSTGRESDB_PASSWORD_FILE=/secrets/postgres_password"
      - "QUEUE_BULL_REDIS_PASSWORD_FILE=/secrets/redis_password"
EOF
}

compose_security_hardening() {
    cat <<'EOF'
    security_opt:
      - no-new-privileges:true
EOF
}
