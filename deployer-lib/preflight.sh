# Preflight and post-deploy validation

preflight_stack() {
    log INFO "Running preflight checks..."
    local errors=0

    if declare -F resolve_install_base_dir >/dev/null; then
        resolve_install_base_dir 2>/dev/null || true
    fi

    if [[ -f "$ENV_FILE" ]]; then
        load_existing_configuration
    elif [[ -n "${DOMAIN:-}" ]]; then
        FQDN="${SUBDOMAIN:-n8n}.${DOMAIN}"
    else
        log WARN "FQDN unknown until install/reconfigure (set DOMAIN or .env)"
        FQDN="${FQDN:-n8n.example.com}"
    fi

    echo ""
    echo "=== Preflight: ${FQDN} ==="

    if command -v host &>/dev/null; then
        local resolved
        resolved=$(host "$FQDN" 2>/dev/null | grep "has address" | head -1 | awk '{print $4}' || true)
        if [[ -n "$resolved" ]]; then
            log OK "DNS ${FQDN} -> ${resolved}"
            local server_ip
            server_ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
            if [[ -n "$server_ip" && "$resolved" != "$server_ip" ]]; then
                log WARN "DNS IP (${resolved}) differs from this server public IP (${server_ip})"
            fi
        else
            log WARN "Could not resolve ${FQDN}"
            ((errors++)) || true
        fi
    fi

    for port in 80 443; do
        if ss -tln 2>/dev/null | grep -q ":${port} "; then
            log OK "Port ${port} in use (expected for nginx)"
        else
            log WARN "Port ${port} not listening (nginx may start later)"
        fi
    done

    if ss -tln 2>/dev/null | grep -q ':5678 '; then
        if curl -fsS --max-time 3 http://127.0.0.1:5678/healthz >/dev/null 2>&1; then
            log OK "n8n upstream already healthy on 5678"
        else
            log WARN "Port 5678 open but /healthz failed"
        fi
    fi

    local disk_avail
    disk_avail=$(df -BG "$BASE_DIR" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G' || echo "0")
    if [[ "${disk_avail:-0}" -lt 10 ]]; then
        log WARN "Low disk: ${disk_avail}GB free under ${BASE_DIR}"
    else
        log OK "Disk: ${disk_avail}GB free"
    fi

    local mem_total
    mem_total=$(free -m | awk '/^Mem:/{print $2}')
    if [[ "$mem_total" -lt 2048 ]]; then
        log WARN "RAM ${mem_total}MB — 2GB+ recommended for queue mode"
    fi

    if docker volume inspect n8n_data &>/dev/null 2>&1; then
        resolve_encryption_key
        local vol_key env_key
        env_key=$(read_env_var "N8N_ENCRYPTION_KEY" "")
        load_encryption_key_from_volume || true
        vol_key="$ENCRYPTION_KEY"
        if [[ -n "$env_key" && -n "$vol_key" && "$env_key" != "$vol_key" ]]; then
            log ERROR "Encryption key mismatch: .env vs n8n_data volume"
            ((errors++)) || true
        else
            log OK "Encryption key consistent (or volume new)"
        fi
    fi

    if [[ "${N8N_PROXY_HOPS:-1}" == "1" ]]; then
        log INFO "N8N_PROXY_HOPS=1 (Cloudflare DNS-only / single nginx)"
    fi

    echo ""
    if [[ $errors -gt 0 ]]; then
        log ERROR "Preflight failed with ${errors} error(s)"
        return 1
    fi
    log OK "Preflight passed"
    return 0
}

validate_stack() {
    log INFO "Validating running stack..."
    local errors=0

    if declare -F resolve_install_base_dir >/dev/null; then
        resolve_install_base_dir 2>/dev/null || true
    fi
    cd "$BASE_DIR" || die "Cannot cd ${BASE_DIR}"

    if declare -F docker_compose >/dev/null; then
        if ! docker_compose config >/dev/null 2>&1; then
            log ERROR "docker compose config invalid"
            return 1
        fi
    elif ! docker compose config >/dev/null 2>&1; then
        log ERROR "docker compose config invalid"
        return 1
    fi
    log OK "docker compose config valid"

    if ! check_n8n_upstream; then
        log ERROR "n8n /healthz not reachable on 127.0.0.1:5678"
        ((errors++)) || true
    else
        log OK "n8n /healthz OK"
    fi

    if curl -fsS --max-time 10 "https://${FQDN}/healthz" >/dev/null 2>&1; then
        log OK "Public https://${FQDN}/healthz OK"
    else
        log WARN "Public HTTPS health check failed (DNS/SSL/nginx?)"
    fi

    if docker logs n8n --tail 20 2>&1 | grep -q 'Mismatching encryption keys'; then
        log ERROR "Encryption key mismatch in logs"
        ((errors++)) || true
    fi

    if docker logs n8n --tail 10 2>&1 | grep -qE 'ready on .*, port 443'; then
        log ERROR "n8n still listening on port 443"
        ((errors++)) || true
    fi

    if [[ "${ENABLE_MONITORING:-false}" == "true" ]]; then
        if declare -F validate_monitoring_stack >/dev/null; then
            validate_monitoring_stack || ((errors++)) || true
        fi
    fi

    if [[ $errors -gt 0 ]]; then
        return 1
    fi
    log OK "Stack validation passed"
    return 0
}

validate_monitoring_stack() {
    log INFO "Validating Prometheus/Grafana (profile observe)..."
    local errors=0

    if ! curl -fsS --max-time 5 http://127.0.0.1:9090/-/healthy >/dev/null 2>&1; then
        log ERROR "Prometheus not healthy on 127.0.0.1:9090"
        ((errors++)) || true
    else
        log OK "Prometheus /-/healthy OK"
    fi

    if ! curl -fsS --max-time 5 http://127.0.0.1:3000/api/health >/dev/null 2>&1; then
        log ERROR "Grafana not healthy on 127.0.0.1:3000"
        ((errors++)) || true
    else
        log OK "Grafana /api/health OK"
    fi

    if docker exec n8n wget -qO- http://127.0.0.1:5678/metrics 2>/dev/null | head -1 | grep -q '^#'; then
        log OK "n8n /metrics exposes Prometheus data"
    elif docker exec n8n node -e "require('http').get('http://127.0.0.1:5678/metrics',r=>{let d='';r.on('data',c=>d+=c);r.on('end',()=>process.exit(d.startsWith('#')?0:1))}).on('error',()=>process.exit(1))" 2>/dev/null; then
        log OK "n8n /metrics exposes Prometheus data"
    else
        log ERROR "n8n /metrics not reachable (check N8N_METRICS=true)"
        ((errors++)) || true
    fi

    local prom_container="${PROMETHEUS_CONTAINER:-n8n-prometheus}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$prom_container"; then
        if docker exec "$prom_container" wget -qO- http://n8n:5678/metrics 2>/dev/null | head -1 | grep -q '^#'; then
            log OK "Prometheus can scrape n8n:5678/metrics"
        elif docker exec "$prom_container" wget -qO- "http://127.0.0.1:9090/api/v1/targets" 2>/dev/null | grep -q '"health":"up"'; then
            log OK "Prometheus reports at least one target UP"
        else
            log WARN "Prometheus scrape of n8n not confirmed — check Status → Targets in UI"
        fi
    fi

    if [[ $errors -gt 0 ]]; then
        log ERROR "Monitoring validation failed"
        return 1
    fi
    log OK "Monitoring validation passed"
    return 0
}
