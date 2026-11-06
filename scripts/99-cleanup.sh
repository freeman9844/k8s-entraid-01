#!/usr/bin/env bash
# 리소스 그룹 전체 삭제 및 로컬 상태 제거
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
read -r -p "리소스 그룹 $RG 를 삭제합니다. 계속할까요? (yes/no) " ans
[[ "$ans" == "yes" ]] || { echo "취소"; exit 0; }
if [[ -n "${APP_CLIENT_ID:-}" ]]; then
  az ad app delete --id "$APP_CLIENT_ID" && echo "Entra 앱 등록 삭제: $APP_CLIENT_ID"   # 앱 등록은 리소스 그룹 밖(테넌트)에 있음
fi
if [[ -n "${SECRET_APP_ID:-}" ]]; then
  az ad app delete --id "$SECRET_APP_ID" && echo "Entra 앱 등록 삭제: $SECRET_APP_ID"
fi
az group delete -n "$RG" --yes --no-wait
rm -rf "$STATE_DIR"
echo "삭제 요청됨. Foundry 이름은 soft-delete 되며 SUFFIX 가 매번 달라 충돌하지 않습니다."
