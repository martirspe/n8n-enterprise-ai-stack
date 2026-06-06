# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/).  
Versionado del **deployer** (`n8n-deployer.sh`), no de la imagen `n8nio/n8n`.

## [1.0.0] - 2026-06-04

### Añadido

- Script principal `n8n-deployer.sh` (**n8n AI Stack Deployer**).
- Librerías en `deployer-lib/`: secretos, preflight/validate, backup/restore/rollback, extras.
- Modo cola: PostgreSQL, Redis (`noeviction` + AOF), workers escalables.
- Perfiles Docker Compose: `ai` (Qdrant), `storage` (MinIO), `observe` (Prometheus/Grafana).
- Secretos en `${BASE_DIR}/secrets/` con sincronización desde `.env` (OpenAI, Claude, Gemini).
- `load_ai_keys_from_secrets` para `ai-test` cuando las claves están solo en `secrets/`.
- Comandos: `install`, `install-auto`, `reconfigure`, `preflight`, `validate`, `doctor`, `restore`, `rollback`, `test-oauth`, `test-webhook`, `sync-encryption-key`, `sync-listen-port`, `ai-test`, etc.
- nginx: SSL, rate limit, rutas OAuth/webhook, WebSocket, métricas solo localhost.
- Documentación en `README.md` y `CHANGELOG.md`.
- `.gitignore` para `.env`, `secrets/`, backups y logs.

### Corregido (respecto a despliegues anteriores v4.x)

- `N8N_PORT=5678` (evita 502 por n8n escuchando en 443).
- `N8N_PROXY_HOPS` para Cloudflare DNS-only vs proxy naranja.
- Eliminación de `N8N_BASIC_AUTH_*` obsoleto en n8n 2.x.
- Publicación de n8n solo en `127.0.0.1:5678`.
- Orden de instalación: reverse proxy antes del stack.
- Sincronización de `N8N_ENCRYPTION_KEY` con volumen `n8n_data`.
- `fix_n8n_config_listen_port` no aborta el install si `n8n_data` aún no existe (primera instalación).
- `docker_compose` aplica perfiles (`ai`/`storage`/`observe`) en `status`, `logs`, `validate`, etc.
- `deploy_stack` continúa con `up --pull always` si `pull` falla; sin abortar por `pipefail` en pull.
- nginx: sin `limit_req` en editor/API (evita 503 en `/assets/*.js`); rate limit opcional solo en webhooks.
- Eliminado `N8N_DISABLE_PRODUCTION_MAIN_PROCESS` en main (UI estable como monolito).
- Healthcheck n8n con `node`; `http2 on` en nginx; sin OCSP stapling que generaba warnings.

### Seguridad

- `security_opt: no-new-privileges` en contenedores n8n.
- fail2ban con exclusiones para OAuth/webhooks.
- Ejemplos de dominio genéricos (`example.com`) en script y documentación.

### Notas

- Imagen n8n por defecto: `2.23.2` (configurable con `N8N_VERSION`).
- Runners internos deshabilitados por defecto (`N8N_RUNNERS_ENABLED=false`).
