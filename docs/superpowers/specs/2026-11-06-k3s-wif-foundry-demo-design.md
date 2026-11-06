# k3s + Workload Identity Federation → Foundry Models Keyless 데모 설계

## 1. 목적과 성공 기준

**목적**: 온프레미스 Kubernetes(Azure VM 1대의 k3s로 모사) → Microsoft Entra ID → Microsoft Foundry Models 구조에서, API Key / Client Secret / 인증서 없이 Workload Identity Federation(WIF)만으로 모델을 호출할 수 있음을 증명한다.

**성공 기준**
1. k3s 파드가 `DefaultAzureCredential`로 Foundry의 `gpt-5.4-mini (구현 시 gpt-4o-mini 폐기로 변경)`를 호출하고 응답을 받는다.
2. 파드와 클러스터 어디에도 키·secret·인증서가 존재하지 않음을 출력으로 보여 준다.
3. 음성 테스트 2건이 기대대로 실패한다.
   - 다른 ServiceAccount의 파드 → Entra가 subject 불일치로 거부
   - API Key 직접 호출 → `disableLocalAuth=true`로 거부
4. Bash 스크립트와 한국어 README만으로 처음부터 끝까지 재현 및 정리(cleanup)할 수 있다.

## 2. 확정된 결정 사항

| 항목 | 결정 |
|---|---|
| OIDC issuer 공개 | Azure Blob Storage 정적 웹사이트에 discovery/JWKS 업로드 |
| Entra 신뢰 주체 | User-assigned Managed Identity(UAMI) + federated credential |
| 모델 | 신규 Foundry(AIServices) 리소스 + `gpt-5.4-mini (구현 시 gpt-4o-mini 폐기로 변경)` 배포(스크립트로 생성) |
| 프로비저닝 | Azure CLI Bash 스크립트 |
| 토큰 획득 | Azure Workload Identity webhook + Azure SDK `DefaultAzureCredential` (curl 교환 단계는 제외) |

## 3. 아키텍처

```
[Azure VM: k3s]                                  [Azure]
 파드(SA 토큰, aud=api://AzureADTokenExchange)
   │ 1) projected SA JWT (iss = Blob 정적 사이트 URL)
   ▼
 Entra ID ── 2) iss/sub/aud를 federated credential과 대조
   │            (JWKS는 Blob의 jwks.json으로 서명 검증)
   ▼ 3) UAMI용 access token (scope: https://cognitiveservices.azure.com/.default)
 Foundry(AIServices) ── 4) RBAC "Cognitive Services OpenAI User" → gpt-5.4-mini (구현 시 gpt-4o-mini 폐기로 변경) 응답
```

- Blob 정적 웹사이트가 `/.well-known/openid-configuration`과 JWKS 문서를 제공한다.
- k3s API 서버는 `--service-account-issuer=<Blob URL>`, `--service-account-jwks-uri=<Blob JWKS URL>`로 구성한다(`--kube-apiserver-arg`로 전달).
- Federated credential 조건: issuer = Blob URL, subject = `system:serviceaccount:wif-demo:wif-sa`, audience = `api://AzureADTokenExchange`.
- Foundry 리소스는 `disableLocalAuth=true`로 키 인증을 차단한다.

## 4. 구성 요소

| 파일 | 책임 |
|---|---|
| `scripts/00-env.sh` | 변수(리전, 이름, 모델 버전)와 사전 점검 |
| `scripts/01-azure-infra.sh` | RG, VM, Storage(정적 웹), UAMI, Foundry + 배포, RBAC |
| `scripts/03-publish-oidc.sh` | SA 서명 공개키로 JWKS 생성, discovery 문서와 함께 업로드 |
| `scripts/02-install-k3s.sh` | VM에 k3s 설치(issuer 플래그 포함) |
| `scripts/04-install-webhook.sh` | Azure Workload Identity webhook(helm) 설치 |
| `scripts/05-federate.sh` | federated credential 생성 |
| `scripts/06-deploy-demo.sh` | Namespace, ServiceAccount, 데모 파드 배포 |
| `scripts/07-verify.sh` | 양성·음성 검증과 증명 출력(재시도 포함) |
| `scripts/99-cleanup.sh` | RG 삭제 |
| `app/demo.py` | `DefaultAzureCredential` + Foundry 호출(ConfigMap으로 주입) |
| `README.md` | 한국어 단계 설명, 다이어그램, 트러블슈팅 |

**순서 의존성**: issuer URL(Storage)이 확정된 후에 k3s를 설치해야 하고, JWKS는 k3s가 생성한 SA 서명 공개키가 필요하다. 따라서 `02`는 issuer URL 확정과 컨테이너 준비(02a), JWKS 업로드(02b, k3s 설치 후 공개키 추출)로 나눈다. 구현 계획에서 이 분리를 명시한다.

## 5. 검증 설계

- **양성**: 파드가 SDK로 `gpt-5.4-mini (구현 시 gpt-4o-mini 폐기로 변경)` 응답을 출력한다.
- **증명**: 파드의 환경변수와 마운트된 secret에 키가 없음을 보이고, 투영된 토큰 JWT의 iss/sub/aud 클레임을 디코딩해 출력한다.
- **음성 1**: 다른 ServiceAccount 파드는 subject 불일치(`AADSTS700213` 계열)로 실패한다.
- **음성 2**: 키 헤더로 직접 호출하면 401/403으로 실패한다.

## 6. 오류 처리와 운영 고려

- 모든 스크립트는 `set -euo pipefail`을 사용하고 멱등하게 작성한다.
- Federated credential 전파 지연에 대비해 `07-verify.sh`에서 재시도한다.
- 리전과 모델 가용성·쿼터는 `00-env.sh`에서 사전 점검한다.
- 비용은 VM 1대(B2s급), Storage, 소량의 모델 호출이며 `99-cleanup.sh`로 RG를 일괄 삭제한다.

## 7. 범위 제외(YAGNI)

- 다중 노드, HA, 실제 온프레미스 네트워크 구성
- curl 기반 수동 토큰 교환 시연
- 컨테이너 이미지 빌드/레지스트리(코드는 ConfigMap으로 주입)
- Terraform/Bicep
