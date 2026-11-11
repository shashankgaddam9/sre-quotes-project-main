#!/usr/bin/env bash
# Installs Argo CD into the lab cluster and prints the admin password.
set -euo pipefail
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=300s
echo
echo "Argo CD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo
echo "Open the UI:  kubectl -n argocd port-forward svc/argocd-server 8443:443  ->  https://localhost:8443"
echo "Then edit argocd/applications.yaml with your GitHub username and: kubectl apply -f argocd/applications.yaml"
