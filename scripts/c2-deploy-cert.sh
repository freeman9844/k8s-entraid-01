#!/usr/bin/env bash
# [cert 모드] 네임스페이스, 개인키 Secret, 데모 코드 ConfigMap 배포
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state APP_CLIENT_ID VM_IP
cd "$ROOT_DIR"

vm_kubectl create namespace "$NS" --dry-run=client -o yaml | vm_kubectl apply -f -
vm_scp ".state/cert/client.pem" /tmp/client.pem
vm_scp "app/demo_cert.py" /tmp/demo_cert.py
vm_kubectl -n "$NS" create secret generic wif-cert --from-file=cert.pem=/tmp/client.pem \
  --dry-run=client -o yaml | vm_kubectl apply -f -
vm_kubectl -n "$NS" create configmap cert-demo-app --from-file=demo_cert.py=/tmp/demo_cert.py \
  --dry-run=client -o yaml | vm_kubectl apply -f -
vm_ssh "shred -u /tmp/client.pem 2>/dev/null || rm -f /tmp/client.pem"
vm_kubectl -n "$NS" get secrets,configmap
