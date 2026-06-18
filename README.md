# poc-awx-ansible

POC de monitoramento: **AWX (em EKS) gerencia, via Ansible, Zabbix Proxy e Agents em
EC2** (1 Linux + 1 Windows), com um **Zabbix Server no cluster** — fluxo completo
**agent → proxy → server → UI**.

```
   Agent Linux  ┐
                ├─► Zabbix Proxy (EC2) ─► Zabbix Server (EKS) ─► UI (port-forward)
   Agent Windows┘                          ▲
                                  AWX (EKS) ┘  instala/configura proxy e agents via Ansible
```

## Estrutura do repositório

| Pasta | Conteúdo |
|---|---|
| [`iac/awx-zabbix-poc/`](iac/awx-zabbix-poc/) | Terraform (VPC, EKS, EC2s Linux/Windows, SGs). |
| [`kubernetes/`](kubernetes/) | Manifests: `awx/`, `addons/`, `zabbix-server/`. |
| [`ansible/`](ansible/) | Roles/playbooks/inventário (Proxy + Agents Linux e Windows). |
| [`docs/`](docs/) | Documentação (explicação + uso/validação). |

## Documentação

- 📖 **[Como funciona](docs/como-funciona.md)** — explicação detalhada (arquitetura,
  cada configuração, Linux × Windows).
- 🛠️ **[Passo a passo de uso](docs/passo-a-passo.md)** — acessar AWX/Zabbix, rodar os
  playbooks, cadastrar e **validar** a ideia ponta a ponta.
- 📦 [Zabbix Server no cluster](docs/kubernetes-zabbix-server.md) — referência dos
  manifests/NLB.
