terraform {
  # Backend S3 com configuracao PARCIAL: bucket/key/region sao informados no
  # `terraform init` (via -backend-config no pipeline, ou backend.hcl localmente).
  # Mantem o state persistente entre execucoes do pipeline (necessario para que
  # um `destroy` posterior encontre os recursos criados por um `apply` anterior).
  #
  # Locking nativo do S3 (Terraform >= 1.10): use_lockfile = true (sem DynamoDB).
  backend "s3" {}
}
