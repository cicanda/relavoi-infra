terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# ─── Variables ────────────────────────────────────────────────────────────────
variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets for the DB subnet group."
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 10
}

variable "max_allocated_storage" {
  type        = number
  default     = 50
  description = "Upper bound for storage autoscaling."
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "db_name" {
  type    = string
  default = "relavoi"
}

variable "db_username" {
  type    = string
  default = "relavoi"
}

variable "allowed_security_group_ids" {
  type        = list(string)
  description = "Security groups permitted to reach Postgres on 5432 (the ECS tasks SG)."
  default     = []
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "backup_retention_days" {
  type    = number
  default = 7
}

locals {
  name = "${var.project}-${var.environment}"
}

# ─── Password ─────────────────────────────────────────────────────────────────
resource "random_password" "db" {
  length = 32
  # RDS disallows /, @, ", and spaces in the master password.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ─── Security group ───────────────────────────────────────────────────────────
resource "aws_security_group" "db" {
  name        = "${local.name}-rds-sg"
  description = "Postgres access from ECS tasks only."
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name}-rds-sg"
    Environment = var.environment
  }
}

resource "aws_security_group_rule" "db_ingress" {
  count                    = length(var.allowed_security_group_ids)
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = var.allowed_security_group_ids[count.index]
  description              = "Postgres from ECS tasks"
}

# ─── Subnet + parameter groups ────────────────────────────────────────────────
resource "aws_db_subnet_group" "this" {
  name       = "${local.name}-db-subnets"
  subnet_ids = var.private_subnet_ids

  tags = {
    Environment = var.environment
  }
}

resource "aws_db_parameter_group" "this" {
  name        = "${local.name}-pg16"
  family      = "postgres16"
  description = "Relavoi Postgres 16 params (${var.environment})."

  parameter {
    name  = "shared_preload_libraries"
    value = "pg_stat_statements"
    # shared_preload_libraries requires a reboot to take effect.
    apply_method = "pending-reboot"
  }

  tags = {
    Environment = var.environment
  }
}

# ─── Instance ─────────────────────────────────────────────────────────────────
resource "aws_db_instance" "this" {
  identifier     = "${local.name}-pg"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result
  port     = 5432

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  multi_az               = var.multi_az
  db_subnet_group_name   = aws_db_subnet_group.this.name
  parameter_group_name   = aws_db_parameter_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]

  backup_retention_period      = var.backup_retention_days
  performance_insights_enabled = true

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = !var.deletion_protection
  final_snapshot_identifier = var.deletion_protection ? "${local.name}-pg-final" : null
  apply_immediately         = true

  tags = {
    Name        = "${local.name}-pg"
    Environment = var.environment
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "endpoint" {
  value = aws_db_instance.this.endpoint
}

output "address" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "database_url" {
  description = "postgresql:// connection string including the generated password."
  value       = "postgresql://${var.db_username}:${random_password.db.result}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${var.db_name}"
  sensitive   = true
}

output "password" {
  value     = random_password.db.result
  sensitive = true
}

output "security_group_id" {
  value = aws_security_group.db.id
}
