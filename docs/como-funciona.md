# Como funciona — POC awx-zabbix (explicação detalhada)

Documento **didático**: explica a **ideia** da POC, como as peças se encaixam e o
**porquê de cada configuração**. Não é um passo a passo — para *usar/validar*, veja
[passo-a-passo.md](passo-a-passo.md).

## Sumário

1. [A ideia da POC](#1-a-ideia-da-poc)
2. [Arquitetura (visão geral)](#2-arquitetura)
3. [As peças e como se encaixam](#3-as-peças)
4. [Como o Ansible funciona aqui (modelo mental)](#4-modelo-mental-do-ansible)
5. [Fluxo de uma execução](#5-fluxo-de-uma-execução)
6. [Inventário e `group_vars`](#6-inventário-e-group_vars)
7. [Roles, templates e handlers](#7-roles-templates-e-handlers)
8. [As diretivas do Zabbix explicadas](#8-diretivas-do-zabbix)
9. [Agent Linux × Agent Windows](#9-linux-x-windows)
10. [Precedência de variáveis](#10-precedência-de-variáveis)
11. [Modelo de segurança](#11-modelo-de-segurança)
12. [Glossário](#12-glossário)

---

## 1. A ideia da POC

Validar um cenário **realista de cliente**: um **AWX** (rodando em Kubernetes/EKS)
que, via **Ansible**, instala e configura **Zabbix Proxy** e **Zabbix Agents** em
EC2 — e um **Zabbix Server** central (aqui, dentro do cluster) recebendo tudo.

O que se quer aprender/validar:
- como o **AWX orquestra Ansible** para gerenciar hosts remotos;
- o papel do **Proxy** entre os agents e o server;
- a diferença de gerenciar um agent **Linux** e um **Windows**;
- como **cadastrar e ver** os dados fluindo (feito **manualmente** na UI, de propósito,
  para aprender).

**Premissa de rede:** em produção o AWX alcançaria os hosts por **VPN + SSH/WinRM**.
Nesta POC, tudo está na **mesma VPC**, então o AWX (pods no EKS) alcança as EC2s pelo
IP privado direto. **Sem bastion.**

## 2. Arquitetura

```
                          ┌──────────────────────── EKS (cluster) ────────────────────────┐
                          │                                                                │
                          │   AWX (operator + web + task + PostgreSQL)                     │
                          │        │  executa Ansible (SSH p/ Linux, WinRM p/ Windows)     │
                          │        ▼                                                        │
   ┌───────────────┐      │   Zabbix Server  ──(NLB interno :10051)──┐                     │
   │ Agent Linux   │──┐   │   + Web (UI)  + PostgreSQL               │                     │
   │ (EC2, SSH)    │  │   └──────────────────────────────────────────┼─────────────────────┘
   │  :10050       │  │                                              ▲
   └───────────────┘  │   ┌───────────────────┐                     │ (proxy → server :10051)
   ┌───────────────┐  ├──▶│  Zabbix Proxy     │─────────────────────┘
   │ Agent Windows │──┘   │  (EC2, SQLite)    │
   │ (EC2, WinRM)  │      │   :10051          │
   │  :10050       │      └───────────────────┘
   └───────────────┘
        agents → proxy                proxy → server (central)
```

- **Agents** (Linux e Windows) coletam métricas e falam **com o proxy** (não com o
  server).
- **Proxy** concentra e repassa ao **Server** (via um **NLB interno** na porta 10051,
  porque o proxy está fora do cluster).
- **Server + Web** ficam no cluster; a **UI** é acessada por *port-forward*.
- **AWX** está no cluster e é quem roda o Ansible que configura proxy e agents.

## 3. As peças

| Peça | Onde | Papel |
|---|---|---|
| **EKS** | AWS | Hospeda AWX e Zabbix Server. |
| **AWX** | EKS (ns `awx`) | Orquestra o Ansible (inventário, credenciais, jobs). |
| **Zabbix Server + Web + DB** | EKS (ns `zabbix`) | Recebe os dados; UI de cadastro/visualização. |
| **NLB interno** | AWS (subnets privadas) | Expõe o trapper (10051) do server para o proxy (EC2). |
| **Zabbix Proxy** | EC2 (Linux, SQLite) | Intermediário agents↔server. |
| **Zabbix Agents** | EC2 (1 Linux + 1 Windows) | Coletam métricas dos hosts. |
| **Ansible** | repo `ansible/` | *Instala e configura* proxy e agents (não cadastra no Zabbix). |

> **Importante:** o Ansible **instala o agent/proxy e escreve os `.conf`**, mas **não
> registra** proxy/hosts no Zabbix Server. Esse cadastro é **manual** (faz parte do
> aprendizado) — ver [passo-a-passo.md](passo-a-passo.md).

## 4. Modelo mental do Ansible

Ansible descreve o **estado desejado** e o aplica via SSH (Linux) ou WinRM (Windows).
É **idempotente**: rodar de novo não muda nada se já estiver certo. Cinco peças:

| Peça | Pergunta | Aqui é... |
|---|---|---|
| **Inventário** | *Em quais máquinas?* | `inventories/poc/hosts.yml` (grupos `proxy`, `linux`, `windows`) |
| **Variáveis** | *Com quais valores?* | `group_vars/*` + `defaults/` das roles + vault |
| **Playbook** | *O quê e onde?* | `playbooks/*.yml` (liga grupo → role) |
| **Role** | *Como (os passos)?* | `roles/zabbix_proxy`, `roles/zabbix_agent_linux`, `roles/zabbix_agent_windows` |
| **Template** | *Como fica o `.conf`?* | `templates/*.conf.j2` |

Regra de ouro: **a role é genérica; os valores específicos vêm de fora** (inventário,
group_vars, vault, AWX). Por isso a role não tem IP/senha dentro.

## 5. Fluxo de uma execução

`configure-all.yml` encadeia, **na ordem certa** (proxy antes dos agents):

```
configure-all.yml
 ├─ configure-proxy.yml    → proxy   → role zabbix_proxy
 ├─ configure-linux.yml    → linux   → role zabbix_agent_linux
 └─ configure-windows.yml  → windows → role zabbix_agent_windows
```

Para **cada host**, o Ansible: (1) monta as variáveis; (2) conecta (SSH ou WinRM);
(3) roda as tasks da role; (4) se algum `.conf` mudou, dispara o **handler** de restart.

## 6. Inventário e group_vars

### Inventário — quais máquinas

```yaml
all:
  children:
    proxy:
      hosts: { proxy-01: { ansible_host: "10.0.48.10" } }
    linux:                       # agent Linux (SSH)
      hosts: { linux-01: { ansible_host: "10.0.48.21" } }
    windows:                     # agent Windows (WinRM)
      hosts: { windows-01: { ansible_host: "10.0.64.31" } }
```

- Nomes (`proxy-01`, `linux-01`...) são **lógicos**; o que conecta é o `ansible_host`
  (IP privado). Esse nome lógico vira o `Hostname` do Zabbix.
- Só dados **não sensíveis** (nome + IP). Usuário/porta/credencial ficam em `group_vars`
  e na Machine Credential do AWX.
- Crescer = adicionar uma linha. O `hosts.yml` real está no `.gitignore` (versionamos
  só o `.example`).

### group_vars — valores por grupo

- **`all.yml`** (todos): `zabbix_version`, `zabbix_server_address` (o **Server central**,
  para onde o proxy reporta), `zabbix_server_port` — e a parte "esperta": os **agents
  derivam o IP do proxy do próprio inventário**:
  ```yaml
  zabbix_agent_server:        "{{ hostvars[groups['proxy'][0]].ansible_host }}"
  zabbix_agent_server_active: "{{ hostvars[groups['proxy'][0]].ansible_host }}"
  ```
  Lendo de dentro pra fora: `groups['proxy']` → `['proxy-01']`; `[0]` → `'proxy-01'`;
  `hostvars['proxy-01'].ansible_host` → o IP do proxy. **Sem hardcode**: troque o proxy e
  os agents continuam certos.
- **`proxy.yml`**: conexão **SSH** (`ec2-user`) + `zabbix_proxy_package` /
  `zabbix_proxy_service_name` / `zabbix_proxy_config_path`. (Modo active e SQLite ficam
  nos `defaults` da role `zabbix_proxy`.)
- **`linux.yml`**: conexão **SSH** (`ec2-user`) + `zabbix_agent_package` /
  `zabbix_agent_service_name` / `zabbix_agent_config_path`.
- **`windows.yml`**: conexão **WinRM** (`Administrator`, porta 5986, `transport: basic`,
  `cert_validation: ignore`) + `zabbix_agent_service_name` / `zabbix_agent_config_path`.

## 7. Roles, templates e handlers

Cada role tem `defaults/` (valores base, menor precedência), `tasks/` (passos),
`handlers/` (ações sob demanda) e `templates/` (arquivos gerados).

**Passo a passo da role (proxy; o agent Linux é igual em espírito):**
1. instala o repositório oficial do Zabbix (RPM de release; `disable_gpg_check` porque é
   esse RPM que traz a chave GPG);
2. instala o pacote (`zabbix-proxy-sqlite3`);
3. garante diretórios;
4. PSK (só se TLS; `no_log: true` para não vazar no log);
5. **renderiza o `.conf`** (template) → `notify` do handler;
6. habilita+inicia o serviço (sobe no boot).

A **validação** (serviço ativo + arquivo de config presente) fica no `validate.yml`,
separada das roles de instalação.

Conceitos-chave:
- **`notify` + handler = idempotência:** a task de template só *avisa*; o handler
  `restart` roda **uma vez, e só se o `.conf` mudou**. Rodar de novo sem mudança = sem
  restart.
- **`assert` no agent Windows:** falha cedo se o `zabbix_agent_server` estiver vazio
  (evita configurar um agent "apontando pro nada").

**Templates Jinja2** (`.conf.j2`) viram o arquivo real substituindo `{{ vars }}`. Se o
resultado for igual ao arquivo atual, nada muda (idempotência).

## 8. Diretivas do Zabbix

### Proxy (`zabbix_proxy.conf`)

| Diretiva | Vem de | O que faz |
|---|---|---|
| `ProxyMode` | `zabbix_proxy_mode` | 0=active (proxy conecta no server) / 1=passive |
| `Server` | `zabbix_server_address` | endereço do **Server** (o NLB) que o proxy alimenta |
| `Hostname` | `zabbix_proxy_hostname` | **deve bater** com o nome cadastrado no server |
| `DBName` | `zabbix_proxy_db_path` | arquivo SQLite (schema criado sozinho na 1ª subida) |
| `CacheSize`/`History*CacheSize` | defaults | buffers (enxutos na POC) |
| `ProxyOfflineBuffer` | default | horas de dados guardados se o server cair |
| bloco `TLS*` | `*_tls_*` | só aparece se `tls_enabled` |

### Agent (`zabbix_agent2.conf`, Linux e Windows)

| Diretiva | Vem de | O que faz |
|---|---|---|
| `Server` | `zabbix_agent_server` | de quem o agent **aceita** conexão (o proxy) — checks **passivos** (proxy → agent:10050) |
| `ServerActive` | `zabbix_agent_server_active` | para quem o agent **envia** — checks **ativos** (agent → proxy:10051) |
| `Hostname` | `zabbix_agent_hostname` | **deve bater** com o host no server |
| `HostMetadata` | `zabbix_agent_host_metadata` | rótulo p/ autoregistro |

> **Active × Passive** é o conceito que mais confunde: *active* = quem **inicia a
> conexão** sai e conecta (proxy→server, agent→proxy); *passive* = o outro lado pergunta
> (proxy→agent). Aqui o proxy é **active** e os agents têm os dois caminhos configurados.

## 9. Linux × Windows

A grande diferença está na **instalação/conexão**, não nas diretivas do Zabbix (que são
as mesmas). Por isso há **uma role por SO**:

| Aspecto | Agent **Linux** (`zabbix_agent_linux`) | Agent **Windows** (`zabbix_agent_windows`) |
|---|---|---|
| Conexão Ansible | **SSH** (`ec2-user`, porta 22) | **WinRM** HTTPS (`Administrator`, porta 5986) |
| Credencial AWX | Machine (chave SSH) | Machine **Windows** (usuário + senha) |
| Instalação | `dnf` no repo RPM oficial | baixa o **MSI** (`win_get_url`) + `win_package` |
| Serviço | `systemd` (`zabbix-agent2`) | `win_service` (`Zabbix Agent 2`) |
| Config | `/etc/zabbix/zabbix_agent2.conf` | `C:\Program Files\Zabbix Agent 2\zabbix_agent2.conf` |
| Módulos | `ansible.builtin.*` | `ansible.windows.*` |
| Grupo no inventário | `linux` | `windows` |

**O que NÃO muda:** o `.conf` (mesmas diretivas `Server`/`ServerActive`/`Hostname`), as
portas Zabbix (10050/10051), e — na UI do Zabbix — o cadastro do host (só muda o
**template de monitoramento**: "Windows by Zabbix agent" em vez de "Linux by Zabbix
agent"; ambos já vêm prontos, você não cria).

**No Terraform**, a EC2 Windows usa AMI **Windows Server 2022**, instância maior
(`t3.small`), um SG com **WinRM (5986)** no lugar do SSH, e um `user_data` (PowerShell)
que **define a senha do Administrator** (output sensível `windows_admin_password`) e
**habilita o WinRM** para o Ansible. O Terraform **não** instala o Zabbix — só prepara a
máquina para o Ansible chegar.

## 10. Precedência de variáveis

Do mais fraco ao mais forte (simplificado):

```
role defaults/  <  group_vars/  <  vault  ≈  inventário  <  extra-vars (AWX survey / -e)
   (base)           (POC)           (segredo)   (host/IP)        (manda sempre)
```

Por isso o `zabbix_server_address` (o DNS do NLB) é passado como **extra-var/survey** no
Job Template do AWX — vence tudo, sem hardcode no código.

## 11. Modelo de segurança

1. **Nenhuma chave/senha no repositório.** SSH → Machine Credential do AWX; senha do
   Windows → Machine Credential Windows (valor vem do output sensível do Terraform). O
   `.gitignore` bloqueia `*.pem`/`*.key`.
2. **Segredos no Vault** (PSK): `vault.yml` criptografado (`ansible-vault encrypt`),
   nunca versionado; no AWX vira um **Vault Credential**.
3. **`.example` para tudo sensível/ambiente-específico** (`hosts.yml`, `vault.yml`).
4. **`no_log: true`** nas tasks de PSK.
5. **Inventário sem segredo** — só nome lógico + IP.

## 12. Glossário

| Termo | Significado |
|---|---|
| **Inventário / Grupo** | Lista de hosts / conjunto que recebe as mesmas vars e role. |
| **`group_vars`** | Variáveis de um grupo (arquivo com o nome do grupo). |
| **Role** | Unidade reutilizável (tasks/handlers/templates/defaults). |
| **Handler** | Task que só roda quando notificada (restart on-change). |
| **Template (Jinja2)** | `.j2` que vira config real substituindo `{{ vars }}`. |
| **Idempotência** | Rodar de novo não muda nada se já estiver certo. |
| **`become`** | Escalar privilégio (root via sudo) — Linux. |
| **WinRM** | Protocolo de gestão remota do Windows (o "SSH do Windows" p/ Ansible). |
| **`hostvars` / `groups`** | Variáveis de outros hosts / membros de um grupo. |
| **`inventory_hostname`** | Nome lógico do host atual. |
| **extra-vars** | Variáveis passadas na execução (`-e`/survey); maior precedência. |
| **Active × Passive** | Quem inicia a conexão (ativo sai/conecta; passivo é perguntado). |
