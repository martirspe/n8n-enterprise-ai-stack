# n8n AI Stack Deployer

Despliegue y operación de **n8n Community** en producción: modo cola, PostgreSQL, Redis, nginx, SSL y perfiles opcionales (Qdrant, MinIO, Prometheus/Grafana).

| | |
|---|---|
| **Versión deployer** | `1.0.4` |
| **Script** | [`n8n-deployer.sh`](n8n-deployer.sh) + [`deployer-lib/`](deployer-lib/) |
| **Cambios** | [`CHANGELOG.md`](CHANGELOG.md) |

---

## Inicio rápido

```bash
# 1. Copiar al servidor (mantén deployer-lib/ junto al script)
scp n8n-deployer.sh deployer-lib devops@SERVIDOR:/tmp/

# 2. En el VPS
sudo mkdir -p /opt/n8n/deployer-lib
sudo cp /tmp/n8n-deployer.sh /opt/n8n/
sudo cp -r /tmp/deployer-lib/* /opt/n8n/deployer-lib/
sudo chmod +x /opt/n8n/n8n-deployer.sh

# 3. Instalar (interactivo)
cd /opt/n8n && sudo bash n8n-deployer.sh install

# 4. Comprobar
sudo bash n8n-deployer.sh validate
```

Tras el primer acceso a `https://<FQDN>`, crea el usuario **owner** en el asistente web de n8n (el script no gestiona usuarios).

---

## ¿Qué flujo necesito?

| Objetivo | Comandos | ¿Borra workflows? |
|----------|----------|-------------------|
| Primera instalación | `install` o `install-auto` | — |
| Actualizar script o config | `reconfigure` → `validate` | No |
| Solo imágenes Docker nuevas | `update` → `validate` | No |
| Auditar `.env` viejo | `doctor-config` → `reconfigure` | No |
| Empezar de cero | `uninstall` → `install` | **Sí** |
| Recuperar backup | `restore` | No (restaura) |

**Importante:** si ya existe `.env`, `install` / `install-auto` ejecutan `reconfigure` (no reinstalan).

### Reinstalación limpia

```bash
export N8N_BASE_DIR=/home/devops/n8n   # opcional; ver abajo

sudo bash n8n-deployer.sh backup          # opcional
sudo N8N_UNINSTALL_CONFIRM=YES bash n8n-deployer.sh uninstall
sudo -E bash n8n-deployer.sh install-auto
sudo bash n8n-deployer.sh validate
```

`uninstall` borra contenedores, volúmenes Docker y el contenido de `BASE_DIR` (`.env`, `secrets/`, workflows). **No** borra certificados Let's Encrypt ni el repo del script si está en otra ruta.

### Ruta de instalación

Detección automática (en este orden):

1. `N8N_BASE_DIR` si lo exportas
2. `/home/USUARIO/n8n` (sudo con usuario no root)
3. `/opt/n8n` (root)

```bash
export N8N_BASE_DIR=/home/devops/n8n
sudo -E bash n8n-deployer.sh status
```

---

## Requisitos

- Ubuntu 22.04/24.04 LTS (u otra con systemd)
- 2+ vCPU, 4 GB RAM, 20 GB disco
- Puertos **80** y **443** abiertos; DNS del FQDN apuntando al servidor
- Ejecución con **sudo** o root

El script instala Docker, nginx y certbot si faltan.

---

## Instalación

### Interactiva

```bash
cd /opt/n8n   # o tu N8N_BASE_DIR
sudo bash n8n-deployer.sh install
```

Pregunta: dominio, email SSL, contraseñas Postgres/Redis, `N8N_PROXY_HOPS`, workers, Qdrant, MinIO, OpenAI (opcional) y monitoring.

### Automática (`install-auto`)

```bash
export DOMAIN="example.com"
export SUBDOMAIN="n8n"
export SSL_EMAIL="admin@example.com"
export POSTGRES_PASSWORD="ContraseñaSegura12+"
export REDIS_PASSWORD="ContraseñaSegura12+"
export N8N_PROXY_HOPS="1"
export N8N_WORKER_REPLICAS="3"
export ENABLE_QDRANT="true"
export ENABLE_MINIO="false"
export ENABLE_MONITORING="false"

sudo -E bash n8n-deployer.sh install-auto
sudo bash n8n-deployer.sh test-oauth
sudo bash n8n-deployer.sh validate
```

Plantilla completa: `sudo bash n8n-deployer.sh export-env-template`

### Actualizar tras subir script nuevo

```bash
sudo bash n8n-deployer.sh reconfigure
sudo bash n8n-deployer.sh validate
```

---

## Stack

### Siempre activo

| Servicio | Función |
|----------|---------|
| n8n | Editor, API, webhooks |
| n8n-worker | Ejecuciones en cola (`EXECUTIONS_MODE=queue`) |
| PostgreSQL 16 | Base de datos |
| Redis 7 | Cola Bull |
| nginx + Certbot | HTTPS en 443; n8n solo en `127.0.0.1:5678` |

### Perfiles opcionales

| Perfil | Activar con | Servicio | Uso |
|--------|-------------|----------|-----|
| `ai` | `ENABLE_QDRANT=true` (default) | Qdrant | Vectores / RAG en workflows |
| `storage` | `ENABLE_MINIO=true` | MinIO | S3-compatible (off por defecto) |
| `observe` | `ENABLE_MONITORING=true` | Prometheus + Grafana | Métricas locales (off por defecto) |

Claves OpenAI / Claude / Gemini: opcionales en `.env` para nodos IA de n8n.

### Monitoring (`ENABLE_MONITORING=true`)

| URL | Acceso |
|-----|--------|
| Prometheus | `http://127.0.0.1:9090` |
| Grafana | `http://127.0.0.1:3000` — usuario `admin`, contraseña en `GRAFANA_ADMIN_PASSWORD` (`.env`) |

`validate` comprueba Prometheus, Grafana y `/metrics` de n8n cuando el perfil está activo.

> El cron de healthcheck del host (`setup_monitoring`) es independiente de Prometheus/Grafana.

---

## Comandos

```bash
sudo bash n8n-deployer.sh <comando>
```

### Despliegue

| Comando | Descripción |
|---------|-------------|
| `install` | Instalación interactiva |
| `install-auto` | Instalación con variables de entorno |
| `reconfigure` | Regenera config y redespliega (uso habitual tras actualizar) |
| `uninstall` | Elimina todo en `BASE_DIR` (confirmar `YES`) |

### Operación

| Comando | Descripción |
|---------|-------------|
| `status` | Estado de contenedores |
| `logs` | Logs en vivo |
| `update` | Nuevas imágenes Docker (backup previo si `BACKUP_ENABLED=true`) |
| `repair` | Reinicia Docker, nginx y recrea stack |
| `backup` | Backup manual |
| `restore [archivo]` | Restaura `.tar.gz` (confirmar `RESTORE`) |
| `rollback` | Imagen n8n anterior (`.n8n-release`) |

### Diagnóstico

| Comando | Descripción |
|---------|-------------|
| `validate` | Salud del stack (+ monitoring si activo) |
| `preflight` | DNS, disco, RAM, cifrado |
| `doctor` | Diagnóstico 502 / puerto / encryption key |
| `doctor-config` | Audita `.env` obsoleto antes de migrar |
| `sync-listen-port` | Fuerza puerto 5678 en volumen n8n |
| `sync-encryption-key` | Sincroniza clave con volumen `n8n_data` |

### Utilidades

| Comando | Descripción |
|---------|-------------|
| `test-oauth` | URLs de callback OAuth y webhooks |
| `test-webhook` | Comprueba que HTTPS no devuelva 502 |
| `ai-test` | Valida `OPENAI_API_KEY` |
| `version` | Versiones deployer e imágenes |
| `menu` | Menú interactivo |
| `help` | Ayuda |

---

## Variables (`install-auto`)

| Variable | Req. | Default | Descripción |
|----------|------|---------|-------------|
| `DOMAIN` | Sí | — | Dominio raíz |
| `SUBDOMAIN` | No | `n8n` | → FQDN `n8n.dominio.com` |
| `SSL_EMAIL` | Sí | — | Let's Encrypt |
| `POSTGRES_PASSWORD` | Sí | — | Mín. 12 caracteres |
| `REDIS_PASSWORD` | Sí | — | Mín. 12 caracteres |
| `N8N_PROXY_HOPS` | No | `1` | `1` = DNS only; `2` = Cloudflare proxy |
| `N8N_WORKER_REPLICAS` | No | `3` | Workers en cola |
| `ENABLE_QDRANT` | No | `true` | Perfil `ai` |
| `ENABLE_MINIO` | No | `false` | Perfil `storage` |
| `ENABLE_MONITORING` | No | `false` | Perfil `observe` |
| `OPENAI_API_KEY` | No | — | Nodos IA (opcional) |
| `N8N_BASE_DIR` | No | auto | Ruta del install |
| `N8N_UNINSTALL_CONFIRM` | No | — | `YES` para uninstall sin prompt |

Más opciones: `N8N_VERSION`, `BACKUP_ENABLED`, `AUTO_SSL`, `CLAUDE_API_KEY`, `GEMINI_API_KEY`, `GRAFANA_ADMIN_PASSWORD`, `ENABLE_NGINX_RATE_LIMIT`.

---

## Secretos y archivos

**`secrets/`** (chmod 700): `encryption_key`, `postgres_password`, `redis_password` (+ `minio_password` si MinIO activo). Montados como `*_FILE` en contenedores n8n.

**No subas `.env` ni `secrets/` a git.**

### Layout en el servidor

```
${BASE_DIR}/               # /opt/n8n o /home/USER/n8n
├── .env                   # Config (chmod 600)
├── docker-compose.yml     # Generado
├── secrets/
├── n8n-deployer.sh
├── deployer-lib/
├── prometheus.yml         # Si monitoring
└── grafana/               # Si monitoring

/etc/nginx/sites-available/n8n.conf
/var/log/n8n/deployer.log
/opt/backups/n8n/          # O ${BASE_DIR}/backups con install en /home/
```

---

## Cloudflare y OAuth

| Cloudflare | `N8N_PROXY_HOPS` |
|------------|------------------|
| Solo DNS (gris) | `1` |
| Proxy naranja | `2` |

```bash
sudo bash n8n-deployer.sh test-oauth
```

URLs típicas:

- Callback: `https://<FQDN>/rest/oauth2-credential/callback`
- Webhooks: `https://<FQDN>/`

---

## Backups

```bash
sudo bash n8n-deployer.sh backup
sudo bash n8n-deployer.sh restore
```

Backup automático (si `BACKUP_ENABLED=true`): cron diario 02:00, retención `BACKUP_RETENTION_DAYS` (default 7).

---

## Problemas frecuentes

| Síntoma | Acción |
|---------|--------|
| 502 Bad Gateway | `doctor` → `reconfigure` |
| 503 en `/assets/*.js` | `reconfigure` (nginx sin rate limit en editor) |
| `ready on port 443` | `sync-listen-port` |
| `Mismatching encryption keys` | `reconfigure` |
| OAuth falla | `test-oauth`, revisar `N8N_PROXY_HOPS` |
| `.env` antiguo | `doctor-config` → `reconfigure` |

```bash
curl -fsS http://127.0.0.1:5678/healthz && echo OK
sudo bash n8n-deployer.sh status
sudo bash n8n-deployer.sh doctor
```

---

## Seguridad

- n8n en `127.0.0.1:5678`; TLS en nginx (443)
- UFW: SSH, 80, 443
- Qdrant/MinIO/Prometheus/Grafana sin exposición pública
- fail2ban en rutas de login

---

## Licencia

Scripts de despliegue en este repositorio. **n8n**, Docker images y APIs de IA tienen sus propias licencias. Tags n8n: [Docker Hub](https://hub.docker.com/r/n8nio/n8n/tags).
