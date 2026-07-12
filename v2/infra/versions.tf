terraform {
  required_version = ">= 1.5"
  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "~> 2.6"
    }
    local = {
      source = "hashicorp/local"
    }
  }
}

provider "ovh" {
  endpoint = var.ovh_endpoint
}
