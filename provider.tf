terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.1"
    }
    localos = {
      source  = "fireflycons/localos"
      version = "0.1.2"
    }
  }

  required_version = ">= 1.2"
}
