#!/usr/bin/env bash
# Restore WordPress files, MySQL dump, and Nginx config from a backup directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DOCKER_COMPOSE="${DOCKER_COMPOSE:-docker compose}"
MYSQL_DATABASE_DEFAULT="wordpress_db"
ASSUME_YES=0
RESTORE_ENV=0
RESTORE_COMPOSE=0
RESTORE_CERTS=1
BACKUP_DIR=""

usage() {
	cat <<'EOF'
Usage: restore.sh [options] BACKUP_DIR

Restore this WordPress Docker stack from a directory created by backup.sh.

This overwrites live WordPress files, Nginx config, and the MySQL database.

Options:
  --yes              Do not prompt for confirmation
  --restore-env      Replace .env with env.backup from the snapshot
  --restore-compose  Replace docker-compose.yml from the snapshot
  --skip-certs       Do not restore Let's Encrypt files even if present
  -h, --help         Show this help

Environment:
  DOCKER_COMPOSE     Compose command (default: "docker compose")
                     Example: DOCKER_COMPOSE="sudo docker compose"

Example:
  ./scripts/restore.sh backups/20260920-125133
  ./scripts/restore.sh --yes --restore-env backups/20260920-125133
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--yes)
			ASSUME_YES=1
			shift
			;;
		--restore-env)
			RESTORE_ENV=1
			shift
			;;
		--restore-compose)
			RESTORE_COMPOSE=1
			shift
			;;
		--skip-certs)
			RESTORE_CERTS=0
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
		*)
			if [[ -n "$BACKUP_DIR" ]]; then
				echo "Unexpected argument: $1" >&2
				usage >&2
				exit 1
			fi
			BACKUP_DIR="$1"
			shift
			;;
	esac
done

if [[ -z "$BACKUP_DIR" ]]; then
	usage >&2
	exit 1
fi

if [[ ! -d "$BACKUP_DIR" ]]; then
	echo "Backup directory not found: $BACKUP_DIR" >&2
	exit 1
fi

# Resolve to an absolute path so later cd/ROOT usage is unambiguous.
BACKUP_DIR="$(cd "$BACKUP_DIR" && pwd)"

DUMP="$BACKUP_DIR/wordpress_db.sql.gz"
WP_TAR="$BACKUP_DIR/wordpress.tar.gz"
NGINX_TAR="$BACKUP_DIR/nginx-conf.tar.gz"

for required in "$DUMP" "$WP_TAR" "$NGINX_TAR"; do
	if [[ ! -f "$required" ]]; then
		echo "Missing required backup file: $required" >&2
		echo "Expected a directory produced by scripts/backup.sh" >&2
		exit 1
	fi
done

echo "Verifying backup archive integrity..."
if ! gzip -t "$DUMP"; then
	echo "Error: Database dump is corrupted: $DUMP" >&2
	exit 1
fi
if ! tar -tzf "$WP_TAR" >/dev/null 2>&1; then
	echo "Error: WordPress archive is corrupted: $WP_TAR" >&2
	exit 1
fi
if ! tar -tzf "$NGINX_TAR" >/dev/null 2>&1; then
	echo "Error: Nginx archive is corrupted: $NGINX_TAR" >&2
	exit 1
fi

echo "Restore source: $BACKUP_DIR"
if [[ -f "$BACKUP_DIR/MANIFEST.txt" ]]; then
	cat "$BACKUP_DIR/MANIFEST.txt"
	echo
fi

echo "This will overwrite:"
echo "  - $ROOT/data/wordpress"
echo "  - MySQL database (wordpress_db unless .env says otherwise)"
echo "  - $ROOT/nginx-conf"
[[ "$RESTORE_ENV" -eq 1 ]] && echo "  - $ROOT/.env"
[[ "$RESTORE_COMPOSE" -eq 1 ]] && echo "  - $ROOT/docker-compose.yml"
if [[ "$RESTORE_CERTS" -eq 1 && -f "$BACKUP_DIR/certbot-etc.tar.gz" ]]; then
	echo "  - $ROOT/data/certbot-etc"
fi
echo

if [[ "$ASSUME_YES" -ne 1 ]]; then
	printf "Type YES to continue: "
	read -r confirm
	if [[ "$confirm" != "YES" ]]; then
		echo "Aborted."
		exit 1
	fi
fi

if [[ "$RESTORE_ENV" -eq 1 ]]; then
	if [[ ! -f "$BACKUP_DIR/env.backup" ]]; then
		echo "Cannot --restore-env: $BACKUP_DIR/env.backup is missing." >&2
		exit 1
	fi
	cp "$BACKUP_DIR/env.backup" "$ROOT/.env"
	chmod 600 "$ROOT/.env"
	echo "Restored .env"
fi

if [[ "$RESTORE_COMPOSE" -eq 1 ]]; then
	if [[ ! -f "$BACKUP_DIR/docker-compose.yml" ]]; then
		echo "Cannot --restore-compose: snapshot has no docker-compose.yml." >&2
		exit 1
	fi
	cp "$BACKUP_DIR/docker-compose.yml" "$ROOT/docker-compose.yml"
	echo "Restored docker-compose.yml"
fi

if [[ ! -f "$ROOT/.env" ]]; then
	echo "Missing $ROOT/.env. Pass --restore-env if the snapshot includes env.backup." >&2
	exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ROOT/.env"
set +a

MYSQL_DATABASE="${MYSQL_DATABASE:-$MYSQL_DATABASE_DEFAULT}"

if [[ -z "${MYSQL_USER:-}" || -z "${MYSQL_PASSWORD:-}" ]]; then
	echo ".env must set MYSQL_USER and MYSQL_PASSWORD." >&2
	exit 1
fi

if ! $DOCKER_COMPOSE ps --services >/dev/null 2>&1; then
	echo "Cannot talk to Docker Compose. If you see permission denied, retry with:" >&2
	echo "  DOCKER_COMPOSE=\"sudo docker compose\" $0 $*" >&2
	exit 1
fi

echo "Stopping WordPress and Nginx so files are not written during restore..."
$DOCKER_COMPOSE stop wordpress webserver >/dev/null 2>&1 || true
$DOCKER_COMPOSE up -d db

echo "Waiting for MySQL..."
ready=0
for _ in $(seq 1 30); do
	if $DOCKER_COMPOSE exec -T -e MYSQL_PWD="$MYSQL_PASSWORD" db \
		mysqladmin ping -u"$MYSQL_USER" --silent >/dev/null 2>&1; then
		ready=1
		break
	fi
	sleep 2
done
if [[ "$ready" -ne 1 ]]; then
	echo "MySQL is not reachable after starting db." >&2
	exit 1
fi

echo "Restoring WordPress files..."
mkdir -p "$ROOT/data/wordpress"
# Remove existing contents but keep the directory (bind mount target).
find "$ROOT/data/wordpress" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tar -xzf "$WP_TAR" -C "$ROOT/data/wordpress"

echo "Restoring Nginx config..."
mkdir -p "$ROOT/nginx-conf"
find "$ROOT/nginx-conf" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tar -xzf "$NGINX_TAR" -C "$ROOT" nginx-conf

if [[ "$RESTORE_CERTS" -eq 1 && -f "$BACKUP_DIR/certbot-etc.tar.gz" ]]; then
	echo "Restoring TLS certificates..."
	mkdir -p "$ROOT/data"
	if ! tar -xzf "$BACKUP_DIR/certbot-etc.tar.gz" -C "$ROOT/data"; then
		echo "Warning: could not extract certbot-etc (often needs sudo). Reissue certs after restore if HTTPS fails." >&2
	fi
fi

echo "Importing database ${MYSQL_DATABASE}..."
# Recreate the schema so leftover tables from newer plugins do not remain.
if [[ -n "${MYSQL_ROOT_PASSWORD:-}" ]]; then
	$DOCKER_COMPOSE exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db \
		mysql -uroot -e "DROP DATABASE IF EXISTS \`${MYSQL_DATABASE}\`; CREATE DATABASE \`${MYSQL_DATABASE}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
	gzip -dc "$DUMP" | $DOCKER_COMPOSE exec -T -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" db \
		mysql -uroot "$MYSQL_DATABASE"
else
	gzip -dc "$DUMP" | $DOCKER_COMPOSE exec -T -e MYSQL_PWD="$MYSQL_PASSWORD" db \
		mysql -u"$MYSQL_USER" "$MYSQL_DATABASE"
fi

echo "Starting stack..."
$DOCKER_COMPOSE up -d

echo
echo "Restore complete from $BACKUP_DIR"
TARGET_DOMAIN="${DOMAIN_NAME:-your-domain.com}"
echo "Check https://${TARGET_DOMAIN}/ and https://${TARGET_DOMAIN}/wp-admin/"
