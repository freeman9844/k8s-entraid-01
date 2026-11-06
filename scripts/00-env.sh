#!/usr/bin/env bash
# source 전용: 변수, 상태 저장, VM 헬퍼, 사전 점검
set -euo pipefail
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/.state"
STATE_FILE="$STATE_DIR/state.env"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
# shellcheck disable=SC1090
source "$STATE_FILE"

save_state() {
  local key="$1" value="$2"
  { grep -v "^${key}=" "$STATE_FILE" || true; echo "${key}=\"${value}\""; } > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  export "${key}=${value}"
}

: "${LOCATION:=eastus2}"
: "${VM_SIZE:=Standard_D2s_v7}"
: "${MODEL_NAME:=gpt-5.4-mini}"
: "${MODEL_VERSION:=2026-03-17}"
: "${MODEL_SKU:=GlobalStandard}"
: "${MODEL_CAPACITY:=10}"
: "${AUTH_MODE:=wif}"   # wif | cert (cert: Entra 앱 등록 + Client Certificate)
NS="wif-demo"
SA_NAME="wif-sa"
OTHER_SA="wif-other-sa"
ADMIN_USER="azureuser"

if [[ -z "${SUFFIX:-}" ]]; then
  save_state SUFFIX "$(printf '%05x' $((RANDOM * RANDOM % 1048576)))"
fi
RG="rg-wif-demo-${SUFFIX}"
VM_NAME="vm-k3s-wif"
STORAGE="stwif${SUFFIX}"
UAMI="id-wif-demo"
FOUNDRY="foundry-wif-${SUFFIX}"
APP_NAME="app-wif-cert-${SUFFIX}"

pick_python() {
  local c
  for c in python3 python; do
    if "$c" -c 'import sys' >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  return 1
}
PY="$(pick_python || true)"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$STATE_DIR/known_hosts" -o ConnectTimeout=10)

vm_ssh() { ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$VM_IP" "$@"; }
vm_scp() { ( cd "$(dirname "$1")" && scp "${SSH_OPTS[@]}" "$(basename "$1")" "$ADMIN_USER@$VM_IP:$2" ); }
: "${KUBECTL_CMD:=sudo k3s kubectl}"   # kubeadm 등: KUBECTL_CMD="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf"
vm_kubectl() { vm_ssh "$KUBECTL_CMD $(printf '%q ' "$@")"; }

retry() { # tries delay cmd...
  local tries="$1" delay="$2" i; shift 2
  for i in $(seq 1 "$tries"); do
    "$@" && return 0
    [[ $i -lt $tries ]] && sleep "$delay"
  done
  return 1
}

require_state() {
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || { echo "상태 변수 $v 가 없습니다. 이전 단계를 먼저 실행하세요." >&2; exit 1; }
  done
}

preflight() {
  local c
  for c in az ssh scp curl; do
    command -v "$c" >/dev/null || { echo "필요한 도구가 없습니다: $c" >&2; exit 1; }
  done
  [[ -n "$PY" ]] || { echo "python3/python 이 필요합니다" >&2; exit 1; }
  "$PY" -c 'import cryptography' 2>/dev/null || { echo "pip install -r requirements-dev.txt 를 먼저 실행하세요" >&2; exit 1; }
  az account show >/dev/null 2>&1 || { echo "az login 을 먼저 실행하세요" >&2; exit 1; }
  local n
  n=$(az cognitiveservices model list -l "$LOCATION" \
    --query "[?model.name=='$MODEL_NAME' && model.version=='$MODEL_VERSION' && model.lifecycleStatus=='GenerallyAvailable'] | length(@)" -o tsv)
  [[ "${n:-0}" -gt 0 ]] || { echo "$LOCATION 에서 $MODEL_NAME $MODEL_VERSION (GA)을 사용할 수 없습니다. LOCATION/MODEL_NAME/MODEL_VERSION 을 바꾸세요." >&2; exit 1; }
  n=$(az vm list-skus -l "$LOCATION" --size "$VM_SIZE" --resource-type virtualMachines \
    --query "[?restrictions==\`[]\`] | length(@)" -o tsv)
  [[ "${n:-0}" -gt 0 ]] || { echo "$LOCATION 에서 VM 크기 $VM_SIZE 를 사용할 수 없습니다. VM_SIZE 를 바꾸세요." >&2; exit 1; }
}
