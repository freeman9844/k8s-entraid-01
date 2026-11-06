# run_app / wait_app / fail / pass (c3, c4 공용). 00-env.sh 를 먼저 source 해야 함
run_app() { # name secret retries
  vm_kubectl -n "$NS" delete deployment "$1" --ignore-not-found >/dev/null
  sed "s|__NAME__|$1|g; s|__NS__|${NS}|g; s|__SECRET__|$2|g; s|__CLIENT_ID__|${APP_CLIENT_ID}|g; s|__TENANT_ID__|${TENANT_ID}|g; s|__ENDPOINT__|${FOUNDRY_ENDPOINT}|g; s|__DEPLOYMENT__|${MODEL_NAME}|g; s|__RETRIES__|$3|g" \
    ${APP_TEMPLATE:-k8s/deploy-cert.yaml.tpl} | vm_kubectl apply -f - >/dev/null
}

wait_app() { # name timeout_sec -> ok|fail|timeout (파드 로그의 RESULT= 기준)
  local deadline=$((SECONDS + $2)) l
  while (( SECONDS < deadline )); do
    l="$(vm_kubectl -n "$NS" logs "deploy/$1" 2>/dev/null || true)"
    grep -q '^RESULT=OK' <<<"$l" && { echo ok; return 0; }
    grep -q '^RESULT=FAIL' <<<"$l" && { echo fail; return 0; }
    sleep 5
  done
  echo timeout
}

fail() { echo "❌ 실패: $*" >&2; exit 1; }
pass() { echo "✅ 통과: $*"; }
