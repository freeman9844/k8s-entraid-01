# k3s + Workload Identity Federation → Microsoft Foundry (keyless) 데모

Azure VM 1대의 k3s 파드가 **API Key / Client Secret / 인증서 없이** Microsoft Entra ID를 거쳐 Foundry 모델을 호출함을 증명합니다.

```
Pod(SA 토큰, aud=api://AzureADTokenExchange)
  → Entra ID (Blob 정적 웹사이트의 OIDC issuer/JWKS로 서명 검증, UAMI federated credential 매칭)
  → 액세스 토큰 → Foundry(gpt-5.4-mini, disableLocalAuth=true)
```

## 사전 요구
- Azure CLI 로그인(`az login`), 구독 Owner 권한, bash(Windows는 **Git Bash**; WSL은 네트워크 이슈 가능)
- `pip install -r requirements-dev.txt` (JWKS 생성용 `cryptography`)
- SSH 클라이언트, curl

## 실행 순서
```bash
bash scripts/01-azure-infra.sh     # RG, UAMI, Storage(OIDC), Foundry+모델, VM
bash scripts/02-install-k3s.sh     # k3s (API 서버 플래그: service-account-issuer 1개)
# 일반 kubeadm 클러스터로 재현하려면 02 대신 scripts/k1-install-kubeadm.sh 실행 후
# 가이드 3단계대로 매니페스트에 issuer 플래그를 추가하고
# export KUBECTL_CMD="sudo kubectl --kubeconfig /etc/kubernetes/admin.conf" (JWKS는 API 서버에서 가져옴)
bash scripts/03-publish-oidc.sh    # JWKS/discovery 업로드, 실제 토큰 iss/kid 대조
bash scripts/05-federate.sh        # UAMI federated credential 생성
bash scripts/06-deploy-demo.sh     # Namespace/SA/ConfigMap 배포
bash scripts/07-verify.sh          # 양성/음성 검증
bash scripts/99-cleanup.sh         # 리소스 삭제
```
기본값(리전 eastus2, 모델 등)은 `scripts/00-env.sh`에서 환경변수로 변경할 수 있습니다.

## 기대 결과 (07-verify)
1. wif-sa 파드가 키 없이 모델 호출 성공 (`RESULT=OK`)
2. 네임스페이스에 Secret 0개
3. 다른 SA(`wif-other-sa`)는 `AADSTS700213`으로 거부
4. API Key 호출은 HTTP 401

## Client Certificate 변형 (v2, `AUTH_MODE=cert`)
issuer 변경 없이 Entra 앱 등록 + 클라이언트 인증서로 호출합니다. 개인키가 Secret 으로 저장되므로 완전한 keyless 는 아닙니다.
```bash
export AUTH_MODE=cert
bash scripts/01-azure-infra.sh && bash scripts/02-install-k3s.sh
bash scripts/c1-create-app-cert.sh && bash scripts/c2-deploy-cert.sh && bash scripts/c3-verify-cert.sh
bash scripts/99-cleanup.sh   # 앱 등록도 함께 삭제
```
가이드: `docs/guide/OnPrem_K8s_Client_Certificate_Foundry_Guide_v2.html` (인증서 갱신 검증 `scripts/c4-rotate-cert.sh` 포함)

## Client Secret 변형
`bash scripts/01-azure-infra.sh && bash scripts/02-install-k3s.sh` (AUTH_MODE=cert) 후:
```bash
bash scripts/s1-create-app-secret.sh && bash scripts/s2-deploy-secret.sh && bash scripts/s3-verify-secret.sh
```n가이드: `docs/guide/OnPrem_K8s_Client_Certificate_Foundry_Guide_v3.html`

## 테스트
`python -m unittest discover -s tests -p "test_*.py"`

## 트러블슈팅
- **Storage 공개 접근이 Disabled로 고정**: 구독/관리그룹 정책(modify)이 강제합니다. Entra가 issuer를 읽어야 하므로 해당 RG에 정책 예외(exemption)가 필요하거나 다른 공개 호스팅(VM+Caddy, GitHub Pages)을 사용하세요.
- **스토리지 키 인증 거부**: 스크립트는 `--auth-mode login` + Blob Data Contributor 역할을 사용합니다.
- **모델 배포 실패**: 모델 폐기/리전 가용성에 따라 `00-env.sh`의 모델·버전·SKU를 조정하세요.
- **VM SKU 제한**: `VM_SIZE`를 변경하세요(기본 `Standard_D2s_v7`).
- **AADSTS700211/700213**: issuer/subject/audience 불일치. federated credential 전파에 수 분 걸릴 수 있습니다.

## 한계
단일 노드 데모이며 SSH는 실행자 IP에만 열립니다. 프로덕션에서는 issuer 호스팅 보호, 모델 접근 최소 권한, 네트워크 격리를 별도로 설계하세요.
