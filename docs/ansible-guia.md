# Guia detalhado — Ansible da POC Zabbix (Proxy + Agents)

> 📂 Código: [`ansible/`](../ansible/)

Guia **didático** de como esta configuração Ansible funciona: o modelo mental, o
papel de **cada arquivo**, a explicação de **cada configuração/variável** e um
**passo a passo** de uso (local e via AWX).

> Procurando só o "como fazer" rápido? Veja a [referência rápida](ansible.md). Este
> guia é o aprofundamento — explica o **porquê** de cada peça.

## Sumário

1. [Conceitos rápidos](#1-conceitos-rápidos)
2. [O modelo mental (como as peças se encaixam)](#2-o-modelo-mental)
3. [Fluxo de uma execução, do início ao fim](#3-fluxo-de-uma-execução)
4. [`ansible.cfg` — comportamento padrão](#4-ansiblecfg)
5. [`requirements.yml` — dependências](#5-requirementsyml)
6. [Inventário — quem são os hosts](#6-inventário)
7. [`group_vars` — variáveis por grupo](#7-group_vars)
8. [As roles — o trabalho de verdade](#8-as-roles)
9. [Os templates `.conf.j2` — a configuração do Zabbix](#9-os-templates)
10. [Os playbooks — o que roda em quê](#10-os-playbooks)
11. [Precedência de variáveis (importante!)](#11-precedência-de-variáveis)
12. [Modelo de segurança](#12-modelo-de-segurança)
13. [Passo a passo: execução LOCAL](#13-passo-a-passo-local)
14. [Passo a passo: execução via AWX](#14-passo-a-passo-awx)
15. [Como adicionar mais agents](#15-como-adicionar-mais-agents)
16. [Glossário](#16-glossário)

---

## 1. Conceitos rápidos

- **Ansible** descreve o **estado desejado** dos servidores (em YAML) e o aplica via
  SSH. É **idempotente**: rodar duas vezes não muda nada se já estiver no estado certo.
- **AWX** é a interface/orquestrador (rodando no EKS) que executa estes playbooks. Ele
  guarda inventário e credenciais e roda os jobs — é o "Ansible como serviço".
- **Arquitetura monitorada:**
  - **Zabbix Agent** roda em cada EC2 monitorada e coleta métricas.
  - **Zabbix Proxy** fica no meio: os agents falam com o **proxy** (não direto com o
    servidor), e o proxy concentra e repassa tudo ao **Zabbix Server central**.
  - Vantagem do proxy: reduz conexões ao servidor central e funciona como ponto único
    de saída do "lado do cliente".

```
[ Agent EC2 ] ─┐
[ Agent EC2 ] ─┼──> [ Zabbix Proxy EC2 ] ──> [ Zabbix Server central ]
[ Agent EC2 ] ─┘        (10051)                     (10051, parametrizado)
   (10050)
```

---

## 2. O modelo mental

Ansible tem 5 tipos de peça. Entender o papel de cada uma é entender tudo:

| Peça | Pergunta que responde | Aqui é... |
|---|---|---|
| **Inventário** | *Em quais máquinas?* | `inventories/poc/hosts.yml` (grupos `zabbix_proxy`, `zabbix_agents`) |
| **Variáveis** | *Com quais valores?* | `group_vars/*` + `defaults/` das roles + vault |
| **Playbook** | *O que fazer e onde?* | `playbooks/*.yml` (liga grupo → role) |
| **Role** | *Como fazer (passos)?* | `roles/zabbix_proxy`, `roles/zabbix_agent` |
| **Template** | *Como fica o arquivo de config?* | `templates/*.conf.j2` |

A regra de ouro: **a role é genérica e reutilizável; os valores específicos vêm de
fora** (inventário, group_vars, vault, AWX). Por isso a role não tem IP/senha dentro.

---

## 3. Fluxo de uma execução

Quando você roda `configure-all.yml`:

```
configure-all.yml
   │  (import na ordem certa)
   ├─ install-zabbix-proxy.yml   → hosts: zabbix_proxy  → role zabbix_proxy
   │      └─ instala pacote, gera /etc/zabbix/zabbix_proxy.conf, inicia serviço
   └─ install-zabbix-agents.yml  → hosts: zabbix_agents → role zabbix_agent
          └─ instala agent2, gera /etc/zabbix/zabbix_agent2.conf apontando p/ o proxy
```

Para **cada host**, o Ansible:
1. monta as variáveis (juntando defaults da role + group_vars + vault + extra-vars);
2. conecta por SSH (usuário/porta/chave);
3. executa as tasks da role em ordem;
4. ao final, se algum arquivo de config mudou, dispara o **handler** de restart.

---

## 4. `ansible.cfg`

Define o comportamento padrão do Ansible **em execução local** (no AWX, a plataforma
controla isso). Linha a linha:

```ini
[defaults]
inventory = inventories/poc/hosts.yml   # inventário usado por padrão
roles_path = roles                       # onde achar as roles
host_key_checking = False                # não pede para confirmar fingerprint SSH de host novo
retry_files_enabled = False              # não cria arquivos .retry ao falhar
interpreter_python = auto_silent         # acha o python3 do host sem avisos
stdout_callback = yaml                   # saída legível (YAML) em vez de JSON cru
forks = 10                               # até 10 hosts em paralelo

[ssh_connection]
pipelining = True                        # menos conexões SSH por task = mais rápido
```

- **`host_key_checking = False`**: conveniente para uma POC com hosts efêmeros (IPs
  novos a cada `apply`). Em produção, prefira gerenciar `known_hosts`.
- **Sem bastion de propósito:** não há `ProxyCommand` nem `ansible_ssh_common_args`. A
  premissa é que a rede privada já existe — via **VPN** (produção) ou pela **mesma
  VPC** (esta POC). Era um requisito explícito.

---

## 5. `requirements.yml`

Lista as **collections** (pacotes de módulos) necessárias. No AWX, a Execution
Environment precisa contê-las (ou o Project as sincroniza a partir deste arquivo).

```yaml
collections:
  - name: ansible.posix       # utilitários POSIX
  - name: community.general   # módulos diversos
  # - community.zabbix        # (opcional) gestão via API do Zabbix Server
```

As roles desta POC usam só módulos **`ansible.builtin`** (dnf, file, template,
systemd, command). As collections acima ficam declaradas para utilidades e
crescimento futuro. `community.zabbix` está comentada: serviria para gerenciar o
**Server** (criar hosts/templates via API), o que está fora do escopo da POC.

---

## 6. Inventário

`inventories/poc/hosts.yml` diz **quais máquinas** existem e **como agrupá-las**:

```yaml
all:
  children:
    zabbix_proxy:                 # grupo
      hosts:
        proxy-01:                 # nome lógico (não precisa ser o hostname real)
          ansible_host: "10.0.48.10"   # IP privado real (alvo do SSH)
    zabbix_agents:
      hosts:
        agent-01: { ansible_host: "10.0.48.21" }
        agent-02: { ansible_host: "10.0.64.22" }
```

- **`all` → `children` → grupos → `hosts`**: hierarquia padrão do Ansible. Os nomes de
  grupo (`zabbix_proxy`, `zabbix_agents`) são o que os playbooks miram em `hosts:`.
- **`proxy-01` é um nome lógico**; o que importa para conectar é o **`ansible_host`**
  (o IP privado). Assim o nome lógico pode virar o `Hostname` do Zabbix sem depender do
  DNS do host.
- **Só dados não sensíveis** aqui (nome + IP). Usuário/porta/chave ficam em `group_vars`
  (defaults) e, no AWX, na Machine Credential.
- **Crescer é trivial:** some um `agent-03: { ansible_host: ... }`. Nada mais muda.

> O `hosts.yml` real está no `.gitignore` (é preenchido com os IPs do Terraform).
> Versionamos só o `hosts.yml.example`.

---

## 7. `group_vars`

Variáveis aplicadas a **todos os hosts de um grupo**. O nome do arquivo = nome do grupo
(`all` = todos).

### `group_vars/all.yml` — conexão + comum a tudo

```yaml
ansible_user: "{{ zbx_ssh_user | default('ec2-user') }}"
ansible_port: "{{ zbx_ssh_port | default(22) }}"
ansible_python_interpreter: /usr/bin/python3
zabbix_version: "7.0"
zabbix_server_address: "{{ vault_zabbix_server_address | default('CHANGE_ME_zabbix_server') }}"
zabbix_server_port: 10051
zabbix_tls_enabled: false
```

- **`ansible_user/port`**: dados de conexão SSH. O padrão `ec2-user` é o usuário do
  Amazon Linux 2023. O padrão `22` é a porta. O padrão `interpreter_python` evita o
  Ansible "adivinhar" o Python e gerar avisos.
- **Padrão `{{ x | default('...') }}`**: significa "use `x` se existir; senão, este
  valor". Permite **sobrescrever por extra-vars** (`-e zbx_ssh_user=...`) sem editar o
  arquivo. É a forma de parametrizar sem hardcode.
- **`zabbix_server_address`**: o endereço do Server central — **parametrizado**. Vem do
  vault, ou de extra-vars do AWX. O placeholder `CHANGE_ME_zabbix_server` deixa óbvio
  que precisa ser preenchido (e o `validate.yml` o ignora se não for trocado).
- **`zabbix_tls_enabled`**: liga/desliga TLS-PSK em proxy e agents de uma vez.

> **Atenção à conexão no AWX:** quando você usa uma **Machine Credential**, o AWX já
> fornece usuário e chave. Como `ansible_user` definido em group_vars tem **precedência
> alta**, mantenha o usuário da credencial igual ao default (`ec2-user`) para não haver
> conflito — ou remova `ansible_user` daqui se quiser que a credencial mande sozinha.

### `group_vars/zabbix_proxy.yml` — o grupo do proxy

```yaml
zabbix_proxy_hostname: "{{ inventory_hostname }}"   # = "proxy-01" (nome no inventário)
zabbix_proxy_mode: 0                                 # 0=active, 1=passive
zabbix_proxy_database: sqlite3
zabbix_proxy_tls_enabled: "{{ zabbix_tls_enabled }}"
zabbix_proxy_tls_psk_identity: "{{ vault_zabbix_proxy_psk_identity | default('') }}"
zabbix_proxy_tls_psk: "{{ vault_zabbix_proxy_psk | default('') }}"
```

- **`inventory_hostname`** é uma variável mágica do Ansible = o nome lógico do host
  (`proxy-01`). Usá-lo como `Hostname` garante que o nome do proxy bate com o que você
  cadastra no Zabbix Server (requisito da POC).
- **`zabbix_proxy_mode: 0` (active)**: o proxy **conecta** no Server e envia dados. No
  modo passivo (1) seria o Server que conecta no proxy. Active é o mais comum para
  "lado do cliente" atrás de NAT/VPN.
- **PSK vem do vault** (`vault_*`), nunca do código.

### `group_vars/zabbix_agents.yml` — o grupo dos agents (a parte mais "esperta")

```yaml
zabbix_proxy_private_ip: "{{ hostvars[groups['zabbix_proxy'][0]].ansible_host }}"
zabbix_agent_hostname: "{{ inventory_hostname }}"
zabbix_agent_server: "{{ zabbix_proxy_private_ip }}"
zabbix_agent_server_active: "{{ zabbix_proxy_private_ip }}"
zabbix_agent_host_metadata: "poc-zabbix-agent"
```

A linha-chave:

```yaml
zabbix_proxy_private_ip: "{{ hostvars[groups['zabbix_proxy'][0]].ansible_host }}"
```

Lendo de dentro para fora:
- **`groups['zabbix_proxy']`** = lista dos hosts do grupo proxy → `['proxy-01']`.
- **`[0]`** = o primeiro → `'proxy-01'`.
- **`hostvars['proxy-01']`** = todas as variáveis daquele host.
- **`.ansible_host`** = o IP privado do proxy.

Ou seja: **o agent descobre o IP do proxy lendo o próprio inventário** — sem hardcode.
Se o IP do proxy mudar, ou você trocar o proxy, **nada nos agents precisa ser editado**.

- **`Server` vs `ServerActive`**: ambos apontam para o proxy.
  - `Server` (checks **passivos**): o proxy conecta no agent (porta 10050) e pergunta.
  - `ServerActive` (checks **ativos**): o agent conecta no proxy (porta 10051) e envia.
- **`HostMetadata`**: rótulo opcional usado em autoregistro no Zabbix.

### `vault.yml.example` — segredos

Modelo das variáveis **sensíveis** (PSK, opcionalmente o endereço do server). O
`vault.yml` real é **criptografado** com Ansible Vault e está no `.gitignore`. No AWX,
vira um **Vault Credential**. Detalhes na [seção 12](#12-modelo-de-segurança).

---

## 8. As roles

Cada role tem 4 partes: `defaults/` (valores padrão), `tasks/` (passos), `handlers/`
(ações sob demanda) e `templates/` (arquivos gerados).

### `defaults/main.yml`

É a **base de menor precedência**: a role funciona sozinha com esses valores, e
qualquer `group_vars`/extra-var os sobrescreve. Aqui ficam nome do pacote, serviço,
caminhos, portas, tamanhos de cache, etc. Exemplos do proxy:

```yaml
zabbix_proxy_package: zabbix-proxy-sqlite3
zabbix_proxy_service: zabbix-proxy
zabbix_proxy_db_path: /var/lib/zabbix/zabbix_proxy.db
zabbix_proxy_cache_size: "32M"
zabbix_repo_rpm_url: "https://repo.zabbix.com/zabbix/{{ zabbix_version }}/release/amazonlinux/2023/noarch/zabbix-release-latest-{{ zabbix_version }}.amzn2023.noarch.rpm"
```

- **`zabbix-proxy-sqlite3`**: o proxy usa **SQLite** como banco local (sem servidor de
  BD externo) — ideal para POC. O schema é criado **automaticamente** na 1ª
  inicialização; não há import manual.
- **`zabbix_repo_rpm_url`**: parametrizado para **Amazon Linux 2023** (a AMI das EC2s).
  Trocar de SO/versão é só mudar esta variável.

### `tasks/main.yml` (proxy) — passo a passo comentado

```yaml
1. Instalar o repositório oficial do Zabbix   (dnf no RPM de release; disable_gpg_check
   porque é justamente esse RPM que instala a chave GPG)
2. Instalar o pacote zabbix-proxy-sqlite3      (update_cache: atualiza metadados antes)
3. Garantir diretórios                         (include dir, dir do banco, /var/log/zabbix,
   donos = zabbix)
4. Provisionar PSK                             (só se TLS habilitado; no_log: não vaza o
   segredo no log; notify restart)
5. Renderizar zabbix_proxy.conf                (template; notify restart se mudou)
6. Habilitar e iniciar o serviço               (systemd: enabled=true → sobe no boot)
7. flush_handlers                              (aplica o restart pendente AGORA, antes de validar)
8. Validar serviço ativo                       (systemctl is-active; falha se != "active")
```

Pontos didáticos:
- **`notify` + handler:** a task de template **não reinicia** o serviço — ela só
  *avisa* (`notify`) o handler. O handler `restart zabbix proxy` roda **uma vez no fim**,
  e **somente se algo mudou**. É assim que ganhamos **idempotência**: rodar de novo sem
  mudanças = nenhum restart.
- **`flush_handlers`**: força o restart pendente a acontecer **antes** da task de
  validação, senão validaríamos a config antiga.
- **`changed_when: false`**: a task de validação só *lê* estado; marcá-la assim evita
  que o Ansible a conte como "mudança".
- **`failed_when`**: define o que é falha (serviço não-`active`).

A role do **agent** segue a mesma lógica, com um detalhe a mais no início:

```yaml
- assert: zabbix_proxy_private_ip não está vazio
```

Um **`assert`** que falha cedo, com mensagem clara, se o inventário não tiver um proxy
com IP — evita configurar um agent "apontando para o nada".

### `handlers/main.yml`

```yaml
- name: restart zabbix proxy
  ansible.builtin.systemd: { name: "{{ zabbix_proxy_service }}", state: restarted }
```

Um handler é uma task que **só roda quando notificada** (e no máximo uma vez por
execução, mesmo se vários `notify` dispararem). É o mecanismo de "reinicie **só se** a
config mudou".

---

## 9. Os templates

Templates **Jinja2** (`.j2`) geram os arquivos de configuração reais, substituindo
`{{ variáveis }}` pelos valores do host. Idempotência: se o resultado renderizado for
igual ao arquivo atual, o Ansible não troca nada (e não notifica restart).

### `zabbix_proxy.conf.j2` — diretivas explicadas

| Diretiva | Vem de | O que faz |
|---|---|---|
| `ProxyMode` | `zabbix_proxy_mode` | 0=active / 1=passive |
| `Server` | `zabbix_server_address` | endereço do **Server central** que o proxy alimenta |
| `Hostname` | `zabbix_proxy_hostname` | nome do proxy (deve bater com o do Server) |
| `ListenPort` | `zabbix_proxy_listen_port` | porta onde o proxy escuta (10051) |
| `DBName` | `zabbix_proxy_db_path` | caminho do arquivo SQLite |
| `CacheSize` / `HistoryCacheSize` / `HistoryIndexCacheSize` | defaults | memória de buffers (enxuto na POC) |
| `Timeout` | `zabbix_proxy_timeout` | timeout de processamento (s) |
| `ProxyOfflineBuffer` | `zabbix_proxy_offline_buffer` | horas de dados guardados se o Server cair |
| bloco `TLS*` | `zabbix_proxy_tls_*` | só aparece se `tls_enabled` (PSK identity/arquivo) |
| `Include` | `zabbix_proxy_include_dir` | carrega `*.conf` extras de um diretório |

O bloco TLS é condicional no template:

```jinja
{% if zabbix_proxy_tls_enabled | bool %}
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity={{ zabbix_proxy_tls_psk_identity }}
TLSPSKFile={{ zabbix_proxy_tls_psk_file }}
{% endif %}
```

### `zabbix_agent2.conf.j2` — diretivas explicadas

| Diretiva | Vem de | O que faz |
|---|---|---|
| `Server` | `zabbix_agent_server` | de quem o agent **aceita** conexão (o proxy) — checks passivos |
| `ServerActive` | `zabbix_agent_server_active` | para quem o agent **envia** dados (o proxy) — checks ativos |
| `Hostname` | `zabbix_agent_hostname` | nome do agent (deve bater com o do Server) |
| `ListenPort` | `zabbix_agent_listen_port` | porta do agent (10050) |
| `HostMetadata` | `zabbix_agent_host_metadata` | rótulo p/ autoregistro (condicional) |
| bloco `TLS*` | `zabbix_agent_tls_*` | PSK, se habilitado |
| `Include` | `zabbix_agent_include_dir` | `*.conf` extras |

**Agent 2** (em vez do agent clássico) por ser o atual e suportar plugins. O pacote é
`zabbix-agent2`, serviço `zabbix-agent2`.

---

## 10. Os playbooks

Cada playbook **liga um grupo a uma role** e roda com `become: true` (vira root via
sudo — `ec2-user` tem sudo sem senha no AL2023).

| Playbook | `hosts:` | Faz |
|---|---|---|
| `install-zabbix-proxy.yml` | `zabbix_proxy` | aplica a role `zabbix_proxy` |
| `install-zabbix-agents.yml` | `zabbix_agents` | aplica a role `zabbix_agent` |
| `configure-all.yml` | — | `import_playbook` dos dois acima, **proxy → agents** |
| `validate.yml` | ambos | valida serviços, portas e conectividade |

- **`configure-all.yml`** garante a **ordem correta**: o proxy primeiro (os agents
  apontam para ele). Usa `import_playbook`, que encadeia playbooks inteiros.
- **`validate.yml`** (sem instalar nada) confere:
  - serviço `active` (proxy e agents);
  - porta escutando localmente (10051 no proxy, 10050 nos agents) via `wait_for`;
  - **agent → proxy** (alcança `proxy_ip:10051`);
  - **proxy → Server** (alcança `server:porta`) — **só se** `zabbix_server_address` foi
    preenchido; e como na POC pode não existir um Server real, essa checagem é
    *não-fatal* (reporta, mas não derruba o playbook).

---

## 11. Precedência de variáveis

Quando a mesma variável é definida em vários lugares, o Ansible escolhe pela
**precedência** (do mais fraco ao mais forte). Simplificado para esta POC:

```
role defaults/   <   group_vars/   <   vault   ≈   inventário   <   extra-vars (AWX survey / -e)
   (base)            (POC)            (segredo)     (host/IP)         (manda sempre)
```

Na prática:
- A **role** traz defaults seguros.
- **`group_vars`** ajusta para a POC (modo do proxy, derivação do IP, etc.).
- **`vault`** injeta segredos (PSK).
- **`extra-vars`** (no AWX: *survey* ou *extra variables*; local: `-e`) vence tudo —
  use para `zabbix_server_address`, sobrescrever usuário, etc., sem editar arquivos.

> É por isso que dá para parametrizar o `zabbix_server_address` no Job Template do AWX
> sem nunca colocá-lo no código.

---

## 12. Modelo de segurança

Princípios aplicados:

1. **Nada de chave privada no repositório.** A chave SSH vive na **Machine Credential**
   do AWX (criptografada, injetada em runtime) ou, localmente, em `--private-key`
   (arquivo fora do repo). O `.gitignore` bloqueia `*.pem`/`*.key`.
2. **Segredos no Vault.** PSK e afins ficam em `vault.yml` **criptografado**:
   ```bash
   cp inventories/poc/group_vars/vault.yml.example inventories/poc/group_vars/vault.yml
   # edite os valores
   ansible-vault encrypt inventories/poc/group_vars/vault.yml
   # rodar:
   ansible-playbook ... --ask-vault-pass
   ```
   No AWX, cadastre um **Vault Credential** (a senha do vault) — o `vault.yml`
   descriptografado **nunca** é versionado.
3. **`.example` para tudo sensível/ambiente-específico** (`hosts.yml`, `vault.yml`) —
   versiona-se o modelo, não o real.
4. **`no_log: true`** nas tasks que manipulam PSK — o segredo não aparece no log do job.
5. **Inventário sem segredo** — só nome lógico + IP privado.

---

## 13. Passo a passo: execução LOCAL

Pré-requisito: estar na **VPN/VPC** (alcançar os IPs privados das EC2s) e ter a chave
SSH do key pair usado nas EC2s.

```bash
cd ansible

# 1) Inventário: copie o modelo e preencha os IPs (outputs do Terraform)
cp inventories/poc/hosts.yml.example inventories/poc/hosts.yml
#   proxy-01.ansible_host  <- zabbix_proxy_private_ip
#   agent-NN.ansible_host  <- zabbix_agent_private_ips[...]

# 2) (Opcional) Segredos com Vault
cp inventories/poc/group_vars/vault.yml.example inventories/poc/group_vars/vault.yml
ansible-vault encrypt inventories/poc/group_vars/vault.yml

# 3) Sanidade: o Ansible alcança os hosts?
ansible all -m ansible.builtin.ping --private-key ~/.ssh/poc.pem
#   espera "pong" em todos

# 4) Configurar (proxy e depois agents), passando o endereço do Server
ansible-playbook playbooks/configure-all.yml \
  --private-key ~/.ssh/poc.pem \
  -e 'zabbix_server_address=zabbix.exemplo.interno' \
  --ask-vault-pass            # só se usou vault

# 5) Validar
ansible-playbook playbooks/validate.yml --private-key ~/.ssh/poc.pem
```

> `--private-key` é **opcional e só local** — não é referenciado em arquivo versionado.

---

## 14. Passo a passo: execução via AWX

1. **Project** → aponte para este repositório (Git). Os playbooks estão em
   `ansible/playbooks/`.
2. **Inventory** → crie os grupos `zabbix_proxy` e `zabbix_agents` com os hosts e seus
   `ansible_host` (IPs privados). Pode ser *Sourced from Project* (usando o `hosts.yml`)
   ou cadastrado na UI.
3. **Machine Credential** → tipo *Machine*: usuário `ec2-user`, cole a **chave privada**
   (a do `ssh_key_name` do Terraform) e habilite *Privilege Escalation* (`sudo`). O AWX
   guarda criptografado e injeta em runtime — sem chave em arquivo/pod.
4. **Vault Credential** (se usar PSK) → cadastre a senha do Ansible Vault.
5. **Job Templates** (associe Inventory + Machine Credential + Vault):
   | Template | Playbook |
   |---|---|
   | `zbx-proxy-install` | `playbooks/install-zabbix-proxy.yml` |
   | `zbx-agents-install` | `playbooks/install-zabbix-agents.yml` |
   | `zbx-configure-all` | `playbooks/configure-all.yml` |
   | `zbx-validate` | `playbooks/validate.yml` |
   - Informe `zabbix_server_address` como **extra-var / survey** do template.
6. **Ordem recomendada:** `zbx-configure-all` (faz proxy → agents) → `zbx-validate`.

**Premissa de rede:** os pods do AWX (no EKS) precisam alcançar os **IPs privados** das
EC2s. Na POC, isso funciona por estarem na **mesma VPC** (o SG das EC2s libera SSH a
partir do SG do EKS). Em produção, a mesma role seria atendida por **VPN**.

---

## 15. Como adicionar mais agents

1. No `hosts.yml`, acrescente o host no grupo `zabbix_agents`:
   ```yaml
   agent-03:
     ansible_host: "10.0.64.23"   # IP da nova EC2 (output do Terraform)
   ```
2. No Terraform, aumente `agent_count` e aplique (cria a EC2).
3. Rode `zbx-agents-install` (ou `zbx-configure-all`).

**Por que é só isso?** O novo agent herda os `group_vars/zabbix_agents.yml`, que
**derivam o IP do proxy do inventário** e definem todo o resto. Você não toca em role,
template nem nos outros hosts. É o que torna a estrutura "fácil de crescer".

---

## 16. Glossário

| Termo | Significado |
|---|---|
| **Inventário** | Lista de hosts e grupos. |
| **Grupo** | Conjunto de hosts (ex.: `zabbix_agents`) que recebem as mesmas vars/role. |
| **`group_vars`** | Variáveis aplicadas a um grupo (arquivo com o nome do grupo). |
| **Role** | Unidade reutilizável com tasks/handlers/templates/defaults. |
| **Task** | Um passo (instalar pacote, copiar arquivo...). |
| **Handler** | Task que só roda quando notificada (ex.: restart on-change). |
| **Template (Jinja2)** | Arquivo `.j2` que vira config real substituindo `{{ vars }}`. |
| **Idempotência** | Rodar de novo não muda nada se já estiver no estado certo. |
| **`become`** | Escalar privilégio (virar root via sudo). |
| **Vault** | Cofre do Ansible para criptografar segredos versionáveis. |
| **`hostvars` / `groups`** | Dicionários mágicos: variáveis de outros hosts / membros de um grupo. |
| **`inventory_hostname`** | Nome lógico do host atual no inventário. |
| **extra-vars** | Variáveis passadas na execução (`-e` / survey do AWX); maior precedência. |
