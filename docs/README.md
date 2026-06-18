# Documentação — POC awx-zabbix

Foco: **entender** a ideia e **usar/validar** a POC.

| Doc | Para quê |
|---|---|
| [como-funciona.md](como-funciona.md) | **Explicação detalhada** — arquitetura, como Ansible/proxy/agent/server se encaixam, cada configuração e o porquê (inclui Linux × Windows). |
| [passo-a-passo.md](passo-a-passo.md) | **Uso e validação** — acessar AWX e Zabbix (port-forward), configurar o AWX, rodar os playbooks, fazer os cadastros manuais e ver os dados fluindo. |
| [kubernetes-zabbix-server.md](kubernetes-zabbix-server.md) | Referência do Zabbix Server no cluster (manifests, NLB, acesso). |

Leitura sugerida: **como-funciona** (entender) → **passo-a-passo** (operar e validar).
