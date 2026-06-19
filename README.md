# poc-awx-ansible

POC de monitoramento: **AWX (em EKS) gerencia, via Ansible, Zabbix Proxy e Agent em
EC2 Linux**, com um **Zabbix Server no cluster** — fluxo completo
**agent → proxy → server → UI**.

```
   Agent Linux (EC2) ─► Zabbix Proxy (EC2) ─► Zabbix Server (EKS) ─► UI (port-forward)
                                                  ▲
                                        AWX (EKS) ┘  instala/configura proxy e agent via Ansible
```

## Estrutura do repositório

| Pasta | Conteúdo |
|---|---|
| [`iac/awx-zabbix-poc/`](iac/awx-zabbix-poc/) | Terraform (VPC, EKS, EC2s Linux, SGs). |
| [`kubernetes/`](kubernetes/) | Manifests: `awx/`, `addons/`, `zabbix-server/`. |
| [`ansible/`](ansible/) | Roles/playbooks/inventário (Proxy + Agent Linux). |
| [`docs/`](docs/) | Documentação (explicação + uso/validação). |

## Documentação

- 📖 **[Como funciona](docs/como-funciona.md)** — explicação detalhada (arquitetura
  e o porquê de cada configuração).
- 🛠️ **[Passo a passo de uso](docs/passo-a-passo.md)** — acessar AWX/Zabbix, rodar os
  playbooks, cadastrar e **validar** a ideia ponta a ponta.
- 📦 [Zabbix Server no cluster](docs/kubernetes-zabbix-server.md) — referência dos
  manifests/NLB.
