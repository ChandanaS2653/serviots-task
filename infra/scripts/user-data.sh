#!/bin/bash
# user-data.sh — cloud-init script, runs once on first EC2 boot as root.
# Sets up 2 GB swap before server-setup.sh runs — critical on t3.micro (1 GB RAM)
# because Jenkins JVM needs headroom during builds.
set -euo pipefail

LOG=/var/log/user-data.log
exec > >(tee -a ${LOG}) 2>&1

echo "[$(date)] Starting cloud-init user-data"

# ── 1. Swap — 2 GB ────────────────────────────────────────────────────────────
# t3.micro has 1 GB RAM. Jenkins + two apps + OS will exceed this during builds.
# Swap prevents OOM kills at the cost of slower builds (disk I/O vs RAM).
SWAP_FILE=/swapfile
if [ ! -f "${SWAP_FILE}" ]; then
    echo "[$(date)] Creating 2 GB swap file..."
    fallocate -l 2G ${SWAP_FILE}
    chmod 600 ${SWAP_FILE}
    mkswap ${SWAP_FILE}
    swapon ${SWAP_FILE}
    echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab

    # Reduce swappiness — only use swap under real pressure, not proactively
    echo "vm.swappiness=10" >> /etc/sysctl.conf
    sysctl -p
    echo "[$(date)] Swap ready: $(free -h | grep Swap)"
else
    echo "[$(date)] Swap already exists, skipping."
fi

# ── 2. Basic system update ────────────────────────────────────────────────────
echo "[$(date)] Running apt update..."
apt-get update -y

# ── 3. Install postgres client (needed by rds.tf null_resource) ───────────────
apt-get install -y --no-install-recommends postgresql-client

# ── 4. Signal that cloud-init finished ────────────────────────────────────────
echo "[$(date)] cloud-init complete. Run server-setup.sh next."
touch /tmp/user-data-complete
