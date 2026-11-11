#!/usr/bin/env bash
# Deploys your latest pushed code to the AWS server, without SSH.
# Usage (from the project folder, after `git push`):  ./scripts/aws-deploy.sh
#
# How it works: AWS Systems Manager (SSM) runs a command on the server:
# pull the latest code from GitHub, rebuild the image, restart only what changed.
set -euo pipefail
cd "$(dirname "$0")/../terraform/aws"

INSTANCE_ID=$(terraform output -raw instance_id)
REGION=$(terraform output -raw region)

echo "==> Deploying to $INSTANCE_ID in $REGION"
CMD_ID=$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "deploy sre-quotes" \
  --parameters '{"commands":["set -e","cd /opt/sre-quotes","git pull --ff-only","export APP_VERSION=$(git rev-parse --short HEAD)","docker compose -f docker-compose.yml -f docker-compose.aws.yml up -d --build","docker compose -f docker-compose.yml -f docker-compose.aws.yml ps"]}' \
  --query 'Command.CommandId' --output text)

echo "==> Waiting for the server to finish (this can take a minute or two)"
aws ssm wait command-executed --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" || true

aws ssm get-command-invocation --region "$REGION" --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '{Status:Status,Output:StandardOutputContent,Errors:StandardErrorContent}' --output yaml

echo
echo "Check the site: $(terraform output -raw website_url)/healthz  (the version should be your latest commit)"
