#!/usr/bin/env bash
#
# Build + push the backend image, apply Terraform, wait for ECS stability, and
# health-check the API.
#
# Usage: ./scripts/deploy.sh <staging|prod> [image_tag]
set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  staging|prod) ;;
  *) echo "Usage: $0 <staging|prod> [image_tag]"; exit 1 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
ENV_DIR="$ROOT/envs/$ENV"
BACKEND_DIR="$(cd "$ROOT/../relavoi-backend" && pwd)"
REGION="${AWS_REGION:-eu-north-1}"

# Use the relavoi AWS profile for local runs (CI uses OIDC, not this).
export AWS_PROFILE="${AWS_PROFILE:-relavoi}"

# Default image tag to the backend's git short SHA.
IMAGE_TAG="${2:-$(git -C "$BACKEND_DIR" rev-parse --short HEAD 2>/dev/null || echo latest)}"

blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

command -v terraform >/dev/null || { red "terraform not found"; exit 1; }
command -v docker >/dev/null || { red "docker not found"; exit 1; }
command -v aws >/dev/null || { red "aws CLI not found"; exit 1; }

blue "==> Environment: $ENV   Image tag: $IMAGE_TAG   Region: $REGION"

# ─── Resolve ECR repo from terraform output (create it first if needed) ───────
cd "$ENV_DIR"
terraform init -input=false >/dev/null
ECR_URL="$(terraform output -raw ecr_repository 2>/dev/null || true)"
if [ -z "$ECR_URL" ]; then
  blue "==> ECR repo not in state yet — applying ecr module first"
  terraform apply -input=false -auto-approve -target=module.ecr -var "image_tag=$IMAGE_TAG"
  ECR_URL="$(terraform output -raw ecr_repository)"
fi
REGISTRY="${ECR_URL%%/*}"
blue "==> ECR: $ECR_URL"

# ─── Build + push ─────────────────────────────────────────────────────────────
blue "==> Logging in to ECR"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

blue "==> Building image (linux/amd64) from $BACKEND_DIR"
docker build --platform linux/amd64 -f "$BACKEND_DIR/docker/Dockerfile" \
  -t "$ECR_URL:$IMAGE_TAG" -t "$ECR_URL:latest" "$BACKEND_DIR"

blue "==> Pushing image"
docker push "$ECR_URL:$IMAGE_TAG"
docker push "$ECR_URL:latest"

# ─── Apply ────────────────────────────────────────────────────────────────────
blue "==> terraform apply"
terraform apply -input=false -auto-approve -var "image_tag=$IMAGE_TAG"

CLUSTER="relavoi-$ENV-cluster"

# ─── Wait for all three services to stabilize ─────────────────────────────────
for svc in api webhook worker; do
  blue "==> Waiting for ECS service relavoi-$ENV-$svc to stabilize"
  aws ecs wait services-stable --region "$REGION" \
    --cluster "$CLUSTER" --services "relavoi-$ENV-$svc"
done

# ─── Health check ─────────────────────────────────────────────────────────────
API_URL="$(terraform output -raw api_url)"
NAT_IP="$(terraform output -raw nat_gateway_ip)"
blue "==> Health checking $API_URL/v1/health"
ok=""
for i in $(seq 1 10); do
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$API_URL/v1/health" || echo 000)"
  if [ "$code" = "200" ]; then ok=1; green "   healthy (attempt $i)"; break; fi
  echo "   attempt $i: HTTP $code — retrying in 10s"
  sleep 10
done
[ -n "$ok" ] || { red "Health check failed after 10 attempts"; exit 1; }

# ─── Summary ──────────────────────────────────────────────────────────────────
green ""
green "==================== DEPLOY COMPLETE ===================="
green " API URL:        $API_URL"
green " ECR image:      $ECR_URL:$IMAGE_TAG"
green " NAT gateway IP: $NAT_IP"
green "========================================================"
cat <<EOF

REMINDERS:
  1. Point the Africa's Talking voice/SMS callback URLs at:
       $API_URL/v1/webhooks/cpaas/voice
       $API_URL/v1/webhooks/cpaas/sms
  2. Whitelist the NAT gateway IP ($NAT_IP) with Africa's Talking so
     outbound webhook deliveries / API calls originate from a known IP.
  3. Run database migrations if the schema changed:
       ./scripts/migrate.sh $ENV
EOF
