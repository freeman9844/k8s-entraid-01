#!/usr/bin/env bash
# 일반 Kubernetes(kubeadm) 단일 노드 설치. issuer 플래그 없이 기본 설정으로 구성한다.
# 이후 03~07 은 KUBECTL_CMD="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf" 로 실행한다.
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state VM_IP

for i in $(seq 1 30); do
  vm_ssh true 2>/dev/null && break
  [[ $i -lt 30 ]] || { echo "SSH 연결 실패" >&2; exit 1; }
  sleep 10
done

cat > "$STATE_DIR/kubeadm-install.sh" <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
sudo swapoff -a
printf 'overlay\nbr_netfilter\n' | sudo tee /etc/modules-load.d/k8s.conf >/dev/null
sudo modprobe overlay; sudo modprobe br_netfilter
printf 'net.bridge.bridge-nf-call-iptables=1\nnet.ipv4.ip_forward=1\n' | sudo tee /etc/sysctl.d/k8s.conf >/dev/null
sudo sysctl --system >/dev/null

sudo apt-get update -qq
sudo apt-get install -y -qq containerd apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd

MINOR="$(curl -fsSL https://dl.k8s.io/release/stable.txt | cut -d. -f1,2)"
echo "Kubernetes ${MINOR}"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${MINOR}/deb/Release.key" | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${MINOR}/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
sudo apt-get update -qq
sudo apt-get install -y -qq kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl >/dev/null

sudo kubeadm init --pod-network-cidr=10.244.0.0/16
export KUBECONFIG=/etc/kubernetes/admin.conf
sudo kubectl --kubeconfig "$KUBECONFIG" apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
sudo kubectl --kubeconfig "$KUBECONFIG" taint nodes --all node-role.kubernetes.io/control-plane- || true
sudo kubectl --kubeconfig "$KUBECONFIG" wait --for=condition=Ready node --all --timeout=300s
EOF
vm_scp "$STATE_DIR/kubeadm-install.sh" /tmp/kubeadm-install.sh
vm_ssh "bash /tmp/kubeadm-install.sh"
KUBECTL_CMD="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf" vm_kubectl get nodes -o wide
