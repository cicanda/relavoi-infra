#!/bin/bash
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-relavoi}"

STAGING_DIR="$(cd "$(dirname "$0")/../envs/staging" && pwd)"
INSTANCE_IP=$(cd "$STAGING_DIR" && terraform output -raw public_ip)
KEY_PAIR_NAME=$(cd "$STAGING_DIR" && terraform output -raw key_pair_name 2>/dev/null || echo "relavoi-staging")
SSH_KEY="$HOME/.ssh/${KEY_PAIR_NAME}.pem"

echo "=== Setting Up GitHub Deploy Key for Staging ==="
echo ""

# Generate a deploy key if it doesn't exist locally
DEPLOY_KEY="$HOME/.ssh/relavoi_deploy"
if [[ ! -f "$DEPLOY_KEY" ]]; then
  echo "Generating deploy key..."
  ssh-keygen -t ed25519 -f "$DEPLOY_KEY" -N "" -C "relavoi-staging-deploy"
  echo ""
  echo "=========================================="
  echo "Add this public key as a deploy key in GitHub:"
  echo "  Repo: cicanda/relavoi-backend"
  echo "  Settings > Deploy keys > Add deploy key"
  echo "  Title: relavoi-staging"
  echo "  Key:"
  echo ""
  cat "${DEPLOY_KEY}.pub"
  echo ""
  echo "=========================================="
  echo ""
  read -p "Press Enter after adding the key to GitHub..."
else
  echo "Deploy key already exists at $DEPLOY_KEY"
fi

# Transfer to EC2
echo "Transferring deploy key to EC2..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$DEPLOY_KEY" "ubuntu@${INSTANCE_IP}:/home/ubuntu/.ssh/relavoi_deploy"
ssh -i "$SSH_KEY" "ubuntu@${INSTANCE_IP}" 'chmod 600 /home/ubuntu/.ssh/relavoi_deploy'

# Test GitHub access
echo "Testing GitHub access from EC2..."
ssh -i "$SSH_KEY" "ubuntu@${INSTANCE_IP}" 'ssh -T git@github.com 2>&1 || true'

echo ""
echo "=== Deploy key setup complete ==="
echo "Now run: ./scripts/deploy-staging.sh"
