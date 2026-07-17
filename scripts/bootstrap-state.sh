#!/usr/bin/env bash
#
# One-time setup of the Terraform remote-state backend: an S3 bucket (versioned,
# encrypted, private) for state and a DynamoDB table for state locking.
#
# Usage: ./scripts/bootstrap-state.sh
set -euo pipefail

REGION="${AWS_REGION:-eu-north-1}"
BUCKET="${STATE_BUCKET:-relavoi-terraform-state}"
TABLE="${LOCK_TABLE:-relavoi-terraform-locks}"

blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }

blue "==> Region: $REGION"
blue "==> State bucket: $BUCKET   Lock table: $TABLE"

# ─── S3 bucket ────────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket $BUCKET already exists — skipping create."
else
  blue "==> Creating S3 bucket"
  # us-east-1 must NOT pass a LocationConstraint; every other region must.
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION"
  fi
fi

blue "==> Enabling versioning"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

blue "==> Enabling default encryption"
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

blue "==> Blocking public access"
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# ─── DynamoDB lock table ──────────────────────────────────────────────────────
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  echo "Table $TABLE already exists — skipping create."
else
  blue "==> Creating DynamoDB lock table"
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --region "$REGION" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
fi

green "==> Done."
cat <<EOF

Next: uncomment the backend "s3" block in envs/staging/main.tf and
envs/prod/main.tf, then run:

  cd envs/staging && terraform init

EOF
