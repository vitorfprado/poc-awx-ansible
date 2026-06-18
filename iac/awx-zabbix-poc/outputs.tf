###############################################################################
# EKS (consumido depois pelo AWX/kubectl/helm)
###############################################################################

output "eks_cluster_name" {
  description = "Nome do cluster EKS."
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "Endpoint da API do cluster EKS."
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "Certificado da CA do cluster (base64), usado para montar o kubeconfig."
  value       = module.eks.cluster_certificate_authority_data
}

output "kubeconfig_command" {
  description = "Comando para configurar o kubeconfig local apontando para o cluster da POC."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "eks_cluster_security_group_id" {
  description = "Security group gerenciado pelo EKS (origem do SSH permitido nas EC2s)."
  value       = module.eks.cluster_security_group_id
}

###############################################################################
# Rede
###############################################################################

output "vpc_id" {
  description = "ID da VPC da POC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs das subnets privadas (nodes do EKS e EC2s do Zabbix)."
  value       = module.vpc.private_subnet_ids
}

###############################################################################
# EC2s (consumidas depois como inventario do Ansible/AWX)
###############################################################################

output "instance_ids" {
  description = "IDs de todas as EC2s, indexados por papel/nome."
  value = merge(
    { (module.zabbix_proxy.private_dns) = module.zabbix_proxy.instance_id },
    { for k, m in module.zabbix_agent : k => m.instance_id },
  )
}

output "zabbix_proxy_instance_id" {
  description = "ID da EC2 do Zabbix Proxy."
  value       = module.zabbix_proxy.instance_id
}

output "zabbix_proxy_private_ip" {
  description = "IP privado da EC2 do Zabbix Proxy (alvo do Ansible e dos Agents)."
  value       = module.zabbix_proxy.private_ip
}

output "zabbix_agent_instance_ids" {
  description = "IDs das EC2s de Zabbix Agent, indexados pelo nome do agent."
  value       = { for k, m in module.zabbix_agent : k => m.instance_id }
}

output "zabbix_agent_private_ips" {
  description = "IPs privados das EC2s de Zabbix Agent Linux, indexados pelo nome do agent."
  value       = { for k, m in module.zabbix_agent : k => m.private_ip }
}

output "zabbix_agent_windows_private_ips" {
  description = "IPs privados das EC2s de Zabbix Agent Windows, indexados pelo nome do agent."
  value       = { for k, m in module.zabbix_agent_windows : k => m.private_ip }
}

output "zabbix_agent_windows_instance_ids" {
  description = "IDs das EC2s de Zabbix Agent Windows."
  value       = { for k, m in module.zabbix_agent_windows : k => m.instance_id }
}

output "windows_admin_password" {
  description = "Senha do Administrator das EC2s Windows (para a Machine Credential do AWX)."
  value       = try(random_password.windows_admin[0].result, null)
  sensitive   = true
}

###############################################################################
# Security Groups
###############################################################################

output "security_group_ids" {
  description = "IDs dos Security Groups criados para as EC2s do Zabbix."
  value = {
    proxy         = aws_security_group.proxy.id
    agent         = aws_security_group.agent.id
    agent_windows = aws_security_group.agent_windows.id
  }
}

###############################################################################
# Acesso / integracao
###############################################################################

output "ssh_key_name" {
  description = "Nome do key pair SSH usado pelas EC2s (null quando o acesso e somente via SSM)."
  value       = var.ssh_key_name
}

output "zabbix_server_address" {
  description = "Endereco do Zabbix Server central, repassado ao Ansible/AWX para configurar o Proxy."
  value       = var.zabbix_server_address
}
