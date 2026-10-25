# Production WordPress on Docker

[English](README.md) | [简体中文](README_CN.md)

A production-ready, security-hardened Docker Compose stack running **WordPress** with **PHP-FPM**, **Nginx** reverse proxy, **MySQL 8.0**, and **Let's Encrypt** SSL/TLS via Certbot.

---

## Overview

This repository provides an enterprise-grade, portable deployment for WordPress with automated backup/restore scripts, production security hardening, container log rotation, and automated TLS certificate management.

### Architecture

```
                       Internet
                          │
                   ┌──────▼──────┐
                   │    Nginx    │  (:80 / :443)
                   │ (webserver) │
                   └──────┬──────┘
                          │
          ┌───────────────┴───────────────┐
          │ (static files & assets)       │ (PHP requests via FastCGI)
          ▼                               ▼
   /var/www/html                 ┌─────────────────┐
(bind: ./data/wordpress)         │  WordPress FPM  │  (:9000 internal)
                                 │   (wordpress)   │
                                 └────────┬────────┘
                                          │
                                          ▼
                                 ┌─────────────────┐
                                 │     MySQL 8     │  (:3306 internal)
                                 │      (db)       │
                                 └─────────────────┘
```

### Services Matrix

| Service | Docker Image | Internal Port | Exposed Port | Role |
| :--- | :--- | :--- | :--- | :--- |
| **`webserver`** | `nginx:1.27-alpine` | `80`, `443` | `80:80`, `443:443` | Reverse proxy, TLS termination, static asset cache |
| **`wordpress`** | `wordpress:6.8-fpm-alpine` | `9000` | None (internal) | WordPress core & PHP-FPM application processor |
| **`db`** | `mysql:8.0` | `3306` | None (internal) | MySQL database server with persistent storage |
| **`certbot`** | `certbot/certbot` | N/A | None (profiled) | Automated Let's Encrypt ACME certificate issuance |

---

## Key Features

- **Decoupled Architecture:** WordPress PHP-FPM runs isolated from Nginx. Neither PHP-FPM nor MySQL ports are exposed to the public internet.
- **Production Security Hardening:**
  - **Upload Protection:** Execution of `.php` scripts within `/wp-content/uploads/` is strictly prohibited in Nginx.
  - **Access Restrictions:** Blocks access to hidden files (`.git`, `.env`), `wp-config.php`, `readme.html`, and `license.txt`.
  - **Security Headers:** Enforces `Strict-Transport-Security` (HSTS), `X-Frame-Options: SAMEORIGIN`, `X-Content-Type-Options: nosniff`, and `Referrer-Policy`.
  - **Safe Permissions:** Backup snapshots enforce `umask 077` and `chmod 700/600` on credentials and SQL dumps.
- **Performance & Upload Ready:**
  - `client_max_body_size 64M` allows large media uploads and plugin installations without HTTP 413 errors.
  - Configured with `fastcgi_read_timeout 300` and FastCGI buffers to prevent 504 Gateway Timeouts during updates.
  - Long-lived browser caching for CSS, JS, images, WebP, AVIF, and web fonts.
- **Automated TLS & Certbot Isolation:**
  - Integrated ACME challenge verification through Nginx webroot.
  - Certbot is isolated under the `certbot` Docker Compose profile (`profiles: ["certbot"]`) with `restart: "no"`, avoiding unwanted duplicate runs and rate limits on standard `docker compose up -d`.
- **Automated Backup & Disaster Recovery:**
  - [scripts/backup.sh](scripts/backup.sh): Creates timestamped snapshots including UTF-8 MySQL dump, site files, Nginx config, `.env`, and TLS certificates.
  - [scripts/restore.sh](scripts/restore.sh): Restores snapshots with automated `gzip` and `tar` archive integrity verification prior to making changes.
- **Disk Space Protection (Log Rotation):**
  - All containers configure Docker `json-file` log rotation (`max-size: 10m`, `max-file: 3`) to prevent unconstrained log files from filling the host drive.
- **Predictable Data Persistence:**
  - All database, media, and certificate state lives in the root `./data/` directory using standard bind mounts, simplifying volume management and external backups.

---

## Project Structure

```text
wordpress/
├── docker-compose.yml       # Container services, networks, volumes & log configuration
├── .env.example             # Template for required environment secrets
├── .env                     # Local environment secrets (strictly gitignored)
├── .dockerignore            # Excludes sensitive files from container contexts
├── .gitignore               # Protects .env, /backups/, and /data/ from Git tracking
├── README.md                # Project documentation and deployment guide
├── BACKUP.md                # Comprehensive backup, restore, and disaster recovery guide
├── nginx-conf/
│   ├── default.conf.template # HTTP port 80 template (auto-substituted with $DOMAIN_NAME)
│   └── ssl.conf.template     # HTTPS port 443 template (auto-substituted with $DOMAIN_NAME)
├── scripts/
│   ├── backup.sh            # Automated server snapshot script (DB dump, files, configs)
│   └── restore.sh           # Automated snapshot restoration script with integrity checks
├── backups/                 # Timestamped backup archives generated by backup.sh (gitignored)
└── data/                    # Bind-mounted persistent state (gitignored)
    ├── dbdata/              # MySQL data directory (/var/lib/mysql)
    ├── wordpress/           # WordPress site root (/var/www/html)
    └── certbot-etc/         # Let's Encrypt certificates & keys (/etc/letsencrypt)
```

---

## Prerequisites

- **Docker:** Engine version 20.10+
- **Docker Compose:** Compose v2 (e.g. `docker compose` CLI plugin)
- **Domain Name:** DNS `A` or `CNAME` record pointing your domain to this server's public IP
- **Network Ports:** Ports **80** and **443** must be open and reachable from the internet

### Cloudflare Users
If you use Cloudflare with Proxied (orange cloud) DNS:
1. Ensure your SSL/TLS encryption mode is set to **Full (strict)** once origin certificates are active.
2. For initial certificate issuance, HTTP port 80 must pass through to the origin without HTTPS enforcement, or temporarily switch DNS to **DNS only** (grey cloud) during validation.

---

## Configuration

### 1. Configure Secrets

Copy the example environment file:

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env` and configure your credentials and domain:

```ini
MYSQL_ROOT_PASSWORD=use_a_strong_root_password_here
MYSQL_USER=wp_user
MYSQL_PASSWORD=use_a_strong_database_password_here
# Optional: defaults to wordpress_db if omitted
MYSQL_DATABASE=wordpress_db

# Domain name and Certbot contact email
DOMAIN_NAME=yourdomain.com
CERTBOT_EMAIL=your-email@example.com
```

Nginx automatically reads `${DOMAIN_NAME}` from `.env` using its built-in template engine (`/docker-entrypoint.d/20-envsubst-on-templates.sh`) and generates the runtime configuration files in `/etc/nginx/conf.d/`.

---

## Quick Start & First-Time Deployment

### Step 1: Bootstrap SSL Certificate

On a fresh installation, Nginx cannot start with HTTPS enabled until certificate files exist. Follow this simple 3-step bootstrap:

**a.** Temporarily disable `ssl.conf.template`:
```bash
mv nginx-conf/ssl.conf.template nginx-conf/ssl.conf.template.bak
```

**b.** Start the web stack on HTTP port 80 and run Certbot:
```bash
docker compose up -d db wordpress webserver
docker compose run --rm certbot
```

**c.** Re-enable `ssl.conf.template` and restart Nginx:
```bash
mv nginx-conf/ssl.conf.template.bak nginx-conf/ssl.conf.template
docker compose restart webserver
```

### Step 2: Complete WordPress Web Setup

1. Open `https://yourdomain.com/` in your browser.
2. Follow the on-screen WordPress setup wizard (select language, site title, administrator username, and password).
3. Access your administration dashboard at `https://yourdomain.com/wp-admin/`.

---

## Common Management Commands

```bash
# Start all core services (db, wordpress, webserver)
docker compose up -d

# Stop all running containers (persistent data remains safe in ./data/)
docker compose down

# Check service status
docker compose ps

# View live logs
docker compose logs -f webserver
docker compose logs -f wordpress
docker compose logs -f db

# View Certbot logs (requires --profile flag)
docker compose --profile certbot logs certbot

# Restart Nginx after configuration adjustments
docker compose restart webserver

# Re-run or renew Certbot manually
docker compose run --rm certbot renew
docker compose restart webserver
```

---

## Backup and Disaster Recovery

A complete backup and disaster recovery guide is provided in **[BACKUP.md](BACKUP.md)**.

### Create a Snapshot
```bash
chmod +x scripts/backup.sh scripts/restore.sh
./scripts/backup.sh
```
*Creates a secured snapshot under `backups/YYYYMMDD-HHMMSS/` containing `wordpress_db.sql.gz`, `wordpress.tar.gz`, `nginx-conf.tar.gz`, `.env`, and TLS certificates.*

### Restore a Snapshot
```bash
./scripts/restore.sh backups/YYYYMMDD-HHMMSS
```
*Pre-validates archive integrity before making any changes, preventing accidental corruption of active sites.*

---

## Security Best Practices

1. **Keep Secrets Out of Version Control:** `.env`, `backups/`, and `data/` are already excluded in `.gitignore`. Never use `git add -f` on these paths.
2. **Offsite Backups:** Copy generated backup directories off the server to remote storage (e.g., S3, SFTP, or an external hard drive).
3. **Regular Updates:** Periodically pull updated Docker images to apply security patches:
   ```bash
   docker compose pull
   docker compose up -d
   ```
4. **File Permissions:** Ensure `.env` is set to `chmod 600` and `backups/` is set to `chmod 700`.

---

## Troubleshooting

### Nginx Crash Loop: `cannot load certificate ... No such file`
This occurs when Nginx starts with `ssl.conf` active before Let's Encrypt certificates have been generated. Follow the [Bootstrap SSL Certificate](#step-1-bootstrap-ssl-certificate) procedure above.

### HTTP 504 Gateway Timeout on Large Imports
FastCGI timeouts are set to 300 seconds by default. If running massive database migrations, you can increase `fastcgi_read_timeout` in [nginx-conf/ssl.conf](nginx-conf/ssl.conf) and reload Nginx.

### Permission Denied on Docker Socket
If running without root or non-root docker group, pass `DOCKER_COMPOSE="sudo docker compose"` when running scripts:
```bash
DOCKER_COMPOSE="sudo docker compose" ./scripts/backup.sh
```

---

## License

This project is open-source and available under the [MIT License](LICENSE).
