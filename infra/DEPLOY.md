# Deployment Guide — CloudFormation + GitHub Actions (us-west-2)

CI/CD via GitHub Actions (no Jenkins). Infrastructure via CloudFormation.
Follow steps in exact order — each depends on the previous.

---

## Prerequisites

- [ ] AWS account with permissions to create EC2, RDS, VPC, IAM
- [ ] AWS CLI installed and configured: `aws configure --profile serviots`
- [ ] An EC2 key pair in `us-west-2` — AWS Console → EC2 → Key Pairs → Create
- [ ] Your public IP: `curl https://checkip.amazonaws.com`

---

## Step 1 — Deploy the CloudFormation Stack

### Option A — AWS Console (easiest)

1. Go to **AWS Console → CloudFormation → Create stack → With new resources**
2. Upload `infra/cloudformation/stack.yml`
3. Fill in parameters:

| Parameter | Value |
|-----------|-------|
| Stack name | `serviots-task` |
| VpcId | Select your **default VPC** |
| SubnetIds | Select **all subnets** in your default VPC |
| KeyName | Your key pair name |
| OpsIpCidr | `YOUR_IP/32` from checkip.amazonaws.com |
| DBPassword | Strong password — save it |
| InstanceType | `t3.micro` |
| DBInstanceClass | `db.t3.micro` |

4. Click Next → Next → Create stack
5. Wait **10–15 minutes** for the RDS instance (it's the slow part)

### Option B — AWS CLI

```bash
aws cloudformation deploy \
  --region us-west-2 \
  --stack-name serviots-task \
  --template-file infra/cloudformation/stack.yml \
  --parameter-overrides \
    VpcId=vpc-XXXXXXXX \
    SubnetIds="subnet-AAA,subnet-BBB,subnet-CCC" \
    KeyName=your-key-name \
    OpsIpCidr=YOUR_IP/32 \
    DBPassword=YourPassword123! \
  --capabilities CAPABILITY_NAMED_IAM
```

### Get the outputs

```bash
aws cloudformation describe-stacks \
  --region us-west-2 \
  --stack-name serviots-task \
  --query 'Stacks[0].Outputs' \
  --output table
```

Note down: **PublicIP** and **RDSEndpoint** — you need both in later steps.

---

## Step 2 — Wait for cloud-init to finish on EC2

The EC2 user-data script runs swap setup and full provisioning on first boot. It takes ~4 minutes.

```bash
# SSH in (use PublicIP from CFT output)
ssh -i ~/.ssh/your-key.pem ubuntu@PUBLIC_IP

# Watch cloud-init progress
tail -f /var/log/user-data.log

# When you see "cloud-init complete" — proceed to Step 3
```

---

## Step 3 — Clone Repos and Configure Nginx

```bash
# On the EC2 server:

# Clone App 1
sudo git clone https://github.com/ChandanaS2653/serviots-task.git /opt/crud-api/current
sudo chown -R appuser:appuser /opt/crud-api/current

# Clone App 2
sudo git clone https://github.com/ChandanaS2653/Multi-Auth.git /opt/multiauth/current
sudo chown -R appuser:appuser /opt/multiauth/current

# Configure Nginx with your real EC2 IP (replaces SERVER_DOMAIN_* placeholders)
sudo bash /opt/crud-api/current/infra/scripts/configure-nginx.sh PUBLIC_IP

# Verify Nginx config
sudo nginx -t
```

---

## Step 4 — Set Up Systemd Service for App 1

```bash
# On the EC2 server:
sudo cp /opt/crud-api/current/infra/systemd/crud-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable crud-api
# Don't start it yet — the first GitHub Actions deploy will start it
```

---

## Step 5 — Create Two Databases in RDS

The CFT creates the RDS instance with only the default `postgres` database.
You need to create `crud_api_db` and `multiauth_db` manually via psql:

```bash
# On the EC2 server (has psql from the cloud-init install):
PGPASSWORD='your-db-password' psql \
  -h RDS_ENDPOINT \
  -U postgres \
  -c "CREATE DATABASE crud_api_db;"

PGPASSWORD='your-db-password' psql \
  -h RDS_ENDPOINT \
  -U postgres \
  -c "CREATE DATABASE multiauth_db;"
```

---

## Step 6 — Set GitHub Secrets for App 1 (serviots-task repo)

Go to: **GitHub → serviots-task → Settings → Secrets and variables → Actions → New repository secret**

| Secret name | Value |
|-------------|-------|
| `EC2_HOST` | EC2 public IP from CFT output |
| `EC2_SSH_KEY` | Full contents of your `.pem` file (including `-----BEGIN...-----END...`) |
| `DATABASE_URL` | `postgresql://postgres:PASSWORD@RDS_HOST:5432/crud_api_db` |

---

## Step 7 — Set GitHub Secrets for App 2 (Multi-Auth repo)

Go to: **GitHub → Multi-Auth → Settings → Secrets and variables → Actions → New repository secret**

| Secret name | Value |
|-------------|-------|
| `EC2_HOST` | Same EC2 public IP |
| `EC2_SSH_KEY` | Same `.pem` file contents |
| `DATABASE_URL` | `postgresql://postgres:PASSWORD@RDS_HOST:5432/multiauth_db` |
| `JWT_PRIVATE_KEY` | RSA private key as one line with `\n` for newlines |
| `JWT_PUBLIC_KEY` | RSA public key as one line with `\n` for newlines |
| `HRM_CLIENT_ID` | HRM OAuth client ID |
| `HRM_CLIENT_SECRET` | HRM OAuth secret |
| `CRM_CLIENT_ID` | CRM OAuth client ID |
| `CRM_CLIENT_SECRET` | CRM OAuth secret |
| `CORS_ORIGIN` | `http://app.PUBLIC_IP.nip.io` (update to https after SSL) |

**To generate RSA keys for Multi-Auth:**
```bash
# On the EC2 server in the multiauth directory
cd /opt/multiauth/current
node scripts/setup-keys.js
# Then convert to single-line format:
cat keys/private.pem | awk '{printf "%s\\n", $0}' | sed 's/\\n$//'
```

---

## Step 8 — Trigger First Deploys

**App 1 — push to main or run manually:**
```
GitHub → serviots-task → Actions → CI/CD — CRUD API → Run workflow
```

Monitor: Actions tab shows live logs. On success:
```bash
curl http://api.PUBLIC_IP.nip.io/health
# Expected: {"status":"healthy","app":"ok","database":"ok"}
```

**App 2 — push to main or run manually:**
```
GitHub → Multi-Auth → Actions → CI/CD — Multi-Auth → Run workflow
```

On success:
```bash
curl http://app.PUBLIC_IP.nip.io/
# Expected: {"success":true,"message":"System Works"}
```

---

## Step 9 — SSL via Let's Encrypt

```bash
# On the EC2 server
sudo apt-get install -y certbot python3-certbot-nginx

sudo certbot --nginx \
  -d api.PUBLIC_IP.nip.io \
  -d app.PUBLIC_IP.nip.io \
  --non-interactive \
  --agree-tos \
  -m your-email@example.com

# Verify auto-renewal
sudo certbot renew --dry-run
```

After certbot, update `CORS_ORIGIN` secret in Multi-Auth to `https://app.PUBLIC_IP.nip.io`.

---

## Step 10 — PM2 Auto-Start for Multi-Auth

After first successful App 2 deploy:
```bash
# On the EC2 server
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u appuser --hp /home/appuser
# Run the command it prints, then:
sudo -u appuser pm2 save
```

---

## Step 11 — Create IAM Reviewer User

1. AWS Console → IAM → Policies → Create policy
2. Paste contents of `infra/iam-reviewer-policy.json`
3. Name it `serviots-reviewer-policy`
4. Create IAM user `serviots-reviewer`, attach this policy
5. Generate access key
6. **Send access key + secret via email — never commit**

---

## Step 12 — Restrict SSH (if not already done by CFT)

```bash
# On the EC2 server — verify SSH is restricted to your IP
sudo ufw status verbose
# Should show: 22/tcp — ALLOW IN — YOUR_IP/32
```

---

## Verify Everything

```bash
# Both apps healthy
curl https://api.PUBLIC_IP.nip.io/health
curl https://app.PUBLIC_IP.nip.io/

# Services running
sudo systemctl status nginx
sudo systemctl status crud-api
sudo -u appuser pm2 status

# Firewall — only 22/80/443 open
sudo ufw status verbose

# Memory on t3.micro
free -h
# Healthy: Mem used < 900Mi, Swap used < 500Mi

# Disk (Jenkins gone — more headroom)
df -h /
```

---

## How GitHub Actions Deploys Work

```
Push to main
    │
    ▼
GitHub Actions Runner (ubuntu-latest, free tier)
    ├── [App 1] pytest with SQLite → rsync code → SSH: migrate → symlink → restart → health check
    └── [App 2] rsync code → SSH: npm ci → prisma generate → conditional migrate → PM2 reload → health check
                                                                    │
                                                          if health check fails
                                                                    │
                                                                    ▼
                                              SSH: revert symlink → restart previous release
```

No Jenkins server required. The GitHub Actions runner is ephemeral — spun up per job, destroyed after. Credentials never touch the runner disk — they're injected as env vars and masked in logs.

---

## Cost Estimate (us-west-2, monthly)

| Resource | Type | Free tier | After free tier |
|----------|------|-----------|----------------|
| EC2 | t3.micro | $0 (750 hrs/mo, 12mo) | ~$8.50/mo |
| RDS | db.t3.micro | $0 (750 hrs/mo, 12mo) | ~$13.00/mo |
| EBS | 20 GB gp3 | $0 (30 GB/mo included) | ~$1.60/mo |
| RDS Storage | 20 GB gp2 | $0 (20 GB/mo included) | ~$2.30/mo |
| Elastic IP | Attached | $0 | $0 |
| GitHub Actions | 2000 min/mo free | $0 | $0 (for public repos) |
| **Total** | | **$0** | **~$25.40/mo** |
