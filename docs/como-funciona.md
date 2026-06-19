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
9. [Precedência de variáveis](#9-precedência-de-variáveis)
10. [Modelo de segurança](#10-modelo-de-segurança)
11. [Glossário](#11-glossário)

---

## 1. A ideia da POC

Validar um cenário **realista de cliente**: um **AWX** (rodando em Kubernetes/EKS)
que, via **Ansible**, instala e configura **Zabbix Proxy** e **Zabbix Agent** em
EC2 Linux — e um **Zabbix Server** central (aqui, dentro do cluster) recebendo tudo.

O que se quer aprender/validar:
- como o **AWX orquestra Ansible** para gerenciar hosts remotos;
- o papel do **Proxy** entre o agent e o server;
- como **cadastrar e ver** os dados fluindo (feito **manualmente** na UI, de propósito,
  para aprender — automatizar esse cadastro fica como próximo passo).

**Premissa de rede:** em produção o AWX alcançaria os hosts por **VPN + SSH**.
Nesta POC, tudo está na **mesma VPC**, então o AWX (pods no EKS) alcança as EC2s pelo
IP privado direto. **Sem bastion.**

## 2. Arquitetura

```
                          ┌──────────────────────── EKS (cluster) ────────────────────────┐
                          │                                                                │
                          │   AWX (operator + web + task + PostgreSQL)                     │
                          │        │  executa Ansible (SSH p/ Linux)                       │
                          │        ▼                                                        │
   ┌───────────────┐      │   Zabbix Server  ──(NLB interno :10051)──┐                     │
   │ Agent Linux   │      │   + Web (UI)  + PostgreSQL               │                     │
   │ (EC2, SSH)    │──┐   └──────────────────────────────────────────┼─────────────────────┘
   │  :10050       │  │                                              ▲
   └───────────────┘  │   ┌───────────────────┐                     │ (proxy → server :10051)
                      └──▶│  Zabbix Proxy     │─────────────────────┘
                          │  (EC2, SQLite)    │
                          │   :10051          │
                          └───────────────────┘
        agent → proxy                proxy → server (central)
```

- **Agent** (Linux) coleta métricas e fala **com o proxy** (não com o server).
- **Proxy** concentra e repassa ao **Server** (via um **NLB interno** na porta 10051,
  porque o proxy está fora do cluster).
- **Server + Web** ficam no cluster; a **UI** é acessada por *port-forward*.
- **AWX** está no cluster e é quem roda o Ansible que configura proxy e agent.

## 3. As peças

| Peça | Onde | Papel |
|---|---|---|
| **EKS** | AWS | Hospeda AWX e Zabbix Server. |
| **AWX** | EKS (ns `awx`) | Orquestra o Ansible (inventário, credenciais, jobs). |
| **Zabbix Server + Web + DB** | EKS (ns `zabbix`) | Recebe os dados; UI de cadastro/visualização. |
| **NLB interno** | AWS (subnets privadas) | Expõe o trapper (10051) do server para o proxy (EC2). |
| **Zabbix Proxy** | EC2 (Linux, SQLite) | Intermediário agent↔server. |
| **Zabbix Agent** | EC2 (1 Linux) | Coleta métricas do host. |
| **Ansible** | repo `ansible/` | *Instala e configura* proxy e agent (não cadastra no Zabbix). |

> **Importante:** o Ansible **instala o agent/proxy e escreve os `.conf`**, mas **não
> registra** proxy/host no Zabbix Server. Esse cadastro é **manual** (faz parte do
> aprendizado) — ver [passo-a-passo.md](passo-a-passo.md).

## 4. Modelo mental do Ansible

Ansible descreve o **estado desejado** e o aplica via SSH.
É **idempotente**: rodar de novo não muda nada se já estiver certo. Cinco peças:

| Peça | Pergunta | Aqui é... |
|---|---|---|
| **Inventário** | *Em quais máquinas?* | `inventories/poc/hosts.yml` (grupos `proxy`, `linux`) |
| **Variáveis** | *Com quais valores?* | `group_vars/*` + `defaults/` das roles + vault |
| **Playbook** | *O quê e onde?* | `playbooks/*.yml` (liga grupo → role) |
| **Role** | *Como (os passos)?* | `roles/zabbix_proxy`, `roles/zabbix_agent_linux` |
| **Template** | *Como fica o `.conf`?* | `templates/*.conf.j2` |

Regra de ouro: **a role é genérica; os valores específicos vêm de fora** (inventário,
group_vars, vault, AWX). Por isso a role não tem IP/senha dentro.

## 5. Fluxo de uma execução

`configure-all.yml` encadeia, **na ordem certa** (proxy antes do agent):

```
configure-all.yml
 ├─ configure-proxy.yml    → proxy   → role zabbix_proxy
 └─ configure-linux.yml    → linux   → role zabbix_agent_linux
```

Para **cada host**, o Ansible: (1) monta as variáveis; (2) conecta (SSH);
(3) roda as tasks da role; (4) se o `.conf` mudou, dispara o **handler** de restart.

## 6. Inventário e group_vars

### Inventário — quais máquinas

```yaml
all:
  children:
    proxy:
      hosts: { proxy-01: { ansible_host: "10.0.48.10" } }
    linux:                       # agent Linux (SSH)
      hosts: { linux-01: { ansible_host: "10.0.48.21" } }
```

- Nomes (`proxy-01`, `linux-01`) são **lógicos**; o que conecta é o `ansible_host`
  (IP privado). Esse nome lógico vira o `Hostname` do Zabbix.
- Só dados **não sensíveis** (nome + IP). Usuário/porta/credencial ficam em `group_vars`
  e na Machine Credential do AWX.
- Crescer = adicionar uma linha. O `hosts.yml` real está no `.gitignore` (versionamos
  só o `.example`).

### group_vars — valores por grupo

- **`all.yml`** (todos): `zabbix_version`, `zabbix_server_address` (o **Server central**,
  para onde o proxy reporta), `zabbix_server_port` — e a parte "esperta": o **agent
  deriva o IP do proxy do próprio inventário**:
  ```yaml
  zabbix_agent_server:        "{{ hostvars[groups['proxy'][0]].ansible_host }}"
  zabbix_agent_server_active: "{{ hostvars[groups['proxy'][0]].ansible_host }}"
  ```
  Lendo de dentro pra fora: `groups['proxy']` → `['proxy-01']`; `[0]` → `'proxy-01'`;
  `hostvars['proxy-01'].ansible_host` → o IP do proxy. **Sem hardcode**: troque o proxy e
  o agent continua certo.
- **`proxy.yml`**: conexão **SSH** (`ec2-user`) + `zabbix_proxy_package` /
  `zabbix_proxy_service_name` / `zabbix_proxy_config_path`. (Modo active e SQLite ficam
  nos `defaults` da role `zabbix_proxy`.)
- **`linux.yml`**: conexão **SSH** (`ec2-user`) + `zabbix_agent_package` /
  `zabbix_agent_service_name` / `zabbix_agent_config_path`.

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

### Agent (`zabbix_agent2.conf`, Linux)

| Diretiva | Vem de | O que faz |
|---|---|---|
| `Server` | `zabbix_agent_server` | de quem o agent **aceita** conexão (o proxy) — checks **passivos** (proxy → agent:10050) |
| `ServerActive` | `zabbix_agent_server_active` | para quem o agent **envia** — checks **ativos** (agent → proxy:10051) |
| `Hostname` | `zabbix_agent_hostname` | **deve bater** com o host no server |
| `HostMetadata` | `zabbix_agent_host_metadata` | rótulo p/ autoregistro |

> **Active × Passive** é o conceito que mais confunde: *active* = quem **inicia a
> conexão** sai e conecta (proxy→server, agent→proxy); *passive* = o outro lado pergunta
> (proxy→agent). Aqui o proxy é **active** e o agent tem os dois caminhos configurados.

## 9. Precedência de variáveis

Do mais fraco ao mais forte (simplificado):

```
role defaults/  <  group_vars/  <  vault  ≈  inventário  <  extra-vars (AWX survey / -e)
   (base)           (POC)           (segredo)   (host/IP)        (manda sempre)
```

Por isso o `zabbix_server_address` (o DNS do NLB) é passado como **extra-var/survey** no
Job Template do AWX — vence tudo, sem hardcode no código.

## 10. Modelo de segurança

1. **Nenhuma chave/senha no repositório.** SSH → Machine Credential do AWX. O
   `.gitignore` bloqueia `*.pem`/`*.key`.
2. **Segredos no Vault** (PSK): `vault.yml` criptografado (`ansible-vault encrypt`),
   nunca versionado; no AWX vira um **Vault Credential**.
3. **`.example` para tudo sensível/ambiente-específico** (`hosts.yml`, `vault.yml`).
4. **`no_log: true`** nas tasks de PSK.
5. **Inventário sem segredo** — só nome lógico + IP.

## 11. Glossário

| Termo | Significado |
|---|---|
| **Inventário / Grupo** | Lista de hosts / conjunto que recebe as mesmas vars e role. |
| **`group_vars`** | Variáveis de um grupo (arquivo com o nome do grupo). |
| **Role** | Unidade reutilizável (tasks/handlers/templates/defaults). |
| **Handler** | Task que só roda quando notificada (restart on-change). |
| **Template (Jinja2)** | `.j2` que vira config real substituindo `{{ vars }}`. |
| **Idempotência** | Rodar de novo não muda nada se já estiver certo. |
| **`become`** | Escalar privilégio (root via sudo) — Linux. |
| **`hostvars` / `groups`** | Variáveis de outros hosts / membros de um grupo. |
| **`inventory_hostname`** | Nome lógico do host atual. |
| **extra-vars** | Variáveis passadas na execução (`-e`/survey); maior precedência. |
| **Active × Passive** | Quem inicia a conexão (ativo sai/conecta; passivo é perguntado). |
