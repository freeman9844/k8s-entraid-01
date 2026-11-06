#!/usr/bin/env bash
# Namespace/ServiceAccount 와 데모 코드 ConfigMap 배포 — Secret 은 만들지 않는다
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state CLIENT_ID VM_IP

sed "s|__NS__|${NS}|g; s|__CLIENT_ID__|${CLIENT_ID}|g" "$ROOT_DIR/k8s/base.yaml.tpl" | vm_kubectl apply -f -
vm_scp "$ROOT_DIR/app/demo.py" /tmp/demo.py
vm_kubectl -n "$NS" create configmap wif-demo-app --from-file=demo.py=/tmp/demo.py --dry-run=client -o yaml | vm_kubectl apply -f -
vm_kubectl -n "$NS" get sa,configmap
echo "Secret 목록(비어 있어야 함):"
vm_kubectl -n "$NS" get secrets
