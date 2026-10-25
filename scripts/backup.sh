#!/usr/bin/env bash
# Backup WordPress files, MySQL dump, Nginx config, and (optionally) TLS certs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DOCKER_COMPOSE="${DOCKER_COMPOSE:-docker compose}"
INCLUDE_CERTS=1
OUT_BASE="$ROOT/backups"
MYSQL_DATABASE_DEFAULT="wordpress_db"

usage() {
	cat <<'EOF'
Usage: backup.sh [options]

Create a timestamped backup of this WordPress Docker stack.

Options:
  --output-dir DIR   Directory to write backups into (default: ./backups)
  --skip-certs       Do not archive Let's Encrypt files (data/certbot-etc)
  -h, --help         Show this help

Environment:
  DOCKER_COMPOSE     Compose command (default: "docker compose")
                     Example: DOCKER_COMPOSE="sudo docker compose"

Example:
  ./scripts/backup.sh
  ./scripts/backup.sh --output-dir /mnt/backups/wordpress
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--output-dir)
			OUT_BASE="${2:?--output-dir requires a path}"
			shift 2
			;;
		--skip-certs)
			INCLUDE_CERTS=0
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
	esac
done

if [[ ! -f "$ROOT/.env" ]]; then
	echo "Missing $ROOT/.env (needed for database credentials)." >&2
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

echo "Waiting for MySQL (service db)..."
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
	echo "MySQL is not reachable. Start the stack with: $DOCKER_COMPOSE up -d" >&2
	exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUT_BASE/$STAMP"
# Ensure restrictive permissions (0700) so sensitive dumps and credentials are not readable by other users
umask 077
mkdir -p "$DEST"
chmod 700 "$DEST"

echo "Writing backup to $DEST"

echo "Dumping database ${MYSQL_DATABASE}..."
$DOCKER_COMPOSE exec -T -e MYSQL_PWD="$MYSQL_PASSWORD" db \
	mysqldump -u"$MYSQL_USER" \
	--single-transaction --routines --triggers --no-tablespaces --default-character-set=utf8mb4 \
	"$MYSQL_DATABASE" | gzip -c >"$DEST/wordpress_db.sql.gz"
chmod 600 "$DEST/wordpress_db.sql.gz"

echo "Archiving WordPress files..."
# Tar may return exit code 1 if files change while being read on an active site.
# Allow exit code 1 (warning) but fail on real tar errors (exit code >= 2).
tar -C "$ROOT/data/wordpress" -czf "$DEST/wordpress.tar.gz" . || {
	rc=$?
	if [[ $rc -ne 1 ]]; then
		echo "Failed to archive WordPress files (exit code $rc)" >&2
		exit $rc
	fi
}

echo "Archiving Nginx config..."
tar -C "$ROOT" -czf "$DEST/nginx-conf.tar.gz" nginx-conf

cp "$ROOT/docker-compose.yml" "$DEST/docker-compose.yml"
cp "$ROOT/.env" "$DEST/env.backup"
chmod 600 "$DEST/env.backup"

CERTS_STATUS="skipped"
if [[ "$INCLUDE_CERTS" -eq 1 ]]; then
	if [[ -d "$ROOT/data/certbot-etc" ]]; then
		if tar -C "$ROOT/data" -czf "$DEST/certbot-etc.tar.gz" certbot-etc 2>/dev/null; then
			CERTS_STATUS="included"
		else
			rm -f "$DEST/certbot-etc.tar.gz"
			CERTS_STATUS="skipped (permission denied; re-run with sudo or omit -- this is OK if you can reissue certs)"
			echo "Warning: could not read data/certbot-etc. TLS certs were not backed up." >&2
		fi
	else
		CERTS_STATUS="skipped (directory missing)"
	fi
fi

{
	echo "WordPress Docker backup"
	echo "created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo "host: $(hostname)"
	echo "project_root: $ROOT"
	echo "database: $MYSQL_DATABASE"
	echo "wordpress_files: wordpress.tar.gz"
	echo "database_dump: wordpress_db.sql.gz"
	echo "nginx: nginx-conf.tar.gz"
	echo "compose: docker-compose.yml"
	echo "env: env.backup"
	echo "certs: $CERTS_STATUS"
} >"$DEST/MANIFEST.txt"

echo
echo "Backup complete: $DEST"
ls -lh "$DEST"
echo
echo "Copy this directory off the server. A backup that only lives here is not a real backup."
echo "Restore with: ./scripts/restore.sh $DEST"
