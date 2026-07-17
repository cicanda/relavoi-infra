terraform {
  required_version = ">= 1.5.0"

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

  # Remote state — uncomment after running scripts/bootstrap-state.sh.
  # backend "s3" {
  #   bucket         = "relavoi-terraform-state"
  #   key            = "prod/terraform.tfstate"
  #   region         = "eu-north-1"
  #   dynamodb_table = "relavoi-terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ─── Variables ────────────────────────────────────────────────────────────────
variable "project" {
  type    = string
  default = "relavoi"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "aws_profile" {
  type    = string
  default = "relavoi"
}

variable "domain_name" {
  type    = string
  default = "relavoi.com"
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "jwt_secret" {
  type      = string
  sensitive = true
}

variable "encryption_master_key" {
  type      = string
  sensitive = true
}

variable "at_api_key" {
  type      = string
  sensitive = true
}

variable "at_username" {
  type    = string
  default = "relavoi"
}

variable "at_environment" {
  type    = string
  default = "production"
}

variable "cors_origins" {
  type        = string
  description = "Allowed browser origins (Vercel-hosted dashboards)."
  default     = "https://app.relavoi.com,https://admin.relavoi.com"
}

# ─── Locals ───────────────────────────────────────────────────────────────────
locals {
  api_subdomain    = "api"
  api_fqdn         = "${local.api_subdomain}.${var.domain_name}"
  webhook_base_url = "https://${local.api_fqdn}"

  app_env = {
    JWT_EXPIRY                            = "15m"
    POOL_COOLDOWN_MINUTES                 = "5"
    POOL_LOW_THRESHOLD_PERCENT            = "20"
    POOL_AUTO_PROVISION_THRESHOLD_PERCENT = "20"
    SESSION_DEFAULT_GRACE_PERIOD_MINUTES  = "15"
    SESSION_DEFAULT_MAX_DURATION_MINUTES  = "120"
    SESSION_EXPIRY_CHECK_INTERVAL_SECONDS = "30"
    CB_FAILURE_THRESHOLD                  = "5"
    CB_ERROR_RATE_THRESHOLD               = "0.1"
    CB_ERROR_RATE_WINDOW_SECONDS          = "120"
    CB_HEALTH_CHECK_INTERVAL_SECONDS      = "30"
    CB_RECOVERY_CHECK_COUNT               = "5"
    CB_HALF_OPEN_TRAFFIC_PERCENT          = "10"
  }
}

data "aws_caller_identity" "current" {}

# ─── Foundation ───────────────────────────────────────────────────────────────
module "vpc" {
  source             = "../../modules/vpc"
  project            = var.project
  environment        = var.environment
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = ["${var.aws_region}a", "${var.aws_region}b"]
}

module "ecr" {
  source      = "../../modules/ecr"
  project     = var.project
  environment = var.environment
}

module "s3" {
  source        = "../../modules/s3"
  project       = var.project
  environment   = var.environment
  bucket_suffix = data.aws_caller_identity.current.account_id
}

module "secrets" {
  source      = "../../modules/secrets"
  project     = var.project
  environment = var.environment
  secrets = {
    JWT_SECRET            = var.jwt_secret
    ENCRYPTION_MASTER_KEY = var.encryption_master_key
    AT_API_KEY            = var.at_api_key
    AT_USERNAME           = var.at_username
    AT_ENVIRONMENT        = var.at_environment
    WEBHOOK_BASE_URL      = local.webhook_base_url
  }
}

# ─── Data stores ──────────────────────────────────────────────────────────────
module "rds" {
  source                     = "../../modules/rds"
  project                    = var.project
  environment                = var.environment
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  instance_class             = "db.t4g.small"
  allocated_storage          = 20
  max_allocated_storage      = 100
  multi_az                   = true
  deletion_protection        = true
  allowed_security_group_ids = [aws_security_group.ecs_tasks.id]
}

module "elasticache" {
  source                     = "../../modules/elasticache"
  project                    = var.project
  environment                = var.environment
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  node_type                  = "cache.t4g.micro"
  snapshot_retention_limit   = 5
  allowed_security_group_ids = [aws_security_group.ecs_tasks.id]
}

# ─── Edge (DNS/cert + ALB) ────────────────────────────────────────────────────
module "dns" {
  source        = "../../modules/route53"
  project       = var.project
  environment   = var.environment
  domain_name   = var.domain_name
  api_subdomain = local.api_subdomain
  alb_dns_name  = module.alb.alb_dns_name
  alb_zone_id   = module.alb.alb_zone_id
}

module "alb" {
  source            = "../../modules/alb"
  project           = var.project
  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  certificate_arn   = module.dns.certificate_arn
}

# ─── ECS tasks security group (env-level to avoid a dependency cycle) ─────────
resource "aws_security_group" "ecs_tasks" {
  name        = "${var.project}-${var.environment}-ecs-tasks-sg"
  description = "ECS tasks: app port from ALB only, all egress."
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "App port from ALB"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [module.alb.alb_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${var.project}-${var.environment}-ecs-tasks-sg"
    Environment = var.environment
  }
}

# ─── Compute ──────────────────────────────────────────────────────────────────
module "ecs" {
  source                   = "../../modules/ecs"
  project                  = var.project
  environment              = var.environment
  aws_region               = var.aws_region
  vpc_id                   = module.vpc.vpc_id
  private_subnet_ids       = module.vpc.private_subnet_ids
  ecr_repository_url       = module.ecr.repository_url
  image_tag                = var.image_tag
  secret_arn               = module.secrets.secret_arn
  api_target_group_arn     = module.alb.api_target_group_arn
  webhook_target_group_arn = module.alb.webhook_target_group_arn
  alb_security_group_id    = module.alb.alb_security_group_id
  ecs_security_group_id    = aws_security_group.ecs_tasks.id
  database_url             = module.rds.database_url
  redis_url                = module.elasticache.redis_url
  env_vars                 = local.app_env
  cors_origins             = var.cors_origins
  recordings_bucket_arn    = module.s3.bucket_arn
  recordings_kms_key_arn   = module.s3.kms_key_arn
  api_desired_count        = 2
  webhook_desired_count    = 3
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "api_url" {
  value = "https://${local.api_fqdn}"
}

output "ecr_repository" {
  value = module.ecr.repository_url
}

output "nat_gateway_ip" {
  description = "Whitelist this IP with Africa's Talking for webhook delivery."
  value       = module.vpc.nat_gateway_ip
}

output "db_password" {
  value     = module.rds.password
  sensitive = true
}
