# Documentação — POC awx-zabbix

Toda a documentação da POC centralizada. Cada doc tem um ponteiro 📂 para o código
correspondente.

## Por camada

| Doc | Sobre |
|---|---|
| [terraform.md](terraform.md) | Consumer Terraform (VPC, EKS, EC2s, SGs) — `iac/awx-zabbix-poc/`. |
| [pipeline-awx-zabbix-poc.md](pipeline-awx-zabbix-poc.md) | Pipeline GitHub Actions (Stage 1 infra + Stage 2 bootstrap), OIDC, variables, destroy. |
| [kubernetes-addons.md](kubernetes-addons.md) | Addons de cluster (metrics-server) no Stage 2. |
| [kubernetes-awx.md](kubernetes-awx.md) | AWX Operator + AWX no EKS (Stage 2). |
| [kubernetes-zabbix-server.md](kubernetes-zabbix-server.md) | Zabbix Server no cluster (server + web + PostgreSQL, NLB interno). |
| [ansible.md](ansible.md) | Ansible (Zabbix Proxy/Agents) — referência rápida. |
| [ansible-guia.md](ansible-guia.md) | Ansible — **guia didático** (explica cada configuração). |
| [runbook-cadastro-manual.md](runbook-cadastro-manual.md) | **Passo a passo dos cadastros manuais** (AWX + UI do Zabbix). |

## Ordem sugerida de leitura

1. **[terraform.md](terraform.md)** — entender a infra.
2. **[pipeline-awx-zabbix-poc.md](pipeline-awx-zabbix-poc.md)** — como subir/destruir tudo.
3. **[kubernetes-awx.md](kubernetes-awx.md)** + **[kubernetes-zabbix-server.md](kubernetes-zabbix-server.md)** — o que roda no cluster.
4. **[ansible-guia.md](ansible-guia.md)** — como o Ansible configura Proxy/Agents.
5. **[runbook-cadastro-manual.md](runbook-cadastro-manual.md)** — fazer os cadastros à mão e ver o fluxo fim a fim.
