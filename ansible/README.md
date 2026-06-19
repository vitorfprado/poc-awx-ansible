# Ansible — Zabbix Proxy + Agent (Linux), via AWX

Instala e configura, nas EC2s da POC: **1 Zabbix Proxy** e **1 Zabbix Agent**, ambos
em **Amazon Linux 2023** (acesso via SSH). Fluxo: **agent → proxy → server**. O agent
aponta para o **proxy**; o **proxy** aponta para o **Zabbix Server central**.

> A execução é feita **pelo AWX (GUI)**. O inventário e as variáveis ficam cadastrados
> no AWX (não há `inventories/` no repo). Este README é a **fonte da verdade** do que
> preencher no GUI.

## 1. Estrutura de pastas

```
ansible/
├── requirements.yml            # sem collections externas (Linux usa ansible.builtin)
├── playbooks/
│   ├── configure-proxy.yml      # roda no grupo `proxy` → role zabbix_proxy
│   ├── configure-linux.yml      # roda no grupo `linux` → role zabbix_agent_linux
│   ├── configure-all.yml        # proxy → linux (ordem certa)
│   └── validate.yml             # serviço ativo + config presente (proxy + agent)
└── roles/
    ├── zabbix_proxy/           # dnf + template + systemd (restart on-change)
    └── zabbix_agent_linux/     # dnf + template + systemd (restart on-change)
```

> O `ansible.cfg` da raiz do repositório define `roles_path = ansible/roles` (o AWX roda
> a partir da raiz do projeto sincronizado). Cada role tem `defaults/` (valores base),
> `handlers/` (restart só quando muda), `tasks/` (passos) e `templates/` (o `.conf`).
> A **versão do Zabbix é uma variável** (ver §4) — não há role por versão.

## 2. Inventário no AWX (GUI)

O AWX com inventário manual **não lê group_vars do repositório** — todas as variáveis
ficam no GUI. Crie um Inventory `zbx-poc` com os grupos `proxy` e `linux` e preencha as
variáveis em **três níveis** (do geral para o específico):

### Nível Inventory (geral/fixo)
```yaml
zabbix_version: "7.0"
zabbix_server_port: 10051
```

### Grupo `proxy`
```yaml
ansible_connection: ssh
ansible_user: ec2-user
ansible_python_interpreter: /usr/bin/python3
zabbix_server_address: "<DNS do NLB do Zabbix Server central>"
zabbix_proxy_package: zabbix-proxy-sqlite3
zabbix_proxy_service_name: zabbix-proxy
zabbix_proxy_config_path: /etc/zabbix/zabbix_proxy.conf
```
Host: `proxy-01` → `ansible_host: <IP privado do proxy>` (output `zabbix_proxy_private_ip`).

### Grupo `linux`
```yaml
ansible_connection: ssh
ansible_user: ec2-user
ansible_python_interpreter: /usr/bin/python3
zabbix_agent_server: "<IP privado do proxy>"
zabbix_agent_server_active: "<IP privado do proxy>"
zabbix_agent_package: zabbix-agent2
zabbix_agent_service_name: zabbix-agent2
zabbix_agent_config_path: /etc/zabbix/zabbix_agent2.conf
```
Host: `linux-01` → `ansible_host: <IP privado do agent>` (output `zabbix_agent_private_ips`).

> **Multiplos proxies:** cada grupo de agents aponta para o seu proxy via
> `zabbix_agent_server*` no group var daquele grupo — sem hardcode central.

## 3. Credenciais e Job Templates no AWX

- **Machine Credential (SSH):** *Username* `ec2-user`, cole a **chave privada** do key
  pair das EC2s, *Privilege Escalation* = `sudo`. (Proxy e agent usam a mesma.)
- **Job Templates** (Inventory `zbx-poc` + a Machine Credential):

| Template | Playbook | Faz |
|---|---|---|
| `zbx-configure-all` | `ansible/playbooks/configure-all.yml` | proxy → linux (ordem certa) |
| `zbx-validate` | `ansible/playbooks/validate.yml` | serviço ativo + config presente |

> Para TLS/PSK, habilite na role (`*_tls_enabled: true`) e cadastre um **Vault
> Credential** com a PSK.

## 4. Alterar a versão do Zabbix

Mude **`zabbix_version`** nas variáveis do Inventory (ex.: `"7.0"` → `"6.4"`). Isso
controla o repositório/pacote instalado no Linux.

## 5. O que NÃO versionar

- **Chave SSH** → Machine Credential do AWX (nunca em arquivo).
- **IPs e endereços do ambiente** → ficam no inventário do AWX (GUI), não no repo.

Chaves locais (`*.pem`, `*.key`) já estão no `.gitignore`.
