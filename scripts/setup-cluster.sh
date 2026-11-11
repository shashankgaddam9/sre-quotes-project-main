#!/usr/bin/env bash
# Creates the local lab: kind cluster + ingress-nginx + metrics-server + Prometheus/Grafana/Alertmanager.
# Requires: docker, kind, kubectl, helm
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Creating kind cluster 'sre-lab'"
kind get clusters | grep -q '^sre-lab$' || kind create cluster --config kind/cluster.yaml

echo "==> Installing ingress-nginx"
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl -n ingress-nginx wait --for=condition=ready pod -l app.kubernetes.io/component=controller --timeout=180s

echo "==> Installing metrics-server (needed by HPA and 'kubectl top')"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl -n kube-system patch deployment metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

echo "==> Installing kube-prometheus-stack (Prometheus, Grafana, Alertmanager)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.ruleSelectorNilUsesHelmValues=false \
  --wait --timeout 10m

echo "==> Wiring up app monitoring (ServiceMonitor, alert rules, dashboard)"
kubectl apply -f k8s/monitoring/servicemonitor.yaml
kubectl apply -f k8s/monitoring/prometheusrule.yaml
kubectl -n monitoring create configmap quotes-dashboard \
  --from-file=monitoring/dashboards/quotes-api.json --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -

echo
echo "Done. Next steps:"
echo "  make deploy-local        # build image, load into kind, deploy"
echo "  make grafana             # http://localhost:3000  (admin / admin)"
echo "  make prometheus          # http://localhost:9090"
