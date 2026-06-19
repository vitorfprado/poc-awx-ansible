# Ansible — Zabbix Proxy + Agent (Linux)

Instala e configura, nas EC2s da POC: **1 Zabbix Proxy** e **1 Zabbix Agent**, ambos
em **Amazon Linux 2023** (acesso via SSH). Fluxo: **agent → proxy → server**. O agent
aponta para o **proxy** (IP derivado do inventário); o **proxy** aponta para o
**Zabbix Server central** (`zabbix_server_address`).

## 1. Estrutura de pastas

```
ansible/
├── ansible.cfg                 # config padrão (inventário, roles, sem bastion)
├── requirements.yml            # sem collections externas (Linux usa ansible.builtin)
├── inventories/poc/
│   ├── hosts.yml.example        # modelo do inventário (copie p/ hosts.yml)
│   └── group_vars/
│       ├── all.yml              # comuns (versão, server central, Server/ServerActive do agent)
│       ├── proxy.yml            # conexão SSH + pacote/serviço/config do Proxy
│       ├── linux.yml            # conexão SSH + pacote/serviço/config do agent Linux
│       └── vault.yml.example    # modelo de variáveis sensíveis (PSK)
├── playbooks/
│   ├── configure-proxy.yml      # roda no grupo `proxy` → role zabbix_proxy
│   ├── configure-linux.yml      # roda no grupo `linux` → role zabbix_agent_linux
│   ├── configure-all.yml        # proxy → linux (ordem certa)
│   └── validate.yml             # serviço ativo + config presente (proxy + agent)
└── roles/
    ├── zabbix_proxy/           # dnf + template + systemd (restart on-change)
    └── zabbix_agent_linux/     # dnf + template + systemd (restart on-change)
```

Cada role tem `defaults/` (valores base), `handlers/` (restart só quando muda),
`tasks/` (passos) e `templates/` (o `.conf`). A **versão do Zabbix é uma variável**
(ver §5) — não há role por versão.

## 2. Preencher `hosts.yml` a partir dos IPs das EC2s

```bash
cp inventories/poc/hosts.yml.example inventories/poc/hosts.yml
```
Preencha os `ansible_host` com os **IPs privados** (outputs do Terraform):

| Host no inventário | IP (output do Terraform) |
|---|---|
| `proxy-01` | `zabbix_proxy_private_ip` |
| `linux-01` | `zabbix_agent_private_ips` |

O inventário guarda **só nome + IP** (nada de usuário/senha/chave). O `hosts.yml`
real está no `.gitignore` — versiona-se só o `.example`.

## 3. Credenciais no AWX

A credencial **não** fica no repositório — é cadastrada no AWX:

- **Linux/Proxy → Machine Credential (SSH):** *Username* `ec2-user`, cole a **chave
  privada** do key pair das EC2s, *Privilege Escalation* = `sudo`. (Proxy e agent Linux
  usam a mesma.)

No Job Template, anexe essa credencial SSH. Para TLS/PSK, use também um
**Vault Credential**.

## 4. Executar os playbooks

No AWX, crie um **Job Template** por playbook (Inventory + credencial SSH), informando o
endereço do **Server central** (para o proxy) como extra-var/survey:
```yaml
zabbix_server_address: "<DNS do NLB do Zabbix Server>"
```
> O **agent** não precisa disso: ele deriva o IP do **proxy** do inventário.

| Playbook | Faz |
|---|---|
| `configure-proxy.yml` | instala/configura o Zabbix Proxy (grupo `proxy`) |
| `configure-linux.yml` | instala/configura o agent no grupo `linux` |
| `configure-all.yml` | proxy → linux (ordem certa) |
| `validate.yml` | serviço ativo + arquivo de config presente (proxy + agent) |

Localmente (precisa de rede privada/VPN até os IPs):
```bash
cd ansible
ansible-playbook playbooks/configure-all.yml \
  -e 'zabbix_server_address=zabbix.exemplo.interno' \
  --private-key ~/.ssh/poc.pem
ansible-playbook playbooks/validate.yml --private-key ~/.ssh/poc.pem
```

## 5. Alterar a versão do Zabbix

Mude **`zabbix_version`** em `group_vars/all.yml` (ex.: `"7.0"` → `"6.4"`). Isso
controla o repositório/pacote instalado no Linux.

## 6. O que NÃO versionar

- **Chave SSH** → Machine Credential do AWX (nunca em arquivo).
- **`hosts.yml`** real (IPs do ambiente) → use o `.example`.
- **`vault.yml`** real (PSK e afins) → criptografe com Ansible Vault / use Vault
  Credential no AWX.

Tudo isso já está no `.gitignore`.
