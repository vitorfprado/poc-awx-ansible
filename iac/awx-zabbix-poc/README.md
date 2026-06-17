# awx-zabbix-poc — Consumer Terraform

Provisiona a **infraestrutura base** para uma POC que valida o uso do **AWX
Operator** em Kubernetes (EKS) para gerenciar, via Ansible, servidores **Zabbix
Proxy** e **Zabbix Agent** em instâncias EC2.

> **Escopo do Terraform:** apenas a infraestrutura. A instalação/configuração do
> AWX Operator, do AWX e do Zabbix (Proxy/Agent) é feita **depois**, via Ansible
> executado pelo AWX. Este código **não** instala nem configura nada disso.

## Arquitetura

- 1 **VPC** única (subnets públicas para NAT/ELB, subnets privadas para tudo).
- 1 **EKS** mínimo (1 managed node group) para AWX Operator + AWX + PostgreSQL
  interno do AWX.
- 1 **EC2** Zabbix Proxy (subnet privada, sem IP público).
- N **EC2s** Zabbix Agent (`agent_count`, distribuídas entre as subnets privadas).
- **Security Groups** simulando ambiente de cliente (acesso interno via SSH):
  - EKS/AWX → EC2s na porta **22** (SSH);
  - Agents → Proxy na porta **10051**;
  - Proxy → Agents na porta **10050** (checks passivos);
  - Proxy → Zabbix Server central na porta **10051** (egress parametrizado);
  - sem ingress vindo da internet (instâncias só em subnet privada).
- **IAM Instance Profile** com **SSM Session Manager** em todas as EC2s.

## Arquivos

| Arquivo | Conteúdo |
|---|---|
| `versions.tf` | Versões do Terraform e providers (`aws`, `tls`). |
| `providers.tf` | Provider AWS (região + `default_tags`). |
| `variables.tf` | Todas as variáveis de entrada. |
| `locals.tf` | Padronização de nomes, tags padrão e geração do mapa de agents. |
| `main.tf` | VPC, EKS, Security Groups e EC2s (Proxy + Agents). |
| `outputs.tf` | Outputs para integração com AWX/Ansible. |
| `terraform.tfvars.example` | Exemplo de valores; copie para `terraform.tfvars`. |
| `backend.tf` | Backend S3 (config parcial) para state remoto persistente. |
| `backend.hcl.example` | Exemplo de `-backend-config` para `init` local. |
| `README.md` | Este arquivo. |

## Módulos consumidos

Todos do repositório [`vitorfprado/terraform-aws-modules`](https://github.com/vitorfprado/terraform-aws-modules):

| Módulo | Uso |
|---|---|
| `//vpc` | VPC única, subnets públicas/privadas e NAT Gateway. |
| `//eks` | Cluster EKS, node group, IRSA, add-ons base e EBS CSI driver. |
| `//ec2` | EC2 do Proxy e EC2s dos Agents (reutilizado via `for_each`). |

> Os Security Groups das EC2s são criados no consumer (não no módulo `ec2`) para
> evitar a dependência circular entre Proxy e Agent e para compartilhar o SG
> entre todos os agents.

## Variáveis que você precisa preencher

A maioria tem default. Os pontos que normalmente exigem ajuste manual:

| Variável | Por quê |
|---|---|
| `aws_region` | Região de destino. |
| `ssh_key_name` | Key pair EC2 **já existente** na região. Opcional — sem ela o acesso é só via SSM. |
| `zabbix_server_address` | Endereço do Zabbix Server central (repassado ao Ansible). |
| `zabbix_server_cidr` | CIDR do Server central para a regra de egress do Proxy (use `null` para pular). |
| `eks_public_access_cidrs` | Restrinja ao seu IP em vez de `0.0.0.0/0`. |

Demais variáveis (CIDRs, instance types, `agent_count`, versão do EKS, tags)
podem ser mantidas nos defaults para uma POC de baixo custo.

## Como adicionar mais uma EC2 de agent

Basta aumentar `agent_count` no `terraform.tfvars` e aplicar:

```hcl
agent_count = 3
```

```bash
terraform apply
```

O `for_each` sobre `local.agents` cria a nova instância (`zbx-agent-03`),
distribuída automaticamente entre as subnets privadas, com o mesmo SG, instance
profile e tags. Nenhuma alteração de código é necessária.

## Como executar

### Via pipeline (recomendado)

Use o workflow manual do GitHub Actions. Veja
[docs/pipeline-awx-zabbix-poc.md](../../docs/pipeline-awx-zabbix-poc.md) para
`plan`/`apply`/`destroy`, OIDC e variables.

### Localmente

```bash
cd iac/awx-zabbix-poc

cp terraform.tfvars.example terraform.tfvars
# edite terraform.tfvars conforme necessário

cp backend.hcl.example backend.hcl
# edite backend.hcl com o bucket S3 do state

terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Pré-requisitos: AWS CLI configurado (credenciais/SSO), Terraform >= 1.5, um bucket
S3 para o state e permissões para criar VPC/EKS/EC2/IAM.

> O state fica em **S3** (`backend.tf`). Sem `-backend-config`, o `init` solicitará
> bucket/key/region interativamente.

## Outputs usados depois pelo AWX/Ansible

| Output | Uso |
|---|---|
| `eks_cluster_name` | Identifica o cluster onde o AWX roda. |
| `eks_cluster_endpoint` | Endpoint da API do Kubernetes. |
| `eks_cluster_certificate_authority_data` | CA para montar kubeconfig. |
| `kubeconfig_command` | Comando pronto (`aws eks update-kubeconfig ...`). |
| `instance_ids` | IDs de todas as EC2s. |
| `zabbix_proxy_private_ip` | IP do Proxy (config dos Agents e alvo do Ansible). |
| `zabbix_agent_private_ips` | IPs dos Agents (inventário do Ansible). |
| `security_group_ids` | SGs criados (proxy/agent). |
| `ssh_key_name` | Chave SSH usada pelo AWX (credencial de máquina). |
| `zabbix_server_address` | Endereço do Server central para configurar o Proxy. |

Depois do `apply`, gere o kubeconfig com o comando do output `kubeconfig_command`
e siga para a instalação do AWX Operator (fora do escopo deste Terraform).
