#!/bin/bash
# configure-nginx.sh — Deploy Nginx configs with the real server IP substituted.
# Usage: sudo bash configure-nginx.sh <EC2_PUBLIC_IP>
# Example: sudo bash configure-nginx.sh 54.123.45.67
#
# Installs HTTP-only configs first. After running certbot, pass --with-ssl to
# switch to the full HTTPS virtual host configs:
#   sudo bash configure-nginx.sh 54.123.45.67 --with-ssl
set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: $0 <EC2_PUBLIC_IP> [--with-ssl]"
    echo "Example: $0 54.123.45.67"
    exit 1
fi

SERVER_IP="$1"
WITH_SSL="${2:-}"
DOMAIN_API="api.${SERVER_IP}.nip.io"
DOMAIN_APP="app.${SERVER_IP}.nip.io"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NGINX_SRC="${SCRIPT_DIR}/../nginx"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"

echo "==> Configuring Nginx for IP: ${SERVER_IP}"
echo "    App 1 domain: ${DOMAIN_API}"
echo "    App 2 domain: ${DOMAIN_APP}"
echo "    SSL: ${WITH_SSL:-no}"

echo "==> Replacing main nginx.conf"
cp "${NGINX_SRC}/nginx.conf" /etc/nginx/nginx.conf

if [ "${WITH_SSL}" = "--with-ssl" ]; then
    echo "==> Installing HTTPS virtual hosts (certbot certs required)"
    sed -e "s|SERVER_DOMAIN_API|${DOMAIN_API}|g" \
        "${NGINX_SRC}/crud-api.conf" > "${NGINX_AVAIL}/crud-api.conf"
    sed -e "s|SERVER_DOMAIN_APP|${DOMAIN_APP}|g" \
        "${NGINX_SRC}/multiauth.conf" > "${NGINX_AVAIL}/multiauth.conf"
else
    echo "==> Installing HTTP-only virtual hosts (pre-SSL)"
    sed -e "s|SERVER_DOMAIN_API|${DOMAIN_API}|g" \
        "${NGINX_SRC}/crud-api-http.conf" > "${NGINX_AVAIL}/crud-api.conf"
    sed -e "s|SERVER_DOMAIN_APP|${DOMAIN_APP}|g" \
        "${NGINX_SRC}/multiauth-http.conf" > "${NGINX_AVAIL}/multiauth.conf"
fi

echo "==> Disabling default Nginx site"
rm -f "${NGINX_ENABLED}/default"

echo "==> Enabling both sites"
ln -sfn "${NGINX_AVAIL}/crud-api.conf"  "${NGINX_ENABLED}/crud-api.conf"
ln -sfn "${NGINX_AVAIL}/multiauth.conf" "${NGINX_ENABLED}/multiauth.conf"

echo "==> Testing Nginx config..."
nginx -t

echo "==> Reloading Nginx"
systemctl reload nginx

echo ""
echo "===================================================================="
echo "  Nginx configured."
echo "  App 1 (FastAPI):    http://${DOMAIN_API}"
echo "  App 2 (Multi-Auth): http://${DOMAIN_APP}"
echo ""
if [ "${WITH_SSL}" != "--with-ssl" ]; then
    echo "  To add SSL after first deploys are healthy:"
    echo "  apt-get install -y certbot python3-certbot-nginx"
    echo "  certbot --nginx -d ${DOMAIN_API} -d ${DOMAIN_APP} --non-interactive \\"
    echo "          --agree-tos -m your-email@example.com"
    echo "  Then update Multi-Auth CORS_ORIGIN secret to https://app.${SERVER_IP}.nip.io"
fi
echo "===================================================================="
