#!/usr/bin/env bash
# [secret 모드] 양성 1 + Secret 평문 노출(대비) + 음성 2 (잘못된 Secret / API Key)
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state FOUNDRY_ENDPOINT SECRET_APP_ID TENANT_ID VM_IP
cd "$ROOT_DIR"
APP_CLIENT_ID="$SECRET_APP_ID"
APP_TEMPLATE="k8s/deploy-secret.yaml.tpl"
source "$ROOT_DIR/scripts/lib/app.sh"

echo "[1/4] 양성: Client Secret 으로 Foundry 호출 (자격 증명 전파 대기 포함)"
run_app secret-call wif-secret 6
state="$(wait_app secret-call 420)"
logs="$(vm_kubectl -n "$NS" logs deploy/secret-call || true)"
echo "$logs"
[[ "$state" == "ok" ]] && grep -q '^RESULT=OK' <<<"$logs" || fail "양성 테스트 ($state)"
pass "Client Secret 기반 토큰 발급 및 모델 호출 성공"

echo "[2/4] 대비: Secret 값이 base64 디코딩만으로 평문 노출됨 (값은 출력하지 않고 길이만 확인)"
len="$(vm_kubectl -n "$NS" get secret wif-secret -o jsonpath='{.data.client-secret}' | base64 -d | wc -c | tr -d ' \r')"
[[ "$len" -gt 0 ]] || fail "Secret 값 없음"
pass "Secret 읽기 권한만 있으면 ${len}자 평문 복원 가능 (유출 시 만료 전까지 누구나 토큰 발급 가능)"

echo "[3/4] 음성 1: 잘못된 Client Secret 은 거부"
vm_kubectl -n "$NS" create secret generic wif-secret-wrong --from-literal=client-secret=wrong-secret-value \
  --dry-run=client -o yaml | vm_kubectl apply -f - >/dev/null
run_app secret-call-wrong wif-secret-wrong 1
state="$(wait_app secret-call-wrong 300)"
logs="$(vm_kubectl -n "$NS" logs deploy/secret-call-wrong || true)"
echo "$logs" | tail -n 4 | cut -c1-300
[[ "$state" == "fail" ]] && grep -q 'AADSTS' <<<"$logs" || fail "음성 테스트 1 ($state)"
pass "Entra 가 잘못된 Secret 을 거부: $(grep -o 'AADSTS[0-9]*' <<<"$logs" | head -n1)"

echo "[4/4] 음성 2: API Key 호출은 disableLocalAuth 로 거부"
code="$(curl -s -w '\n%{http_code}' -H 'api-key: not-a-real-key' -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}],"max_completion_tokens":5}' \
  "${FOUNDRY_ENDPOINT}/openai/deployments/${MODEL_NAME}/chat/completions?api-version=2024-10-21" | tail -n1 | tr -d '\r')"
[[ "$code" == "401" || "$code" == "403" ]] || fail "키 호출이 거부되지 않음 (HTTP $code)"
pass "키 호출 HTTP $code"

echo "🎉 Client Secret 방식 검증 완료"
