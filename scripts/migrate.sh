#!/usr/bin/env bash
#
# Run database migrations as a one-off ECS Fargate task, reusing the running api
# service's task definition and network configuration.
#
# Usage: ./scripts/migrate.sh <staging|prod>
set -euo pipefail

ENV="${1:-}"
case "$ENV" in
  staging|prod) ;;
  *) echo "Usage: $0 <staging|prod>"; exit 1 ;;
esac

REGION="${AWS_REGION:-af-south-1}"
CLUSTER="relavoi-$ENV-cluster"
SERVICE="relavoi-$ENV-api"

blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

command -v aws >/dev/null || { red "aws CLI not found"; exit 1; }

blue "==> Reading task definition + network config from $SERVICE"
SVC_JSON="$(aws ecs describe-services --region "$REGION" \
  --cluster "$CLUSTER" --services "$SERVICE")"

TASK_DEF="$(echo "$SVC_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["services"][0]["taskDefinition"])')"
SUBNETS="$(echo "$SVC_JSON" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["services"][0]["networkConfiguration"]["awsvpcConfiguration"]["subnets"]))')"
SECGROUPS="$(echo "$SVC_JSON" | python3 -c 'import json,sys;print(",".join(json.load(sys.stdin)["services"][0]["networkConfiguration"]["awsvpcConfiguration"]["securityGroups"]))')"

blue "==> Task def: $TASK_DEF"

# The compiled migration runner (same command the compose 'migrate' service uses).
OVERRIDES="$(cat <<JSON
{"containerOverrides":[{"name":"api","command":["node","dist/scripts/run-migrations.js"]}]}
JSON
)"
NETCFG="awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECGROUPS],assignPublicIp=DISABLED}"

blue "==> Launching one-off migration task"
TASK_ARN="$(aws ecs run-task --region "$REGION" \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEF" \
  --launch-type FARGATE \
  --count 1 \
  --overrides "$OVERRIDES" \
  --network-configuration "$NETCFG" \
  --query 'tasks[0].taskArn' --output text)"

[ -n "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ] || { red "Failed to launch task"; exit 1; }
blue "==> Task: $TASK_ARN — waiting for completion"
aws ecs wait tasks-stopped --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN"

EXIT_CODE="$(aws ecs describe-tasks --region "$REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].containers[0].exitCode' --output text)"

if [ "$EXIT_CODE" = "0" ]; then
  green "==> Migrations completed successfully (exit 0)."
else
  red "==> Migration task exited with code $EXIT_CODE"
  red "    Check CloudWatch logs: /ecs/relavoi-$ENV/api"
  exit 1
fi
