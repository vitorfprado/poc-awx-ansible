locals {
  # Prefixo unico para padronizar a nomeacao de todos os recursos da POC.
  name_prefix = "${var.project_name}-${var.environment}"

  # Tags padrao exigidas pela POC, mescladas com tags extras do usuario.
  common_tags = merge(
    {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )

  # Politica IAM que habilita o SSM Session Manager nas EC2s.
  ssm_policy_arns = {
    ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Access entries do EKS concedendo admin de cluster aos principals informados.
  # A chave do mapa e a propria ARN (apenas usada pelo for_each do modulo).
  eks_admin_access_entries = {
    for arn in var.eks_admin_principal_arns : arn => {
      principal_arn = arn
      policy_associations = {
        cluster_admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          scope_type = "cluster"
        }
      }
    }
  }

  # Mapa dos Zabbix Agents gerado a partir de agent_count.
  # Cada agent recebe um indice de subnet (round-robin entre as subnets privadas)
  # para distribuir as instancias entre as AZs. Para adicionar mais agents,
  # basta aumentar var.agent_count.
  agents = {
    for i in range(var.agent_count) :
    format("zbx-agent-%02d", i + 1) => {
      subnet_index = i % length(var.private_subnet_cidrs)
    }
  }

  # Mapa dos Zabbix Agents WINDOWS (mesma logica do Linux).
  windows_agents = {
    for i in range(var.windows_agent_count) :
    format("zbx-agent-win-%02d", i + 1) => {
      subnet_index = i % length(var.private_subnet_cidrs)
    }
  }
}
