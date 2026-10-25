# Backup and restore

[English](BACKUP.md) | [简体中文](BACKUP_CN.md)

Two ways to back up this Docker WordPress stack:

| Method | Purpose |
|--------|---------|
| [`scripts/backup.sh`](scripts/backup.sh) | Server snapshot: database, site files, Nginx, Compose, `.env`, certs |
| [From wp-admin](#backup-from-wp-admin) | Plugin backup from the WordPress dashboard (database + `wp-content`) |
| [`scripts/restore.sh`](scripts/restore.sh) | Restore a snapshot created by `backup.sh` |

The scripts dump MySQL and archive site files. They do **not** copy the live MySQL datadir (`data/dbdata`) while the database is running.

## What a backup contains

Each run creates `backups/YYYYMMDD-HHMMSS/` (or another directory you pass with `--output-dir`):

| File | Contents |
|------|----------|
| `wordpress_db.sql.gz` | `mysqldump` of `wordpress_db` |
| `wordpress.tar.gz` | Everything under `data/wordpress` (core, themes, plugins, uploads) |
| `nginx-conf.tar.gz` | Nginx HTTP/HTTPS config |
| `docker-compose.yml` | Compose file as it was at backup time |
| `env.backup` | Copy of `.env` (database secrets) |
| `certbot-etc.tar.gz` | Let's Encrypt files, if readable |
| `MANIFEST.txt` | Timestamp, host, and what was included |

The live InnoDB files in `data/dbdata/` are **not** archived. Restore uses the SQL dump instead.

## Backup

From the project root (`wordpress/`):

```bash
chmod +x scripts/backup.sh scripts/restore.sh   # once
./scripts/backup.sh
```

The stack must be running so `mysqldump` can reach MySQL:

```bash
docker compose up -d
./scripts/backup.sh
```

Useful options:

```bash
# Write somewhere other than ./backups
./scripts/backup.sh --output-dir /mnt/backups/wordpress

# Skip TLS certs (you can reissue with Certbot after restore)
./scripts/backup.sh --skip-certs

# If Docker needs root
DOCKER_COMPOSE="sudo docker compose" ./scripts/backup.sh
```

Copy the new directory **off this server** (another disk, object storage, or your laptop). A folder that only exists on this VM is not a recovery plan.

`env.backup` contains database passwords. Treat backup directories like secrets. `scripts/backup.sh` automatically enforces restrictive directory permissions (`chmod 700`) and file permissions (`chmod 600` on credentials and database dumps).

## Backup from wp-admin

Use this when you can log in to WordPress and want a downloadable backup without SSH. It covers the WordPress database and files the plugin is configured to include. It does **not** back up Docker, Nginx, `.env`, or Let's Encrypt certificates — use `backup.sh` for a full stack snapshot.

Admin: `https://yourdomain.com/wp-admin/`  
Login: `https://yourdomain.com/wp-login.php`

### 1. Install a backup plugin

1. Log in as an administrator.
2. Go to **Plugins → Add Plugin**.
3. Search for a backup plugin (for example **UpdraftPlus**).
4. Click **Install Now**, then **Activate**.

Any maintained backup plugin works. The labels below match UpdraftPlus; others use the same idea under **Settings** or their own menu.

### 2. Run a backup

1. Open **Settings → UpdraftPlus Backups** (or the plugin’s own menu).
2. Confirm it will include:
   - Database
   - Plugins
   - Themes
   - Uploads
   - Other `wp-content` files (if listed)
3. Click **Backup Now**.
4. Wait until the job finishes (do not close the tab until it reports success).

### 3. Download the backup off the site

1. On the same screen, find the new backup in the backup history.
2. Download **every** part it offers (database, plugins, themes, uploads, and others).
3. Save the files on your laptop or another disk — not only on this server.

Files left only under `wp-content/updraft` (or similar) are lost if the site or disk is wiped.

### Restore from wp-admin

1. Install and activate the **same** backup plugin on the site you are restoring to.
2. Upload the downloaded backup archives in the plugin’s restore UI, or place them where the plugin expects them.
3. Choose the components to restore and run **Restore**.
4. Log in again if the plugin asks you to; then check the site and wp-admin.

This restores WordPress content only. It will not recreate `docker-compose.yml`, `nginx-conf/`, `.env`, or TLS certs. For a new server or a broken stack, use [Restore](#restore) with `restore.sh`.

## Restore

Restore overwrites the live site. Take a fresh backup first if the current site still matters.

Before modifying any live files or stopping services, `scripts/restore.sh` automatically pre-validates archive integrity (`gzip -t` on the database dump and `tar -tzf` on WordPress and Nginx archives). If any archive is corrupted or truncated, restore aborts immediately to protect your live installation from accidental data loss.

```bash
./scripts/restore.sh backups/YYYYMMDD-HHMMSS
```

You must type `YES` to continue, unless you pass `--yes`.

What restore always replaces:

- `data/wordpress/`
- Nginx files in `nginx-conf/`
- MySQL database `wordpress_db` (imported from the dump)

Optional flags:

```bash
# Also replace .env from the snapshot (needed if this server has no .env)
./scripts/restore.sh --restore-env backups/YYYYMMDD-HHMMSS

# Also replace docker-compose.yml from the snapshot
./scripts/restore.sh --restore-compose backups/YYYYMMDD-HHMMSS

# Non-interactive (automation)
./scripts/restore.sh --yes backups/YYYYMMDD-HHMMSS

# Keep current certificates
./scripts/restore.sh --skip-certs backups/YYYYMMDD-HHMMSS
```

`--restore-env` must match the MySQL users already inside `data/dbdata`. If you restore an old `.env` onto a database volume that was initialized with different passwords, WordPress will fail to connect. For a same-server rollback, omit `--restore-env` unless `.env` is missing.

After restore, open:

- Site: `https://yourdomain.com/`
- Admin: `https://yourdomain.com/wp-admin/`

If HTTPS fails because certs were not restored, reissue them (see [README.md](README.md#certificate-renewal)):

```bash
docker compose run --rm certbot
docker compose restart webserver
```

## Typical workflows

### Before a risky change (plugin/theme/delete Elementor)

```bash
./scripts/backup.sh
# then make the change in wp-admin
```

Or back up from wp-admin first (see [Backup from wp-admin](#backup-from-wp-admin)), then make the change.

If you need to undo a script snapshot:

```bash
./scripts/restore.sh backups/YYYYMMDD-HHMMSS
```

### New server / empty disk

1. Copy this repo (at least `docker-compose.yml`, `scripts/`, `nginx-conf/`).
2. Copy a backup directory onto the machine.
3. Restore env and compose from the snapshot, then restore data:

```bash
./scripts/restore.sh --yes --restore-env --restore-compose /path/to/backups/YYYYMMDD-HHMMSS
```

If `data/dbdata` does not exist yet, `docker compose up -d db` creates it from `.env`, then the script imports SQL.

## Troubleshooting

**Cannot log in to wp-admin**

Use `./scripts/backup.sh` instead. Plugin backups require an administrator session.

**`permission denied` talking to Docker**

Use `DOCKER_COMPOSE="sudo docker compose"` or add your user to the `docker` group.

**Backup skipped certs**

`data/certbot-etc` is often root-owned. Re-run backup with sudo, or skip certs and run Certbot after restore.

**Restore cannot extract certs or WordPress files**

Run the restore with the same privileges that own those directories (`sudo` if they are root-owned).

**Site shows old content after restore**

Hard-refresh the browser or purge Cloudflare cache if the domain is proxied.

## Git

`./backups/` is gitignored. Do not commit snapshots; they include `.env` secrets and the full site.