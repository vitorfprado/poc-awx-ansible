provider "aws" {
  region = var.aws_region

  # Aplica as tags padrao da POC em todos os recursos, inclusive os que os
  # modulos criam internamente. Tags definidas no recurso continuam tendo
  # precedencia sobre as default_tags.
  default_tags {
    tags = local.common_tags
  }
}
