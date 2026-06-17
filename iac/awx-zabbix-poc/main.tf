###############################################################################
# VPC unica da POC
###############################################################################

module "vpc" {
  source = "github.com/vitorfprado/terraform-aws-modules//vpc?ref=main"

  name       = "${local.name_prefix}-vpc"
  cidr_block = var.vpc_cidr

  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  # NAT garante saida para internet das subnets privadas (SSM, instalacao de
  # pacotes pelo Ansible, acesso ao Zabbix Server central). single = mais barato.
  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  # Tags exigidas pelo EKS para descoberta de subnets por load balancers.
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }

  tags = local.common_tags
}

###############################################################################
# EKS minimo (hospeda AWX Operator + AWX + PostgreSQL interno)
###############################################################################

module "eks" {
  source = "github.com/vitorfprado/terraform-aws-modules//eks?ref=main"

  cluster_name    = "${local.name_prefix}-eks"
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  endpoint_private_access = true
  endpoint_public_access  = var.eks_endpoint_public_access
  public_access_cidrs     = var.eks_public_access_cidrs

  enable_irsa           = true
  enable_ebs_csi_driver = true # necessario para o PVC do PostgreSQL interno do AWX

  node_groups = {
    general = {
      instance_types = var.eks_node_instance_types
      capacity_type  = "ON_DEMAND"
      desired_size   = var.eks_node_desired_size
      min_size       = var.eks_node_min_size
      max_size       = var.eks_node_max_size
      labels = {
        role = "awx"
      }
    }
  }

  # Add-ons base do EKS (nao sao os addons de aplicacao do Kubernetes).
  cluster_addons = {
    coredns                = {}
    kube-proxy             = {}
    vpc-cni                = {}
    eks-pod-identity-agent = {}
  }

  tags = local.common_tags
}

###############################################################################
# Security Groups das EC2s
#
# Criados aqui (e nao dentro do modulo ec2) por dois motivos:
#  1. O SG do Agent referencia o SG do Proxy e vice-versa; declarar as regras
#     como recursos separados evita a dependencia circular.
#  2. O SG do Agent e compartilhado por todas as EC2s de agent.
###############################################################################

resource "aws_security_group" "proxy" {
  name_prefix = "${local.name_prefix}-zbx-proxy-"
  description = "Zabbix Proxy: SSH interno (EKS/AWX), recebe Agents e fala com o Server central"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-zbx-proxy" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "agent" {
  name_prefix = "${local.name_prefix}-zbx-agent-"
  description = "Zabbix Agent: SSH interno (EKS/AWX) e comunicacao com o Proxy"
  vpc_id      = module.vpc.vpc_id

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-zbx-agent" })

  lifecycle {
    create_before_destroy = true
  }
}

# --- Ingress do Proxy ---------------------------------------------------------

# SSH a partir dos nodes/pods do EKS (AWX executa o Ansible de dentro do cluster).
resource "aws_vpc_security_group_ingress_rule" "proxy_ssh_from_eks" {
  security_group_id            = aws_security_group.proxy.id
  description                  = "SSH a partir do EKS/AWX"
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.cluster_security_group_id
}

# Agents ativos enviam dados ao Proxy na porta do Proxy.
resource "aws_vpc_security_group_ingress_rule" "proxy_from_agents" {
  security_group_id            = aws_security_group.proxy.id
  description                  = "Zabbix Agents ativos para o Proxy"
  from_port                    = var.zabbix_proxy_port
  to_port                      = var.zabbix_proxy_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.agent.id
}

# --- Egress do Proxy ----------------------------------------------------------

# Saida geral via NAT (SSM, instalacao de pacotes pelo Ansible).
resource "aws_vpc_security_group_egress_rule" "proxy_all" {
  security_group_id = aws_security_group.proxy.id
  description       = "Saida geral (NAT)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Saida parametrizada para o Zabbix Server central (declarativa; so e criada
# quando zabbix_server_cidr e informado).
resource "aws_vpc_security_group_egress_rule" "proxy_to_server" {
  count = var.zabbix_server_cidr != null ? 1 : 0

  security_group_id = aws_security_group.proxy.id
  description       = "Proxy para o Zabbix Server central"
  from_port         = var.zabbix_proxy_port
  to_port           = var.zabbix_proxy_port
  ip_protocol       = "tcp"
  cidr_ipv4         = var.zabbix_server_cidr
}

# --- Ingress do Agent ---------------------------------------------------------

# SSH a partir dos nodes/pods do EKS (AWX executa o Ansible de dentro do cluster).
resource "aws_vpc_security_group_ingress_rule" "agent_ssh_from_eks" {
  security_group_id            = aws_security_group.agent.id
  description                  = "SSH a partir do EKS/AWX"
  from_port                    = 22
  to_port                      = 22
  ip_protocol                  = "tcp"
  referenced_security_group_id = module.eks.cluster_security_group_id
}

# Proxy faz checks passivos no Agent na porta do Agent.
resource "aws_vpc_security_group_ingress_rule" "agent_from_proxy" {
  security_group_id            = aws_security_group.agent.id
  description                  = "Proxy para o Zabbix Agent (checks passivos)"
  from_port                    = var.zabbix_agent_port
  to_port                      = var.zabbix_agent_port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.proxy.id
}

# --- Egress do Agent ----------------------------------------------------------

# Saida geral via NAT (SSM, pacotes) e comunicacao com o Proxy.
resource "aws_vpc_security_group_egress_rule" "agent_all" {
  security_group_id = aws_security_group.agent.id
  description       = "Saida geral (NAT) e comunicacao com o Proxy"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

###############################################################################
# EC2 do Zabbix Proxy
###############################################################################

module "zabbix_proxy" {
  source = "github.com/vitorfprado/terraform-aws-modules//ec2?ref=main"

  name          = "${local.name_prefix}-zbx-proxy"
  instance_type = var.proxy_instance_type

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[0]

  key_name = var.ssh_key_name

  # AL2023 exige root >= 30GB (tamanho do snapshot da AMI).
  root_volume_size = var.ec2_root_volume_size

  # SG gerenciado no consumer (ver bloco de Security Groups acima).
  create_security_group  = false
  vpc_security_group_ids = [aws_security_group.proxy.id]

  # Instance profile com SSM Session Manager (acesso sem expor SSH a internet).
  create_iam_instance_profile = true
  iam_role_policy_arns        = local.ssm_policy_arns

  tags = merge(local.common_tags, { Role = "zabbix-proxy" })
}

###############################################################################
# EC2s dos Zabbix Agents (reutilizaveis via for_each sobre local.agents)
###############################################################################

module "zabbix_agent" {
  source = "github.com/vitorfprado/terraform-aws-modules//ec2?ref=main"

  for_each = local.agents

  name          = "${local.name_prefix}-${each.key}"
  instance_type = var.agent_instance_type

  vpc_id    = module.vpc.vpc_id
  subnet_id = module.vpc.private_subnet_ids[each.value.subnet_index]

  key_name = var.ssh_key_name

  # AL2023 exige root >= 30GB (tamanho do snapshot da AMI).
  root_volume_size = var.ec2_root_volume_size

  create_security_group  = false
  vpc_security_group_ids = [aws_security_group.agent.id]

  create_iam_instance_profile = true
  iam_role_policy_arns        = local.ssm_policy_arns

  tags = merge(local.common_tags, { Role = "zabbix-agent" })
}
