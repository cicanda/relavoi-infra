terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }
}

# ─── Variables ────────────────────────────────────────────────────────────────
variable "project" {
  type        = string
  description = "Project name, used as a resource name prefix."
}

variable "environment" {
  type        = string
  description = "Environment name (staging, prod)."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC."
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  type        = list(string)
  description = "AZs to spread subnets across (exactly two expected)."
  default     = ["eu-north-1a", "eu-north-1b"]
}

locals {
  name = "${var.project}-${var.environment}"
}

# ─── VPC ──────────────────────────────────────────────────────────────────────
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "${local.name}-vpc"
    Project     = var.project
    Environment = var.environment
  }
}

# ─── Subnets ──────────────────────────────────────────────────────────────────
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name        = "${local.name}-public-${count.index}"
    Tier        = "public"
    Environment = var.environment
  }
}

resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name        = "${local.name}-private-${count.index}"
    Tier        = "private"
    Environment = var.environment
  }
}

# ─── Internet gateway ─────────────────────────────────────────────────────────
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name        = "${local.name}-igw"
    Environment = var.environment
  }
}

# ─── NAT gateway (single, for cost — add a second per-AZ for HA later) ─────────
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = {
    Name        = "${local.name}-nat-eip"
    Environment = var.environment
  }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = {
    Name        = "${local.name}-nat"
    Environment = var.environment
  }

  depends_on = [aws_internet_gateway.this]
}

# ─── Route tables ─────────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name        = "${local.name}-public-rt"
    Environment = var.environment
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name        = "${local.name}-private-rt"
    Environment = var.environment
  }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "nat_gateway_ip" {
  description = "Elastic IP of the NAT gateway — whitelist this with Africa's Talking."
  value       = aws_eip.nat.public_ip
}
