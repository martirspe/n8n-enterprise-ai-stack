# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es/1.1.0/).  
Versionado del **deployer** (`n8n-deployer.sh`), no de la imagen `n8nio/n8n`.

## [1.0.4] - 2026-06-06

### Corregido

- **Prometheus:** `prometheus.yml` solo incluye Qdrant/MinIO si esos perfiles están activos; ruta MinIO corregida a `/minio/v2/metrics/cluster`; `MINIO_PROMETHEUS_AUTH_TYPE=public` cuando hay monitoring + MinIO.
- **Grafana:** provisioning automático del datasource Prometheus; contraseña admin en `GRAFANA_ADMIN_PASSWORD`; healthchecks y volumen persistente para Prometheus.
- **n8n metrics:** `N8N_METRICS_INCLUDE_QUEUE_METRICS=true` en modo cola.
- **`validate`:** comprueba Prometheus, Grafana y `/metrics` de n8n si `ENABLE_MONITORING=true`.

## [1.0.3] - 2026-06-06

### Añadido

- Comando **`doctor-config`**: audita `.env` y `secrets/` en busca de variables obsoletas (`AI_ROUTER_*`, `N8N_ADMIN_PASS`, etc.), claves recomendadas faltantes (`DOMAIN`, `SSL_EMAIL`) y archivos de secretos huérfanos antes de `reconfigure`.
- Opción **12** en el menú interactivo.

## [1.0.2] - 2026-06-06

### Eliminado

- Variables y prompts sin efecto: `AI_ROUTER_*`, `N8N_LICENSE_KEY`, `N8N_ADMIN_PASS`, `N8N_RUNNERS_ENABLED`.
- Secretos duplicados de API keys (`openai_api_key`, `claude_api_key`, `gemini_api_key`); las claves viven solo en `.env` cuando se configuran.

### Cambiado

- Enfoque **n8n Community** en modo cola (sin branding Enterprise).
- Instalación interactiva: solo pregunta lo que el deploy usa (`N8N_PROXY_HOPS`, Qdrant, MinIO, workers, OpenAI opcional, monitoring).
- `ENABLE_MINIO=false` por defecto; MinIO solo si lo activas.
- `.env` persiste `DOMAIN`, `SUBDOMAIN`, `SSL_EMAIL` (certbot en `reconfigure`).
- Redis `maxmemory` 512 MB (antes 256 MB).
- Owner: se crea en el asistente web de n8n (no hay contraseña en el script).

## [1.0.1] - 2026-06-06

### Corregido

- **nginx:** sin `limit_req` en editor/API (evita 503 al cargar `/assets/*.js`); rate limit opcional solo en `/webhook/` (`ENABLE_NGINX_RATE_LIMIT=false` por defecto).
- **`deploy_stack`:** no aborta si `docker compose pull` falla; continúa con `up --pull always`; registro explícito en log.
- **`fix_n8n_config_listen_port`:** no interrumpe el install si el volumen `n8n_data` aún no existe.
- **`docker_compose`:** aplica perfiles `ai` / `storage` / `observe` en `status`, `logs`, `validate`, `doctor`, `uninstall`, etc.
- **`resolve_install_base_dir` / `require_install`:** detecta `/home/USER/n8n` y `/opt/n8n`; variable `N8N_BASE_DIR`.
- **Install idempotente:** si ya existe `.env`, `install` / `install-auto` ejecutan `reconfigure`.
- **Menú:** errores no cierran el script (`run_menu_action`); backup crea el script si falta.
- **`uninstall`:** perfiles Compose, limpieza forzada de contenedores/volúmenes y archivos ocultos (`.env`, `secrets/`).
- **Healthcheck** del contenedor `n8n` con Node (más fiable en la imagen oficial).
- **nginx:** directiva `http2 on`; eliminado OCSP stapling que generaba warnings.
- **`reconfigure`:** falla con mensaje claro si `deploy_stack` no termina.

### Añadido

- `.gitignore` para `.env`, `secrets/`, backups y logs.
- Secretos `claude_api_key` y `gemini_api_key`; `load_ai_keys_from_secrets` para `ai-test`.
- `N8N_UNINSTALL_CONFIRM=YES` para desinstalación no interactiva.
- Ejemplos de dominio genéricos (`example.com`) en script y documentación.

## [1.0.0] - 2026-06-04

Primera versión pública del **n8n AI Stack Deployer**.

### Añadido

- Script principal [`n8n-deployer.sh`](n8n-deployer.sh) y librerías [`deployer-lib/`](deployer-lib/):
  - `secrets.sh` — archivos de secretos y montajes `*_FILE`
  - `preflight.sh` — comprobaciones pre/post despliegue
  - `backup-restore.sh` — restore, rollback, snapshot `.n8n-release`
  - `extras.sh` — version, test-oauth, test-webhook, plantillas, logrotate
- Stack en **modo cola:** PostgreSQL 16, Redis 7 (`noeviction` + AOF), `n8n` + workers escalables.
- Perfiles Docker Compose: `ai` (Qdrant), `storage` (MinIO), `observe` (Prometheus/Grafana).
- Reverse proxy **nginx** + Let's Encrypt (certbot); upstream `127.0.0.1:5678`.
- Configuración de producción: `N8N_PORT=5678`, `N8N_PROXY_HOPS`, `WEBHOOK_URL`, OAuth/webhooks, WebSocket.
- Secretos en `${BASE_DIR}/secrets/` (encryption, postgres, redis, OpenAI).
- Comandos CLI y menú interactivo: `install`, `install-auto`, `reconfigure`, `preflight`, `validate`, `doctor`, `restore`, `rollback`, `test-oauth`, `test-webhook`, `sync-encryption-key`, `sync-listen-port`, `ai-test`, `repair`, `update`, `backup`, `uninstall`, `status`, `logs`.
- Sincronización de `N8N_ENCRYPTION_KEY` con volumen `n8n_data`.
- UFW, fail2ban (exclusiones OAuth/webhook), backups programados con retención.
- Documentación [`README.md`](README.md) y este changelog.

### Seguridad

- `security_opt: no-new-privileges` en contenedores n8n.
- n8n publicado solo en `127.0.0.1:5678`; sin `N8N_BASIC_AUTH_*` (obsoleto en n8n 2.x).
- Métricas `/metrics` restringidas a localhost en nginx.

### Notas

- Imagen n8n por defecto: `2.23.2` (configurable con `N8N_VERSION`).
- `N8N_RUNNERS_ENABLED=false` por defecto.
- `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true` en modo cola.
