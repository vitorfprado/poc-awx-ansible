terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
    # Exigido transitivamente pelo modulo eks (OIDC provider / IRSA).
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    # Usados pelo modulo eks/addons (metrics-server via Helm).
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.30"
    }
  }
}
