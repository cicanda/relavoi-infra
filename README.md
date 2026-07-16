# relavoi-infra

Terraform for deploying the **Relavoi backend** to AWS on **ECS Fargate**.

Only the backend lives here. The tenant dashboard and operator console deploy
separately to Vercel; the mobile SDKs and docs site are not deployed
infrastructure.

## Why Fargate (not EKS)

Fargate is cheaper and simpler for a small team — no $75/month EKS control-plane
fee, no node management. The backend is three stateless services that scale
horizontally, which Fargate handles well.

## Region

Everything deploys to **`af-south-1` (Cape Town)** — closest to the Nigerian
market. **`af-south-1` is an opt-in region**: enable it in the AWS console
(Account → AWS Regions) before deploying, or API calls will fail with
`OptInRequired`.

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
  does not create it). `af-south-1` **opt-in region enabled**.

## First-time deployment

```bash
# 0. Enable af-south-1 in the AWS console if you haven't.

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
#      https://staging-api.relavoi.com/v1/webhooks/cpaas/voice
#      https://staging-api.relavoi.com/v1/webhooks/cpaas/sms
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

## Cost estimates (approximate, af-south-1)

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
the main variables. Numbers exclude data transfer out and Africa's Talking
telephony charges.

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
