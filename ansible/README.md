# Ansible — Zabbix Proxy + Agents (Linux + Windows)

Instala e configura, nas EC2s da POC: **1 Zabbix Proxy** (Amazon Linux 2023) e
os **Zabbix Agents** — **1 Linux** (SSH) e **1 Windows** (WinRM). Fluxo:
**agents → proxy → server**. Os agents apontam para o **proxy** (IP derivado do
inventário); o **proxy** aponta para o **Zabbix Server central** (`zabbix_server_address`).

## 1. Estrutura de pastas

```
ansible/
├── ansible.cfg                 # config padrão (inventário, roles, sem bastion)
├── requirements.yml            # collections (ansible.windows p/ o Windows)
├── inventories/poc/
│   ├── hosts.yml.example        # modelo do inventário (copie p/ hosts.yml)
│   └── group_vars/
│       ├── all.yml              # comuns (versão, server central, Server/ServerActive dos agents)
│       ├── proxy.yml            # conexão SSH + pacote/serviço/config do Proxy
│       ├── linux.yml            # conexão SSH + pacote/serviço/config do agent Linux
│       ├── windows.yml          # conexão WinRM + serviço/config do agent Windows
│       └── vault.yml.example    # modelo de variáveis sensíveis (PSK)
├── playbooks/
│   ├── configure-proxy.yml      # roda no grupo `proxy`  → role zabbix_proxy
│   ├── configure-linux.yml      # roda no grupo `linux`  → role zabbix_agent_linux
│   ├── configure-windows.yml    # roda no grupo `windows`→ role zabbix_agent_windows
│   ├── configure-all.yml        # proxy → linux → windows (ordem certa)
│   └── validate.yml             # serviço ativo + config presente (proxy + agents)
└── roles/
    ├── zabbix_proxy/           # dnf + template + systemd (restart on-change)
    ├── zabbix_agent_linux/     # dnf + template + systemd (restart on-change)
    └── zabbix_agent_windows/   # MSI + win_template + win_service (restart on-change)
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
| `windows-01` | `zabbix_agent_windows_private_ips` |

O inventário guarda **só nome + IP** (nada de usuário/senha/chave). O `hosts.yml`
real está no `.gitignore` — versiona-se só o `.example`.

## 3. Credenciais no AWX

As credenciais **não** ficam no repositório — são cadastradas no AWX:

- **Linux/Proxy → Machine Credential (SSH):** *Username* `ec2-user`, cole a **chave
  privada** do key pair das EC2s, *Privilege Escalation* = `sudo`. (Proxy e agent Linux
  usam a mesma.)
- **Windows → Machine Credential (WinRM):** *Username* `Administrator`, *Password* =
  output `windows_admin_password` do Terraform. Sem chave.

No Job Template, anexe a credencial do(s) grupo(s) que ele atinge (SSH para proxy/Linux,
WinRM para Windows, ou ambas no `configure-all`). Para TLS/PSK, use também um
**Vault Credential**.

## 4. Executar os playbooks

No AWX, crie um **Job Template** por playbook (Inventory + credencial), informando o
endereço do **Server central** (para o proxy) como extra-var/survey:
```yaml
zabbix_server_address: "<DNS do NLB do Zabbix Server>"
```
> Os **agents** não precisam disso: eles derivam o IP do **proxy** do inventário.

| Playbook | Faz |
|---|---|
| `configure-proxy.yml` | instala/configura o Zabbix Proxy (grupo `proxy`) |
| `configure-linux.yml` | instala/configura o agent no grupo `linux` |
| `configure-windows.yml` | instala/configura o agent no grupo `windows` |
| `configure-all.yml` | proxy → linux → windows (ordem certa) |
| `validate.yml` | serviço ativo + arquivo de config presente (proxy + agents) |

Localmente (precisa de rede privada/VPN até os IPs):
```bash
cd ansible
ansible-playbook playbooks/configure-all.yml \
  -e 'zabbix_server_address=zabbix.exemplo.interno' \
  --private-key ~/.ssh/poc.pem            # proxy + Linux (SSH)
# Windows local: passe -e 'ansible_password=...' (em produção use a Machine Credential)
ansible-playbook playbooks/validate.yml --private-key ~/.ssh/poc.pem
```

## 5. Alterar a versão do Zabbix

Mude **`zabbix_version`** em `group_vars/all.yml` (ex.: `"7.0"` → `"6.4"`). Isso
controla o repositório/pacote no Linux e a URL do MSI no Windows.

> No Windows, o MSI exige o **patch completo** (não há "latest"): ajuste também
> `zabbix_agent_windows_version` em `roles/zabbix_agent_windows/defaults/main.yml`
> (ex.: `"7.0.6"`), conforme o patch atual em
> <https://www.zabbix.com/download_agents>.

## 6. O que NÃO versionar

- **Chave SSH** e **senha do Windows** → Machine Credential do AWX (nunca em arquivo).
- **`hosts.yml`** real (IPs do ambiente) → use o `.example`.
- **`vault.yml`** real (PSK e afins) → criptografe com Ansible Vault / use Vault
  Credential no AWX.

Tudo isso já está no `.gitignore`.
