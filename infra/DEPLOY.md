# AWS Deployment Guide — us-west-2

Step-by-step instructions to go from zero to both apps live.
Follow these in exact order — each step depends on the previous one.

---

## Prerequisites (do these before starting)

- [ ] AWS account with IAM user that has EC2 + RDS create permissions
- [ ] AWS CLI installed and configured: `aws configure` (set region to `us-west-2`)
- [ ] Terraform installed: https://developer.hashicorp.com/terraform/install
- [ ] An EC2 key pair already created in `us-west-2` (AWS Console → EC2 → Key Pairs)
- [ ] Your public IP: visit https://checkip.amazonaws.com

---

## Step 1 — Create `terraform.tfvars`

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` with real values:
```hcl
aws_region         = "us-west-2"
ops_ip_cidr        = "YOUR_PUBLIC_IP/32"   # from checkip.amazonaws.com
key_name           = "your-key-pair-name"  # must exist in us-west-2
db_password        = "StrongPassword123!"  # save this — you'll need it for Jenkins
```

---

## Step 2 — Terraform Init and Plan

```bash
cd infra/terraform
terraform init
terraform plan
```

Review the plan — you should see:
- 1 EC2 instance (t3.micro)
- 1 Elastic IP
- 1 RDS instance (db.t3.micro)
- 1 DB subnet group
- 2 security groups
- 1 null_resource (creates both databases)

---

## Step 3 — Terraform Apply

```bash
terraform apply
```

Type `yes` when prompted. This takes **8–12 minutes** — RDS provisioning is the slow part.

When done, note the outputs:
```
app_server_public_ip = "X.X.X.X"
rds_host             = "serviots-task-postgres.XXXX.us-west-2.rds.amazonaws.com"
ssh_command          = "ssh -i ~/.ssh/your-key.pem ubuntu@X.X.X.X"
crud_api_url         = "http://api.X.X.X.X.nip.io"
multiauth_url        = "http://app.X.X.X.X.nip.io"
jenkins_url          = "http://X.X.X.X:9090"
```

---

## Step 4 — SSH into the Server

```bash
# Use the ssh_command from terraform output
ssh -i ~/.ssh/your-key-name.pem ubuntu@<EC2_PUBLIC_IP>
```

Wait for cloud-init (user-data.sh) to finish — it runs swap setup on first boot:
```bash
cat /var/log/user-data.log   # watch for "cloud-init complete"
```

---

## Step 5 — Run server-setup.sh

```bash
# Clone the repo onto the server
git clone https://github.com/ChandanaS2653/serviots-task.git /opt/crud-api/current

# Run the provisioning script
sudo bash /opt/crud-api/current/infra/scripts/server-setup.sh
```

This takes ~5 minutes. When it finishes, note the Jenkins initial admin password printed at the end.

---

## Step 6 — Clone Multi-Auth App

```bash
sudo git clone https://github.com/ChandanaS2653/Multi-Auth.git /opt/multiauth/current
sudo chown -R appuser:appuser /opt/multiauth
```

---

## Step 7 — Configure Nginx

```bash
sudo bash /opt/crud-api/current/infra/scripts/configure-nginx.sh <EC2_PUBLIC_IP>
```

Verify both configs loaded:
```bash
sudo nginx -t
# should print: configuration file /etc/nginx/nginx.conf test is successful
```

---

## Step 8 — Set Up Systemd Service for App 1

```bash
sudo cp /opt/crud-api/current/infra/systemd/crud-api.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable crud-api
```

Don't start it yet — Jenkins will do the first deploy.

---

## Step 9 — Configure Jenkins

Open `http://<EC2_PUBLIC_IP>:9090` in your browser.

### 9a — Initial setup
- Paste the admin password from Step 5
- Click "Install suggested plugins"
- Create your admin account
- Create a **second account** with read-only/viewer permissions (for the reviewer)

### 9b — Add Jenkins Credentials
Go to: **Manage Jenkins → Credentials → Global → Add Credential**

Add these credentials (type = Secret text):

| ID | Value |
|----|-------|
| `DATABASE_URL` | `postgresql://postgres:<db_password>@<rds_host>:5432/crud_api_db` |
| `MULTIAUTH_DATABASE_URL` | `postgresql://postgres:<db_password>@<rds_host>:5432/multiauth_db` |
| `JWT_PRIVATE_KEY` | RSA private key (generate with `node scripts/setup-keys.js` in Multi-Auth dir) |
| `JWT_PUBLIC_KEY` | RSA public key |
| `HRM_CLIENT_ID` | HRM OAuth client ID |
| `HRM_CLIENT_SECRET` | HRM OAuth secret |
| `CRM_CLIENT_ID` | CRM OAuth client ID |
| `CRM_CLIENT_SECRET` | CRM OAuth secret |

### 9c — Create Job 1 (CRUD API)
- New Item → Pipeline → name it `crud-api`
- Definition: **Pipeline script from SCM**
- SCM: Git
- Repository URL: `https://github.com/ChandanaS2653/serviots-task.git`
- Branch: `*/main`
- Script Path: `Jenkinsfile`
- Save

### 9d — Create Job 2 (Multi-Auth)
- New Item → Pipeline → name it `multiauth`
- Definition: **Pipeline script from SCM**
- SCM: Git
- Repository URL: `https://github.com/ChandanaS2653/Multi-Auth.git`
- Branch: `*/main`
- Script Path: `Jenkinsfile`
- Save

### 9e — Configure GitHub Webhooks
For each repo on GitHub:
1. Go to **Settings → Webhooks → Add webhook**
2. Payload URL: `http://<EC2_IP>:9090/github-webhook/`
3. Content type: `application/json`
4. Events: **Just the push event**
5. Save

---

## Step 10 — Run First Deploys

Trigger Job 1 manually first:
```
Jenkins → crud-api → Build Now
```

Watch the console. On success, test:
```bash
curl http://api.<EC2_IP>.nip.io/health
# Expected: {"status":"healthy","app":"ok","database":"ok"}
```

Then trigger Job 2:
```
Jenkins → multiauth → Build Now
```

Test:
```bash
curl http://app.<EC2_IP>.nip.io/
# Expected: {"success":true,"message":"System Works"}
```

---

## Step 11 — SSL (Let's Encrypt)

```bash
sudo apt-get install -y certbot python3-certbot-nginx

sudo certbot --nginx \
  -d api.<EC2_IP>.nip.io \
  -d app.<EC2_IP>.nip.io \
  --non-interactive \
  --agree-tos \
  -m your-email@example.com
```

Certbot automatically modifies the Nginx configs to add SSL and sets up auto-renewal.

Verify HTTPS works:
```bash
curl https://api.<EC2_IP>.nip.io/health
curl https://app.<EC2_IP>.nip.io/
```

---

## Step 12 — Create IAM Reviewer User

1. Go to AWS Console → IAM → Users → Create user
2. Name: `serviots-reviewer`
3. Access type: Programmatic access
4. Attach policy: Create a new policy using `infra/iam-reviewer-policy.json`
5. Generate access key
6. **Send access key + secret via email only — never commit**

---

## Step 13 — PM2 Auto-Start for Multi-Auth

After first successful deploy of Job 2:
```bash
sudo -u appuser pm2 startup
# Copy and run the command it prints
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u appuser --hp /home/appuser
sudo -u appuser pm2 save
```

This makes PM2 restart the Multi-Auth app automatically on server reboot.

---

## Verify Everything

```bash
# App 1 health
curl https://api.<EC2_IP>.nip.io/health

# App 2 health
curl https://app.<EC2_IP>.nip.io/

# Nginx status
sudo systemctl status nginx

# App 1 service
sudo systemctl status crud-api

# App 2 process
sudo -u appuser pm2 status

# Jenkins
sudo systemctl status jenkins

# Firewall
sudo ufw status verbose

# Memory (watch this on t3.micro)
free -h
```

---

## Memory Check (t3.micro)

After all services are running, check memory:
```bash
free -h
```

Expected on a healthy t3.micro:
```
              total   used   free   swap used
Mem:          951Mi   750Mi  100Mi  200Mi
Swap:         2.0Gi   300Mi  1.7Gi
```

If `used` memory exceeds 900Mi regularly, Jenkins builds may start hitting swap heavily. Monitor with:
```bash
# Watch memory live during a Jenkins build
watch -n 2 free -h
```

---

## Cost Estimate (us-west-2, monthly)

| Resource | Type | Cost |
|----------|------|------|
| EC2 | t3.micro | $0 (free tier 12mo) / ~$8.50 after |
| RDS | db.t3.micro | $0 (free tier 12mo) / ~$13 after |
| EBS | 20 GB gp3 | ~$1.60/mo |
| RDS Storage | 20 GB gp2 | $0 (free tier) / ~$2.30 after |
| Elastic IP | (free when attached) | $0 |
| Data transfer | Minimal | <$1 |
| **Total** | | **~$0 (free tier) / ~$26/mo after** |
