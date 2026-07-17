#!/bin/bash
set -euo pipefail
exec > /var/log/relavoi-setup.log 2>&1

echo "=== Relavoi Staging Setup ==="

# Install Docker
apt-get update -y
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu

# Install Caddy (reverse proxy with automatic TLS)
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

# Install Git
apt-get install -y git

# Create SSH directory for deploy key
mkdir -p /home/ubuntu/.ssh
chmod 700 /home/ubuntu/.ssh

# The deploy key will be added manually after first boot:
#   scp -i ~/.ssh/relavoi-staging.pem deploy_key ubuntu@<IP>:/home/ubuntu/.ssh/relavoi_deploy
#   ssh -i ~/.ssh/relavoi-staging.pem ubuntu@<IP> 'chmod 600 ~/.ssh/relavoi_deploy'
# Then add to SSH config:
cat > /home/ubuntu/.ssh/config << 'SSHEOF'
Host github.com
  IdentityFile /home/ubuntu/.ssh/relavoi_deploy
  StrictHostKeyChecking accept-new
SSHEOF
chmod 600 /home/ubuntu/.ssh/config
chown -R ubuntu:ubuntu /home/ubuntu/.ssh

# Create app directory
mkdir -p /opt/relavoi
chown ubuntu:ubuntu /opt/relavoi
cd /opt/relavoi

# Create .env file
cat > .env << 'ENVEOF'
NODE_ENV=production
PORT=3000
HOST=0.0.0.0
LOG_LEVEL=info

DATABASE_URL=postgresql://relavoi:${db_password}@localhost:5432/relavoi
REDIS_URL=redis://localhost:6379
REDIS_PREFIX=relavoi:

JWT_SECRET=${jwt_secret}
JWT_EXPIRY=15m
DASHBOARD_JWT_EXPIRY=24h
ENCRYPTION_MASTER_KEY=${encryption_master_key}

AT_API_KEY=${at_api_key}
AT_USERNAME=${at_username}
AT_ENVIRONMENT=${at_environment}

WEBHOOK_BASE_URL=https://${domain_name}/v1/webhooks/cpaas
WEBHOOK_HMAC_ALGO=sha256

CORS_ORIGINS=${cors_origins}

POOL_COOLDOWN_MINUTES=5
POOL_LOW_THRESHOLD_PERCENT=20
POOL_AUTO_PROVISION_THRESHOLD_PERCENT=80
SESSION_DEFAULT_GRACE_PERIOD_MINUTES=15
SESSION_DEFAULT_MAX_DURATION_MINUTES=120

CB_FAILURE_THRESHOLD=5
CB_ERROR_RATE_THRESHOLD=0.10
CB_ERROR_RATE_WINDOW_SECONDS=120
CB_HEALTH_CHECK_INTERVAL_SECONDS=30
CB_RECOVERY_CHECK_COUNT=5
CB_HALF_OPEN_TRAFFIC_PERCENT=10

POSTGRES_USER=relavoi
POSTGRES_PASSWORD=${db_password}
POSTGRES_DB=relavoi
ENVEOF

# Create docker-compose.yml (all-in-one: app + postgres + redis)
cat > docker-compose.yml << 'COMPOSEEOF'
version: "3.8"

services:
  postgres:
    image: postgres:16-alpine
    container_name: relavoi-postgres
    env_file: .env
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U relavoi"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    container_name: relavoi-redis
    command: redis-server --appendonly yes --maxmemory 256mb --maxmemory-policy allkeys-lru
    volumes:
      - redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  api:
    build:
      context: ./relavoi-backend
      dockerfile: docker/Dockerfile
    image: relavoi-api:latest
    container_name: relavoi-api
    env_file: .env
    environment:
      - DATABASE_URL=postgresql://relavoi:${db_password}@postgres:5432/relavoi
      - REDIS_URL=redis://redis:6379
    ports:
      - "127.0.0.1:3000:3000"
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000/v1/health"]
      interval: 30s
      timeout: 5s
      start_period: 15s
      retries: 3
    restart: unless-stopped

volumes:
  pgdata:
  redisdata:
COMPOSEEOF

# Configure Caddy (automatic HTTPS via Let's Encrypt)
cat > /etc/caddy/Caddyfile << CADDYEOF
${domain_name} {
    reverse_proxy localhost:3000
}
CADDYEOF

systemctl restart caddy

echo "=== Setup Complete ==="
echo "Caddy will obtain TLS certificate automatically when DNS propagates."
echo "API will be available at https://${domain_name}/v1/health"
