#!/usr/bin/env bash
# [secret 모드] Entra 앱 등록 + 서비스 주체 + Client Secret(1년) + Foundry RBAC
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state FOUNDRY_ID
cd "$ROOT_DIR"

mkdir -p "$STATE_DIR/secret"
TENANT_ID="$(az account show --query tenantId -o tsv | tr -d '\r')"
SECRET_APP_NAME="app-wif-secret-${SUFFIX}"

echo "[1/3] 앱 등록: $SECRET_APP_NAME"
SECRET_APP_ID="$(az ad app create --display-name "$SECRET_APP_NAME" --query appId -o tsv | tr -d '\r')"
save_state SECRET_APP_ID "$SECRET_APP_ID"
save_state TENANT_ID "$TENANT_ID"
retry 6 10 az ad sp create --id "$SECRET_APP_ID" -o none
SP_OID="$(az ad sp show --id "$SECRET_APP_ID" --query id -o tsv | tr -d '\r')"

echo "[2/3] Client Secret 생성 (유효기간 1년, 값은 .state/secret 에만 저장하고 출력하지 않음)"
printf '%s' "$(az ad app credential reset --id "$SECRET_APP_ID" --append --display-name wif-demo --years 1 --query password -o tsv 2>/dev/null | tr -d '\r\n')" > "$STATE_DIR/secret/client-secret.txt"
[[ -s "$STATE_DIR/secret/client-secret.txt" ]] || { echo "Client Secret 생성 실패" >&2; exit 1; }

echo "[3/3] RBAC: 서비스 주체 → Cognitive Services OpenAI User"
retry 12 10 az role assignment create --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" --scope "$FOUNDRY_ID" -o none
echo "완료: app=$SECRET_APP_ID"
