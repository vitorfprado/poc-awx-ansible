# Ansible — Zabbix Agents (Linux + Windows)

Instala e configura o **Zabbix Agent 2** em duas EC2s da POC: **1 Linux** (Amazon
Linux 2023, via SSH) e **1 Windows** (Windows Server 2022, via WinRM). Os agents
apontam para `zabbix_agent_server` / `zabbix_agent_server_active` (definidos em
`group_vars/all.yml`) — que pode ser o **Zabbix Proxy** ou o **Server**.

## 1. Estrutura de pastas

```
ansible/
├── ansible.cfg                 # config padrão (inventário, roles, sem bastion)
├── requirements.yml            # collections (ansible.windows p/ o Windows)
├── inventories/poc/
│   ├── hosts.yml.example        # modelo do inventário (copie p/ hosts.yml)
│   └── group_vars/
│       ├── all.yml              # comuns (versão, endereço do server, Server/ServerActive)
│       ├── linux.yml            # conexão SSH + pacote/serviço/config do Linux
│       ├── windows.yml          # conexão WinRM + serviço/config do Windows
│       └── vault.yml.example    # modelo de variáveis sensíveis (PSK)
├── playbooks/
│   ├── configure-linux.yml      # roda no grupo `linux`  → role zabbix_agent_linux
│   ├── configure-windows.yml    # roda no grupo `windows`→ role zabbix_agent_windows
│   ├── configure-all.yml        # Linux + Windows
│   └── validate.yml             # serviço ativo + config presente (Linux e Windows)
└── roles/
    ├── zabbix_agent_linux/      # dnf + template + systemd (restart on-change)
    └── zabbix_agent_windows/    # MSI + win_template + win_service (restart on-change)
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
| `linux-01` | `zabbix_agent_private_ips` |
| `windows-01` | `zabbix_agent_windows_private_ips` |

O inventário guarda **só nome + IP** (nada de usuário/senha/chave). O `hosts.yml`
real está no `.gitignore` — versiona-se só o `.example`.

## 3. Credenciais no AWX

As credenciais **não** ficam no repositório — são cadastradas no AWX:

- **Linux → Machine Credential (SSH):** *Username* `ec2-user`, cole a **chave privada**
  do key pair das EC2s, *Privilege Escalation* = `sudo`.
- **Windows → Machine Credential (WinRM):** *Username* `Administrator`, *Password* =
  output `windows_admin_password` do Terraform. Sem chave.

No Job Template, anexe a credencial do(s) grupo(s) que ele atinge (Linux, Windows, ou
ambas no `configure-all`). Para TLS/PSK, use também um **Vault Credential**.

## 4. Executar os playbooks

No AWX, crie um **Job Template** por playbook (Inventory + credencial), informando o
endereço do destino como extra-var/survey:
```yaml
zabbix_server_address: "<IP do Proxy ou DNS do NLB do Server>"
```

| Playbook | Faz |
|---|---|
| `configure-linux.yml` | instala/configura o agent no grupo `linux` |
| `configure-windows.yml` | instala/configura o agent no grupo `windows` |
| `configure-all.yml` | os dois acima |
| `validate.yml` | valida serviço ativo + arquivo de config presente (Linux e Windows) |

Localmente (precisa de rede privada/VPN até os IPs):
```bash
cd ansible
ansible-playbook playbooks/configure-all.yml \
  -e 'zabbix_server_address=10.0.48.10' \
  --private-key ~/.ssh/poc.pem            # Linux (SSH)
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
