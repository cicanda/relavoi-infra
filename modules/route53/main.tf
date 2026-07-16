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

variable "domain_name" {
  type        = string
  description = "Apex domain, e.g. relavoi.com. Its hosted zone must already exist."
}

variable "api_subdomain" {
  type        = string
  description = "Subdomain label for the API, e.g. api or staging-api."
  default     = "api"
}

variable "alb_dns_name" { type = string }
variable "alb_zone_id" { type = string }

locals {
  fqdn = "${var.api_subdomain}.${var.domain_name}"
}

# The hosted zone is NOT created here — it exists from domain registration /
# nameserver delegation. We only read it.
data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

# ─── ACM certificate (DNS-validated), covers the apex + wildcard ──────────────
resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Project     = var.project
    Environment = var.environment
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ─── A-record alias -> ALB ────────────────────────────────────────────────────
resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = var.alb_zone_id
    evaluate_target_health = true
  }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────
output "certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "api_fqdn" {
  value = local.fqdn
}

output "zone_id" {
  value = data.aws_route53_zone.this.zone_id
}
