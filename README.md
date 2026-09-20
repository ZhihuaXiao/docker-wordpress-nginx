# WordPress (Docker)

A Docker Compose stack for running WordPress behind **Nginx** with **PHP-FPM**, **MySQL 8**, and **Let's Encrypt** TLS via Certbot.

**Domain:** `blog.tryvibes.cc`  
**Admin portal:** [https://blog.tryvibes.cc/wp-admin/](https://blog.tryvibes.cc/wp-admin/) (login page: `https://blog.tryvibes.cc/wp-login.php`)

## Architecture

```
Internet → Nginx (webserver :80/:443)
              ├── static files from /var/www/html
              └── PHP requests → WordPress FPM (wordpress :9000)
                                        └── MySQL (db :3306)
```

| Service    | Image                    | Role                                      |
|------------|--------------------------|-------------------------------------------|
| `db`       | `mysql:8.0`              | MySQL database                            |
| `wordpress`| `wordpress:6.8-fpm-alpine` | WordPress (PHP-FPM, port 9000 internal) |
| `webserver`| `nginx:1.27-alpine`      | Reverse proxy, TLS termination            |
| `certbot`  | `certbot/certbot`        | One-shot Let's Encrypt certificate issue  |

Nginx listens on ports **80** and **443** on the host. WordPress FPM does not expose HTTP directly; Nginx forwards PHP to `wordpress:9000`.

## Project layout

```
wordpress/
├── docker-compose.yml
├── .env                    # secrets (not committed)
├── .env.example
├── BACKUP.md               # backup and restore guide
├── scripts/
│   ├── backup.sh
│   └── restore.sh
├── nginx-conf/
│   ├── nginx.conf          # HTTP: ACME challenge + redirect to HTTPS
│   └── ssl.conf            # HTTPS: WordPress + SSL
├── backups/                # created by backup.sh (gitignored)
└── data/                   # bind-mounted persistent data
    ├── dbdata/             # MySQL database
    ├── wordpress/          # WordPress site files
    └── certbot-etc/        # Let's Encrypt certificates
```

## Prerequisites

- Docker and Docker Compose
- DNS `A` record for `blog.tryvibes.cc` pointing to this server
- Ports **80** and **443** reachable from the internet (required for Let's Encrypt and HTTPS)

### Cloudflare

If using Cloudflare with **Proxied** (orange cloud) DNS:

- Set **SSL/TLS → Overview** to **Full (strict)** once origin HTTPS is working.
- For initial certificate issuance, the origin must be reachable on **HTTP port 80** (Certbot webroot validation).

## Quick start

### 1. Configure environment

```bash
cp .env.example .env
```

Edit `.env` and set strong values:

```
MYSQL_ROOT_PASSWORD=...
MYSQL_USER=...
MYSQL_PASSWORD=...
```

### 2. First-time SSL bootstrap

Nginx cannot start with `ssl.conf` until certificates exist. On a **fresh install**, use this order:

**a.** Ensure only HTTP config is active — use the HTTP-only `nginx.conf` below (serve WordPress on port 80, no redirect). Temporarily remove or rename `ssl.conf`:

```bash
mv nginx-conf/ssl.conf nginx-conf/ssl.conf.bak
```

Copy this into `nginx-conf/nginx.conf` for bootstrap:

```nginx
server {
        listen 80;
        listen [::]:80;
        server_name blog.tryvibes.cc;
        index index.php index.html index.htm;
        root /var/www/html;

        location ~ /.well-known/acme-challenge {
                allow all;
                root /var/www/html;
        }

        location / {
                try_files $uri $uri/ /index.php$is_args$args;
        }

        location ~ \.php$ {
                try_files $uri =404;
                fastcgi_split_path_info ^(.+\.php)(/.+)$;
                fastcgi_pass wordpress:9000;
                fastcgi_index index.php;
                include fastcgi_params;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_param PATH_INFO $fastcgi_path_info;
        }
}
```

**b.** Start the stack and obtain a certificate:

```bash
docker compose up -d db wordpress webserver
docker compose run --rm certbot
```

**c.** Restore HTTPS config (the repo's normal `nginx.conf` + `ssl.conf`) and restart:

```bash
mv nginx-conf/ssl.conf.bak nginx-conf/ssl.conf   # if renamed
docker compose restart webserver
```

Or start everything:

```bash
docker compose up -d
```

### 3. Complete WordPress setup

Open `https://blog.tryvibes.cc/` and follow the WordPress installation wizard.

After install, the admin portal is at `https://blog.tryvibes.cc/wp-admin/`. If you are logged out, WordPress redirects to `https://blog.tryvibes.cc/wp-login.php`.

## Common commands

```bash
# Start all services
docker compose up -d

# Stop services (data in ./data/ is preserved)
docker compose down

# View logs
docker compose logs -f webserver
docker compose logs certbot

# Restart a single service
docker compose restart webserver

# Re-run certbot (e.g. after expiry or domain change)
docker compose run --rm certbot

# Backup / restore (see BACKUP.md)
./scripts/backup.sh
./scripts/restore.sh backups/YYYYMMDD-HHMMSS
```

## Backup and restore

Dump MySQL and archive site files with [`scripts/backup.sh`](scripts/backup.sh). Restore with [`scripts/restore.sh`](scripts/restore.sh). You can also back up from wp-admin with a plugin. Full steps: **[BACKUP.md](BACKUP.md)** (including [Backup from wp-admin](BACKUP.md#backup-from-wp-admin)).

## Certificate renewal

Certificates are stored in `./data/certbot-etc/`. To renew:

```bash
docker compose run --rm certbot renew
docker compose restart webserver
```

Update the email and domain in `docker-compose.yml` under the `certbot` service if needed:

```yaml
command: certonly --webroot --webroot-path=/var/www/html \
  --email your@email.com --agree-tos --no-eff-email \
  -d blog.tryvibes.cc
```

## Nginx configuration

| File           | Purpose                                                |
|----------------|--------------------------------------------------------|
| `nginx.conf`   | Port 80: ACME challenge path + redirect to HTTPS       |
| `ssl.conf`     | Port 443: TLS + WordPress (FastCGI to `wordpress:9000`)|

After editing nginx config:

```bash
docker compose restart webserver
```

## Data persistence

All application data lives under `./data/` via bind mounts:

| Host path              | Container path        | Contents              |
|------------------------|-----------------------|-----------------------|
| `./data/dbdata`        | `/var/lib/mysql`      | MySQL database        |
| `./data/wordpress`     | `/var/www/html`       | WordPress files       |
| `./data/certbot-etc`   | `/etc/letsencrypt`    | TLS certificates      |

`docker compose down` does **not** delete `./data/`. Avoid `docker compose down -v` unless you intend to wipe volumes (not used here, but worth noting).

## Troubleshooting

### Nginx crash loop: `cannot load certificate ... No such file`

The SSL certificate is missing from `./data/certbot-etc/`. Follow [First-time SSL bootstrap](#2-first-time-ssl-bootstrap) above.

### Cloudflare error 521

Cloudflare cannot reach your origin. Check that:

- `webserver` is running: `docker compose ps`
- Origin listens on **443** (and **80** for redirects/ACME)
- Cloudflare SSL mode is **Full (strict)**, not expecting HTTPS before certs exist

### Certbot validation fails (404 / 521)

- Ensure `blog.tryvibes.cc` DNS points to this server
- Temporarily use HTTP-only nginx (no HTTPS redirect) during issuance
- If proxied through Cloudflare, try **DNS only** (grey cloud) during validation, then re-enable proxy

### WordPress install redirect loop

Confirm `blog.tryvibes.cc` is set as the site URL in WordPress settings and that HTTPS is working end-to-end.

## Security notes

- Never commit `.env` (already listed in `.gitignore`)
- Backup directories include `env.backup` (database secrets) and the full site — keep them off git (`/backups/` is gitignored) and copy them off this server
- Consider adding `data/` to `.gitignore` if the repo is shared — it contains database and site files
- Keep images updated periodically (`docker compose pull && docker compose up -d`)
