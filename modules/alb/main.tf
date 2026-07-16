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

variable "public_subnet_ids" {
  type        = list(string)
  description = "Public subnets for the internet-facing ALB."
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate ARN for the HTTPS listener."
}

variable "container_port" {
  type    = number
  default = 3000
}

locals {
  name = "${var.project}-${var.environment}"
}

# ─── ALB security group ───────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "Public HTTP/HTTPS ingress to the ALB."
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "${local.name}-alb-sg"
    Environment = var.environment
  }
}

# ─── Load balancer ────────────────────────────────────────────────────────────
resource "aws_lb" "this" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids

  tags = {
    Name        = "${local.name}-alb"
    Environment = var.environment
  }
}

# ─── Target groups (Fargate awsvpc => target_type ip) ─────────────────────────
resource "aws_lb_target_group" "api" {
  name        = "${local.name}-api-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/v1/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30

  tags = {
    Environment = var.environment
  }
}

resource "aws_lb_target_group" "webhook" {
  name        = "${local.name}-wh-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  # Latency-critical: probe more often and fail fast.
  health_check {
    path                = "/v1/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  deregistration_delay = 15

  tags = {
    Environment = var.environment
  }
}

# ─── Listeners ────────────────────────────────────────────────────────────────
# HTTP :80 -> redirect to HTTPS.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS :443 -> default forward to the api target group (TLS 1.3 policy).
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# /v1/webhooks/* -> webhook target group.
resource "aws_lb_listener_rule" "webhooks" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["/v1/webhooks/*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.webhook.arn
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "alb_zone_id" {
  value = aws_lb.this.zone_id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "api_target_group_arn" {
  value = aws_lb_target_group.api.arn
}

output "webhook_target_group_arn" {
  value = aws_lb_target_group.webhook.arn
}
