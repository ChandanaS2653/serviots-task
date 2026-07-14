#!/bin/bash
# server-setup.sh — One-time EC2 server provisioning script
# Run as: sudo bash server-setup.sh
# Idempotent: safe to re-run — existing installs are skipped or upgraded cleanly.
set -euo pipefail

JENKINS_PORT=9090
APP_USER=appuser
APP_DIR=/opt/crud-api
MULTIAUTH_DIR=/opt/multiauth
NODE_VERSION=20

echo "==> [1/8] System update"
apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends \
    curl wget gnupg lsb-release ca-certificates \
    git unzip software-properties-common \
    ufw fail2ban \
    libpq-dev postgresql-client

echo "==> [2/8] Install Python 3.11"
add-apt-repository -y ppa:deadsnakes/ppa
apt-get update -y
apt-get install -y python3.11 python3.11-venv python3.11-dev
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1

echo "==> [3/8] Install Node.js ${NODE_VERSION} and PM2"
curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
apt-get install -y nodejs
npm install -g pm2
# Make PM2 start on boot for the appuser
# (run 'pm2 startup' manually as appuser after first deploy)

echo "==> [4/8] Install Nginx"
apt-get install -y nginx
systemctl enable nginx

echo "==> [5/8] Install Jenkins on port ${JENKINS_PORT}"
# Add Jenkins repo and key
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
    | tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
    https://pkg.jenkins.io/debian-stable binary/" \
    | tee /etc/apt/sources.list.d/jenkins.list > /dev/null

apt-get update -y
apt-get install -y default-jdk jenkins

# Change Jenkins port from default 8080 to JENKINS_PORT
# Using the new override approach (jenkins.xml is deprecated in newer versions)
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="JENKINS_PORT=${JENKINS_PORT}"
EOF

systemctl daemon-reload
systemctl enable jenkins
systemctl restart jenkins

echo "    Jenkins will be available on port ${JENKINS_PORT}"
echo "    Initial admin password: $(cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo 'not ready yet — wait ~60s')"

echo "==> [6/8] Create app user and directory structure"
if ! id "${APP_USER}" &>/dev/null; then
    useradd --system --shell /bin/bash --home /home/${APP_USER} --create-home ${APP_USER}
fi

# App 1 — CRUD API
mkdir -p ${APP_DIR}/releases
python3.11 -m venv ${APP_DIR}/venv
chown -R ${APP_USER}:${APP_USER} ${APP_DIR}

# App 2 — Multi-Auth MERN
mkdir -p ${MULTIAUTH_DIR}/releases
chown -R ${APP_USER}:${APP_USER} ${MULTIAUTH_DIR}

# Let certbot write to this path for ACME challenge
mkdir -p /var/www/certbot
chown www-data:www-data /var/www/certbot

echo "==> [7/8] Configure UFW firewall"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# SSH — REPLACE with your actual ops IP range before running
# Example: ufw allow from 203.0.113.0/24 to any port 22
# Using 0.0.0.0/0 here is a placeholder — MUST be changed before deploy
echo "    WARNING: SSH is currently open to all — restrict to your IP in UFW rules below"
ufw allow 22/tcp comment 'SSH — RESTRICT TO YOUR IP'

# Public web traffic
ufw allow 80/tcp  comment 'HTTP — Nginx (Let'\''s Encrypt + redirect)'
ufw allow 443/tcp comment 'HTTPS — Nginx reverse proxy for both apps'

# Jenkins — restrict to ops IP (same as SSH)
# ufw allow from YOUR_IP to any port ${JENKINS_PORT} proto tcp
echo "    Jenkins port ${JENKINS_PORT}: add UFW rule manually for your IP"
echo "    Example: ufw allow from YOUR_OPS_IP to any port ${JENKINS_PORT} proto tcp"

ufw --force enable
ufw status verbose

echo "==> [8/8] Install and enable fail2ban (SSH brute-force protection)"
systemctl enable fail2ban
systemctl start fail2ban

echo ""
echo "===================================================================="
echo "  Server setup complete."
echo ""
echo "  NEXT STEPS (manual, in order):"
echo "  1. Edit /etc/ufw/applications.d or run:"
echo "     ufw delete allow 22/tcp"
echo "     ufw allow from YOUR_OPS_IP to any port 22 proto tcp"
echo "     ufw allow from YOUR_OPS_IP to any port ${JENKINS_PORT} proto tcp"
echo ""
echo "  2. Copy Nginx configs:"
echo "     bash /opt/crud-api/current/infra/scripts/configure-nginx.sh YOUR_EC2_PUBLIC_IP"
echo ""
echo "  3. Get SSL certificates (after DNS is resolving):"
echo "     certbot --nginx -d api.YOUR_IP.nip.io -d app.YOUR_IP.nip.io"
echo ""
echo "  4. Copy systemd service and start:"
echo "     cp /opt/crud-api/current/infra/systemd/crud-api.service /etc/systemd/system/"
echo "     systemctl daemon-reload && systemctl enable crud-api && systemctl start crud-api"
echo ""
echo "  5. Open Jenkins at http://YOUR_IP:${JENKINS_PORT} and complete setup"
echo "===================================================================="
