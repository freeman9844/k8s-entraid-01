#!/usr/bin/env bash
# VM에 k3s 설치: ServiceAccount issuer/JWKS URI 를 Blob 정적 웹 URL 로 지정
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state VM_IP
[[ "$AUTH_MODE" == "cert" ]] || require_state ISSUER_URL

echo "[1/3] VM SSH 대기"
for i in $(seq 1 30); do
  vm_ssh true 2>/dev/null && break
  [[ $i -lt 30 ]] || { echo "SSH 연결 실패" >&2; exit 1; }
  sleep 10
done

echo "[2/3] k3s 설정 파일 배포"
if [[ "$AUTH_MODE" == "cert" ]]; then
  echo 'write-kubeconfig-mode: "0644"' > "$STATE_DIR/k3s-config.yaml"   # issuer 설정 없음(기본 k3s)
else
cat > "$STATE_DIR/k3s-config.yaml" <<EOF
write-kubeconfig-mode: "0644"
kube-apiserver-arg:
  - "service-account-issuer=${ISSUER_URL}"
  - "service-account-jwks-uri=${ISSUER_URL}/openid/v1/jwks"
EOF
fi
vm_scp "$STATE_DIR/k3s-config.yaml" /tmp/k3s-config.yaml
vm_ssh "sudo mkdir -p /etc/rancher/k3s && sudo mv /tmp/k3s-config.yaml /etc/rancher/k3s/config.yaml"

echo "[3/3] k3s 설치"
vm_ssh "curl -sfL https://get.k3s.io | sudo sh -"
vm_kubectl wait --for=condition=Ready node --all --timeout=180s
vm_kubectl get nodes
