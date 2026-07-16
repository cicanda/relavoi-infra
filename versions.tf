# Shared version pins for the Relavoi infrastructure.
#
# Each environment root (envs/staging, envs/prod) declares its own terraform{}
# and provider "aws" block; this file documents the versions the project targets.
# Terraform 1.7+ is recommended; 1.5+ is the validated floor.

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
}
