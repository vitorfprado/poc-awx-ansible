# Pipeline Terraform — awx-zabbix-poc

Pipeline **manual/sob demanda** (GitHub Actions) para gerenciar o ciclo de vida da
infraestrutura da POC: `plan`, `apply` e `destroy`.

- **Workflow:** [`.github/workflows/terraform-awx-zabbix-poc.yml`](../.github/workflows/terraform-awx-zabbix-poc.yml)
- **Working directory:** `iac/awx-zabbix-poc`

> **Nota sobre o caminho:** o pedido original mencionava `terraform/consumers/awx-zabbix-poc`,
> mas o consumer foi mantido em `iac/awx-zabbix-poc`. A pipeline aponta para esse caminho.

## Como funciona

- **Só roda manualmente** (`workflow_dispatch`). Não há trigger de `push`/`pull_request`,
  então **nenhum `apply` ou `destroy` acontece automaticamente**.
- Parâmetro de entrada **`action`**: `plan` | `apply` | `destroy`.
- Em **toda** execução roda, nesta ordem: `terraform fmt -check` → `init` →
  `validate` → `plan`.
- `apply` e `destroy` aplicam o **plano salvo** (`tfplan`) gerado no passo `plan`
  da mesma execução (consistência entre o que foi revisado e o que é aplicado).
- `destroy` exige um campo de confirmação extra e emite banners/avisos bem visíveis.
- O **state fica em S3** (backend remoto), para que um `destroy` posterior encontre
  os recursos de um `apply` anterior.
- A autenticação na AWS é via **OIDC** (sem access keys estáticas): o job assume uma
  IAM role usando o token de identidade emitido pelo GitHub.

## Pré-requisitos (uma única vez)

1. **Bucket S3 para o state** já existente na conta AWS (ex.: `meu-bucket-tfstate`).
   O locking usa o recurso nativo do S3 (`use_lockfile`), sem necessidade de DynamoDB.
2. **OIDC configurado na AWS** (ver abaixo) com uma IAM role para a pipeline assumir.

## Autenticação via OIDC (sem access keys)

Configure uma vez na conta AWS:

1. **Identity provider OIDC** para o GitHub Actions:
   - URL: `https://token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`

   ```bash
   aws iam create-open-id-connect-provider \
     --url https://token.actions.githubusercontent.com \
     --client-id-list sts.amazonaws.com
   ```

2. **IAM role** com trust policy restrita a este repositório. Exemplo de trust
   policy (ajuste `ACCOUNT_ID` e `OWNER/REPO`):

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Principal": {
           "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
         },
         "Action": "sts:AssumeRoleWithWebIdentity",
         "Condition": {
           "StringEquals": {
             "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
           },
           "StringLike": {
             "token.actions.githubusercontent.com:sub": "repo:OWNER/REPO:*"
           }
         }
       }
     ]
   }
   ```

   > Para restringir ainda mais, troque o `sub` por algo como
   > `repo:OWNER/REPO:ref:refs/heads/main` ou `repo:OWNER/REPO:environment:NOME`.

3. **Permissões** da role: suficientes para criar/destruir VPC, EKS, EC2, IAM e
   acessar o bucket S3 do state. Para a POC pode-se usar uma policy ampla; em
   ambientes reais, restrinja ao mínimo necessário.

4. Copie o **ARN da role** para a variable `AWS_OIDC_ROLE_ARN` (abaixo).

> No workflow, isso depende de `permissions: id-token: write` (já configurado) e do
> step `aws-actions/configure-aws-credentials` com `role-to-assume`.

## Variables a cadastrar

Em **Settings → Secrets and variables → Actions → Variables**. Com OIDC, **não há
secrets de access key** — apenas variables:

| Variable | Obrigatório | Descrição |
|---|---|---|
| `AWS_OIDC_ROLE_ARN` | Sim | ARN da IAM role que a pipeline assume via OIDC. |
| `TF_STATE_BUCKET` | Opcional | Nome do bucket S3 do state. Default no workflow: `tfstate-awx-zabbix-poc-650687537445`. |
| `AWS_REGION` | Opcional | Região AWS. Default `us-east-1`. |
| `SSH_KEY_NAME` | Opcional | Key pair EC2 existente. Sem ela, acesso só via SSM. |
| `ZABBIX_SERVER_ADDRESS` | Opcional | Endereço do Zabbix Server central. |
| `ZABBIX_SERVER_CIDR` | Opcional | CIDR do Server central (regra de egress do Proxy). |
| `AGENT_COUNT` | Opcional | Quantidade de Zabbix Agents. Default `2`. |

As variables definidas são transformadas em um `ci.auto.tfvars` em tempo de execução;
as não definidas mantêm os defaults do consumer.

## Como executar

Vá em **Actions → "Terraform - awx-zabbix-poc" → Run workflow** e escolha o `action`.

### plan
1. `action` = `plan`.
2. **Run workflow**.
3. Revise a saída do passo *Terraform plan*. Nada é alterado na AWS.

### apply
1. `action` = `apply`.
2. **Run workflow**.
3. O job roda `fmt/init/validate/plan` e então `terraform apply tfplan`.
4. Ao final, o **Summary** do run mostra os outputs úteis (cluster EKS, IP do Proxy,
   IPs dos Agents e o comando de kubeconfig).

### destroy
1. `action` = `destroy`.
2. No campo **`confirm_destroy`**, digite exatamente `destroy`.
3. **Run workflow**.
4. O job exibe banners de DESTRUIÇÃO, gera um `plan -destroy` e aplica.

> Sem `confirm_destroy == "destroy"`, o job **falha logo no início**, antes de tocar
> em qualquer recurso.

## Cuidados antes de destruir

- **Confirme a conta/região AWS** alvo — o destroy remove tudo: VPC, EKS (cluster +
  nodes), EC2 do Proxy, EC2s dos Agents, SGs e IAM da POC.
- Garanta que **nada importante** (AWX, dados, configs feitas manualmente no cluster
  ou nas EC2s) precisa ser preservado — não há backup automático.
- Recursos criados **fora do Terraform** dentro dessa infra (ex.: LoadBalancers do AWX,
  volumes provisionados pelo Kubernetes) podem **bloquear** o destroy ou ficar órfãos.
  Remova-os antes (desinstale o AWX/serviços) se existirem.
- Confirme que **ninguém mais** está usando o ambiente.
- Rode um `action=destroy` e **leia o plano de destruição** nos logs antes de considerar
  o ambiente realmente encerrado.

## Outputs exibidos após o apply

No **Summary** do run de `apply`:

- Nome do cluster EKS (`eks_cluster_name`);
- Comando para atualizar o kubeconfig (`kubeconfig_command`);
- IP privado do Zabbix Proxy (`zabbix_proxy_private_ip`);
- IPs privados dos Zabbix Agents (`zabbix_agent_private_ips`).

Esses valores alimentam a etapa seguinte (instalação do AWX e execução dos playbooks
Ansible), que **não** faz parte desta pipeline.
