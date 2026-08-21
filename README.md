# relavoi-infra

Terraform for deploying the **Relavoi backend** to AWS on **ECS Fargate**.

Only the backend lives here. The tenant dashboard and operator console deploy
separately to Vercel; the mobile SDKs and docs site are not deployed
infrastructure.

There are two deployment shapes:

- **Staging** — a single EC2 instance running everything in Docker Compose
  (~$16/month). See [Staging (Single EC2)](#staging-single-ec2) below.
- **Production** — the full ECS Fargate architecture (ALB, RDS, ElastiCache,
  auto-scaling). Everything from [Production (ECS Fargate)](#production-ecs-fargate)
  onward describes it.

## Staging Deployment

Staging runs on a single EC2 instance (~$16/month). Code is built **on the
instance** from GitHub — no local Docker builds, no image transfers over SSH.
The box runs, all in Docker Compose:

- Relavoi backend (all services in one process)
- PostgreSQL 16
- Redis 7
- Caddy (automatic TLS via Let's Encrypt)

The instance boots from `envs/staging/user-data.sh` (installs Docker, Caddy, and
Git; writes `.env` and `docker-compose.yml` under `/opt/relavoi`; starts Postgres
+ Redis). `deploy-staging.sh` then SSHes in, `git pull`s the latest code, builds
the image on the box, and restarts the `api` container.

### Prerequisites
- AWS key pair created in eu-north-1 (EC2 > Key Pairs > Create)
- relavoi.com nameservers pointed to Route 53
- A GitHub **deploy key** for `cicanda/relavoi-backend` (read-only) — set up in
  step 2 below. (Skip it only if the repo is public.)

### First Time Setup
```bash
# 1. Create infrastructure
cd envs/staging
cp terraform.tfvars.example terraform.tfvars
# Fill in values (key pair, secrets, etc.)
terraform init
terraform apply

# 2. Set up deploy key (one-time)
cd ../..
./scripts/setup-staging-deploy-key.sh
# Follow the prompts to add the key to GitHub

# 3. Deploy the application
./scripts/deploy-staging.sh

# 4. Seed the database
ssh -i ~/.ssh/relavoi-staging.pem ubuntu@<IP> \
  'cd /opt/relavoi && docker compose exec api node dist/scripts/run-seed.js'
```

### Subsequent Deploys
```bash
# Deploy latest from main
./scripts/deploy-staging.sh

# Deploy a specific branch
./scripts/deploy-staging.sh feature/some-branch
```

### Useful Commands
```bash
# SSH into the instance
ssh -i ~/.ssh/relavoi-staging.pem ubuntu@<IP>

# View logs
ssh -i ~/.ssh/<key>.pem ubuntu@<IP> 'cd /opt/relavoi && docker compose logs -f api'

# Restart
ssh -i ~/.ssh/<key>.pem ubuntu@<IP> 'cd /opt/relavoi && docker compose restart api'

# Rebuild and restart (on the instance)
ssh -i ~/.ssh/<key>.pem ubuntu@<IP> 'cd /opt/relavoi && docker compose up -d --build api'
```

### Cost
- t3.small: ~$15/month
- Elastic IP: free (while attached to running instance)
- Route 53: ~$0.50/month
- Total: ~$16/month

---

# Production (ECS Fargate)

## Why Fargate (not EKS)

Fargate is cheaper and simpler for a small team — no $75/month EKS control-plane
fee, no node management. The backend is three stateless services that scale
horizontally, which Fargate handles well.

## Region

Everything deploys to **`eu-north-1` (Stockholm)**, a standard (always-enabled)
AWS region — no opt-in step required.

### Latency to Nigeria

Stockholm adds roughly **80–120 ms** to the round trip for Nigerian PSTN traffic,
versus ~30–50 ms from Cape Town (`af-south-1`). This is acceptable: the
latency-critical path is **server-side webhook processing**, and the extra
network hop stays well inside the 500 ms p99 budget. The actual call audio
travels over PSTN **directly between the two Nigerian phones** — it never
transits your servers.

## Architecture

```
                          Internet
                             │
                    Route 53  A ALIAS
                 api.relavoi.com → ALB
                             │
                 ┌───────────▼───────────┐   ACM (TLS 1.3), :80 → :443 redirect
                 │   Application LB       │
                 │   (public subnets)     │
                 └───────┬────────┬───────┘
        /v1/webhooks/*   │        │   /v1/*  (default)
                 ┌───────▼──┐  ┌──▼────────┐
                 │ webhook  │  │   api     │   ECS Fargate services
                 │ TG :3000 │  │  TG :3000 │   (private subnets)
                 └───────┬──┘  └──┬────────┘
                         │        │
   ┌─────────────────────┼────────┼──────────────────────┐
   │  ECS cluster (Fargate) — one image, SERVICE_MODE     │
   │                                                      │
   │   api (2–10)     webhook (3–15)     worker (1)       │
   │   REST/auth/     CPaaS voice/SMS    consumers,       │
   │   sessions/      webhooks only      expiry, reaper,  │
   │   analytics      (latency-crit)     health (no HTTP) │
   └──────────┬───────────────────────────────┬──────────┘
              │                                │
      ┌───────▼───────┐               ┌────────▼────────┐
      │ RDS Postgres  │               │ ElastiCache     │
      │ 16 (Multi-AZ  │               │ Redis 7         │
      │ in prod)      │               │ (private)       │
      └───────────────┘               └─────────────────┘

   Outbound (private subnets) → single NAT gateway → Internet
   The NAT Elastic IP is the stable egress IP to whitelist with Africa's Talking.
```

All three services run the **same Docker image**, differentiated by the
`SERVICE_MODE` environment variable (`api` / `webhook` / `worker`). Only `api`
and `webhook` have port mappings, health checks, and an ALB target group; the
`worker` serves no HTTP.

## Prerequisites

- **AWS CLI** v2, authenticated to the target account
- **Terraform** 1.7+ recommended (validated against 1.5+)
- **Docker** (with `linux/amd64` build support; the deploy script forces the platform)
- The **domain's hosted zone already in Route 53** (this project reads it, it
  does not create it).

## AWS Profile

All scripts and Terraform commands use the `relavoi` AWS profile by default. Set it up once:

```bash
aws configure --profile relavoi
# Enter your access key, secret key, region eu-north-1, output json

# Make it the default for your terminal
echo 'export AWS_PROFILE=relavoi' >> ~/.zshrc
source ~/.zshrc
```

The Terraform provider reads the profile from the `aws_profile` variable
(default `relavoi`); the scripts honor `AWS_PROFILE` if already exported and fall
back to `relavoi`. CI does not use a profile — it authenticates via OIDC role
assumption.

## First-time deployment

```bash
# 1. Create the remote-state backend (S3 + DynamoDB), then uncomment the
#    backend "s3" block in envs/<env>/main.tf.
./scripts/bootstrap-state.sh

# 2. Fill in secrets/config.
cd envs/staging
cp terraform.tfvars.example terraform.tfvars
#   openssl rand -hex 32  -> jwt_secret
#   openssl rand -hex 64  -> encryption_master_key
$EDITOR terraform.tfvars

# 3. Init + review + apply the infrastructure.
terraform init
terraform plan
terraform apply

# 4. Build + push the image, apply with the tag, wait for stability, health-check.
#    (Run from the repo root.)
cd ../..
./scripts/deploy.sh staging

# 5. Run database migrations as a one-off ECS task.
./scripts/migrate.sh staging

# 6. Point Africa's Talking voice/SMS callbacks at:
#      https://api.relavoi.com/v1/webhooks/cpaas/voice
#      https://api.relavoi.com/v1/webhooks/cpaas/sms
#    and whitelist the NAT gateway IP printed by the deploy script.
```

Production is the same with `prod` in place of `staging`.

## CORS and the Vercel dashboards

The dashboard and admin console are hosted on Vercel and call this API from the
browser, so their origins must be allowed by CORS. `cors_origins` is a Terraform
variable passed to the ECS tasks as `CORS_ORIGINS`; the default is:

```
https://app.relavoi.com,https://admin.relavoi.com
```

Add Vercel preview URLs (e.g. `https://*.vercel.app`) in staging as needed.

## NAT gateway IP / Africa's Talking

ECS tasks run in private subnets and egress through a **single NAT gateway**
(one per environment, for cost — add a second per-AZ NAT for HA later). Its
Elastic IP is the platform's stable outbound address. `deploy.sh` prints it
prominently; **whitelist it with Africa's Talking** so callbacks and API traffic
originate from a known IP.

## Secrets

Stored in AWS Secrets Manager and referenced by the ECS task definitions via
`valueFrom`: `JWT_SECRET`, `ENCRYPTION_MASTER_KEY`, `AT_API_KEY`, `AT_USERNAME`,
`AT_ENVIRONMENT`, `WEBHOOK_BASE_URL`, plus `DATABASE_URL` (its own secret,
because it contains the DB password). `REDIS_URL` is plain environment —
ElastiCache is private and security-group-guarded. Non-secret config (pool sizes,
circuit-breaker thresholds, `NODE_ENV`, `PORT`, `LOG_LEVEL`, `CORS_ORIGINS`) is
passed directly as task-definition environment.

## Cost estimates (approximate, eu-north-1)

**Staging ~ $80–120/month**

| Item | Monthly |
|---|---|
| ECS Fargate (api 2 + webhook 3 + worker 1, small) | ~$45–70 |
| RDS `db.t4g.micro`, single-AZ, 10 GB gp3 | ~$15–20 |
| ElastiCache `cache.t4g.micro` | ~$12–15 |
| ALB | ~$18 + LCU |
| NAT gateway | ~$32 + data |
| Secrets/ECR/CloudWatch/S3 | ~$5 |

**Production ~ $210–315/month**

| Item | Monthly |
|---|---|
| ECS Fargate (api 2–10 + webhook 3–15 + worker 1) | ~$110–200 |
| RDS `db.t4g.small`, **Multi-AZ**, 20 GB gp3 | ~$55–75 |
| ElastiCache `cache.t4g.micro` (+ snapshots) | ~$15–18 |
| ALB | ~$18 + LCU |
| NAT gateway | ~$32 + data |
| Secrets/ECR/CloudWatch/S3/KMS | ~$8–12 |

NAT-gateway and ALB data processing, plus Fargate auto-scaling under load, are
the main variables. `eu-north-1` list prices run modestly lower than
`af-south-1` for Fargate and RDS, so these ranges are conservative. Numbers
exclude data transfer out and Africa's Talking telephony charges.

## Layout

```
relavoi-infra/
  versions.tf                 shared version pins (each env re-declares them)
  modules/
    vpc/        2 AZs, public + private subnets, IGW, single NAT
    ecr/        container registry (scan-on-push, keep last 10)
    rds/        Postgres 16, gp3, encrypted, PI, pg_stat_statements
    elasticache/ Redis 7.1, allkeys-lru
    alb/        ALB, api + webhook target groups, HTTPS + path routing
    ecs/        cluster, 3 task defs + services, IAM, logs, autoscaling
    secrets/    Secrets Manager (app secrets JSON)
    route53/    ACM DNS-validated cert + A-record alias (reads existing zone)
    s3/         recordings bucket, KMS, versioned, Glacier@90d, expire@365d
  envs/
    staging/    10.1.0.0/16, db.t4g.micro single-AZ, staging-api subdomain
    prod/       10.0.0.0/16, db.t4g.small Multi-AZ, api subdomain
  scripts/      bootstrap-state.sh, deploy.sh, migrate.sh
  .github/workflows/deploy.yml   plan + apply via OIDC
```

## Notes / deviations

- The **ECS tasks security group is created at the environment level** (not
  inside the `ecs` module) and passed into `rds`, `elasticache`, and `ecs`. This
  breaks the otherwise-circular dependency (RDS ingress needs the tasks SG; ECS
  needs the RDS-derived `DATABASE_URL`).
- `migrate.sh` overrides the one-off task command to
  `node dist/scripts/run-migrations.js` — the compiled runner that actually
  works inside the container (the repo's `scripts/docker-migrate.sh` is a
  local-compose helper and would not run in Fargate).
- Fargate tasks are pinned to **`linux/amd64`**; `deploy.sh` builds with
  `--platform linux/amd64` so images built on Apple Silicon still run.
- `required_version` is `>= 1.5.0` so the project validates on older Terraform;
  1.7+ is recommended.
