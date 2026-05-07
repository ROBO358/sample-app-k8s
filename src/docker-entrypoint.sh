#!/bin/sh
set -eu

TMPL=/usr/share/nginx/html.tmpl/index.html.tmpl
OUT=/usr/share/nginx/html/index.html
SECRET_FILE=/eso/notesPlain
DATA_FILE=/var/lib/sample-app/.mtime

# Compute SHA-256 of the ESO-injected secret (or placeholder if missing)
if [ -r "${SECRET_FILE}" ]; then
  SECRET_HASH=$(sha256sum "${SECRET_FILE}" | awk '{print $1}')
else
  SECRET_HASH="(secret not found)"
fi

# Touch and record mtime in persistent volume
mkdir -p "$(dirname "${DATA_FILE}")"
touch "${DATA_FILE}"
DATA_MTIME=$(date -r "${DATA_FILE}" -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")

# Render template
sed \
  -e "s|__SECRET_HASH__|${SECRET_HASH}|g" \
  -e "s|__HOSTNAME__|${HOSTNAME}|g" \
  -e "s|__BUILT_AT__|${BUILT_AT:-unknown}|g" \
  -e "s|__DATA_MTIME__|${DATA_MTIME}|g" \
  "${TMPL}" > "${OUT}"

exec "$@"
