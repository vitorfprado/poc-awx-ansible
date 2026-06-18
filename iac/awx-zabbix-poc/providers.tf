provider "aws" {
  region = var.aws_region

  # Aplica as tags padrao da POC em todos os recursos, inclusive os que os
  # modulos criam internamente. Tags definidas no recurso continuam tendo
  # precedencia sobre as default_tags.
  default_tags {
    tags = local.common_tags
  }
}

# Providers Kubernetes/Helm usados pelo modulo eks/addons (metrics-server).
# Autenticam no cluster via token efemero do EKS (exec), sem kubeconfig em disco.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}
