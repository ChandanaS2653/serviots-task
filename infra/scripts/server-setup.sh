#!/bin/bash
# server-setup.sh — One-time EC2 server provisioning script (GitHub Actions CI/CD)
# Run as: sudo bash server-setup.sh
# Idempotent: safe to re-run.
#
# NOTE: The CloudFormation user-data already handles:
#   - swap setup, system update, Python, Node, Nginx, app user, directories, UFW, fail2ban
# This script is for manual runs on instances NOT launched from the CFT,
# or to re-apply/verify the provisioning state.
set -euo pipefail

APP_USER=appuser
APP_DIR=/opt/crud-api
MULTIAUTH_DIR=/opt/multiauth
NODE_VERSION=20

echo "==> [1/7] System update"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
apt-get install -y --no-install-recommends \
    curl wget gnupg lsb-release ca-certificates \
    git rsync unzip software-properties-common \
    ufw fail2ban libpq-dev postgresql-client

echo "==> [2/7] Install Python 3.11"
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update -y
apt-get install -y python3.11 python3.11-venv python3.11-dev
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1

echo "==> [3/7] Install Node.js ${NODE_VERSION} and PM2"
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
apt-get install -y nodejs
npm install -g pm2

echo "==> [4/7] Install Nginx"
apt-get install -y nginx
systemctl enable nginx

echo "==> [5/7] Create app user and directory structure"
if ! id "${APP_USER}" &>/dev/null; then
    useradd --system --shell /bin/bash --home /home/${APP_USER} --create-home ${APP_USER}
fi

mkdir -p ${APP_DIR}/releases
python3.11 -m venv ${APP_DIR}/venv
chown -R ${APP_USER}:${APP_USER} ${APP_DIR}

mkdir -p ${MULTIAUTH_DIR}/releases
chown -R ${APP_USER}:${APP_USER} ${MULTIAUTH_DIR}

mkdir -p /var/www/certbot
chown www-data:www-data /var/www/certbot

echo "==> [6/7] Sudoers rule for GitHub Actions deploy user (ubuntu)"
# GitHub Actions SSHes as ubuntu and needs to restart services.
# Grant only the specific systemctl commands — not full sudo.
cat > /etc/sudoers.d/gha-deploy << 'SUDO'
ubuntu ALL=(ALL) NOPASSWD: \
  /bin/systemctl restart crud-api, \
  /bin/systemctl reload crud-api, \
  /bin/systemctl start crud-api, \
  /bin/systemctl stop crud-api, \
  /bin/systemctl daemon-reload, \
  /usr/sbin/nginx -t, \
  /bin/systemctl reload nginx
SUDO
chmod 440 /etc/sudoers.d/gha-deploy

echo "==> [7/7] Configure UFW firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH — restricted to ops IP. Replace YOUR_OPS_IP before running.
# Example: ufw allow from 203.0.113.5/32 to any port 22 proto tcp
echo "  WARNING: Set your ops IP below before running UFW rules."
echo "  Edit this script: replace YOUR_OPS_IP/32 with your real IP."
# ufw allow from YOUR_OPS_IP/32 to any port 22 proto tcp comment 'SSH ops IP'
ufw allow 22/tcp comment 'SSH — RESTRICT THIS TO YOUR IP'

ufw allow 80/tcp  comment 'HTTP Nginx (Let'\''s Encrypt + redirect)'
ufw allow 443/tcp comment 'HTTPS Nginx (both apps)'
# No port 9090 — GitHub Actions replaces Jenkins entirely.

ufw --force enable
ufw status verbose

systemctl enable fail2ban
systemctl start fail2ban

echo ""
echo "===================================================================="
echo "  Server setup complete."
echo ""
echo "  NEXT STEPS:"
echo "  1. Restrict SSH to your IP:"
echo "     ufw delete allow 22/tcp"
echo "     ufw allow from YOUR_IP/32 to any port 22 proto tcp"
echo ""
echo "  2. Configure Nginx (after cloning repo):"
echo "     sudo bash /opt/crud-api/current/infra/scripts/configure-nginx.sh EC2_PUBLIC_IP"
echo ""
echo "  3. Install systemd service for App 1:"
echo "     cp /opt/crud-api/current/infra/systemd/crud-api.service /etc/systemd/system/"
echo "     systemctl daemon-reload && systemctl enable crud-api"
echo ""
echo "  4. Add GitHub Secrets to both repos and push to main to trigger deploys."
echo ""
echo "  5. After first successful deploys, run certbot for SSL:"
echo "     certbot --nginx -d api.IP.nip.io -d app.IP.nip.io"
echo "===================================================================="
