# Ansible — Zabbix Proxy & Agents (POC awx-zabbix)

> 📂 Código: [`ansible/`](../ansible/)

Playbooks/roles que o **AWX** usa para instalar e configurar **Zabbix Proxy** (1 EC2)
e **Zabbix Agent 2** (N EC2s) na POC. Os agents apontam para o **proxy**; o proxy
aponta para o **Zabbix Server central** (parametrizado).

> 📘 **Quer entender como tudo funciona (e o porquê de cada configuração)?**
> Veja o **[guia detalhado](ansible-guia.md)** — explicação didática, peça por peça.
> Este documento é a referência rápida (setup e comandos).

> O **Terraform não** instala/configura Zabbix — só cria a infra. Toda a
> instalação/configuração é feita aqui, via AWX/Ansible.

## Premissa de rede (VPN + SSH, sem bastion)

- O AWX precisa **alcançar as EC2s pelo IP privado** via SSH.
- **Produção:** essa conectividade vem por **VPN**.
- **Nesta POC:** tudo está na **mesma VPC**, então o AWX (pods no EKS) alcança as
  EC2s diretamente pelo IP privado (o SG das EC2s libera SSH a partir do SG do EKS).
- **Sem bastion/jump host:** não há `ProxyCommand` nem `ansible_ssh_common_args`.

## Estrutura

```
ansible/
├── ansible.cfg
├── requirements.yml
├── inventories/poc/
│   ├── hosts.yml.example         # modelo do inventário (copie p/ hosts.yml)
│   └── group_vars/
│       ├── all.yml               # conexão + variáveis comuns
│       ├── zabbix_proxy.yml      # grupo do proxy
│       ├── zabbix_agents.yml     # grupo dos agents (deriva IP do proxy)
│       └── vault.yml.example     # variáveis sensíveis (PSK) — modelo
├── playbooks/
│   ├── install-zabbix-proxy.yml  # só zabbix_proxy
│   ├── install-zabbix-agents.yml # só zabbix_agents
│   ├── configure-all.yml         # proxy e depois agents
│   └── validate.yml              # serviços, portas e conectividade
└── roles/
    ├── zabbix_proxy/             # defaults, handlers, tasks, template .conf
    └── zabbix_agent/             # defaults, handlers, tasks, template .conf
```

> `hosts.yml` e `vault.yml` **reais** estão no `.gitignore` — versione só os `.example`.

## Variáveis

### Obrigatórias (preencher)

| Variável | Onde | Origem |
|---|---|---|
| `ansible_host` (por host) | `inventories/poc/hosts.yml` | Outputs do Terraform (IPs privados) |
| `zabbix_server_address` | `group_vars/all.yml` ou vault/extra-vars | DNS do **NLB interno** do Zabbix Server (publicado no *Summary* do Stage 2) |

### Sensíveis (NÃO versionar — usar Vault/AWX)

| Variável | Uso |
|---|---|
| `vault_zabbix_proxy_psk` / `_identity` | PSK do proxy (se `zabbix_tls_enabled: true`) |
| `vault_zabbix_agent_psk` / `_identity` | PSK dos agents (se TLS habilitado) |
| `vault_zabbix_server_address` | Endereço do Server (opcional manter no vault) |
| **Chave SSH** | **Nunca** em arquivo — Machine Credential do AWX |

### Principais parametrizáveis (com default)

- Conexão: `ansible_user` (`ec2-user`), `ansible_port` (`22`), `ansible_python_interpreter`.
- Zabbix: `zabbix_version` (`7.0`), `zabbix_server_port` (`10051`), `zabbix_tls_enabled` (`false`).
- Proxy: `zabbix_proxy_mode`, `zabbix_proxy_database` (`sqlite3`), `*cache_size*`,
  `zabbix_proxy_timeout`, `zabbix_proxy_offline_buffer`, `zabbix_proxy_listen_port`.
- Agent: `zabbix_agent_hostname`, `zabbix_agent_server[_active]` (derivam do proxy),
  `zabbix_agent_host_metadata`, `zabbix_agent_listen_port`.

## Como adicionar mais agents

1. Acrescente o host no grupo `zabbix_agents` do `hosts.yml`:
   ```yaml
   agent-03:
     ansible_host: "10.0.64.23"   # IP privado da nova EC2 (output do Terraform)
   ```
2. (Terraform) aumente `agent_count` e aplique para criar a EC2.
3. Rode `install-zabbix-agents.yml` (ou o Job Template correspondente).

Nada mais muda: o agent novo herda os `group_vars`, deriva o IP do proxy
automaticamente e é configurado igual aos demais.

## Preencher o inventário com os outputs do Terraform

Do `terraform output` (consumer `iac/awx-zabbix-poc`):

| Output do Terraform | Vai para |
|---|---|
| `zabbix_proxy_private_ip` | `proxy-01.ansible_host` |
| `zabbix_agent_private_ips` (map) | `agent-01/02/...ansible_host` |
| `ssh_key_name` | Machine Credential do AWX (a chave em si, não o nome) |
| usuário SSH | `ansible_user` / Machine Credential (`ec2-user` no AL2023) |
| porta SSH (se ≠ 22) | `ansible_port` / `zbx_ssh_port` |

## Execução LOCAL (opcional)

```bash
cd ansible
cp inventories/poc/hosts.yml.example inventories/poc/hosts.yml
# edite os ansible_host com os IPs privados

# (opcional) segredos:
cp inventories/poc/group_vars/vault.yml.example inventories/poc/group_vars/vault.yml
ansible-vault encrypt inventories/poc/group_vars/vault.yml

# conectividade: precisa estar na VPN/VPC (alcançar os IPs privados)
ansible-playbook playbooks/configure-all.yml \
  --private-key ~/.ssh/poc.pem \
  --ask-vault-pass            # só se usar vault

ansible-playbook playbooks/validate.yml --private-key ~/.ssh/poc.pem
```

> A chave (`--private-key`) é **opcional e só para uso local**; não é referenciada
> em arquivo versionado.

## Execução via AWX

### 1. Project
- **SCM Type:** Git, apontando para este repositório.
- **Base Path / Playbook Directory:** os Job Templates usam playbooks em
  `ansible/playbooks/`.
- Em *Project*, opcionalmente habilite o sync das collections (`requirements.yml`).

### 2. Inventory
- Crie um **Inventory** e importe/escreva os grupos `zabbix_proxy` e `zabbix_agents`
  com os hosts e seus `ansible_host` (IPs privados). Pode-se:
  - usar este `inventories/poc/hosts.yml` como **Sourced from a Project**, ou
  - cadastrar os hosts/grupos manualmente na UI do AWX.
- Mantenha no inventário **apenas dados não sensíveis** (hostname lógico + IP privado).

### 3. Machine Credential (SSH) — chave de forma segura
- Crie uma **Credential do tipo "Machine"**:
  - **Username:** `ec2-user` (AL2023).
  - **SSH Private Key:** cole a chave privada correspondente ao key pair usado nas
    EC2s (`ssh_key_name` do Terraform). O AWX **armazena criptografada** e injeta em
    runtime — **não** fica em arquivo no pod nem no repositório.
  - **Privilege Escalation:** `sudo` (os playbooks usam `become: true`).
- Associe essa credencial aos Job Templates.

### 4. Vault Credential (se usar TLS/PSK ou segredos)
- Crie uma **Credential do tipo "Vault"** com a senha do Ansible Vault, **ou**
  cadastre os `vault_*` como variáveis de um Custom Credential / extra-vars
  protegidas. Nunca comite o `vault.yml` descriptografado.

### 5. Job Templates (ordem recomendada)
| Template | Playbook | Quando |
|---|---|---|
| `zbx-proxy-install` | `playbooks/install-zabbix-proxy.yml` | 1º |
| `zbx-agents-install` | `playbooks/install-zabbix-agents.yml` | 2º |
| `zbx-configure-all` | `playbooks/configure-all.yml` | alternativa aos 2 acima (faz proxy → agents) |
| `zbx-validate` | `playbooks/validate.yml` | após instalar |

- Em cada Job Template: selecione o **Inventory**, a **Machine Credential** e (se
  aplicável) a **Vault Credential**.
- Informe `zabbix_server_address` via **extra-vars/survey** do template (ou pelo
  vault), em vez de hardcode.

### Premissa de rede no AWX
- Os pods do AWX (no EKS) precisam **alcançar os IPs privados** das EC2s. Nesta POC
  isso funciona por estarem na **mesma VPC** (o SG das EC2s libera SSH a partir do
  SG do EKS). Em produção, a mesma role seria atendida por **VPN**.

## Como validar que o AWX consegue acessar as EC2s via SSH

1. **Ad-hoc ping** (Job Template ou ad-hoc command no AWX):
   ```bash
   ansible all -m ansible.builtin.ping
   ```
   `pong` em todos os hosts = SSH + Python OK.
2. **Rode `zbx-validate`** (`playbooks/validate.yml`): confere serviços, portas
   (10051 no proxy, 10050 nos agents) e conectividade agent → proxy e proxy → server.
3. Se falhar a conexão, verifique:
   - o **IP privado** no inventário (output do Terraform);
   - a **Machine Credential** (usuário `ec2-user` + chave certa);
   - o **SG** das EC2s libera SSH a partir do SG do EKS;
   - que o AWX está na **mesma VPC** (POC) ou com **VPN** (produção).

## Notas

- **Banco do proxy:** SQLite (`zabbix-proxy-sqlite3`). O schema é criado
  automaticamente na 1ª inicialização — sem import manual.
- **Repositório Zabbix:** instalado via RPM oficial para Amazon Linux 2023
  (`zabbix_repo_rpm_url`). Se a versão mudar, ajuste essa variável conferindo o
  caminho em <https://repo.zabbix.com>.
- **Idempotência:** os serviços só reiniciam quando a config muda (handlers).
