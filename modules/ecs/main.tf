terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

# ─── Variables ────────────────────────────────────────────────────────────────
variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }

variable "ecr_repository_url" { type = string }
variable "image_tag" {
  type    = string
  default = "latest"
}

variable "secret_arn" {
  type        = string
  description = "ARN of the app secrets JSON in Secrets Manager."
}

variable "api_target_group_arn" { type = string }
variable "webhook_target_group_arn" { type = string }
variable "alb_security_group_id" { type = string }

# The ECS tasks security group is created at the environment level and passed in
# to break the RDS/ElastiCache <-> ECS dependency cycle (RDS ingress needs this
# SG; ECS needs the RDS-derived DATABASE_URL). See envs/*/main.tf.
variable "ecs_security_group_id" { type = string }

variable "database_url" {
  type        = string
  description = "postgresql:// URL (contains the password); routed through Secrets Manager."
  sensitive   = true
}

variable "redis_url" {
  type        = string
  description = "redis:// URL. Plain env — ElastiCache is private + SG-guarded."
}

variable "env_vars" {
  type        = map(string)
  description = "Non-secret config (pool + circuit-breaker settings, etc.)."
  default     = {}
}

variable "cors_origins" {
  type        = string
  description = "Comma-separated allowed origins for the hosted dashboards."
  default     = "https://app.relavoi.com,https://admin.relavoi.com"
}

variable "recordings_bucket_arn" {
  type    = string
  default = ""
}

variable "recordings_kms_key_arn" {
  type    = string
  default = ""
}

variable "container_port" {
  type    = number
  default = 3000
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# Per-service sizing / scaling.
variable "api_desired_count" {
  type    = number
  default = 2
}
variable "webhook_desired_count" {
  type    = number
  default = 3
}

locals {
  name  = "${var.project}-${var.environment}"
  image = "${var.ecr_repository_url}:${var.image_tag}"

  # App secrets are stored as a single JSON secret; each key is referenced by
  # `<secret_arn>:KEY::`. DATABASE_URL lives in its own secret (below).
  app_secret_keys = [
    "JWT_SECRET",
    "ENCRYPTION_MASTER_KEY",
    "AT_API_KEY",
    "AT_USERNAME",
    "AT_ENVIRONMENT",
    "WEBHOOK_BASE_URL",
  ]

  common_secrets = concat(
    [{ name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.database_url.arn }],
    [for k in local.app_secret_keys : { name = k, valueFrom = "${var.secret_arn}:${k}::" }],
  )

  # Non-secret environment shared by all three services.
  base_env = merge(
    {
      NODE_ENV          = "production"
      PORT              = tostring(var.container_port)
      HOST              = "0.0.0.0"
      LOG_LEVEL         = "info"
      REDIS_URL         = var.redis_url
      REDIS_PREFIX      = "relavoi:"
      CORS_ORIGINS      = var.cors_origins
      AWS_REGION        = var.aws_region
      RECORDINGS_BUCKET = var.recordings_bucket_arn == "" ? "" : element(split(":::", var.recordings_bucket_arn), length(split(":::", var.recordings_bucket_arn)) - 1)
    },
    var.env_vars,
  )
}

# ─── DATABASE_URL secret (contains the password) ──────────────────────────────
resource "aws_secretsmanager_secret" "database_url" {
  name                    = "${var.project}/${var.environment}/database-url"
  description             = "Relavoi DATABASE_URL (${var.environment})."
  recovery_window_in_days = 7

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_secretsmanager_secret_version" "database_url" {
  secret_id     = aws_secretsmanager_secret.database_url.id
  secret_string = var.database_url
}

# ─── Cluster + logs ───────────────────────────────────────────────────────────
resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${local.name}/api"
  retention_in_days = var.log_retention_days
  tags              = { Environment = var.environment }
}

resource "aws_cloudwatch_log_group" "webhook" {
  name              = "/ecs/${local.name}/webhook"
  retention_in_days = var.log_retention_days
  tags              = { Environment = var.environment }
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${local.name}/worker"
  retention_in_days = var.log_retention_days
  tags              = { Environment = var.environment }
}

# ─── IAM ──────────────────────────────────────────────────────────────────────
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-exec"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = { Environment = var.environment }
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Allow the execution role to read the two secrets for `valueFrom`.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      var.secret_arn,
      aws_secretsmanager_secret.database_url.arn,
    ]
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${local.name}-exec-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

# Task role — the app's own AWS permissions (S3 recordings).
resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  tags               = { Environment = var.environment }
}

data "aws_iam_policy_document" "task_s3" {
  count = var.recordings_bucket_arn == "" ? 0 : 1

  statement {
    actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [var.recordings_bucket_arn, "${var.recordings_bucket_arn}/*"]
  }

  statement {
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
    resources = [var.recordings_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "task_s3" {
  count  = var.recordings_bucket_arn == "" ? 0 : 1
  name   = "${local.name}-task-s3"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_s3[0].json
}

# ─── Task definitions ─────────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "api"
      image        = local.image
      essential    = true
      portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
      environment  = [for k, v in merge(local.base_env, { SERVICE_MODE = "api" }) : { name = k, value = v }]
      secrets      = local.common_secrets
      healthCheck = {
        command     = ["CMD-SHELL", "wget -q --spider http://localhost:${var.container_port}/v1/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 20
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.api.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api"
        }
      }
    }
  ])

  tags = { Environment = var.environment }
}

resource "aws_ecs_task_definition" "webhook" {
  family                   = "${local.name}-webhook"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "webhook"
      image        = local.image
      essential    = true
      portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
      environment  = [for k, v in merge(local.base_env, { SERVICE_MODE = "webhook" }) : { name = k, value = v }]
      secrets      = local.common_secrets
      healthCheck = {
        command     = ["CMD-SHELL", "wget -q --spider http://localhost:${var.container_port}/v1/health || exit 1"]
        interval    = 15
        timeout     = 3
        retries     = 2
        startPeriod = 15
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.webhook.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "webhook"
        }
      }
    }
  ])

  tags = { Environment = var.environment }
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${local.name}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  # No portMappings and no healthCheck — the worker serves no HTTP.
  container_definitions = jsonencode([
    {
      name        = "worker"
      image       = local.image
      essential   = true
      environment = [for k, v in merge(local.base_env, { SERVICE_MODE = "worker" }) : { name = k, value = v }]
      secrets     = local.common_secrets
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.worker.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "worker"
        }
      }
    }
  ])

  tags = { Environment = var.environment }
}

# ─── Services ─────────────────────────────────────────────────────────────────
resource "aws_ecs_service" "api" {
  name            = "${local.name}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.api_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.api_target_group_arn
    container_name   = "api"
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # Ignore desired_count so autoscaling isn't reverted on each apply.
  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = { Environment = var.environment }
}

resource "aws_ecs_service" "webhook" {
  name            = "${local.name}-webhook"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.webhook.arn
  desired_count   = var.webhook_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.webhook_target_group_arn
    container_name   = "webhook"
    container_port   = var.container_port
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = { Environment = var.environment }
}

resource "aws_ecs_service" "worker" {
  name            = "${local.name}-worker"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.ecs_security_group_id]
    assign_public_ip = false
  }

  # No load_balancer block — the worker has no HTTP surface.

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = { Environment = var.environment }
}

# ─── Auto-scaling (api + webhook only) ────────────────────────────────────────
resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2
  max_capacity       = 10
}

resource "aws_appautoscaling_policy" "api_cpu" {
  name               = "${local.name}-api-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.api.service_namespace
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70
    scale_in_cooldown  = 120
    scale_out_cooldown = 60
  }
}

resource "aws_appautoscaling_target" "webhook" {
  service_namespace  = "ecs"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.webhook.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 3
  max_capacity       = 15
}

resource "aws_appautoscaling_policy" "webhook_cpu" {
  name               = "${local.name}-webhook-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.webhook.service_namespace
  resource_id        = aws_appautoscaling_target.webhook.resource_id
  scalable_dimension = aws_appautoscaling_target.webhook.scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_in_cooldown  = 120
    scale_out_cooldown = 45
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "ecs_security_group_id" {
  value = var.ecs_security_group_id
}

output "api_service_name" {
  value = aws_ecs_service.api.name
}

output "webhook_service_name" {
  value = aws_ecs_service.webhook.name
}

output "worker_service_name" {
  value = aws_ecs_service.worker.name
}
