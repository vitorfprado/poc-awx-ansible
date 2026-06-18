# Passo a passo — usar e validar a POC

Guia prático para **usar** a POC (acessar AWX e Zabbix) e **validar a ideia**
(agent → proxy → server → ver os dados). Para entender *por que* cada coisa
funciona, veja [como-funciona.md](como-funciona.md).

> A infra (Terraform) e o cluster (AWX, Zabbix Server, addons) já estão de pé. Aqui o
> foco é **operar e validar**, não subir.

## Sumário
1. [Pré-requisitos](#1-pré-requisitos)
2. [Acessar o cluster (kubeconfig)](#2-acessar-o-cluster)
3. [Coletar os dados do Terraform](#3-coletar-os-dados-do-terraform)
4. [Acessar o AWX](#4-acessar-o-awx)
5. [Acessar a UI do Zabbix](#5-acessar-a-ui-do-zabbix)
6. [Configurar o AWX](#6-configurar-o-awx)
7. [Rodar os playbooks (instalar/configurar)](#7-rodar-os-playbooks)
8. [Cadastros manuais no Zabbix](#8-cadastros-manuais-no-zabbix)
9. [Validar a ideia ponta a ponta](#9-validar-a-ideia)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Pré-requisitos

- `kubectl` e `aws` CLI configurados (credenciais com acesso à conta da POC).
- Acesso de **admin ao cluster** (o Terraform já cria a access entry do seu usuário).
- A chave SSH do key pair das EC2s Linux (para a Machine Credential do AWX).

Variáveis úteis (ajuste se mudou):
```bash
CLUSTER=awx-zabbix-poc-poc-eks
REGION=us-east-1
```

## 2. Acessar o cluster

```bash
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
kubectl get nodes            # devem aparecer Ready
kubectl get pods -A          # awx, zabbix, kube-system...
```

## 3. Coletar os dados do Terraform

No diretório do consumer (`iac/awx-zabbix-poc`):
```bash
terraform output                              # visão geral
terraform output -raw zabbix_proxy_private_ip
terraform output -json zabbix_agent_private_ips          # agents Linux
terraform output -json zabbix_agent_windows_private_ips  # agents Windows
terraform output -raw windows_admin_password             # senha do Administrator (sensível)
```

O **endereço do Zabbix Server** (para o proxy) é o **DNS do NLB interno**:
```bash
kubectl -n zabbix get svc zabbix-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```

Anote: IP do proxy, IPs dos agents (Linux e Windows), senha do Windows, DNS do NLB.

## 4. Acessar o AWX

Senha do admin e port-forward:
```bash
# senha (usuário: admin)
kubectl -n awx get secret awx-admin-password -o jsonpath="{.data.password}" | base64 -d; echo

# port-forward (deixe rodando num terminal)
kubectl -n awx port-forward svc/awx-service 8080:80
```
Acesse <http://localhost:8080> e faça login (`admin` + senha acima).

## 5. Acessar a UI do Zabbix

```bash
kubectl -n zabbix port-forward svc/zabbix-web 8888:80
```
Acesse <http://localhost:8888> — login padrão **`Admin` / `zabbix`** (troque a senha).

> Dica: rode os dois port-forwards em terminais separados (eles ficam em foreground).

## 6. Configurar o AWX

Cadastros que você cria **uma vez** (orquestram o Ansible).

### 6.1 Project
**Resources → Projects → Add** → *Source Control Type: Git* → URL deste repositório.
Os playbooks ficam em `ansible/playbooks/`.

### 6.2 Inventory
**Resources → Inventories → Add → Inventory**. Adicione **Groups** e **Hosts**:

| Grupo | Hosts | Variável por host |
|---|---|---|
| `proxy` | `proxy-01` | `ansible_host: <IP do proxy>` |
| `linux` | `linux-01` | `ansible_host: <IP do agent Linux>` |
| `windows` | `windows-01` | `ansible_host: <IP do agent Windows>` |

> Os IPs vêm do passo 3. Mantenha o inventário só com **nome + IP** (sem segredo).

### 6.3 Credentials
- **SSH (proxy + Linux) — Machine Credential:** tipo *Machine*, **Username** `ec2-user`,
  cole a **SSH Private Key** do key pair das EC2s, **Privilege Escalation** = `sudo`.
- **Windows — Machine Credential:** tipo *Machine*, **Username** `Administrator`,
  **Password** = `windows_admin_password` (output do Terraform, passo 3). Sem chave.
- **(Opcional) Vault Credential:** só se usar TLS/PSK — a senha do Ansible Vault.

> Por que credenciais diferentes? Proxy e Linux conectam por **SSH (chave)**; Windows
> por **WinRM (usuário+senha)**.

### 6.4 Job Templates
**Resources → Templates → Add → Job Template** (associe Inventory + a(s) credencial(is)):

| Template | Playbook | Credenciais |
|---|---|---|
| `zbx-configure-all` | `ansible/playbooks/configure-all.yml` | SSH **+** Windows (+ Vault se houver) |
| `zbx-configure-proxy` | `ansible/playbooks/configure-proxy.yml` | SSH |
| `zbx-configure-linux` | `ansible/playbooks/configure-linux.yml` | SSH |
| `zbx-configure-windows` | `ansible/playbooks/configure-windows.yml` | Windows |
| `zbx-validate` | `ansible/playbooks/validate.yml` | SSH + Windows |

- No template do **proxy** (ou no `configure-all`), informe o **Server central** em
  **Variables/Survey** (os agents não precisam — derivam o IP do proxy do inventário):
  ```yaml
  zabbix_server_address: "<DNS do NLB do Zabbix Server, passo 3>"
  ```
- Num Job Template, você pode **anexar mais de uma Machine Credential** (SSH e Windows) —
  o AWX aplica cada uma conforme o host.

## 7. Rodar os playbooks

1. **Launch** do `zbx-configure-all` → instala/configura **proxy → agents Linux →
   agents Windows**. Ao final, os serviços estão rodando e os `.conf` escritos.
2. **Launch** do `zbx-validate` → confere serviços, portas e conectividade
   (agent → proxy, proxy → server).

> Dica de sanidade antes: ad-hoc `ansible proxy:linux -m ansible.builtin.ping` (SSH) e
> `ansible windows -m ansible.windows.win_ping` (WinRM) confirmam a conexão.

Depois disto: os hosts estão **prontos**, mas **ainda não aparecem** no Zabbix — falta
o cadastro manual (passo 8).

## 8. Cadastros manuais no Zabbix

Na UI (passo 5). Aqui é onde você **aprende o fluxo** — nada é automatizado.

### 8.1 Cadastrar o Proxy
**Data collection → Proxies → Create proxy**:
- **Proxy name:** `proxy-01` — **idêntico** ao `Hostname` do `zabbix_proxy.conf`.
- **Proxy mode:** **Active** (configuramos `ProxyMode=0`; o proxy se conecta ao server).
- ✅ Em alguns minutos o proxy aparece com *last seen* recente.

### 8.2 Cadastrar os Hosts (agents)
**Data collection → Hosts → Create host**, um para cada agent:

| Campo | Agent Linux (`linux-01`) | Agent Windows (`windows-01`) |
|---|---|---|
| **Host name** | `linux-01` (= `Hostname` do `.conf`) | `windows-01` (= `Hostname` do `.conf`) |
| **Templates** | `Linux by Zabbix agent` | `Windows by Zabbix agent` |
| **Host groups** | ex.: `POC/Linux` | ex.: `POC/Windows` |
| **Interfaces → Agent** | IP do agent : `10050` | IP do agent : `10050` |
| **Monitored by** | **Proxy** → `proxy-01` | **Proxy** → `proxy-01` |

- **Por que "Monitored by proxy":** diz ao server que **quem coleta é o proxy**, não o
  server direto.
- **Templates já existem** — você não cria; o de Windows é o `Windows by Zabbix agent`.

### 8.3 (Se usar checks ativos)
Para o agent **enviar** ao proxy (ativo), use o template `... by Zabbix agent active`.
Configuramos `Server` **e** `ServerActive` no `.conf`, então os dois modos funcionam.

## 9. Validar a ideia

1. **Monitoring → Hosts:** a coluna **ZBX** fica **verde** (proxy e agents coletando).
2. **Monitoring → Latest data:** filtre por host → veja métricas (CPU, memória, disco).
3. **Monitoring → Hosts → Proxies:** o `proxy-01` aparece *online*.
4. Confirme o caminho completo: **agent (Linux e Windows) → proxy-01 → zabbix-server →
   dados na UI**. Se chegou aqui, a POC está **validada de ponta a ponta**.

Checklist:
- [ ] `kubectl get pods -n awx` e `-n zabbix` tudo `Running`.
- [ ] `zbx-configure-all` e `zbx-validate` verdes no AWX.
- [ ] Proxy `proxy-01` **online**.
- [ ] `linux-01` (Linux) e `windows-01` (Windows) com **ZBX verde**.
- [ ] Métricas em **Latest data** dos dois.

## 10. Troubleshooting

| Sintoma | Provável causa / o que olhar |
|---|---|
| Proxy não fica online | `Proxy name` ≠ `Hostname` do proxy; proxy não alcança o NLB:10051 |
| Host `ZBX` vermelho | IP/porta da Interface; SG bloqueando 10050; serviço do agent parado |
| Agent Windows não conecta (AWX) | WinRM/5986; senha errada na credencial; `user_data` ainda rodando (espere o boot) |
| Agent Linux não conecta (AWX) | chave SSH errada; SG não libera 22 a partir do EKS |
| Nada em Latest data | host sem **template**, ou ainda dentro do 1º intervalo de coleta |

Comandos úteis:
```bash
# Zabbix Server (no cluster)
kubectl -n zabbix logs deploy/zabbix-server | tail -50

# Proxy / Agent Linux (via SSM ou SSH na EC2)
sudo tail -50 /var/log/zabbix/zabbix_proxy.log
sudo tail -50 /var/log/zabbix/zabbix_agent2.log

# Agent Windows (no host, PowerShell)
Get-Content "C:\Program Files\Zabbix Agent 2\zabbix_agent2.log" -Tail 50
Get-Service "Zabbix Agent 2"
```

> Para conectar nas EC2s sem expor SSH/RDP à internet, use o **SSM Session Manager**
> (todas as EC2s têm o instance profile de SSM):
> `aws ssm start-session --target <instance-id>`.
