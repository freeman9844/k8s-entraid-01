#!/usr/bin/env bash
# [cert 모드] 양성 1 + Secret 존재(대비) + 음성 2 (다른 인증서 / API Key)
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state FOUNDRY_ENDPOINT APP_CLIENT_ID TENANT_ID VM_IP
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/lib/app.sh"

echo "[1/4] 양성: 인증서로 Foundry 호출 (자격 증명 전파 대기 포함)"
run_app cert-call wif-cert 6
state="$(wait_app cert-call 420)"
logs="$(vm_kubectl -n "$NS" logs deploy/cert-call || true)"
echo "$logs"
[[ "$state" == "ok" ]] && grep -q '^RESULT=OK' <<<"$logs" || fail "양성 테스트 ($state)"
pass "인증서 기반 토큰 발급 및 모델 호출 성공"

echo "[2/4] 개인키가 Secret 으로 클러스터에 저장됨"
secrets="$(vm_kubectl -n "$NS" get secrets -o name)"
grep -q 'secret/wif-cert' <<<"$secrets" || fail "wif-cert Secret 없음"
pass "Secret 존재: $secrets (유출 시 만료 전까지 누구나 토큰 발급 가능)"

echo "[3/4] 음성 1: Entra 에 등록되지 않은 다른 인증서는 거부"
bash scripts/lib/make_cert.sh rogue 1 .state/rogue rogue >/dev/null
vm_scp ".state/rogue/rogue.pem" /tmp/rogue.pem
vm_kubectl -n "$NS" create secret generic wif-cert-rogue --from-file=cert.pem=/tmp/rogue.pem \
  --dry-run=client -o yaml | vm_kubectl apply -f -
vm_ssh "rm -f /tmp/rogue.pem"
run_app cert-call-rogue wif-cert-rogue 1
state="$(wait_app cert-call-rogue 300)"
logs="$(vm_kubectl -n "$NS" logs deploy/cert-call-rogue || true)"
echo "$logs" | tail -n 5
[[ "$state" == "fail" ]] && grep -q 'AADSTS' <<<"$logs" || fail "음성 테스트 1 ($state)"
pass "Entra 가 미등록 인증서를 거부: $(grep -o 'AADSTS[0-9]*' <<<"$logs" | head -n1)"

echo "[4/4] 음성 2: API Key 호출은 disableLocalAuth 로 거부"
code="$(curl -s -w '\n%{http_code}' -H 'api-key: not-a-real-key' -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}],"max_completion_tokens":5}' \
  "${FOUNDRY_ENDPOINT}/openai/deployments/${MODEL_NAME}/chat/completions?api-version=2024-10-21" | tail -n1 | tr -d '\r')"
[[ "$code" == "401" || "$code" == "403" ]] || fail "키 호출이 거부되지 않음 (HTTP $code)"
pass "키 호출 HTTP $code"

echo "🎉 Client Certificate 방식 검증 완료"
