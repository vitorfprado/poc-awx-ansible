# poc-awx-ansible

POC de monitoramento com **AWX (em EKS) gerenciando, via Ansible, Zabbix Proxy e
Agents em EC2**, com um **Zabbix Server no cluster** — fluxo completo
**agent → proxy → server → UI**.

```
Terraform (infra)              Pipeline Stage 2 (cluster)            AWX/Ansible (config)        Você (manual)
  VPC, EKS, EC2s, SGs   ──►   metrics-server, AWX, Zabbix Server  ──►  instala/configura     ──►  cadastra proxy
                                                                       Proxy + Agents             e hosts na UI
```

## Estrutura do repositório

| Pasta | Conteúdo |
|---|---|
| [`iac/awx-zabbix-poc/`](iac/awx-zabbix-poc/) | Terraform (VPC, EKS, EC2s, SGs, backend S3). |
| [`kubernetes/`](kubernetes/) | Manifests do Stage 2: `awx/`, `addons/`, `zabbix-server/`. |
| [`ansible/`](ansible/) | Roles/playbooks/inventário do Zabbix (Proxy + Agents). |
| [`.github/workflows/`](.github/workflows/) | Pipeline manual (plan/apply/destroy + bootstrap). |
| [`docs/`](docs/) | **Toda a documentação** (ver índice abaixo). |

## Documentação

Comece por **[docs/](docs/README.md)** — índice com tudo. Atalhos:

- [Infra (Terraform)](docs/terraform.md) · [Pipeline](docs/pipeline-awx-zabbix-poc.md)
- [AWX no EKS](docs/kubernetes-awx.md) · [Zabbix Server no cluster](docs/kubernetes-zabbix-server.md) · [Addons](docs/kubernetes-addons.md)
- [Ansible — guia didático](docs/ansible-guia.md) · [Ansible — referência](docs/ansible.md)
- [Runbook de cadastros manuais](docs/runbook-cadastro-manual.md)

## Subir / destruir

Pela pipeline **Actions → "Terraform - awx-zabbix-poc" → Run workflow** (`plan` /
`apply` / `destroy`). Detalhes em [docs/pipeline-awx-zabbix-poc.md](docs/pipeline-awx-zabbix-poc.md).
