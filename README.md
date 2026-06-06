# n8n AI Stack Deployer

Script de despliegue y operación para **n8n Enterprise** con **stack de IA** en producción: modo cola (*queue mode*), PostgreSQL, Redis, nginx, Let's Encrypt, **Qdrant** (vectores), **MinIO**, integración **OpenAI / Claude / Gemini**, OAuth, webhooks y observabilidad opcional.

**Versión del deployer:** `1.0.0`  
**Script principal:** [`n8n-deployer.sh`](n8n-deployer.sh)  
**Librerías:** [`deployer-lib/`](deployer-lib/)

---

## Tabla de contenidos

1. [Qué incluye el stack (n8n + IA)](#qué-incluye-el-stack)
2. [Requisitos](#requisitos)
3. [Estructura del repositorio](#estructura-del-repositorio)
4. [Instalación](#instalación)
5. [Layout en el servidor](#layout-en-el-servidor)
6. [Comandos CLI](#comandos-cli)
7. [Variables de entorno](#variables-de-entorno)
8. [Perfiles Docker Compose](#perfiles-docker-compose)
9. [Secretos](#secretos)
10. [Cloudflare, nginx y OAuth](#cloudflare-nginx-y-oauth)
11. [Backups, restore y rollback](#backups-restore-y-rollback)
12. [Solución de problemas](#solución-de-problemas)
13. [Seguridad](#seguridad)
14. [Actualizar el stack](#actualizar-el-stack)
15. [Licencia y soporte](#licencia-y-soporte)

---

## Qué incluye el stack

### Plataforma n8n

| Componente | Rol |
|------------|-----|
| **n8n** | Proceso principal (webhooks, editor, API REST) |
| **n8n-worker** | Workers en modo cola (`EXECUTIONS_MODE=queue`) |
| **PostgreSQL 16** | Base de datos y binarios en modo `database` |
| **Redis 7** | Cola Bull; política `noeviction` + AOF |
| **nginx** | Reverse proxy, SSL, rate limit, rutas OAuth/webhook |
| **Certbot** | Certificados Let's Encrypt (si `AUTO_SSL=true`) |

### Capa de IA

| Componente | Rol |
|------------|-----|
| **Qdrant** *(perfil `ai`)* | Base vectorial para RAG y workflows con embeddings |
| **MinIO** *(perfil `storage`)* | Almacenamiento S3-compatible (artefactos, ficheros) |
| **OpenAI / Claude / Gemini** | API keys vía secretos; variables `AI_*` en `.env` |
| **AI Router** | `AI_ROUTER_MODE`, `AI_PRIMARY`, `AI_SECONDARY`, `AI_COST_MODE` |
| **Prometheus + Grafana** *(perfil `observe`)* | Métricas de n8n, MinIO y Qdrant (opcional) |

Características destacadas del deployer:

- n8n escucha en **5678** dentro del contenedor; publicación solo en **`127.0.0.1:5678`** (nginx termina TLS en 443).
- **`N8N_PROXY_HOPS`** configurable (Cloudflare DNS-only vs proxy naranja).
- Secretos en **`/opt/n8n/secrets/`** montados como `*_FILE` (no en variables planas del compose para n8n).
- Clave de cifrado alineada con el volumen **`n8n_data`** (prioridad al `config` del volumen).
- Comandos SRE: `preflight`, `validate`, `doctor`, `restore`, `rollback`, `reconfigure`.
- Prueba de IA: `ai-test` (validación de API key OpenAI configurada).

---

## Requisitos

### Servidor

- **SO:** Ubuntu 22.04/24.04 LTS (u otra distro con systemd; el script valida el SO).
- **CPU:** 2+ vCPU recomendado (queue mode + workers).
- **RAM:** 4 GB mínimo recomendado (2 GB solo para pruebas).
- **Disco:** 20+ GB libres bajo `/opt/n8n` o ruta de despliegue.
- **Red:** Puertos **80** y **443** abiertos (UFW configurado por el script).
- **DNS:** Registro A/AAAA del FQDN apuntando al servidor **antes** de SSL automático.

### Software (instalado por el script si falta)

- Docker Engine + plugin **Compose v2**
- nginx, certbot, curl, openssl, jq (recomendado)

### Acceso

- Ejecución como **root** o con **sudo** (el script se re-ejecuta con sudo si hace falta).

---

## Estructura del repositorio

```
.
├── n8n-deployer.sh          # Script principal
├── deployer-lib/
│   ├── secrets.sh           # Archivos de secretos y montajes
│   ├── preflight.sh         # preflight + validate
│   ├── backup-restore.sh    # restore, rollback, snapshot
│   └── extras.sh            # version, test-oauth, plantillas, logrotate
├── README.md
├── CHANGELOG.md
└── .gitignore               # Excluye .env, secrets/, backups
```

> **Importante:** al copiar al servidor, mantén **`deployer-lib/`** en el mismo directorio que `n8n-deployer.sh` (o en `/opt/n8n/deployer-lib` tras `install` / `reconfigure`).

---

## Instalación

### 1. Copiar al servidor

Desde tu máquina local:

```bash
scp n8n-deployer.sh devops@TU_SERVIDOR:/tmp/
scp -r deployer-lib devops@TU_SERVIDOR:/tmp/
```

En el VPS:

```bash
sudo mkdir -p /opt/n8n/deployer-lib
sudo cp /tmp/n8n-deployer.sh /opt/n8n/n8n-deployer.sh
sudo cp -r /tmp/deployer-lib/* /opt/n8n/deployer-lib/
sudo chmod +x /opt/n8n/n8n-deployer.sh
```

El comando `install` o `reconfigure` también copia el script y las libs a `BASE_DIR` (`/opt/n8n` por defecto).

### 2. Instalación interactiva

```bash
cd /opt/n8n
sudo bash n8n-deployer.sh install
```

Solicita dominio, subdominio, email SSL, contraseñas y opciones (IA, MinIO, Qdrant, monitorización).

### 3. Instalación no interactiva (`install-auto`)

```bash
export DOMAIN="example.com"
export SUBDOMAIN="n8n"
export SSL_EMAIL="admin@example.com"
export N8N_ADMIN_PASS="ContraseñaSegura12+"
export POSTGRES_PASSWORD="ContraseñaSegura12+"
export REDIS_PASSWORD="ContraseñaSegura12+"
export N8N_PROXY_HOPS="1"
export N8N_WORKER_REPLICAS="3"

sudo -E bash /opt/n8n/n8n-deployer.sh install-auto
```

### 4. Servidor ya instalado (actualizar script/config)

```bash
cd /opt/n8n
sudo bash n8n-deployer.sh reconfigure
sudo bash n8n-deployer.sh validate
```

### 5. Comprobar versión

```bash
sudo bash n8n-deployer.sh version
```

---

## Layout en el servidor

Por defecto (`BASE_DIR=/opt/n8n`):

```
/opt/n8n/
├── n8n-deployer.sh       # Copia del script (auto en install/reconfigure)
├── deployer-lib/         # Librerías
├── .env                  # Variables de entorno (chmod 600)
├── .env.example          # Plantilla (export-env-template)
├── docker-compose.yml    # Generado por el script
├── secrets/              # chmod 700 — encryption_key, postgres, redis, etc.
├── .n8n-release          # Snapshot de versión n8n para rollback
└── prometheus.yml        # Solo si ENABLE_MONITORING=true

/opt/backups/n8n/         # Backups programados y manuales
/var/log/n8n/deployer.log # Log del deployer
/etc/nginx/sites-available/n8n.conf
/usr/local/bin/n8n-backup.sh
```

Si instalas con un usuario no root vía `sudo`, `BASE_DIR` puede ser `/home/USUARIO/n8n`.

---

## Comandos CLI

```bash
sudo bash n8n-deployer.sh <comando>
```

| Comando | Descripción |
|---------|-------------|
| `install` | Instalación interactiva completa |
| `install-auto` | Instalación con variables de entorno |
| `reconfigure` | Regenera `.env`, compose, nginx, secretos y redespliega (**recomendado tras actualizar el script**) |
| `preflight` | Comprueba DNS, disco, RAM, puertos, clave de cifrado |
| `validate` | Valida `docker compose config`, `/healthz` local y HTTPS público |
| `restore [archivo]` | Restaura backup `.tar.gz` (pide confirmación `RESTORE`) |
| `rollback` | Vuelve a la imagen n8n guardada en `.n8n-release` |
| `export-env-template` | Escribe `.env.example` |
| `version` | Versión del deployer e imágenes |
| `test-oauth` | Muestra URLs de callback OAuth y webhook |
| `test-webhook` | Prueba que la URL pública no devuelva 502 |
| `status` | Estado de contenedores y recursos |
| `logs` | Logs en vivo (`docker compose logs -f`) |
| `update` | Pull de imágenes + recreación (backup previo si está habilitado) |
| `doctor` | Diagnóstico de 502, puerto 443, encryption key |
| `sync-encryption-key` | Alias de reconfigure orientado a clave de cifrado |
| `sync-listen-port` | Fuerza puerto 5678 en config del volumen n8n |
| `repair` | Reinicia Docker, nginx y recrea el stack |
| `backup` | Ejecuta backup manual |
| `ai-test` | Valida API key de OpenAI configurada |
| `uninstall` | Elimina stack (destructivo) |
| `menu` | Menú interactivo |
| `help` | Ayuda |

**Menú interactivo:** `sudo bash n8n-deployer.sh menu`

### Idempotencia

| Acción | Comportamiento al repetir |
|--------|---------------------------|
| `install` / `install-auto` | Si ya existe `.env` → ejecuta `reconfigure` |
| `reconfigure` | Regenera config y `up -d` (seguro repetir) |
| `repair` / `update` | Reinicia o actualiza sin borrar volúmenes |
| `uninstall` | Solo con confirmación `YES` |
| Menú | Un error no cierra el menú (vuelve al prompt) |

El script detecta el install en `N8N_BASE_DIR`, `/home/USER/n8n` o `/opt/n8n`.

---

## Variables de entorno

### Instalación (`install-auto`)

| Variable | Obligatoria | Default | Descripción |
|----------|-------------|---------|-------------|
| `DOMAIN` | Sí | — | Dominio raíz (ej. `example.com`) |
| `SUBDOMAIN` | No | `n8n` | Subdominio → FQDN `n8n.example.com` |
| `SSL_EMAIL` | Sí | — | Email para Let's Encrypt |
| `N8N_ADMIN_PASS` | Sí | — | Contraseña del owner (mín. 12 caracteres) |
| `POSTGRES_PASSWORD` | Sí | — | PostgreSQL (mín. 12 caracteres) |
| `REDIS_PASSWORD` | Sí | — | Redis (mín. 12 caracteres) |
| `N8N_PROXY_HOPS` | No | `1` | Saltos de proxy (ver Cloudflare) |
| `N8N_WORKER_REPLICAS` | No | `3` | Réplicas del worker |
| `N8N_VERSION` | No | `2.23.2` | Tag de imagen `n8nio/n8n` |
| `OPENAI_API_KEY` | No | — | OpenAI (opcional) |
| `CLAUDE_API_KEY` | No | — | Anthropic (opcional) |
| `GEMINI_API_KEY` | No | — | Google Gemini (opcional) |
| `N8N_LICENSE_KEY` | No | — | Licencia Enterprise |
| `ENABLE_MONITORING` | No | `false` | Perfil `observe` |
| `ENABLE_QDRANT` | No | `true` | Perfil `ai` |
| `ENABLE_MINIO` | No | `true` | Perfil `storage` |
| `BACKUP_ENABLED` | No | `true` | Cron de backups |
| `AUTO_SSL` | No | `true` | Certbot + nginx HTTPS |
| `AI_ROUTER_MODE` | No | `api_only` | Enrutado IA |
| `AI_PRIMARY` / `AI_SECONDARY` | No | `openai` / `gemini` | Proveedores IA |
| `AI_COST_MODE` | No | `balanced` | Modo de coste IA |
| `MINIO_VERSION` | No | ver script | Tag MinIO |
| `BACKUP_RETENTION_DAYS` | No | `7` | Retención de backups |
| `N8N_BASE_DIR` | No | auto | Ruta del install si no es la default |
| `ENABLE_NGINX_RATE_LIMIT` | No | `false` | Rate limit solo en `/webhook/` |

### Generadas en `.env` (referencia)

Variables críticas que el script escribe o mantiene:

- `FQDN`, `N8N_HOST`, `WEBHOOK_URL`, `N8N_EDITOR_BASE_URL`
- `N8N_PORT=5678`, `N8N_LISTEN_ADDRESS=0.0.0.0`
- `EXECUTIONS_MODE=queue`, `N8N_DEFAULT_BINARY_DATA_MODE=database`
- `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`
- `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true` (ejecuciones en workers, UI en main)
- `N8N_ENCRYPTION_KEY` (sincronizada con volumen `n8n_data`)
- `QUEUE_BULL_REDIS_*`, `DB_POSTGRESDB_*`

SMTP opcional: `N8N_SMTP_HOST`, `N8N_SMTP_PORT`, `N8N_SMTP_USER`, `N8N_SMTP_PASS`, `N8N_SMTP_SENDER`.

### IA (Qdrant y LLM)

- `QDRANT_URL=http://qdrant:6333` — solo con perfil `ai` activo
- `OPENAI_API_KEY`, `CLAUDE_API_KEY`, `GEMINI_API_KEY` — opcionales; cada clave se copia a `secrets/` en `reconfigure` / `generate_env`
- Tras instalar, valida OpenAI: `sudo bash n8n-deployer.sh ai-test`

Plantilla: `sudo bash n8n-deployer.sh export-env-template`

---

## Perfiles Docker Compose

| Perfil | Activación | Servicios |
|--------|------------|-----------|
| *(core)* | siempre | `postgres`, `redis`, `n8n`, `n8n-worker` |
| `ai` | `ENABLE_QDRANT=true` | `qdrant` |
| `storage` | `ENABLE_MINIO=true` | `minio` |
| `observe` | `ENABLE_MONITORING=true` | `prometheus`, `grafana` |

Los perfiles se aplican con `docker compose --profile ...` vía la función interna `compose_profiles_args`.

---

## Secretos

Tras `generate_env` / `reconfigure`, el script escribe en `${BASE_DIR}/secrets/`:

| Archivo | Uso |
|---------|-----|
| `encryption_key` | `N8N_ENCRYPTION_KEY_FILE` |
| `postgres_password` | `DB_POSTGRESDB_PASSWORD_FILE` |
| `redis_password` | `QUEUE_BULL_REDIS_PASSWORD_FILE` |
| `minio_password` | MinIO (si aplica) |
| `openai_api_key` | OpenAI (si aplica) |
| `claude_api_key` | Anthropic Claude (si aplica) |
| `gemini_api_key` | Google Gemini (si aplica) |

Permisos: directorio `700`, archivos `600`. Montaje en contenedores n8n: `/secrets:ro` con `security_opt: no-new-privileges:true`.

**No subas `.env` ni `secrets/` a git.**

---

## Cloudflare, nginx y OAuth

### Cloudflare

| Modo | `N8N_PROXY_HOPS` |
|------|------------------|
| Solo DNS (nube gris) | `1` (solo nginx delante de n8n) |
| Proxy naranja activo | `2` (Cloudflare + nginx) |

### URLs para consolas OAuth (Google, Meta, etc.)

```bash
sudo bash n8n-deployer.sh test-oauth
```

Registra típicamente:

- **OAuth callback:** `https://<FQDN>/rest/oauth2-credential/callback`
- **Editor:** `https://<FQDN>`
- **Webhooks:** `https://<FQDN>/` (`WEBHOOK_URL`)

### WhatsApp / webhooks

- Los webhooks deben resolverse al mismo FQDN HTTPS.
- Prueba rápida: `sudo bash n8n-deployer.sh test-webhook` (no debe devolver **502**).

### nginx

- Upstream: `127.0.0.1:5678`
- Sin rate limit en editor/API por defecto (`ENABLE_NGINX_RATE_LIMIT=false`); opcional solo en `/webhook/`
- WebSocket habilitado para el editor
- `/metrics` restringido a localhost

---

## Backups, restore y rollback

### Backup automático

- Script: `/usr/local/bin/n8n-backup.sh`
- Directorio: `/opt/backups/n8n/`
- Contenido típico: dump PostgreSQL, Redis RDB, copia `.env`, snapshot volumen `n8n_data`
- Retención: `BACKUP_RETENTION_DAYS` (default 7)

### Backup manual

```bash
sudo bash n8n-deployer.sh backup
```

### Restore

```bash
sudo bash n8n-deployer.sh restore
# o
sudo bash n8n-deployer.sh restore /opt/backups/n8n/n8n_backup_YYYYMMDD_HHMMSS.tar.gz
```

Escribe `RESTORE` para confirmar.

### Rollback de imagen n8n

Tras un `update`, el archivo `.n8n-release` guarda la versión anterior:

```bash
sudo bash n8n-deployer.sh rollback
```

---

## Solución de problemas

| Síntoma | Causa habitual | Acción |
|---------|----------------|--------|
| **502 Bad Gateway** | nginx no alcanza n8n en `127.0.0.1:5678` | `doctor` → `reconfigure` |
| Log `ready on port 443` | `N8N_PORT` o config del volumen en 443 | `sync-listen-port` o `reconfigure` |
| `Mismatching encryption keys` | `.env` ≠ clave en `n8n_data` | `reconfigure` (lee volumen) |
| Workers reiniciando | Misma clave de cifrado o Redis caído | `docker logs n8n-worker` + `reconfigure` |
| OAuth 401 / redirect | URL o `N8N_PROXY_HOPS` incorrectos | `test-oauth`, revisar Cloudflare |
| `docker compose` sin archivo | Ejecutar fuera de `/opt/n8n` | `cd /opt/n8n` |
| compose inválido | Perfil o variable faltante | `preflight` + `validate` |

### Comprobaciones rápidas

```bash
cd /opt/n8n
curl -fsS http://127.0.0.1:5678/healthz && echo OK
sudo docker compose ps
sudo docker logs n8n --tail 30
sudo bash n8n-deployer.sh doctor
```

---

## Seguridad

- UFW: permite SSH, 80, 443; **no** expone 5678 al público.
- n8n publicado solo en loopback: `127.0.0.1:5678:5678`.
- Qdrant/MinIO sin puertos publicados en el host (solo red Docker).
- fail2ban configurado con filtros que evitan bloquear rutas OAuth en exceso.
- Sin `N8N_BASIC_AUTH_*` (obsoleto en n8n 2.x); login vía UI de usuarios.
- Cookies seguras: `N8N_SECURE_COOKIE=true` con HTTPS.

---

## Actualizar el stack

1. Sube el nuevo `n8n-deployer.sh` y `deployer-lib/`.
2. Ejecuta:

```bash
cd /opt/n8n
sudo bash n8n-deployer.sh reconfigure
sudo bash n8n-deployer.sh update    # si solo quieres nuevas imágenes Docker
sudo bash n8n-deployer.sh validate
```

`update` exige backup exitoso si `BACKUP_ENABLED=true`.

---

## Licencia y soporte

- **n8n** y los proveedores de IA (OpenAI, Anthropic, Google, etc.) tienen sus propias licencias y condiciones de uso; este repositorio solo incluye scripts de despliegue.
- Imágenes Docker: [n8nio/n8n tags](https://hub.docker.com/r/n8nio/n8n/tags)
- Ajusta `N8N_VERSION` en `.env` o variables de `install-auto` para fijar versiones.

---

## Ejemplo de instalación

```bash
export DOMAIN="example.com"
export SUBDOMAIN="n8n"
export SSL_EMAIL="admin@example.com"
export N8N_PROXY_HOPS="1"
# ... contraseñas (POSTGRES_PASSWORD, REDIS_PASSWORD, N8N_ADMIN_PASS) ...

sudo -E bash /opt/n8n/n8n-deployer.sh install-auto
sudo bash /opt/n8n/n8n-deployer.sh test-oauth
sudo bash /opt/n8n/n8n-deployer.sh validate
```

FQDN resultante: **https://n8n.example.com**
