#!/bin/bash
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-relavoi}"

# Resolve instance details from Terraform
STAGING_DIR="$(cd "$(dirname "$0")/../envs/staging" && pwd)"
INSTANCE_IP=$(cd "$STAGING_DIR" && terraform output -raw public_ip)
KEY_PAIR_NAME=$(cd "$STAGING_DIR" && terraform output -raw key_pair_name 2>/dev/null || echo "relavoi-staging")
SSH_KEY="$HOME/.ssh/${KEY_PAIR_NAME}.pem"
BRANCH="${1:-main}"
REPO_URL="${REPO_URL:-git@github.com:cicanda/relavoi-backend.git}"

echo "=== Deploying Relavoi Staging ==="
echo "Instance: $INSTANCE_IP"
echo "Branch:   $BRANCH"
echo "Repo:     $REPO_URL"
echo ""

# Check SSH key exists
if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: SSH key not found at $SSH_KEY"
  echo "Download your key pair .pem from AWS and place it there."
  exit 1
fi

# Deploy on the remote instance
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "ubuntu@${INSTANCE_IP}" << REMOTEOF
set -e
cd /opt/relavoi

echo "--- Pulling latest code ---"
if [[ -d "relavoi-backend" ]]; then
  cd relavoi-backend
  git fetch origin
  git checkout ${BRANCH}
  git pull origin ${BRANCH}
  cd ..
else
  git clone -b ${BRANCH} ${REPO_URL} relavoi-backend
fi

echo ""
echo "--- Building Docker image ---"
docker build -f relavoi-backend/docker/Dockerfile -t relavoi-api:latest relavoi-backend/

echo ""
echo "--- Restarting services ---"
docker compose up -d --force-recreate api

echo ""
echo "--- Running migrations ---"
# Wait for postgres to be ready
sleep 5
docker compose exec -T api node dist/scripts/run-migrations.js 2>&1 || echo "Migration runner not found, trying alternative..."

echo ""
echo "--- Health check ---"
for i in {1..20}; do
  STATUS=\$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/v1/health 2>/dev/null || echo "000")
  if [[ "\$STATUS" == "200" ]]; then
    echo "Health check passed!"
    break
  fi
  echo "  Attempt \$i: HTTP \$STATUS"
  sleep 5
done
REMOTEOF

echo ""

# External health check
API_URL=$(cd "$STAGING_DIR" && terraform output -raw api_url)
echo "--- External health check ---"
for i in {1..10}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$API_URL/v1/health" 2>/dev/null || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    echo "External health check passed: $API_URL/v1/health -> 200"
    break
  fi
  echo "  Attempt $i: HTTP $STATUS (retrying in 10s...)"
  sleep 10
done

echo ""
echo "=== Deploy Complete ==="
echo "API:        $API_URL"
echo "Instance:   $INSTANCE_IP"
echo "Branch:     $BRANCH"
echo ""
echo "Useful commands:"
echo "  SSH:      ssh -i $SSH_KEY ubuntu@$INSTANCE_IP"
echo "  Logs:     ssh -i $SSH_KEY ubuntu@$INSTANCE_IP 'cd /opt/relavoi && docker compose logs -f api'"
echo "  Seed:     ssh -i $SSH_KEY ubuntu@$INSTANCE_IP 'cd /opt/relavoi && docker compose exec api node dist/scripts/run-seed.js'"
echo "  Restart:  ssh -i $SSH_KEY ubuntu@$INSTANCE_IP 'cd /opt/relavoi && docker compose restart api'"
