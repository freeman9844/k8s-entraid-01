#!/usr/bin/env bash
# 양성 1 + Secret 부재 + 음성 2 검증
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state FOUNDRY_ENDPOINT VM_IP

run_job() { # name sa retries
  vm_kubectl -n "$NS" delete job "$1" --ignore-not-found >/dev/null
  sed "s|__NAME__|$1|g; s|__NS__|${NS}|g; s|__SA__|$2|g; s|__ENDPOINT__|${FOUNDRY_ENDPOINT}|g; s|__DEPLOYMENT__|${MODEL_NAME}|g; s|__RETRIES__|$3|g" \
    "$ROOT_DIR/k8s/job.yaml.tpl" | vm_kubectl apply -f - >/dev/null
}

wait_job() { # name timeout_sec -> succeeded|failed|timeout
  local deadline=$((SECONDS + $2)) s f
  while (( SECONDS < deadline )); do
    s="$(vm_kubectl -n "$NS" get job "$1" -o jsonpath='{.status.succeeded}')"
    f="$(vm_kubectl -n "$NS" get job "$1" -o jsonpath='{.status.failed}')"
    [[ "$s" == "1" ]] && { echo succeeded; return 0; }
    [[ "$f" == "1" ]] && { echo failed; return 0; }
    sleep 5
  done
  echo timeout
}

fail() { echo "❌ 실패: $*" >&2; exit 1; }
pass() { echo "✅ 통과: $*"; }

echo "[1/4] 양성: wif-sa 파드가 키 없이 Foundry 호출 (federated credential 전파 대기 포함)"
run_job wif-call "$SA_NAME" 6
state="$(wait_job wif-call 420)"
logs="$(vm_kubectl -n "$NS" logs job/wif-call || true)"
echo "$logs"
[[ "$state" == "succeeded" ]] && grep -q '^RESULT=OK' <<<"$logs" || fail "양성 테스트 ($state)"
pass "토큰 교환 및 모델 호출 성공"

echo "[2/4] 증명: 네임스페이스에 Secret 없음"
secrets="$(vm_kubectl -n "$NS" get secrets -o name)"
[[ -z "$secrets" ]] || fail "Secret 존재: $secrets"
pass "Secret 0개"

echo "[3/4] 음성 1: 다른 ServiceAccount($OTHER_SA)는 subject 불일치로 거부"
run_job wif-call-other "$OTHER_SA" 1
state="$(wait_job wif-call-other 300)"
logs="$(vm_kubectl -n "$NS" logs job/wif-call-other || true)"
echo "$logs" | tail -n 5
[[ "$state" == "failed" ]] && grep -q 'AADSTS700213' <<<"$logs" || fail "음성 테스트 1 ($state)"
pass "Entra가 AADSTS700213 으로 거부"

echo "[4/4] 음성 2: API Key 호출은 disableLocalAuth 로 거부"
code="$(curl -s -w '\n%{http_code}' -H 'api-key: not-a-real-key' -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}],"max_completion_tokens":5}' \
  "${FOUNDRY_ENDPOINT}/openai/deployments/${MODEL_NAME}/chat/completions?api-version=2024-10-21" | tail -n1 | tr -d '\r')"
[[ "$code" == "401" || "$code" == "403" ]] || fail "키 호출이 거부되지 않음 (HTTP $code)"
pass "키 호출 HTTP $code"

echo "🎉 모든 검증 통과: keyless WIF 증명 완료"
