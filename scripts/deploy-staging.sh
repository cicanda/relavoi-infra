#!/bin/bash
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-relavoi}"

INSTANCE_IP=$(cd envs/staging && terraform output -raw public_ip)
KEY_PAIR=$(cd envs/staging && terraform output -raw ssh_command | grep -oP '~/.ssh/\K[^.]+')
SSH_KEY="~/.ssh/${KEY_PAIR}.pem"
BACKEND_DIR="${1:-../relavoi-backend}"

echo "=== Deploying Relavoi to Staging ==="
echo "Instance: $INSTANCE_IP"
echo "Backend:  $BACKEND_DIR"
echo ""

# Step 1: Build Docker image locally
echo "--- Step 1: Building Docker image ---"
if [[ ! -d "$BACKEND_DIR" ]]; then
  echo "ERROR: Backend directory not found at $BACKEND_DIR"
  exit 1
fi

docker build -f "$BACKEND_DIR/docker/Dockerfile" -t relavoi-api:latest "$BACKEND_DIR"
echo "Image built."

# Step 2: Save and transfer image to EC2
echo ""
echo "--- Step 2: Transferring image to EC2 ---"
docker save relavoi-api:latest | gzip > /tmp/relavoi-api.tar.gz
scp -i "$SSH_KEY" /tmp/relavoi-api.tar.gz "ubuntu@${INSTANCE_IP}:/tmp/"
rm /tmp/relavoi-api.tar.gz
echo "Image transferred."

# Step 3: Load image and restart on EC2
echo ""
echo "--- Step 3: Loading image and restarting ---"
ssh -i "$SSH_KEY" "ubuntu@${INSTANCE_IP}" << 'REMOTEOF'
set -e
cd /opt/relavoi

# Load the new image
docker load < /tmp/relavoi-api.tar.gz
rm /tmp/relavoi-api.tar.gz

# Restart the API container with the new image
docker compose up -d --force-recreate api

# Wait for health
echo "Waiting for health check..."
for i in {1..20}; do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3000/v1/health 2>/dev/null || echo "000")
  if [[ "$STATUS" == "200" ]]; then
    echo "Health check passed!"
    break
  fi
  echo "  Attempt $i: HTTP $STATUS"
  sleep 5
done
REMOTEOF

# Step 4: Run migrations
echo ""
echo "--- Step 4: Running migrations ---"
ssh -i "$SSH_KEY" "ubuntu@${INSTANCE_IP}" << 'REMOTEOF'
cd /opt/relavoi
docker compose exec api node dist/scripts/run-migrations.js
REMOTEOF

# Step 5: Health check from outside
echo ""
echo "--- Step 5: External health check ---"
API_URL=$(cd envs/staging && terraform output -raw api_url)
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
echo "API:       $API_URL"
echo "Instance:  $INSTANCE_IP"
echo ""
echo "Next steps:"
echo "  1. Give Africa's Talking the webhook URL: $API_URL/v1/webhooks/cpaas/voice"
echo "  2. Give Africa's Talking the static IP for whitelisting: $INSTANCE_IP"
echo "  3. Seed the database: ssh -i $SSH_KEY ubuntu@$INSTANCE_IP 'cd /opt/relavoi && docker compose exec api node dist/scripts/run-seed.js'"
