# Task Manager CRUD API

A simple task management REST API built with **Python + FastAPI** and **PostgreSQL**, deployed on AWS EC2 with CI/CD via Jenkins and Nginx as a reverse proxy.

---

## Architecture Overview

```
Internet
   │
   ▼
[Nginx on EC2 :80/:443]
   ├── api.{IP}.nip.io  ──▶  localhost:8000  (FastAPI — this app)
   └── app.{IP}.nip.io  ──▶  localhost:3000  (Multi-Auth MERN)

[AWS RDS PostgreSQL]
   ├── crud_api_db       ──▶  Application 1
   └── multiauth_db      ──▶  Application 2
```

---

## Open Inbound Ports — Justification

| Port | Protocol | Source       | Reason |
|------|----------|-------------|--------|
| 22   | TCP      | Specific IP range only | SSH admin access — restricted to ops team IP, not 0.0.0.0/0 |
| 80   | TCP      | 0.0.0.0/0   | HTTP — required for Let's Encrypt ACME challenge and HTTP→HTTPS redirect |
| 443  | TCP      | 0.0.0.0/0   | HTTPS — public web traffic for both apps via Nginx |
| 9090 | TCP      | Specific IP range only | Jenkins UI — restricted to ops team IP; not exposed publicly |

Ports 8000 (FastAPI) and 3000 (MERN) are **not** open on the security group — they are only accessible internally via Nginx proxy. The RDS security group allows port 5432 inbound from the EC2 instance's private IP only.

---

## Database Strategy

Both apps use PostgreSQL. I chose **one RDS instance with two separate databases** (`crud_api_db` and `multiauth_db`) over two separate instances.

**Trade-offs considered:**

| Factor | Single instance, 2 DBs | Two separate instances |
|--------|------------------------|------------------------|
| Cost | Lower (one instance) | Higher (two instances) |
| Isolation | Logical only — shared CPU/memory | Full isolation |
| Connection limits | Shared pool | Separate pools |
| Failover | Single point of failure | Independent failover |

**Decision:** Single instance chosen because this is a hiring-task environment with low traffic. The two databases are logically separate with different credentials — one compromise does not automatically expose the other. For a production multi-tenant system, separate instances would be the correct call.

---

## Nginx Reverse Proxy Design

Nginx routes by `server_name` (virtual host). Each app has its own config file in `/etc/nginx/sites-available/`:

- `api.{IP}.nip.io` → `proxy_pass http://127.0.0.1:8000` (this FastAPI app)
- `app.{IP}.nip.io` → `proxy_pass http://127.0.0.1:3000` (Multi-Auth MERN)

The two apps bind to different localhost ports (8000 and 3000) and are never exposed directly — only Nginx is internet-facing. This prevents port conflicts and keeps inter-app traffic off the public interface.

---

## CI/CD Pipeline Design (Job 1 — This App)

**Trigger:** GitHub webhook on push to `main`.

**Stages:**
1. `Checkout` — pulls latest code
2. `Build` — creates Python venv, installs dependencies
3. `Test` — runs `pytest` (unit tests with SQLite in-memory, no DB required)
4. `Deploy` — creates a timestamped release directory, writes `.env` from Jenkins credentials (never from repo), runs `alembic upgrade head`, symlinks `/opt/crud-api/current`, restarts systemd service
5. `Health Check` — polls `GET /health` with defined retry logic

**Health Check Parameters (not magic numbers):**
- `HC_RETRIES=5` — 5 attempts before declaring failure
- `HC_WAIT_SECS=6` — 6 seconds between retries → max 30s wait total
- `HC_TIMEOUT_SECS=5` — per-request curl timeout
- A check is **healthy** only when HTTP status is `200` AND `database` field in JSON response is `"ok"`
- A `200` with `database: "unreachable"` is still treated as unhealthy

**Rollback:**
- Before deploy, the current symlink target is saved to `/tmp/crud_api_prev_release`
- If the health check stage fails (after all retries), the `post { failure }` block re-points the symlink to the previous release and restarts the service
- If no previous release exists (first deploy), rollback is skipped and the error is surfaced

---

## Rollback Trigger Logic

```
HTTP 200 + { "database": "ok" }  →  HEALTHY
HTTP 200 + { "database": "unreachable" }  →  UNHEALTHY (app up but DB down)
HTTP non-200  →  UNHEALTHY
curl timeout (>5s)  →  UNHEALTHY
```

After 5 consecutive unhealthy responses spaced 6 seconds apart, the pipeline marks the deploy as failed and triggers rollback.

---

## Secrets Across Stages

| Stage | Where secrets live | Method |
|-------|--------------------|--------|
| Build | Not needed | — |
| Test | Not needed (SQLite in-memory) | — |
| Deploy | Jenkins Credentials store | `withCredentials` block injects `DATABASE_URL` as env var into the shell; written to `.env` in the release dir on the server; never in the repo or image |
| Runtime | `/opt/crud-api/current/.env` on EC2 | Loaded by `python-dotenv` at startup; file has `chmod 600`, owned by app service user |

No credentials appear in git history, Docker layers, or Jenkins console output.

---

## IAM Scoping (Reviewer Read-Only User)

Permissions granted and why:

| Permission | Why |
|-----------|-----|
| `ec2:DescribeInstances` | Verify the EC2 instance exists and see its state/config |
| `ec2:DescribeSecurityGroups` | Verify inbound port rules are correctly scoped |
| `rds:DescribeDBInstances` | Verify RDS instance exists, engine version, multi-AZ setting |
| `rds:DescribeDBSubnetGroups` | Verify DB is in private subnet, not publicly accessible |
| `logs:DescribeLogGroups` | List CloudWatch log groups for the app |
| `logs:GetLogEvents` | Read application logs for verification |

No write, no IAM, no admin. Broad `ReadOnlyAccess` managed policy was **not** used because it grants access to all AWS services including sensitive ones (S3 contents, Secrets Manager list). The above 6 permissions are the minimum needed to verify this task.

---

## Instance Sizing Rationale

**t3.small (2 vCPU, 2 GB RAM):** Both apps are I/O-bound (DB calls), not compute-bound. Running FastAPI (async) + Node/Express + Nginx + Jenkins on the same instance. Jenkins is the memory-heavy component (JVM). t3.micro (1 GB) would cause OOM during Jenkins builds; t3.small provides headroom without over-provisioning for a hiring task workload.

**RDS db.t3.micro (2 vCPU, 1 GB RAM):** Adequate for two low-traffic databases. RDS Multi-AZ not enabled — this is not a production system requiring HA. Automated backups enabled with 7-day retention.

---

## Local Development

```bash
cp .env.example .env
# Edit .env with your local PostgreSQL credentials

pip install -r requirements.txt
alembic upgrade head
uvicorn app.main:app --reload --port 8000
```

### API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | API info |
| GET | `/health` | App + DB health check |
| GET | `/tasks/` | List all tasks |
| POST | `/tasks/` | Create a task |
| GET | `/tasks/{id}` | Get a task |
| PUT | `/tasks/{id}` | Update a task |
| DELETE | `/tasks/{id}` | Delete a task |

---

## Running Tests

```bash
pytest tests/ -v
```

Tests use SQLite in-memory — no real DB required for the test stage.
