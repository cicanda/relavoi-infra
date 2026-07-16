terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

variable "project" { type = string }
variable "environment" { type = string }

variable "bucket_suffix" {
  type        = string
  description = "Suffix to keep the bucket name globally unique (e.g. account id)."
  default     = ""
}

locals {
  name        = "${var.project}-${var.environment}"
  bucket_name = var.bucket_suffix == "" ? "${local.name}-recordings" : "${local.name}-recordings-${var.bucket_suffix}"
}

# ─── KMS key for at-rest encryption ───────────────────────────────────────────
resource "aws_kms_key" "recordings" {
  description             = "Relavoi call-recording encryption (${var.environment})."
  deletion_window_in_days = 14
  enable_key_rotation     = true

  tags = {
    Environment = var.environment
  }
}

resource "aws_kms_alias" "recordings" {
  name          = "alias/${local.name}-recordings"
  target_key_id = aws_kms_key.recordings.key_id
}

# ─── Bucket ───────────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "recordings" {
  bucket = local.bucket_name

  tags = {
    Name        = local.bucket_name
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "recordings" {
  bucket = aws_s3_bucket.recordings.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "recordings" {
  bucket = aws_s3_bucket.recordings.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.recordings.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "recordings" {
  bucket                  = aws_s3_bucket.recordings.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "recordings" {
  bucket = aws_s3_bucket.recordings.id

  rule {
    id     = "archive-then-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "bucket_name" {
  value = aws_s3_bucket.recordings.id
}

output "bucket_arn" {
  value = aws_s3_bucket.recordings.arn
}

output "kms_key_arn" {
  value = aws_kms_key.recordings.arn
}
