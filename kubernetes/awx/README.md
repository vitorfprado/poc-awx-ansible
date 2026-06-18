# AWX no EKS — Stage 2 da POC

Bootstrap do cluster EKS (criado no Stage 1 via Terraform) e instalação do
**AWX Operator** + **AWX** com **PostgreSQL interno** do operator.

> **Escopo:** apenas subir o AWX. A configuração de Zabbix Proxy/Agent e os
> playbooks Ansible **não** fazem parte desta etapa.

## Conteúdo

| Arquivo | Função |
|---|---|
| `kustomization.yaml` | Instala o AWX Operator (base oficial, ref fixado) + StorageClass. |
| `storageclass.yaml` | StorageClass `ebs-csi-gp3` (EBS CSI) para o PVC do PostgreSQL. |
| `awx.yaml` | Custom Resource `AWX` (PostgreSQL interno, ClusterIP, recursos mínimos). |

> O namespace `awx` é criado pela própria base do operator (`config/default`), por
> isso não há um `namespace.yaml` aqui — declará-lo duplicaria o recurso.

## Addons necessários (e por quê)

O mínimo para o AWX rodar **já vem do Terraform (Stage 1)**:

- `coredns`, `kube-proxy`, `vpc-cni` — addons base do EKS;
- **EBS CSI driver** (com IRSA) — provisionamento dinâmico de volumes.

No cluster, o Stage 2 só adiciona a **StorageClass gp3** (`storageclass.yaml`). O
**metrics-server** (`kubectl top` / HPA) é instalado pelo **Terraform** (módulo
`eks/addons`, no Stage 1). **Não** são instalados cert-manager nem ingress
controller (o AWX fica em ClusterIP + port-forward), mantendo a POC simples.

## Por que dois passos (e não um `apply -k`)

O CRD do AWX e o Custom Resource não podem ser aplicados juntos (o CR falharia
porque o CRD ainda não existe). Por isso:

1. `kubectl apply -k .` → instala operator + namespace + StorageClass;
2. aguardar o operator; então `kubectl apply -f awx.yaml` → cria a instância AWX.

A pipeline (Stage 2) faz isso automaticamente. Para rodar **manualmente**:

```bash
# pré-requisito: kubeconfig apontando para o cluster da POC
aws eks update-kubeconfig --name <cluster> --region <region>

# 1) Operator + namespace + StorageClass
kubectl apply -k kubernetes/awx

# 2) aguardar o operator
kubectl -n awx rollout status deployment/awx-operator-controller-manager --timeout=300s

# 3) instância AWX
kubectl apply -f kubernetes/awx/awx.yaml
```

## Validar os pods do AWX

```bash
kubectl get pods -n awx
kubectl get svc -n awx
```

Espere os deployments `awx-web` e `awx-task` ficarem disponíveis (o operator pode
levar alguns minutos para criá-los após o `awx.yaml`):

```bash
kubectl -n awx rollout status deployment/awx-web  --timeout=900s
kubectl -n awx rollout status deployment/awx-task --timeout=900s
```

## Obter a senha do admin

O operator cria o secret `awx-admin-password`:

```bash
kubectl -n awx get secret awx-admin-password \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

Usuário padrão: `admin`.

## Port-forward e acesso local

```bash
kubectl -n awx port-forward svc/awx-service 8080:80
```

Acesse: <http://localhost:8080> (usuário `admin`, senha do passo anterior).

## Troubleshooting

- **Operator preso em `1/2 ImagePullBackOff` (`kube-rbac-proxy ... not found`):**
  o awx-operator 2.19.1 aponta para `gcr.io/kubebuilder/kube-rbac-proxy:v0.15.0`,
  que foi removido daquele registry. O `kustomization.yaml` já remapeia essa imagem
  para `quay.io/brancz/kube-rbac-proxy` — garanta que está usando esta versão dos
  manifests.
- **PostgreSQL (`awx-postgres-*`) em `Pending`:** verifique o PVC
  (`kubectl -n awx get pvc`) e se a StorageClass `ebs-csi-gp3` existe e o EBS CSI
  driver está saudável.
- **PostgreSQL em `CrashLoopBackOff` com `Permission denied` em
  `/var/lib/pgsql/data/userdata`:** a imagem roda como usuário não-root e não
  consegue escrever no volume EBS recém-provisionado. O `awx.yaml` já define
  `postgres_data_volume_init: true` (init container que ajusta a permissão).

## Remover tudo

A POC é destruída pelo Terraform (Stage 1):

```bash
# action=destroy na pipeline, ou localmente:
cd iac/awx-zabbix-poc
terraform destroy
```

> **Atenção:** o PVC do PostgreSQL provisiona um volume **EBS** dinamicamente, que
> **não** é gerenciado pelo Terraform. Destruir o cluster sem remover o AWX antes
> pode deixar o volume órfão. Para um destroy limpo, remova o namespace primeiro
> (a pipeline já faz isso no `action=destroy`):
>
> ```bash
> kubectl delete namespace awx --wait=true
> ```
