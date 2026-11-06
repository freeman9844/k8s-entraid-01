#!/usr/bin/env bash
# RG, UAMI, Storage(정적 웹), Foundry(+gpt-4o-mini, 키 인증 차단), RBAC, VM 생성
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
preflight

save_state TENANT_ID "$(az account show --query tenantId -o tsv)"
save_state SUBSCRIPTION_ID "$(az account show --query id -o tsv)"
save_state MY_IP "$(curl -fsS https://api.ipify.org)"

echo "[1/6] 리소스 그룹: $RG ($LOCATION)"
az group create -n "$RG" -l "$LOCATION" -o none

if [[ "$AUTH_MODE" == "wif" ]]; then
echo "[2/6] User-assigned Managed Identity: $UAMI"
az identity create -g "$RG" -n "$UAMI" -l "$LOCATION" -o none
save_state CLIENT_ID "$(az identity show -g "$RG" -n "$UAMI" --query clientId -o tsv)"
save_state PRINCIPAL_ID "$(az identity show -g "$RG" -n "$UAMI" --query principalId -o tsv)"

echo "[3/6] Storage 정적 웹사이트(OIDC issuer 호스팅): $STORAGE"
az storage account create -g "$RG" -n "$STORAGE" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 -o none
STORAGE_ID="$(az storage account show -g "$RG" -n "$STORAGE" --query id -o tsv)"
az role assignment create --assignee-object-id "$(az ad signed-in-user show --query id -o tsv)" \
  --assignee-principal-type User --role "Storage Blob Data Contributor" --scope "$STORAGE_ID" -o none
retry 18 10 az storage blob service-properties update --account-name "$STORAGE" \
  --static-website --index-document index.html --auth-mode login -o none
web_url="$(az storage account show -g "$RG" -n "$STORAGE" --query primaryEndpoints.web -o tsv)"
save_state ISSUER_URL "${web_url%/}"
else
echo "[2-3/6] AUTH_MODE=cert: UAMI/issuer 호스팅 불필요 (앱 등록은 c1-create-app-cert.sh 에서 생성)"
fi

echo "[4/6] Foundry(AIServices) + $MODEL_NAME 배포, 키 인증 차단"
cat > "$STATE_DIR/foundry.json" <<EOF
{
  "location": "${LOCATION}",
  "kind": "AIServices",
  "sku": { "name": "S0" },
  "properties": {
    "customSubDomainName": "${FOUNDRY}",
    "publicNetworkAccess": "Enabled",
    "disableLocalAuth": true
  }
}
EOF
(cd "$STATE_DIR" && az rest --method put -o none \
  --url "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}/providers/Microsoft.CognitiveServices/accounts/${FOUNDRY}?api-version=2025-06-01" \
  --body "@foundry.json")
provisioned() { [[ "$(az cognitiveservices account show -g "$RG" -n "$FOUNDRY" --query properties.provisioningState -o tsv)" == "Succeeded" ]]; }
retry 30 10 provisioned
save_state FOUNDRY_ID "$(az cognitiveservices account show -g "$RG" -n "$FOUNDRY" --query id -o tsv)"
az cognitiveservices account deployment create -g "$RG" -n "$FOUNDRY" \
  --deployment-name "$MODEL_NAME" --model-name "$MODEL_NAME" --model-version "$MODEL_VERSION" \
  --model-format OpenAI --sku-name "$MODEL_SKU" --sku-capacity "$MODEL_CAPACITY" -o none
save_state FOUNDRY_ENDPOINT "https://${FOUNDRY}.openai.azure.com"

if [[ "$AUTH_MODE" == "wif" ]]; then
echo "[5/6] RBAC: UAMI → Cognitive Services OpenAI User"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" --scope "$FOUNDRY_ID" -o none
fi

echo "[6/6] VM(k3s 호스트, 관리 ID 없음) — SSH는 현재 공인 IP($MY_IP)만 허용"
az vm create -g "$RG" -n "$VM_NAME" -l "$LOCATION" --image Ubuntu2204 --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" --generate-ssh-keys --public-ip-sku Standard --nsg-rule NONE -o none
az network nsg rule create -g "$RG" --nsg-name "${VM_NAME}NSG" -n allow-ssh-from-me --priority 1000 \
  --access Allow --protocol Tcp --direction Inbound --source-address-prefixes "$MY_IP" \
  --destination-port-ranges 22 -o none
save_state VM_IP "$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)"

echo "완료: mode=$AUTH_MODE, issuer=${ISSUER_URL:-없음}, endpoint=$FOUNDRY_ENDPOINT, vm=$VM_IP"
