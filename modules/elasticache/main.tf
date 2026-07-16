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
variable "vpc_id" { type = string }

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnets for the cache subnet group."
}

variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}

variable "num_cache_nodes" {
  type    = number
  default = 1
}

variable "allowed_security_group_ids" {
  type        = list(string)
  description = "Security groups permitted to reach Redis on 6379 (the ECS tasks SG)."
  default     = []
}

variable "snapshot_retention_limit" {
  type        = number
  default     = 0
  description = "Days of snapshots to retain (0 disables; set > 0 in prod)."
}

locals {
  name = "${var.project}-${var.environment}"
}

# ─── Security group ───────────────────────────────────────────────────────────
resource "aws_security_group" "redis" {
  name        = "${local.name}-redis-sg"
  description = "Redis access from ECS tasks only."
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name}-redis-sg"
    Environment = var.environment
  }
}

resource "aws_security_group_rule" "redis_ingress" {
  count                    = length(var.allowed_security_group_ids)
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = var.allowed_security_group_ids[count.index]
  description              = "Redis from ECS tasks"
}

# ─── Subnet + parameter groups ────────────────────────────────────────────────
resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name}-redis-subnets"
  subnet_ids = var.private_subnet_ids

  tags = {
    Environment = var.environment
  }
}

resource "aws_elasticache_parameter_group" "this" {
  name        = "${local.name}-redis7"
  family      = "redis7"
  description = "Relavoi Redis 7 params (${var.environment})."

  # Evict least-recently-used keys under memory pressure — appropriate for the
  # session/routing cache. ElastiCache manages durability internally (no AOF).
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  tags = {
    Environment = var.environment
  }
}

# ─── Cluster (cluster-mode disabled, single node) ─────────────────────────────
resource "aws_elasticache_cluster" "this" {
  cluster_id           = "${local.name}-redis"
  engine               = "redis"
  engine_version       = "7.1"
  node_type            = var.node_type
  num_cache_nodes      = var.num_cache_nodes
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.this.name
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.redis.id]

  snapshot_retention_limit = var.snapshot_retention_limit

  tags = {
    Name        = "${local.name}-redis"
    Environment = var.environment
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "endpoint" {
  value = aws_elasticache_cluster.this.cache_nodes[0].address
}

output "port" {
  value = aws_elasticache_cluster.this.cache_nodes[0].port
}

output "redis_url" {
  value = "redis://${aws_elasticache_cluster.this.cache_nodes[0].address}:${aws_elasticache_cluster.this.cache_nodes[0].port}"
}

output "security_group_id" {
  value = aws_security_group.redis.id
}
