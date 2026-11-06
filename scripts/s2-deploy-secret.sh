#!/usr/bin/env bash
# [secret 모드] Client Secret 을 Kubernetes Secret 으로 저장하고 데모 코드 ConfigMap 배포
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state SECRET_APP_ID VM_IP
cd "$ROOT_DIR"

vm_kubectl create namespace "$NS" --dry-run=client -o yaml | vm_kubectl apply -f -
vm_scp ".state/secret/client-secret.txt" /tmp/client-secret.txt
vm_scp "app/demo_secret.py" /tmp/demo_secret.py
vm_kubectl -n "$NS" create secret generic wif-secret --from-file=client-secret=/tmp/client-secret.txt \
  --dry-run=client -o yaml | vm_kubectl apply -f -
vm_kubectl -n "$NS" create configmap secret-demo-app --from-file=demo_secret.py=/tmp/demo_secret.py \
  --dry-run=client -o yaml | vm_kubectl apply -f -
vm_ssh "shred -u /tmp/client-secret.txt 2>/dev/null || rm -f /tmp/client-secret.txt"
vm_kubectl -n "$NS" get secrets,configmap
