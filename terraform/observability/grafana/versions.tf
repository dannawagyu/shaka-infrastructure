terraform {
  required_version = ">= 1.5.0"

  backend "s3" {
    bucket         = "dannawagyu-shaka-prod-terraform-state"
    key            = "observability/grafana/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "shaka-prod-terraform-locks"
    encrypt        = true
  }

  required_providers {
    grafana = {
      source  = "grafana/grafana"
      version = "~> 3.25"
    }
  }
}
