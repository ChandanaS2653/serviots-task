#!/bin/bash
# configure-nginx.sh — Deploy Nginx configs with the real server IP substituted.
# Usage: sudo bash configure-nginx.sh <EC2_PUBLIC_IP>
# Example: sudo bash configure-nginx.sh 54.123.45.67
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <EC2_PUBLIC_IP>"
    echo "Example: $0 54.123.45.67"
    exit 1
fi

SERVER_IP="$1"
DOMAIN_API="api.${SERVER_IP}.nip.io"
DOMAIN_APP="app.${SERVER_IP}.nip.io"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_SRC="${SCRIPT_DIR}/../nginx"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

echo "==> Configuring Nginx for IP: ${SERVER_IP}"
echo "    App 1 domain: ${DOMAIN_API}"
echo "    App 2 domain: ${DOMAIN_APP}"

echo "==> Replacing main nginx.conf"
cp "${NGINX_SRC}/nginx.conf" /etc/nginx/nginx.conf

echo "==> Installing crud-api virtual host"
sed \
    -e "s|SERVER_DOMAIN_API|${DOMAIN_API}|g" \
    "${NGINX_SRC}/crud-api.conf" > "${NGINX_AVAIL}/crud-api.conf"

echo "==> Installing multiauth virtual host"
sed \
    -e "s|SERVER_DOMAIN_APP|${DOMAIN_APP}|g" \
    "${NGINX_SRC}/multiauth.conf" > "${NGINX_AVAIL}/multiauth.conf"

echo "==> Disabling default Nginx site"
rm -f "${NGINX_ENABLED}/default"

echo "==> Enabling both sites"
ln -sfn "${NGINX_AVAIL}/crud-api.conf"  "${NGINX_ENABLED}/crud-api.conf"
ln -sfn "${NGINX_AVAIL}/multiauth.conf" "${NGINX_ENABLED}/multiauth.conf"

echo "==> Testing Nginx config..."
# Test without SSL first — comment out ssl_certificate lines if certs not yet issued
nginx -t

echo "==> Reloading Nginx"
systemctl reload nginx

echo ""
echo "===================================================================="
echo "  Nginx configured."
echo "  App 1 (FastAPI):   http://${DOMAIN_API}"
echo "  App 2 (Multi-Auth): http://${DOMAIN_APP}"
echo ""
echo "  To add SSL (after apps are running on HTTP):"
echo "  apt-get install -y certbot python3-certbot-nginx"
echo "  certbot --nginx -d ${DOMAIN_API} -d ${DOMAIN_APP}"
echo ""
echo "  NOTE: nip.io does not support Let's Encrypt for wildcard certs."
echo "  Certbot will issue individual certs for each subdomain — this is fine."
echo "===================================================================="
