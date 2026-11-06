#!/usr/bin/env bash
# [cert 모드] Entra 앱 등록 + 서비스 주체 + 클라이언트 인증서(공개키만 업로드) + Foundry RBAC
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state FOUNDRY_ID
cd "$ROOT_DIR"

mkdir -p "$STATE_DIR/cert"
TENANT_ID="$(az account show --query tenantId -o tsv)"
THUMB="$(bash scripts/lib/make_cert.sh "$APP_NAME" 1095 .state/cert client | tr -d '\r')"
save_state CERT_THUMB "$THUMB"
echo "인증서 생성 thumbprint=$THUMB (유효기간 3년)"

echo "[1/3] 앱 등록: $APP_NAME"
APP_CLIENT_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv | tr -d '\r')"
save_state APP_CLIENT_ID "$APP_CLIENT_ID"
save_state TENANT_ID "$TENANT_ID"
retry 6 10 az ad sp create --id "$APP_CLIENT_ID" -o none
SP_OID="$(az ad sp show --id "$APP_CLIENT_ID" --query id -o tsv | tr -d '\r')"

echo "[2/3] 공개 인증서 업로드 (개인키는 Entra 로 가지 않음)"
az ad app credential reset --id "$APP_CLIENT_ID" --cert "@.state/cert/client.crt" --append -o none

echo "[3/3] RBAC: 서비스 주체 → Cognitive Services OpenAI User"
retry 12 10 az role assignment create --assignee-object-id "$SP_OID" --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" --scope "$FOUNDRY_ID" -o none
echo "완료: app=$APP_CLIENT_ID tenant=$TENANT_ID"
