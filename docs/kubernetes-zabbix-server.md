# Zabbix Server no cluster (Stage 2)

> 📂 Código/manifests: [`kubernetes/zabbix-server/`](../kubernetes/zabbix-server/)

Sobe o **Zabbix Server central** dentro do EKS (server + frontend web + PostgreSQL
interno), para a POC ficar completa: **agent → proxy → server → UI**.

> Instalado via `kubectl`/kustomize no Stage 2 (mesmo padrão do AWX), **não** pelo
> Terraform — assim o Terraform não depende da API do cluster.

## Componentes

| Arquivo | Recurso | Exposição |
|---|---|---|
| `postgres.yaml` | PostgreSQL (`postgres:16-alpine`) + PVC gp3 | `ClusterIP` 5432 (interno) |
| `server.yaml` | `zabbix-server-pgsql` (cria schema sozinho) | **NLB interno** 10051 (trapper) |
| `web.yaml` | `zabbix-web-nginx-pgsql` (frontend) | `ClusterIP` 80→8080 (port-forward) |
| `namespace.yaml` | namespace `zabbix` | — |

A senha do banco fica no secret **`zabbix-db`**, **gerado pelo pipeline** (não
versionado).

## Por que NLB interno para o trapper

O **Zabbix Proxy roda numa EC2 fora do cluster** e precisa alcançar o server na porta
**10051**. Um `ClusterIP` não serve para quem está fora do cluster, então o Service do
server é `type: LoadBalancer` com anotações que criam um **NLB interno** (nas subnets
privadas, tag `kubernetes.io/role/internal-elb`). As EC2s da VPC alcançam esse NLB; ele
**não é exposto à internet**. Usa o cloud-provider in-tree do EKS — **não** exige o AWS
Load Balancer Controller.

## Endereço do Server para o Proxy

Após o deploy, pegue o DNS do NLB:

```bash
kubectl -n zabbix get svc zabbix-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
```

Esse hostname é o **`zabbix_server_address`** que você informa ao AWX/Ansible do Proxy
(extra-var/survey do Job Template). O pipeline também o publica no *Summary* do Stage 2.

## Acessar a UI

```bash
kubectl -n zabbix port-forward svc/zabbix-web 8888:80
# http://localhost:8888  (login padrão do Zabbix: Admin / zabbix)
```

## Validar

```bash
kubectl -n zabbix get pods
kubectl -n zabbix get svc zabbix-server   # EXTERNAL-IP = DNS do NLB interno
kubectl -n zabbix logs deploy/zabbix-server | grep -i "server #0 started"
```

## Custo / recursos

Recursos propositalmente **enxutos** (requests ~100m CPU / 128–256Mi por pod) para
caber nos 2× `t3.large` junto do AWX. Se houver pressão (pods `Pending` por falta de
CPU/memória), aumente `eks_node_desired_size` no Terraform (ou o instance type).

## Remoção

O namespace `zabbix` é removido no `action=destroy` do pipeline **antes** de destruir a
VPC — isso libera o **NLB** (senão ele trava a deleção das subnets). Manual:

```bash
kubectl delete namespace zabbix --wait=true
```
