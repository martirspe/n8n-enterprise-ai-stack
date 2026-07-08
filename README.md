# n8n AI Stack Deployer

Deployer Bash para **n8n Community** con stack de IA: modo cola, PostgreSQL, Redis, workers, nginx/SSL, OAuth/webhooks y perfiles Docker para Qdrant (vectores), MinIO (S3) y monitoring (Prometheus/Grafana). Claves IA opcionales (OpenAI, Claude, Gemini). Secretos en archivos, backups y comandos SRE (`preflight`, `validate`, `doctor`, `doctor-config`, `restore`).

| | |
|---|---|
| **Versión deployer** | `1.0.7` |
| **Script** | [`n8n-deployer.sh`](n8n-deployer.sh) + [`deployer-lib/`](deployer-lib/) |
| **Cambios** | [`CHANGELOG.md`](CHANGELOG.md) |

---

## Inicio rápido

### Opción A — Clonar en el VPS (recomendado)

Separa el **código del deployer** (git) del **runtime del stack** (`.env`, volúmenes, backups):

| Ruta | Contenido |
|------|-----------|
| `~/n8n-deployer/` | Repo clonado (`n8n-deployer.sh`, `deployer-lib/`) |
| `/home/devops/n8n/` | Instalación (`N8N_BASE_DIR`: `.env`, `secrets/`, `docker-compose.yml`, `backups/`) |

```bash
# En el VPS (como devops)
sudo apt-get update && sudo apt-get install -y git

# Clonar (HTTPS o SSH si tienes clave en GitHub)
git clone https://github.com/martirspe/n8n-enterprise-ai-stack.git ~/n8n-deployer
cd ~/n8n-deployer
chmod +x n8n-deployer.sh

# Instalar apuntando al directorio de runtime
export N8N_BASE_DIR=/home/devops/n8n
sudo -E bash ~/n8n-deployer/n8n-deployer.sh install

# Comprobar
export N8N_BASE_DIR=/home/devops/n8n
sudo -E bash ~/n8n-deployer/n8n-deployer.sh validate
```

Tras `install` / `reconfigure`, el script copia una copia de sí mismo en `${N8N_BASE_DIR}/` (`install_deployer_to_base`). Puedes operar desde el repo o desde `${N8N_BASE_DIR}/n8n-deployer.sh`; lo habitual es **actualizar el repo y ejecutar desde ahí**.

**Repo privado:** configura una clave SSH en el VPS (`ssh-keygen`, añade la pública en GitHub) y clona con:

```bash
git clone git@github.com:martirspe/n8n-enterprise-ai-stack.git ~/n8n-deployer
```

### Opción B — Copiar por SCP

```bash
# Desde tu PC
scp -r n8n-deployer.sh deployer-lib devops@SERVIDOR:/tmp/

# En el VPS
sudo mkdir -p /opt/n8n/deployer-lib
sudo cp /tmp/n8n-deployer.sh /opt/n8n/
sudo cp -r /tmp/deployer-lib/* /opt/n8n/deployer-lib/
sudo chmod +x /opt/n8n/n8n-deployer.sh

cd /opt/n8n && sudo bash n8n-deployer.sh install
sudo bash n8n-deployer.sh validate
```

Tras el primer acceso a `https://<FQDN>`, crea el usuario **owner** en el asistente web de n8n (el script no gestiona usuarios).

---

## Clonar y actualizar desde el VPS

### Primera vez

```bash
git clone https://github.com/martirspe/n8n-enterprise-ai-stack.git ~/n8n-deployer
cd ~/n8n-deployer
export N8N_BASE_DIR=/home/devops/n8n   # ajusta a tu ruta real
```

### Actualizar el deployer (nuevo script, sin tocar workflows)

```bash
cd ~/n8n-deployer
git pull
export N8N_BASE_DIR=/home/devops/n8n
sudo -E bash n8n-deployer.sh reconfigure
sudo -E bash n8n-deployer.sh validate
sudo -E bash n8n-deployer.sh doctor-config   # opcional: auditar .env obsoleto
```

### Actualizar solo imágenes Docker (n8n, Postgres, Qdrant…)

```bash
export N8N_BASE_DIR=/home/devops/n8n
sudo -E bash ~/n8n-deployer/n8n-deployer.sh update
sudo -E bash ~/n8n-deployer/n8n-deployer.sh validate
```

`update` hace backup previo si `BACKUP_ENABLED=true`, tira de imágenes nuevas y redespliega.

### Alias útil (opcional)

Añade a `~/.bashrc`:

```bash
export N8N_BASE_DIR=/home/devops/n8n
alias n8n-deploy='sudo -E bash ~/n8n-deployer/n8n-deployer.sh'
```

Uso: `n8n-deploy status`, `n8n-deploy validate`, `n8n-deploy backup`.

---

## Gestión recomendada en producción

### Rutina periódica

| Frecuencia | Acción |
|------------|--------|
| Tras cada cambio en `.env` o script | `reconfigure` → `validate` |
| Semanal | `status`, `preflight`, revisar disco (`df -h`) |
| Tras problemas OAuth/webhooks | `test-oauth`, `test-webhook`, `doctor` |
| Antes de cambios grandes | `backup` manual |
| Tras `git pull` del deployer | `reconfigure` → `validate` |

### Disco y backups

El histórico de ejecuciones y los **binarios en Postgres** (`binary_data`, con `N8N_DEFAULT_BINARY_DATA_MODE=database`) pueden ocupar decenas de GB. Recomendado en `.env`:

```env
BACKUP_RETENTION_DAYS=2
BACKUP_EXCLUDE_BINARY_DATA=true
BACKUP_EXCLUDE_EXECUTIONS=true
N8N_EXECUTIONS_DATA_PRUNE=true
N8N_EXECUTIONS_DATA_MAX_AGE=168
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
```

Comprobar tamaño de tablas:

```bash
sudo docker exec n8n-postgres psql -U n8n -d n8n -c "
SELECT relname, pg_size_pretty(pg_total_relation_size(oid))
FROM pg_class WHERE relkind = 'r'
ORDER BY pg_total_relation_size(oid) DESC LIMIT 10;"
du -sh ${N8N_BASE_DIR}/backups/*.tar.gz 2>/dev/null
```

Ideal: **copiar backups fuera del VPS** (S3, otro servidor) y dejar en local solo 1–2 copias recientes.

### Postgres y Qdrant

- **Postgres:** no expuesto a internet. Para DBeaver, pgAdmin o TablePlus desde tu PC:
  1. En `docker-compose.yml` del servicio `postgres`, expón solo localhost: `ports: ["127.0.0.1:5432:5432"]` y `reconfigure`.
  2. Túnel SSH desde tu PC: `ssh -L 5433:127.0.0.1:5432 devops@TU_VPS -N`
  3. Cliente SQL: host `localhost`, puerto `5433`, db `n8n`, user `n8n`, password en `secrets/postgres_password`.
- **Qdrant:** incluido en backup si `BACKUP_QDRANT=true` (colecciones RAG). Listar colecciones en vivo:

```bash
sudo docker exec n8n wget -qO- http://qdrant:6333/collections
```

### Secretos y git

- **Nunca** subas `.env`, `secrets/` ni backups a git.
- El repo del deployer puede vivir en el VPS; el runtime (`${N8N_BASE_DIR}`) contiene datos sensibles aparte.

### Cloudflare

| Modo | `N8N_PROXY_HOPS` |
|------|------------------|
| DNS only (gris) | `1` |
| Proxy naranja | `2` |

Tras cambiar: `reconfigure` y `test-oauth`.

### Qué no borra `uninstall`

Certificados Let's Encrypt en el host y el **repo clonado** en `~/n8n-deployer` (si está fuera de `N8N_BASE_DIR`). Sí borra contenedores, volúmenes Docker y contenido de `${N8N_BASE_DIR}`.

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

Plantilla completa en el repo: [`.env.example`](.env.example) o en el servidor:

```bash
sudo bash n8n-deployer.sh export-env-template   # escribe ${N8N_BASE_DIR}/.env.example
```

### Actualizar tras subir script nuevo

Desde el repo clonado:

```bash
cd ~/n8n-deployer && git pull
export N8N_BASE_DIR=/home/devops/n8n
sudo -E bash n8n-deployer.sh reconfigure
sudo -E bash n8n-deployer.sh validate
```

Si copiaste el script a mano (SCP), sustituye `git pull` por copiar los archivos nuevos.

### Producción: `.env` independiente (recomendado)

- Mantén el runtime en `${N8N_BASE_DIR}` y el código en `~/n8n-deployer`.
- No reemplaces el `.env` de producción con `.env.example`; úsalo solo como referencia.
- Antes de `reconfigure`, haz backup de `.env` y valida variables críticas.

Checklist pre-`reconfigure`:

```bash
sudo cp /home/devops/n8n/.env /home/devops/n8n/.env.bak.$(date +%Y%m%d_%H%M%S)
grep -E '^(FQDN|DOMAIN|SUBDOMAIN|SSL_EMAIL|POSTGRES_PASSWORD|REDIS_PASSWORD|N8N_ENCRYPTION_KEY)=' /home/devops/n8n/.env
grep -E '^(N8N_DEFAULT_BINARY_DATA_MODE|N8N_EXECUTIONS_DATA_PRUNE|N8N_EXECUTIONS_DATA_MAX_AGE|BACKUP_EXCLUDE_BINARY_DATA|BACKUP_EXCLUDE_EXECUTIONS|BACKUP_QDRANT)=' /home/devops/n8n/.env
export N8N_BASE_DIR=/home/devops/n8n && sudo -E bash ~/n8n-deployer/n8n-deployer.sh reconfigure
sudo -E bash ~/n8n-deployer/n8n-deployer.sh validate
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

Más opciones: `N8N_VERSION`, `BACKUP_ENABLED`, `BACKUP_RETENTION_DAYS`, `BACKUP_EXCLUDE_BINARY_DATA`, `BACKUP_EXCLUDE_EXECUTIONS`, `BACKUP_QDRANT`, `AUTO_SSL`, `CLAUDE_API_KEY`, `GEMINI_API_KEY`, `GRAFANA_ADMIN_PASSWORD`, `ENABLE_NGINX_RATE_LIMIT`, `N8N_EXECUTIONS_DATA_PRUNE`, `N8N_DEFAULT_BINARY_DATA_MODE`.

---

## Secretos y archivos

**`secrets/`** (chmod 700): `encryption_key`, `postgres_password`, `redis_password` (+ `minio_password` si MinIO activo). Montados como `*_FILE` en contenedores n8n.

**No subas `.env` ni `secrets/` a git.**

### Layout en el servidor

**Runtime** (`${N8N_BASE_DIR}`, p. ej. `/home/devops/n8n`):

```
${N8N_BASE_DIR}/
├── .env                   # Config (chmod 600)
├── docker-compose.yml     # Generado
├── secrets/
├── n8n-deployer.sh        # Copia del script (reconfigure)
├── deployer-lib/
├── backups/
├── prometheus.yml         # Si monitoring
└── grafana/               # Si monitoring
```

**Repo del deployer** (recomendado aparte, p. ej. `~/n8n-deployer/`):

```
~/n8n-deployer/
├── n8n-deployer.sh
├── deployer-lib/
├── README.md
└── CHANGELOG.md
```

Otros paths del host:

```
/etc/nginx/sites-available/n8n.conf
/var/log/n8n/deployer.log
/opt/backups/n8n/          # Si install en /opt/n8n (sin N8N_BASE_DIR en /home)
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
export N8N_BASE_DIR=/home/devops/n8n
sudo -E bash n8n-deployer.sh backup
sudo -E bash n8n-deployer.sh restore
```

Backup automático (si `BACKUP_ENABLED=true`): cron diario 02:00, retención `BACKUP_RETENTION_DAYS` (default 7).

| Variable | Default | Efecto |
|----------|---------|--------|
| `BACKUP_RETENTION_DAYS` | `7` | Días que se conservan los `.tar.gz` |
| `BACKUP_EXCLUDE_BINARY_DATA` | `false` | Omite tabla `binary_data` (ahorra GB si hay WhatsApp/RAG) |
| `BACKUP_EXCLUDE_EXECUTIONS` | `false` | Omite historial de ejecuciones |
| `BACKUP_QDRANT` | `true`* | Incluye volumen Qdrant (`n8n_qdrant_data`) para RAG |

\* Default `true` cuando `ENABLE_QDRANT=true`. Qdrant se para unos segundos durante el snapshot.

El archivo `n8n_backup_*.tar.gz` incluye: Postgres, Redis, `.env`, volumen `n8n_data` y (si aplica) snapshot Qdrant.

Tras cambiar estas variables: `reconfigure` o `backup` (regenera el script de backup).

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
