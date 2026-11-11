#!/usr/bin/env bash
# Deploys your latest pushed code to the Azure server.
# Usage (from the project folder, after `git push`):  ./scripts/azure-deploy.sh
#
# How it works: Azure "Run Command" runs a script on the VM for you (no SSH needed):
# pull the latest code from GitHub, rebuild the image, restart only what changed.
set -euo pipefail
cd "$(dirname "$0")/../terraform/azure"

RG=$(terraform output -raw resource_group)
VM=$(terraform output -raw vm_name)

echo "==> Deploying to $VM (this takes 1-3 minutes)"
az vm run-command invoke \
  --resource-group "$RG" \
  --name "$VM" \
  --command-id RunShellScript \
  --scripts 'set -e
cd /opt/sre-quotes
git pull --ff-only
export APP_VERSION=$(git rev-parse --short HEAD)
docker compose -f docker-compose.yml -f docker-compose.azure.yml up -d --build
docker compose -f docker-compose.yml -f docker-compose.azure.yml ps' \
  --query 'value[0].message' --output tsv

echo
echo "Check the site: $(terraform output -raw website_url)/healthz  (the version should be your latest commit)"
