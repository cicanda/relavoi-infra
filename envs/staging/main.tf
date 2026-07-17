terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # Uncomment after bootstrap-state.sh
  # backend "s3" {
  #   bucket         = "relavoi-terraform-state"
  #   key            = "staging/terraform.tfstate"
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

variable "project" {
  type    = string
  default = "relavoi"
}

variable "environment" {
  type    = string
  default = "staging"
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

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "key_pair_name" {
  type        = string
  description = "Name of an existing EC2 key pair for SSH access"
}

variable "ssh_allowed_cidr" {
  type        = string
  default     = "0.0.0.0/0"
  description = "CIDR block allowed to SSH. Set to your IP for security: x.x.x.x/32"
}

# App secrets (passed via tfvars or TF_VAR_)
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
  default = "sandbox"
}

variable "at_environment" {
  type    = string
  default = "sandbox"
}

variable "cors_origins" {
  type    = string
  default = "https://app.relavoi.com,https://admin.relavoi.com,http://localhost:3001,http://localhost:3003"
}

variable "db_password" {
  type      = string
  sensitive = true
}

# ── DNS ──

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_route53_record" "staging_api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "staging-api.${var.domain_name}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.staging.public_ip]
}

# ── VPC (default VPC, keep it simple) ──

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# ── Security Group ──

resource "aws_security_group" "staging" {
  name_prefix = "${var.project}-staging-"
  vpc_id      = data.aws_vpc.default.id
  description = "Relavoi staging - HTTP, HTTPS, SSH"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
    description = "SSH"
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP (Caddy redirects to HTTPS)"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound"
  }

  tags = {
    Name = "${var.project}-staging"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Elastic IP (static IP for AT webhook whitelisting) ──

resource "aws_eip" "staging" {
  domain = "vpc"

  tags = {
    Name = "${var.project}-staging"
  }
}

resource "aws_eip_association" "staging" {
  instance_id   = aws_instance.staging.id
  allocation_id = aws_eip.staging.id
}

# ── EC2 Instance ──

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "staging" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  vpc_security_group_ids = [aws_security_group.staging.id]
  subnet_id              = tolist(data.aws_subnets.default.ids)[0]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    project               = var.project
    environment           = var.environment
    domain_name           = "staging-api.${var.domain_name}"
    db_password           = var.db_password
    jwt_secret            = var.jwt_secret
    encryption_master_key = var.encryption_master_key
    at_api_key            = var.at_api_key
    at_username           = var.at_username
    at_environment        = var.at_environment
    cors_origins          = var.cors_origins
  }))

  tags = {
    Name = "${var.project}-staging"
  }
}

# ── Outputs ──

output "instance_id" {
  value = aws_instance.staging.id
}

output "public_ip" {
  value       = aws_eip.staging.public_ip
  description = "Static IP - whitelist this with Africa's Talking"
}

output "api_url" {
  value = "https://staging-api.${var.domain_name}"
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${var.key_pair_name}.pem ubuntu@${aws_eip.staging.public_ip}"
}

output "key_pair_name" {
  value = var.key_pair_name
}
