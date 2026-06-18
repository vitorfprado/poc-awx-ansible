# Runbook — cadastros manuais da POC (aprendizado)

Guia **didático** para você fazer **todos os cadastros à mão** e entender o fluxo
ponta a ponta. **Não há automação de registro aqui** — só o passo a passo e o
**porquê** de cada cadastro.

> **O que é automático x manual**
>
> | Camada | Quem faz | O quê |
> |---|---|---|
> | Infra | **Terraform** | VPC, EKS, EC2s, SGs |
> | Cluster | **Pipeline (Stage 2)** | AWX e **Zabbix Server** (server+web+DB) |
> | Instalação/config dos hosts | **AWX/Ansible** | *instala* Proxy/Agents e *gera os `.conf`* |
> | **Cadastro de monitoramento** | **VOCÊ (manual)** | proxy, hosts, templates na UI do Zabbix |
>
> O Ansible instala o binário e escreve o `Hostname`/`Server` nos `.conf`, mas **não
> registra nada** no Zabbix. Esse registro é o exercício deste runbook.

## Fluxo que você vai montar

```
[ Agent EC2 ] --(10050/10051)--> [ Proxy EC2 ] --(10051, via NLB interno)--> [ Zabbix Server (EKS) ] --> [ UI web ]
   agent-01/02                       proxy-01                                    zabbix-server
```

## Pré-requisitos

1. `apply` concluído (Stage 1 + Stage 2). No **Summary** do run você tem:
   - **DNS do NLB** do Zabbix Server (= `zabbix_server_address`);
   - IPs privados do Proxy e dos Agents (outputs do Terraform);
   - comandos de acesso ao AWX e à UI do Zabbix.
2. `kubectl` configurado (`aws eks update-kubeconfig --name <cluster> --region <região>`).
3. Acesso ao AWX (port-forward) e à UI do Zabbix (port-forward).

---

# Parte 1 — Cadastros no AWX (orquestrar o Ansible)

O AWX precisa saber **onde** estão os hosts, **como** conectar e **o que** rodar.
Cada item abaixo é um cadastro que você cria **uma vez**.

### 1.1 Project — "de onde vem o código"
**Resources → Projects → Add.**
- **Source Control Type:** Git → URL deste repositório.
- **Por quê:** o AWX sincroniza os playbooks (`ansible/playbooks/…`) a partir do Git.
  Sem Project, não há o que executar.

### 1.2 Inventory — "em quais máquinas"
**Resources → Inventories → Add → Inventory.** Depois, adicione **Groups** e **Hosts**:
- Grupos: `zabbix_proxy` e `zabbix_agents`.
- Hosts: `proxy-01`, `agent-01`, `agent-02`, cada um com a variável
  `ansible_host: <IP privado>` (dos outputs do Terraform).
- **Por quê:** os playbooks miram `hosts: zabbix_proxy` / `hosts: zabbix_agents`. O
  `ansible_host` é o IP que o AWX usa no SSH. (Mesma ideia do `hosts.yml.example`.)

> Alternativa: *Sources → Add → Sourced from a Project* apontando para
> `ansible/inventories/poc/hosts.yml`. Para aprender, fazer na UI é mais didático.

### 1.3 Machine Credential — "como conectar (SSH)"
**Resources → Credentials → Add → tipo *Machine*.**
- **Username:** `ec2-user` (Amazon Linux 2023).
- **SSH Private Key:** cole a chave privada do key pair usado nas EC2s
  (`ssh_key_name` do Terraform).
- **Privilege Escalation:** `sudo` (os playbooks usam `become: true`).
- **Por quê:** é assim que a chave entra **com segurança** — o AWX guarda
  criptografada e injeta em runtime. **Nunca** colocamos a chave em arquivo no repo.

### 1.4 (Opcional) Vault Credential — segredos do Ansible
Só se você habilitar TLS/PSK (vault). **Credentials → Add → tipo *Vault*** com a
senha do Ansible Vault. **Por quê:** decifra o `vault.yml` em runtime sem versioná-lo.

### 1.5 Job Templates — "o que rodar"
**Resources → Templates → Add → Job Template**, um para cada playbook:
| Template | Playbook |
|---|---|
| `zbx-configure-all` | `ansible/playbooks/configure-all.yml` |
| `zbx-validate` | `ansible/playbooks/validate.yml` |
(opcionalmente `install-zabbix-proxy.yml` e `install-zabbix-agents.yml` separados.)
- Em cada um: selecione o **Inventory** e a **Machine Credential** (e Vault, se houver).
- Em **Variables**, informe o endereço do server:
  ```yaml
  zabbix_server_address: "<DNS do NLB do Stage 2>"
  ```
- **Por quê:** o Job Template amarra *playbook + inventário + credencial + variáveis*
  num botão de "Launch". As `Variables`/survey têm a **maior precedência** — por isso o
  endereço do server entra aqui, sem hardcode no código.

### 1.6 Executar
1. **Launch** do `zbx-configure-all` → instala/configura **proxy primeiro, depois
   agents**. Ao final, os `.conf` estão escritos e os serviços rodando.
2. **Launch** do `zbx-validate` → confere serviços, portas e conectividade.

> Resultado desta parte: os hosts estão **instalados e configurados**, mas **ainda não
> aparecem** no Zabbix — falta o cadastro na UI (Parte 2).

---

# Parte 2 — Cadastros na UI do Zabbix (o coração)

Acesse a UI:
```bash
kubectl -n zabbix port-forward svc/zabbix-web 8888:80
# http://localhost:8888   (login: Admin / zabbix)
```

### 2.1 Trocar a senha do Admin
Canto superior direito (perfil) → **Password**. **Por quê:** `Admin/zabbix` é padrão
público; trocar é o primeiro passo de qualquer instalação.

### 2.2 Cadastrar o Proxy
**Data collection → Proxies → Create proxy.**
- **Proxy name:** `proxy-01` — **idêntico** ao `Hostname` do `zabbix_proxy.conf`
  (que o Ansible gerou a partir do `inventory_hostname`).
- **Proxy mode:** **Active** — porque configuramos `ProxyMode=0`. No modo ativo é o
  **proxy quem inicia** a conexão com o server (sai pela VPC até o NLB:10051).
- **(Encryption):** só se você habilitou PSK.
- **Por quê cada campo:**
  - O *name* é a chave: o server só aceita dados de um proxy que ele **conhece pelo
    nome**. Se não bater com o `.conf`, o proxy nunca fica "online".
  - O *mode* tem que casar com o `.conf` — ativo lá, ativo aqui.
- ✅ Em alguns minutos o proxy aparece com **"last seen"** recente (ele se conectou).

### 2.3 Cadastrar os Hosts (cada agent)
**Data collection → Hosts → Create host** (repita para `agent-01`, `agent-02`):
- **Host name:** `agent-01` — **idêntico** ao `Hostname` do `zabbix_agent2.conf`.
- **Templates:** adicione **"Linux by Zabbix agent"** (checks passivos: o proxy
  pergunta ao agent). *Por quê:* o template traz os **itens e triggers** prontos; sem
  template, o host existe mas não coleta nada.
- **Host groups:** crie/escolha um grupo (ex.: `POC/Linux`). *Por quê:* organização e
  permissões; o Zabbix exige ao menos um grupo.
- **Interfaces → Add → Agent:** `IP = <IP privado do agent>`, `Port = 10050`.
  *Por quê:* é por onde o proxy **alcança** o agent nos checks passivos.
- **Monitored by → Proxy → `proxy-01`.** *Por quê:* diz ao server que **quem coleta
  este host é o proxy** (não o server direto). É a peça que liga host → proxy.
- ✅ Salve. O host nasce e o proxy passa a coletá-lo.

> Quer usar **checks ativos** (agent envia ao proxy)? Use o template **"Linux by
> Zabbix agent active"**. Configuramos `Server` e `ServerActive` no `.conf`, então os
> dois modos funcionam.

### 2.4 Ver os dados chegando
- **Monitoring → Hosts:** a coluna **Availability/ZBX** fica **verde** quando a coleta
  funciona. Vermelho = veja o tooltip (erro de conexão/timeout).
- **Monitoring → Latest data:** filtre pelo host e veja métricas (CPU, memória…).

---

## Os 3 conceitos que este exercício ensina

1. **O nome tem que bater.** `Hostname` no `.conf` (gerado pelo Ansible) ↔ `Proxy
   name`/`Host name` na UI. Diferente = o server **rejeita** por não reconhecer.
2. **Quem inicia a conexão.** *Active* (proxy/agent saem e conectam) x *Passive* (o
   outro lado pergunta). Aqui tudo é **ativo** no `.conf`; o cadastro na UI precisa
   refletir isso (proxy mode Active; template passivo/ativo conforme a escolha).
3. **O server não fala com os agents.** Ele fala com o **proxy**; o proxy fala com os
   agents. Por isso o host é **"Monitored by proxy"**.

## Troubleshooting rápido

| Sintoma | Provável causa |
|---|---|
| Proxy não fica "online" | `Proxy name` ≠ `Hostname` do proxy; ou proxy não alcança o NLB:10051 |
| Host `ZBX` vermelho | IP/porta da Interface errados; SG bloqueando 10050; agent parado |
| "host not found" nos logs do proxy | `Host name` na UI ≠ `Hostname` do agent |
| Nada em Latest data | host sem **template**, ou ainda dentro do 1º intervalo de coleta |

Logs úteis (via `kubectl` ou SSM nas EC2s):
```bash
kubectl -n zabbix logs deploy/zabbix-server | tail -50      # server
# nas EC2s (SSH/SSM):
sudo tail -50 /var/log/zabbix/zabbix_proxy.log              # proxy
sudo tail -50 /var/log/zabbix/zabbix_agent2.log            # agent
```

## Checklist final

- [ ] AWX: Project, Inventory, Machine Credential, Job Templates criados.
- [ ] `zbx-configure-all` executado com sucesso (proxy → agents).
- [ ] `zbx-validate` verde.
- [ ] Senha do Admin trocada.
- [ ] Proxy `proxy-01` cadastrado (Active) e **online**.
- [ ] Hosts `agent-01`/`agent-02` cadastrados (template + interface + Monitored by proxy).
- [ ] **ZBX verde** e métricas em **Latest data**.
