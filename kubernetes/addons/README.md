# Addons de cluster (Stage 2)

Addons mínimos instalados via **kubectl** no Stage 2 do pipeline (não pelo
Terraform), para que o Terraform **não dependa da API do cluster** em
`plan`/`apply`/`destroy`. Somem junto com o cluster no destroy.

## metrics-server

- Habilita `kubectl top` e HPA.
- Instalado a partir do manifesto oficial **pinado** (`v0.7.2`):
  `https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml`
- **EKS:** o certificado de serving do kubelet não é confiável por padrão, então
  o pipeline adiciona o argumento `--kubelet-insecure-tls` ao deployment (senão o
  metrics-server falha ao raspar os kubelets). Para a POC é aceitável; em produção
  avalie aprovar os CSRs de serving do kubelet em vez de usar insecure-tls.

### Aplicar manualmente

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/download/v0.7.2/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s

# validar
kubectl top nodes
```

Para trocar a versão, ajuste o pin no manifesto acima e no passo
`Instalar metrics-server (addon)` do workflow.
