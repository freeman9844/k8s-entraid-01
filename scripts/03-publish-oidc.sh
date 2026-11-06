#!/usr/bin/env bash
# k3s SA 서명 공개키로 JWKS 를 만들고 discovery 문서와 함께 Blob 정적 웹에 업로드 후 검증
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state ISSUER_URL VM_IP STORAGE
[[ -n "$PY" ]] || { echo "python 필요" >&2; exit 1; }

echo "[1/4] SA 서명 공개키 추출 → JWKS 생성"
pem="$(vm_ssh 'for f in service.current.key service.key; do p=/var/lib/rancher/k3s/server/tls/$f; sudo test -f $p && sudo openssl rsa -in $p -pubout 2>/dev/null || true; done')"
cd "$ROOT_DIR"
printf '%s\n' "$pem" | "$PY" scripts/lib/make_jwks.py > "$STATE_DIR/jwks.json"

echo "[2/4] discovery 문서 생성"
cat > "$STATE_DIR/openid-configuration" <<EOF
{
  "issuer": "${ISSUER_URL}",
  "jwks_uri": "${ISSUER_URL}/openid/v1/jwks",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"]
}
EOF

echo "[3/4] 업로드(Entra 로그인 + Storage Blob Data Contributor 역할 사용, 스토리지 키 미사용)"
(
  cd "$STATE_DIR"
  retry 6 10 az storage blob upload --account-name "$STORAGE" --auth-mode login -c '$web' \
    -f openid-configuration -n .well-known/openid-configuration --content-type application/json --overwrite -o none
  retry 6 10 az storage blob upload --account-name "$STORAGE" --auth-mode login -c '$web' \
    -f jwks.json -n openid/v1/jwks --content-type application/json --overwrite -o none
)

echo "[4/4] 공개 URL 확인 + 실제 SA 토큰의 iss/kid 대조"
for i in $(seq 1 12); do
  curl -fsS "${ISSUER_URL}/.well-known/openid-configuration" >/dev/null 2>&1 && \
  curl -fsS "${ISSUER_URL}/openid/v1/jwks" >/dev/null 2>&1 && break
  [[ $i -lt 12 ]] || { echo "공개 URL 접근 실패" >&2; exit 1; }
  sleep 5
done
token="$(vm_kubectl -n default create token default --audience api://AzureADTokenExchange)"
"$PY" scripts/lib/check_jwks.py --issuer "$ISSUER_URL" --token "$token"
