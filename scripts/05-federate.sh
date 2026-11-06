#!/usr/bin/env bash
# UAMI 에 federated credential 생성: issuer + subject(wif-sa) + audience
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state ISSUER_URL

FIC_NAME="fic-k3s-${SA_NAME}"
SUBJECT="system:serviceaccount:${NS}:${SA_NAME}"

if az identity federated-credential show -g "$RG" --identity-name "$UAMI" -n "$FIC_NAME" >/dev/null 2>&1; then
  echo "이미 존재: $FIC_NAME"
else
  az identity federated-credential create -g "$RG" --identity-name "$UAMI" -n "$FIC_NAME" \
    --issuer "$ISSUER_URL" --subject "$SUBJECT" --audiences api://AzureADTokenExchange -o none
fi
az identity federated-credential show -g "$RG" --identity-name "$UAMI" -n "$FIC_NAME" \
  --query "{issuer:issuer,subject:subject,audiences:audiences}" -o jsonc
