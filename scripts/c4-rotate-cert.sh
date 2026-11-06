#!/usr/bin/env bash
# [cert 모드] 인증서 갱신 테스트: 신규 추가(--append) → 중복 기간 → Secret 교체/재시작 → 옛 키 삭제 → 옛 인증서 거부
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state FOUNDRY_ENDPOINT APP_CLIENT_ID TENANT_ID VM_IP CERT_THUMB
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/lib/app.sh"
OLD_THUMB="$CERT_THUMB"

app_logs() { vm_kubectl -n "$NS" logs "deploy/$1" 2>/dev/null || true; }
wait_thumb() { # name thumb timeout_sec : 해당 thumbprint 로 RESULT=OK 가 나올 때까지 대기
  local deadline=$((SECONDS + $3)) l
  while (( SECONDS < deadline )); do
    l="$(app_logs "$1")"
    grep -q "thumbprint: $2" <<<"$l" && grep -q '^RESULT=OK' <<<"$l" && return 0
    sleep 5
  done
  return 1
}

echo "[1/6] 기준선: 옛 인증서($OLD_THUMB)로 앱 동작"
run_app cert-app wif-cert 6
wait_thumb cert-app "$OLD_THUMB" 420 || fail "기준선 호출 실패"
pass "옛 인증서로 호출 성공"

echo "[2/6] 새 인증서(90일) 생성 후 Entra 에 추가 (--append, 옛 키 유지)"
OLD_KEY_ID="$(az ad app credential list --id "$APP_CLIENT_ID" --cert --query "[0].keyId" -o tsv | tr -d '\r')"
NEW_THUMB="$(bash scripts/lib/make_cert.sh "$APP_NAME" 90 .state/cert-new client | tr -d '\r')"
az ad app credential reset --id "$APP_CLIENT_ID" --cert "@.state/cert-new/client.crt" --append -o none 2>/dev/null
count="$(az ad app credential list --id "$APP_CLIENT_ID" --cert --query "length(@)" -o tsv | tr -d '\r')"
[[ "$count" == "2" ]] || fail "등록된 인증서가 2개가 아님 ($count)"
pass "Entra 에 인증서 2개 공존: 옛 $OLD_THUMB / 새 $NEW_THUMB"

echo "[3/6] 중복 기간: 옛 인증서 전용 파드가 여전히 성공하는지 확인"
vm_scp ".state/cert/client.pem" /tmp/old.pem
vm_kubectl -n "$NS" create secret generic wif-cert-old --from-file=cert.pem=/tmp/old.pem --dry-run=client -o yaml | vm_kubectl apply -f - >/dev/null
vm_ssh "rm -f /tmp/old.pem"
run_app cert-old wif-cert-old 6
wait_thumb cert-old "$OLD_THUMB" 420 || fail "중복 기간에 옛 인증서가 거부됨"
pass "중복 기간 동안 옛 인증서도 유효 (무중단 전환 가능)"

echo "[4/6] Secret 덮어쓰기 + rollout restart"
vm_scp ".state/cert-new/client.pem" /tmp/new.pem
vm_kubectl -n "$NS" create secret generic wif-cert --from-file=cert.pem=/tmp/new.pem --dry-run=client -o yaml | vm_kubectl apply -f -
vm_ssh "rm -f /tmp/new.pem"
vm_kubectl -n "$NS" rollout restart deployment/cert-app
vm_kubectl -n "$NS" rollout status deployment/cert-app --timeout=300s
wait_thumb cert-app "$NEW_THUMB" 420 || fail "새 인증서로 호출 실패"
pass "새 인증서($NEW_THUMB)로 호출 성공"

echo "[5/6] Entra 에서 옛 키 삭제 (keyId=$OLD_KEY_ID)"
az ad app credential delete --id "$APP_CLIENT_ID" --cert --key-id "$OLD_KEY_ID" -o none
count="$(az ad app credential list --id "$APP_CLIENT_ID" --cert --query "length(@)" -o tsv | tr -d '\r')"
[[ "$count" == "1" ]] || fail "삭제 후 인증서 개수가 1이 아님 ($count)"
pass "옛 인증서 삭제 완료 (남은 인증서 1개)"

echo "[6/6] 옛 인증서는 거부되고 새 인증서는 계속 동작 (삭제 전파 대기)"
rejected=""
for i in 1 2 3 4 5 6 7 8; do
  run_app cert-old wif-cert-old 1
  state="$(wait_app cert-old 240)"
  logs="$(app_logs cert-old)"
  if [[ "$state" == "fail" ]] && grep -q 'AADSTS700027' <<<"$logs"; then rejected=yes; break; fi
  echo "  시도 $i: 아직 옛 인증서가 허용됨, 30초 후 재시도"; sleep 30
done
[[ -n "$rejected" ]] || fail "옛 인증서가 거부되지 않음"
pass "옛 인증서 거부: AADSTS700027"
run_app cert-new wif-cert 6
wait_thumb cert-new "$NEW_THUMB" 420 || fail "새 인증서 재확인 실패"
pass "새 인증서는 계속 정상"

echo "🎉 인증서 갱신 검증 완료"