#!/usr/bin/env bash
# Azure Workload Identity webhook 설치(helm)
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state TENANT_ID VM_IP

vm_ssh 'command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash'
vm_ssh "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; \
  helm repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts --force-update && \
  helm repo update && \
  helm upgrade --install workload-identity-webhook azure-workload-identity/workload-identity-webhook \
    --namespace azure-workload-identity-system --create-namespace \
    --set azureTenantID=${TENANT_ID} --wait --timeout 5m"
vm_kubectl -n azure-workload-identity-system get pods
