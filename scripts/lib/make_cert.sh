#!/usr/bin/env bash
# openssl 로 자체 서명 클라이언트 인증서 생성. 사용: make_cert.sh <cn> <days> <out_dir> <name>
# 산출물: <name>.pem(개인키+인증서, 파드용), <name>.crt(공개 인증서, Entra 업로드용). stdout: SHA1 thumbprint
set -euo pipefail
export MSYS_NO_PATHCONV=1
cn="$1"; days="$2"; out="$3"; name="$4"
mkdir -p "$out"
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days "$days" -subj "/CN=${cn}" \
  -keyout "$out/$name.key" -out "$out/$name.crt" 2>/dev/null
cat "$out/$name.key" "$out/$name.crt" > "$out/$name.pem"
rm -f "$out/$name.key"
openssl x509 -in "$out/$name.crt" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'
