###############################################################################
# Identificacao / padronizacao
###############################################################################

variable "project_name" {
  description = "Nome do projeto. Usado como prefixo na nomeacao dos recursos e na tag Project."
  type        = string
  default     = "awx-zabbix-poc"
}

variable "environment" {
  description = "Ambiente da POC. Compoe o prefixo de nomes e a tag Environment."
  type        = string
  default     = "poc"
}

variable "aws_region" {
  description = "Regiao AWS onde toda a infraestrutura da POC sera provisionada."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Tags adicionais aplicadas a todos os recursos, combinadas com as tags padrao (Project, Environment, ManagedBy)."
  type        = map(string)
  default     = {}
}

###############################################################################
# Rede (VPC)
###############################################################################

variable "vpc_cidr" {
  description = "Bloco CIDR primario da VPC unica da POC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDRs das subnets publicas (uma por AZ). Usadas para NAT Gateway e, se habilitado, acesso publico ao EKS."
  type        = list(string)
  default     = ["10.0.0.0/20", "10.0.16.0/20"]
}

variable "private_subnet_cidrs" {
  description = "CIDRs das subnets privadas (uma por AZ). Hospedam os nodes do EKS e todas as EC2s do Zabbix."
  type        = list(string)
  default     = ["10.0.48.0/20", "10.0.64.0/20"]
}

variable "azs" {
  description = "Zonas de disponibilidade a utilizar. Vazio = seleciona automaticamente conforme a quantidade de subnets."
  type        = list(string)
  default     = []
}

variable "single_nat_gateway" {
  description = "Usa um unico NAT Gateway para todas as subnets privadas (mais barato). Recomendado para POC."
  type        = bool
  default     = true
}

###############################################################################
# EKS (AWX Operator + AWX + PostgreSQL interno)
###############################################################################

variable "cluster_version" {
  description = "Versao do Kubernetes do control plane do EKS."
  type        = string
  default     = "1.32"
}

variable "eks_node_instance_types" {
  description = "Tipos de instancia dos nodes do EKS. t3.large atende AWX + PostgreSQL interno com folga minima."
  type        = list(string)
  default     = ["t3.large"]
}

variable "eks_node_desired_size" {
  description = "Quantidade desejada de nodes no managed node group do EKS."
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "Quantidade minima de nodes no managed node group do EKS."
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "Quantidade maxima de nodes no managed node group do EKS."
  type        = number
  default     = 3
}

variable "eks_endpoint_public_access" {
  description = "Habilita acesso publico ao endpoint da API do EKS. Conveniente para administrar a POC (kubectl/helm) de fora da VPC."
  type        = bool
  default     = true
}

variable "eks_public_access_cidrs" {
  description = "CIDRs autorizados a acessar o endpoint publico do EKS. Restrinja ao seu IP/escritorio em vez de 0.0.0.0/0."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "eks_admin_principal_arns" {
  description = "ARNs de principals IAM (usuarios/roles) que recebem acesso de admin ao cluster via EKS access entries (AmazonEKSClusterAdminPolicy). Permite kubectl fora do pipeline e e gerenciado por apply/destroy."
  type        = list(string)
  default     = []
}

variable "enable_metrics_server" {
  description = "Instala o Metrics Server (kubectl top / HPA) via modulo eks/addons (Helm)."
  type        = bool
  default     = true
}

###############################################################################
# EC2s Zabbix (Proxy + Agents)
###############################################################################

variable "ssh_key_name" {
  description = "Nome de um key pair EC2 existente para acesso SSH (simula VPN+SSH do cliente). Quando null, usa-se somente SSM Session Manager."
  type        = string
  default     = null
}

variable "proxy_instance_type" {
  description = "Tipo de instancia da EC2 do Zabbix Proxy."
  type        = string
  default     = "t3.micro"
}

variable "agent_instance_type" {
  description = "Tipo de instancia das EC2s de Zabbix Agent."
  type        = string
  default     = "t3.micro"
}

variable "agent_count" {
  description = "Quantidade de EC2s de Zabbix Agent. Aumente este numero para adicionar mais agents (distribuidos entre as subnets privadas)."
  type        = number
  default     = 2
}

variable "ec2_root_volume_size" {
  description = "Tamanho (GB) do volume raiz das EC2s. Minimo 30 para a AMI Amazon Linux 2023."
  type        = number
  default     = 30

  validation {
    condition     = var.ec2_root_volume_size >= 30
    error_message = "ec2_root_volume_size deve ser >= 30 (tamanho do snapshot da AMI AL2023)."
  }
}

###############################################################################
# Conectividade Zabbix
###############################################################################

variable "zabbix_server_address" {
  description = "Endereco (IP ou hostname) do Zabbix Server central com o qual o Proxy se comunica. Repassado ao Ansible/AWX para configuracao."
  type        = string
  default     = ""
}

variable "zabbix_server_cidr" {
  description = "CIDR do Zabbix Server central usado na regra de saida (egress) parametrizada do SG do Proxy. Quando null, nenhuma regra dedicada e criada (vale a saida geral via NAT)."
  type        = string
  default     = null
}

variable "zabbix_proxy_port" {
  description = "Porta TCP do Zabbix Proxy/Server (Agents ativos -> Proxy e Proxy -> Server central)."
  type        = number
  default     = 10051
}

variable "zabbix_agent_port" {
  description = "Porta TCP do Zabbix Agent (Proxy -> Agent em checks passivos)."
  type        = number
  default     = 10050
}
