# Backup, restore, rollback

BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"

restore_stack() {
    local archive="${1:-}"
    check_root
    cd "$BASE_DIR" || die "Missing ${BASE_DIR}"

    if [[ -z "$archive" ]]; then
        echo "Available backups:"
        ls -1t "${BACKUP_DIR}"/n8n_backup_*.tar.gz 2>/dev/null | head -10 || echo "  (none)"
        read -r -p "Backup file path: " archive
    fi

    [[ -f "$archive" ]] || die "Backup not found: ${archive}"

    log WARN "Restore will stop n8n and overwrite DB/Redis/env from backup"
    read -r -p "Type RESTORE to continue: " confirm
    [[ "$confirm" == "RESTORE" ]] || die "Restore cancelled"

    local tmp
    tmp=$(mktemp -d)
    tar -xzf "$archive" -C "$tmp"

    load_existing_configuration 2>/dev/null || true

    docker compose stop n8n n8n-worker 2>/dev/null || true

    local pg_file shell_env redis_file
    pg_file=$(find "$tmp" -name 'postgres_*.sql.gz' | head -1)
    redis_file=$(find "$tmp" -name 'redis_*.rdb' | head -1)
    shell_env=$(find "$tmp" -name 'env_*.bak' | head -1)

    [[ -n "$pg_file" ]] || die "No postgres dump in archive"
    gunzip -c "$pg_file" | docker exec -i n8n-postgres psql -U n8n -d n8n -v ON_ERROR_STOP=1 >/dev/null
    log OK "PostgreSQL restored"

    if [[ -n "$redis_file" ]]; then
        docker compose stop redis
        docker cp "$redis_file" n8n-redis:/data/dump.rdb
        docker compose start redis
        log OK "Redis restored"
    fi

    if [[ -n "$shell_env" ]]; then
        cp "$shell_env" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
        load_existing_configuration
        resolve_encryption_key
        sync_secrets_from_env
        log OK "Environment file restored"
    fi

    local data_dir
    data_dir=$(find "$tmp" -maxdepth 1 -type d -name 'n8n_data_*' | head -1)
    if [[ -n "$data_dir" ]]; then
        docker run --rm \
            -v n8n_data:/target \
            -v "${data_dir}:/source:ro" \
            alpine sh -c 'rm -rf /target/* /target/.[!.]* 2>/dev/null; cp -a /source/. /target/' 2>/dev/null || \
            log WARN "n8n_data volume restore skipped (manual copy may be needed)"
        log OK "n8n_data volume restored"
    fi

    rm -rf "$tmp"
    generate_compose
    docker compose up -d --scale "n8n-worker=${N8N_WORKER_REPLICAS:-3}"
    wait_for_n8n_upstream 180 || true
    systemctl reload nginx 2>/dev/null || true
    log OK "Restore complete"
}

save_release_snapshot() {
    mkdir -p "$BASE_DIR"
    cat > "$RELEASE_FILE" <<EOF
N8N_VERSION=${N8N_VERSION}
DEPLOYED_AT=$(date -Iseconds)
FQDN=${FQDN}
EOF
}

rollback_stack() {
    check_root
    cd "$BASE_DIR"
    [[ -f "$RELEASE_FILE" ]] || die "No ${RELEASE_FILE} for rollback"

    # shellcheck disable=SC1090
    source "$RELEASE_FILE"
    local prev="${N8N_VERSION:-}"
    [[ -n "$prev" ]] || die "Previous version unknown"

    log INFO "Rolling back to n8n image tag: ${prev}"
    N8N_VERSION="$prev"
    if [[ "$BACKUP_ENABLED" == "true" ]] && [[ -x "$BACKUP_SCRIPT" ]]; then
        "$BACKUP_SCRIPT" || log WARN "Pre-rollback backup failed"
    fi
    load_existing_configuration
    generate_env
    generate_compose
    deploy_stack
}
