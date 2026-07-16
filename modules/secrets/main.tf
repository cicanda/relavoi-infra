terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

variable "project" {
  type        = string
  description = "Project name."
}

variable "environment" {
  type        = string
  description = "Environment name."
}

variable "secrets" {
  type        = map(string)
  description = "Application secrets, stored as a single JSON secret. Keys become valueFrom references in ECS."
  sensitive   = true
}

# A single Secrets Manager secret holding the app config as JSON. ECS task
# definitions reference individual keys via `${secret_arn}:KEY::`.
resource "aws_secretsmanager_secret" "app" {
  name        = "${var.project}/${var.environment}/app"
  description = "Relavoi backend application secrets (${var.environment})."

  # Short recovery window so re-creates during early setup aren't blocked for days.
  recovery_window_in_days = 7

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "app" {
  secret_id     = aws_secretsmanager_secret.app.id
  secret_string = jsonencode(var.secrets)
}

output "secret_arn" {
  value = aws_secretsmanager_secret.app.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.app.name
}
