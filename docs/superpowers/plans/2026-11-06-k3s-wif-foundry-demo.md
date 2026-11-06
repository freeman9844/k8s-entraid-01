# k3s + WIF → Foundry Keyless 데모 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Azure VM 1대의 k3s 파드가 API Key/Client Secret/인증서 없이 Workload Identity Federation만으로 Foundry `gpt-4o-mini`를 호출함을 증명하는 재현 가능한 Bash 데모를 만든다.

**Architecture:** k3s의 ServiceAccount issuer를 Blob 정적 웹사이트(discovery + JWKS)로 공개하고, UAMI의 federated credential이 이 issuer와 `system:serviceaccount:wif-demo:wif-sa` subject를 신뢰한다. Azure Workload Identity webhook이 파드에 토큰 볼륨과 환경변수를 주입하고, 앱은 `DefaultAzureCredential`로 Foundry를 호출한다. 순수 로직(JWKS 생성, 토큰 점검, 데모 앱 헬퍼)은 Python 단위 테스트로, 인프라 스크립트는 `bash -n` 구문 검사와 `07-verify.sh` 종단 검증으로 확인한다.

**Tech Stack:** Bash + Azure CLI, k3s, Helm(azure-workload-identity chart), Python 3 (`cryptography`, `azure-identity`, `openai`), `unittest`

**Spec:** `docs/superpowers/specs/2026-11-06-k3s-wif-foundry-demo-design.md`

## Global Constraints

- 문서(README, 주석 외 사용자 출력 메시지)는 한국어로 작성한다.
- API Key, Client Secret, 인증서를 어디에서도 생성·저장·사용하지 않는다(VM에는 관리 ID도 할당하지 않는다). 키 호출은 음성 테스트용 가짜 값만 허용한다.
- Foundry 리소스는 `disableLocalAuth=true`로 설정한다.
- federated credential: audience `api://AzureADTokenExchange`, subject `system:serviceaccount:wif-demo:wif-sa`, issuer는 SA 토큰의 `iss`와 문자 단위로 동일해야 한다(끝 슬래시 없음).
- 모델: `gpt-4o-mini`, 버전 `2024-07-18`, SKU `GlobalStandard`. 기본 리전 `eastus2`.
- RBAC 역할: `Cognitive Services OpenAI User`. 토큰 scope: `https://cognitiveservices.azure.com/.default`.
- 모든 스크립트는 `set -euo pipefail`, 멱등, `00-env.sh`를 `source`해서 사용한다.
- 스크립트 실행 순서: 01 → 02(k3s) → 03(OIDC 공개) → 04(webhook) → 05(federate) → 06(deploy) → 07(verify) → 99(cleanup). (스펙 §4의 02/03 번호 순서를 이 계획에서 교체했으며 Task 9에서 스펙을 갱신한다.)
- 테스트 명령: `python -m unittest discover -s tests -p "test_*.py"` (저장소 루트에서).

## Review Focus

1. 빈 입력, RSA가 아닌 키, 중복 키가 `make_jwks.py`에 들어오는 경우: 명확한 오류(빈 입력/비RSA) 또는 중복 제거 (Task 2 테스트).
2. issuer 끝 슬래시 불일치(`https://x/` vs `https://x`): `check_jwks.py`가 불일치를 보고 (Task 3 테스트).
3. 토큰 `kid`가 JWKS에 없는 경우(키 회전·잘못된 키 선택): `check_jwks.py`가 보고 (Task 3 테스트).
4. 파드 환경에 `*_KEY`, `*_SECRET` 유사 변수가 섞이는 경우: `audit_env`가 탐지하고 데모가 FAIL (Task 4 테스트).
5. federated credential 전파 지연: `with_retry`가 N회 재시도 후 마지막 오류를 그대로 전달하고, `retries=1`이면 대기하지 않음 (Task 4 테스트).

---

## 파일 구조

```
.gitignore
requirements-dev.txt
README.md                      (Task 9)
app/demo.py                    데모 앱(파드에서 실행)
k8s/base.yaml.tpl              Namespace + ServiceAccount 2개
k8s/job.yaml.tpl               호출 Job 템플릿
scripts/00-env.sh              변수, 상태 저장, VM 헬퍼, 사전 점검 (source 전용)
scripts/01-azure-infra.sh
scripts/02-install-k3s.sh
scripts/03-publish-oidc.sh
scripts/04-install-webhook.sh
scripts/05-federate.sh
scripts/06-deploy-demo.sh
scripts/07-verify.sh
scripts/99-cleanup.sh
scripts/lib/make_jwks.py       PEM 공개키 → JWKS
scripts/lib/check_jwks.py      토큰 iss/kid ↔ JWKS 점검
tests/test_make_jwks.py
tests/test_check_jwks.py
tests/test_demo.py
tests/test_scripts_syntax.py   scripts/*.sh `bash -n`
```

---

### Task 1: 프로젝트 골격과 공통 환경(00-env.sh)

**Files:**
- Create: `.gitignore`, `requirements-dev.txt`, `scripts/00-env.sh`, `tests/test_scripts_syntax.py`

**Interfaces:**
- Produces (bash, `source scripts/00-env.sh` 이후 사용 가능):
  - 변수: `ROOT_DIR STATE_DIR LOCATION VM_SIZE MODEL_NAME MODEL_VERSION MODEL_SKU MODEL_CAPACITY NS SA_NAME OTHER_SA SUFFIX RG VM_NAME STORAGE UAMI FOUNDRY ADMIN_USER PY`
  - `save_state KEY VALUE` (`.state/state.env`에 저장하고 export)
  - `require_state VAR...` (없으면 안내 후 exit 1)
  - `preflight` (도구·로그인·모델 가용성 점검)
  - `vm_ssh ARGS...`, `vm_scp LOCAL_FILE REMOTE_PATH`, `vm_kubectl ARGS...` (`VM_IP` 필요)

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_scripts_syntax.py`:

```python
import glob
import os
import shutil
import subprocess
import unittest

ROOT = os.path.join(os.path.dirname(__file__), "..")
SCRIPTS = sorted(glob.glob(os.path.join(ROOT, "scripts", "*.sh")))


@unittest.skipUnless(shutil.which("bash"), "bash 필요")
class ScriptSyntaxTest(unittest.TestCase):
    def test_scripts_exist(self):
        self.assertTrue(SCRIPTS, "scripts/*.sh 가 없음")

    def test_all_scripts_parse(self):
        for path in SCRIPTS:
            with self.subTest(script=os.path.basename(path)):
                r = subprocess.run(["bash", "-n", path], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_env_defines_helpers(self):
        env = os.path.join(ROOT, "scripts", "00-env.sh")
        cmd = f'source "{env}" && type save_state require_state preflight vm_ssh vm_scp vm_kubectl >/dev/null && echo "$RG"'
        r = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.strip().startswith("rg-wif-demo-"))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 실패 확인**

Run: `python -m unittest tests.test_scripts_syntax -v`
Expected: FAIL (`scripts/*.sh 가 없음`)

- [ ] **Step 3: 구현**

`.gitignore`:

```
.state/
__pycache__/
*.pyc
```

`requirements-dev.txt`:

```
cryptography>=42
```

`scripts/00-env.sh`:

```bash
#!/usr/bin/env bash
# source 전용: 변수, 상태 저장, VM 헬퍼, 사전 점검
set -euo pipefail
export MSYS_NO_PATHCONV=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/.state"
STATE_FILE="$STATE_DIR/state.env"
mkdir -p "$STATE_DIR"
touch "$STATE_FILE"
# shellcheck disable=SC1090
source "$STATE_FILE"

save_state() {
  local key="$1" value="$2"
  { grep -v "^${key}=" "$STATE_FILE" || true; echo "${key}=\"${value}\""; } > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
  export "${key}=${value}"
}

: "${LOCATION:=eastus2}"
: "${VM_SIZE:=Standard_B2s}"
: "${MODEL_NAME:=gpt-4o-mini}"
: "${MODEL_VERSION:=2024-07-18}"
: "${MODEL_SKU:=GlobalStandard}"
: "${MODEL_CAPACITY:=10}"
NS="wif-demo"
SA_NAME="wif-sa"
OTHER_SA="wif-other-sa"
ADMIN_USER="azureuser"

if [[ -z "${SUFFIX:-}" ]]; then
  save_state SUFFIX "$(printf '%05x' $((RANDOM * RANDOM % 1048576)))"
fi
RG="rg-wif-demo-${SUFFIX}"
VM_NAME="vm-k3s-wif"
STORAGE="stwif${SUFFIX}"
UAMI="id-wif-demo"
FOUNDRY="foundry-wif-${SUFFIX}"

pick_python() {
  local c
  for c in python3 python; do
    if "$c" -c 'import sys' >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  return 1
}
PY="$(pick_python || true)"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$STATE_DIR/known_hosts" -o ConnectTimeout=10)

vm_ssh() { ssh "${SSH_OPTS[@]}" "$ADMIN_USER@$VM_IP" "$@"; }
vm_scp() { ( cd "$(dirname "$1")" && scp "${SSH_OPTS[@]}" "$(basename "$1")" "$ADMIN_USER@$VM_IP:$2" ); }
vm_kubectl() { vm_ssh "sudo k3s kubectl $(printf '%q ' "$@")"; }

require_state() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" ]] || { echo "상태 변수 $v 가 없습니다. 이전 단계를 먼저 실행하세요." >&2; exit 1; }
  done
}

preflight() {
  local c
  for c in az ssh scp curl; do
    command -v "$c" >/dev/null || { echo "필요한 도구가 없습니다: $c" >&2; exit 1; }
  done
  [[ -n "$PY" ]] || { echo "python3/python 이 필요합니다" >&2; exit 1; }
  "$PY" -c 'import cryptography' 2>/dev/null || { echo "pip install -r requirements-dev.txt 를 먼저 실행하세요" >&2; exit 1; }
  az account show >/dev/null 2>&1 || { echo "az login 을 먼저 실행하세요" >&2; exit 1; }
  local n
  n=$(az cognitiveservices model list -l "$LOCATION" \
    --query "[?model.name=='$MODEL_NAME' && model.version=='$MODEL_VERSION'] | length(@)" -o tsv)
  [[ "${n:-0}" -gt 0 ]] || { echo "$LOCATION 에서 $MODEL_NAME $MODEL_VERSION 을 사용할 수 없습니다. LOCATION 을 바꾸세요." >&2; exit 1; }
}
```

- [ ] **Step 4: 통과 확인**

Run: `python -m unittest tests.test_scripts_syntax -v`
Expected: PASS (3 tests)

- [ ] **Step 5: 커밋**

```bash
git add .gitignore requirements-dev.txt scripts/00-env.sh tests/test_scripts_syntax.py
git commit -m "chore: add project skeleton and common env script"
```

---

### Task 2: JWKS 생성기(make_jwks.py)

**Files:**
- Create: `scripts/lib/make_jwks.py`, `tests/test_make_jwks.py`

**Interfaces:**
- Produces: `build_jwks(pem_text: str) -> dict` — `{"keys":[{"use","kty","alg","kid","n","e"}]}`. `kid` = base64url(sha256(DER SubjectPublicKeyInfo)) (Kubernetes 방식). 예외: 공개키 없음/비RSA → `ValueError`. 중복 kid 제거.
- CLI: stdin의 PEM 텍스트 → stdout JSON. 오류 시 stderr + exit 1.

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_make_jwks.py`:

```python
import base64
import hashlib
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "lib"))

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

import make_jwks

ENC = serialization.Encoding
FMT = serialization.PublicFormat


def public_pem(private_key):
    return private_key.public_key().public_bytes(ENC.PEM, FMT.SubjectPublicKeyInfo).decode()


def b64url_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


class BuildJwksTest(unittest.TestCase):
    def setUp(self):
        self.key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    def test_kid_matches_kubernetes_derivation_and_numbers(self):
        jwks = make_jwks.build_jwks(public_pem(self.key))
        self.assertEqual(len(jwks["keys"]), 1)
        k = jwks["keys"][0]
        der = self.key.public_key().public_bytes(ENC.DER, FMT.SubjectPublicKeyInfo)
        expected = base64.urlsafe_b64encode(hashlib.sha256(der).digest()).rstrip(b"=").decode()
        self.assertEqual(k["kid"], expected)
        nums = self.key.public_key().public_numbers()
        self.assertEqual(int.from_bytes(b64url_decode(k["n"]), "big"), nums.n)
        self.assertEqual(int.from_bytes(b64url_decode(k["e"]), "big"), nums.e)
        self.assertEqual((k["kty"], k["alg"], k["use"]), ("RSA", "RS256", "sig"))

    def test_duplicate_keys_are_deduplicated(self):
        pem = public_pem(self.key)
        self.assertEqual(len(make_jwks.build_jwks(pem + "\n" + pem)["keys"]), 1)

    def test_multiple_distinct_keys(self):
        other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        jwks = make_jwks.build_jwks(public_pem(self.key) + public_pem(other))
        self.assertEqual(len(jwks["keys"]), 2)

    def test_empty_input_raises(self):
        with self.assertRaises(ValueError):
            make_jwks.build_jwks("")

    def test_non_rsa_key_raises(self):
        ec_key = ec.generate_private_key(ec.SECP256R1())
        with self.assertRaises(ValueError):
            make_jwks.build_jwks(public_pem(ec_key))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 실패 확인**

Run: `pip install -r requirements-dev.txt` 후 `python -m unittest tests.test_make_jwks -v`
Expected: FAIL (`ModuleNotFoundError: make_jwks`)

- [ ] **Step 3: 구현**

`scripts/lib/make_jwks.py`:

```python
"""PEM 공개키(들)를 Kubernetes ServiceAccount 토큰 검증용 JWKS로 변환한다."""
import base64
import hashlib
import json
import re
import sys

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

PEM_RE = re.compile(r"-----BEGIN PUBLIC KEY-----.+?-----END PUBLIC KEY-----", re.S)


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _int_b64url(n: int) -> str:
    return _b64url(n.to_bytes((n.bit_length() + 7) // 8, "big"))


def build_jwks(pem_text: str) -> dict:
    keys, seen = [], set()
    for block in PEM_RE.findall(pem_text):
        pub = serialization.load_pem_public_key(block.encode())
        if not isinstance(pub, rsa.RSAPublicKey):
            raise ValueError("RSA 공개키만 지원합니다")
        der = pub.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        kid = _b64url(hashlib.sha256(der).digest())
        if kid in seen:
            continue
        seen.add(kid)
        nums = pub.public_numbers()
        keys.append({"use": "sig", "kty": "RSA", "alg": "RS256", "kid": kid,
                     "n": _int_b64url(nums.n), "e": _int_b64url(nums.e)})
    if not keys:
        raise ValueError("입력에서 공개키(PEM)를 찾지 못했습니다")
    return {"keys": keys}


def main() -> int:
    try:
        print(json.dumps(build_jwks(sys.stdin.read()), indent=2))
    except ValueError as e:
        print(f"오류: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 통과 확인**

Run: `python -m unittest tests.test_make_jwks -v`
Expected: PASS (5 tests)

- [ ] **Step 5: 커밋**

```bash
git add scripts/lib/make_jwks.py tests/test_make_jwks.py
git commit -m "feat: add JWKS generator for SA signing keys"
```

---

### Task 3: 토큰 ↔ JWKS 점검기(check_jwks.py)

**Files:**
- Create: `scripts/lib/check_jwks.py`, `tests/test_check_jwks.py`

**Interfaces:**
- Produces: `check_token(token: str, jwks: dict, issuer: str) -> list[str]` (빈 리스트 = 정상). CLI: `python check_jwks.py --issuer URL [--token T | stdin]` — `URL/openid/v1/jwks`를 받아와 점검, 문제가 있으면 stderr 출력 후 exit 1.

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_check_jwks.py`:

```python
import base64
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "lib"))

import check_jwks


def seg(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()


def fake_token(iss, kid):
    return f"{seg({'alg': 'RS256', 'kid': kid})}.{seg({'iss': iss, 'sub': 's'})}.sig"


ISSUER = "https://stwif1.z13.web.core.windows.net"
JWKS = {"keys": [{"kid": "abc"}]}


class CheckTokenTest(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(check_jwks.check_token(fake_token(ISSUER, "abc"), JWKS, ISSUER), [])

    def test_trailing_slash_issuer_mismatch(self):
        problems = check_jwks.check_token(fake_token(ISSUER + "/", "abc"), JWKS, ISSUER)
        self.assertEqual(len(problems), 1)
        self.assertIn("iss", problems[0])

    def test_kid_missing_from_jwks(self):
        problems = check_jwks.check_token(fake_token(ISSUER, "zzz"), JWKS, ISSUER)
        self.assertEqual(len(problems), 1)
        self.assertIn("kid", problems[0])

    def test_not_a_jwt(self):
        self.assertTrue(check_jwks.check_token("not-a-jwt", JWKS, ISSUER))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 실패 확인**

Run: `python -m unittest tests.test_check_jwks -v`
Expected: FAIL (`ModuleNotFoundError: check_jwks`)

- [ ] **Step 3: 구현**

`scripts/lib/check_jwks.py`:

```python
"""ServiceAccount 토큰의 iss/kid 가 공개된 issuer/JWKS 와 일치하는지 점검한다."""
import argparse
import base64
import json
import sys
import urllib.request


def _decode(segment: str) -> dict:
    segment += "=" * (-len(segment) % 4)
    return json.loads(base64.urlsafe_b64decode(segment))


def check_token(token: str, jwks: dict, issuer: str) -> list:
    parts = token.strip().split(".")
    if len(parts) != 3:
        return ["토큰이 JWT 형식이 아닙니다"]
    try:
        header, payload = _decode(parts[0]), _decode(parts[1])
    except ValueError:
        return ["토큰 헤더/페이로드를 해석할 수 없습니다"]
    problems = []
    if payload.get("iss") != issuer:
        problems.append(f"iss 불일치: 토큰={payload.get('iss')!r}, issuer={issuer!r}")
    kids = {k.get("kid") for k in jwks.get("keys", [])}
    if header.get("kid") not in kids:
        problems.append(f"kid {header.get('kid')!r} 가 JWKS에 없습니다")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--issuer", required=True)
    ap.add_argument("--token")
    args = ap.parse_args()
    token = args.token or sys.stdin.read()
    with urllib.request.urlopen(f"{args.issuer}/openid/v1/jwks", timeout=15) as r:
        jwks = json.load(r)
    problems = check_token(token, jwks, args.issuer)
    for p in problems:
        print(f"오류: {p}", file=sys.stderr)
    if not problems:
        print("OK: 토큰의 iss/kid 가 공개된 issuer/JWKS 와 일치합니다")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 통과 확인**

Run: `python -m unittest tests.test_check_jwks -v`
Expected: PASS (4 tests)

- [ ] **Step 5: 커밋**

```bash
git add scripts/lib/check_jwks.py tests/test_check_jwks.py
git commit -m "feat: add token/JWKS consistency checker"
```

---

### Task 4: 데모 앱(app/demo.py)

**Files:**
- Create: `app/demo.py`, `tests/test_demo.py`

**Interfaces:**
- Produces (모두 `app/demo.py`): `decode_claims(token_path: str) -> dict`, `audit_env(environ: Mapping) -> list[str]` (secret 유사 이름), `with_retry(fn, retries: int, delay: float, sleep=time.sleep)`, `main() -> int`.
- 환경변수 입력: `AZURE_FEDERATED_TOKEN_FILE`(webhook 주입), `FOUNDRY_ENDPOINT`, `FOUNDRY_DEPLOYMENT`, `WIF_RETRIES`(기본 1).
- 출력 계약: 마지막 줄이 성공이면 `RESULT=OK`, 실패면 `RESULT=FAIL <오류>`; 종료코드 0/1. 이 계약을 Task 8이 사용한다.

- [ ] **Step 1: 실패하는 테스트 작성**

`tests/test_demo.py`:

```python
import base64
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))

import demo


def seg(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()


class AuditEnvTest(unittest.TestCase):
    def test_clean_env(self):
        env = {"AZURE_CLIENT_ID": "x", "AZURE_TENANT_ID": "y",
               "AZURE_FEDERATED_TOKEN_FILE": "/var/run/secrets/azure/tokens/azure-identity-token",
               "PATH": "/bin"}
        self.assertEqual(demo.audit_env(env), [])

    def test_detects_secret_like_names(self):
        env = {"AZURE_CLIENT_SECRET": "s", "OPENAI_API_KEY": "k", "db_password": "p", "PATH": "/bin"}
        self.assertEqual(demo.audit_env(env), ["AZURE_CLIENT_SECRET", "OPENAI_API_KEY", "db_password"])


class WithRetryTest(unittest.TestCase):
    def test_succeeds_after_failures(self):
        calls, sleeps = [], []

        def fn():
            calls.append(1)
            if len(calls) < 3:
                raise RuntimeError("not yet")
            return "ok"

        self.assertEqual(demo.with_retry(fn, 5, 7, sleep=sleeps.append), "ok")
        self.assertEqual(sleeps, [7, 7])

    def test_raises_last_error_when_exhausted(self):
        def fn():
            raise RuntimeError("AADSTS700213")

        with self.assertRaisesRegex(RuntimeError, "AADSTS700213"):
            demo.with_retry(fn, 3, 0, sleep=lambda _: None)

    def test_single_attempt_never_sleeps(self):
        sleeps = []
        with self.assertRaises(RuntimeError):
            demo.with_retry(lambda: (_ for _ in ()).throw(RuntimeError("x")), 1, 9, sleep=sleeps.append)
        self.assertEqual(sleeps, [])


class DecodeClaimsTest(unittest.TestCase):
    def test_reads_payload(self):
        token = f"{seg({'alg': 'RS256'})}.{seg({'iss': 'https://i', 'sub': 'system:serviceaccount:a:b', 'aud': ['api://AzureADTokenExchange']})}.sig"
        with tempfile.NamedTemporaryFile("w", suffix=".tok", delete=False) as f:
            f.write(token + "\n")
        try:
            claims = demo.decode_claims(f.name)
        finally:
            os.unlink(f.name)
        self.assertEqual(claims["iss"], "https://i")
        self.assertEqual(claims["sub"], "system:serviceaccount:a:b")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 실패 확인**

Run: `python -m unittest tests.test_demo -v`
Expected: FAIL (`ModuleNotFoundError: demo`)

- [ ] **Step 3: 구현**

`app/demo.py`:

```python
"""파드 안에서 실행: 키 없이(WIF) Foundry 모델을 호출하고 증거를 출력한다."""
import base64
import json
import os
import re
import sys
import time

SCOPE = "https://cognitiveservices.azure.com/.default"
API_VERSION = "2024-10-21"
SECRET_LIKE = re.compile(r"(API_?KEY|SECRET|PASSWORD|CERT|PFX)", re.IGNORECASE)


def decode_claims(token_path):
    with open(token_path) as f:
        payload = f.read().strip().split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def audit_env(environ):
    return [k for k in environ if SECRET_LIKE.search(k)]


def with_retry(fn, retries, delay, sleep=time.sleep):
    for attempt in range(1, retries + 1):
        try:
            return fn()
        except Exception:
            if attempt == retries:
                raise
            sleep(delay)


def main():
    env = os.environ
    retries = int(env.get("WIF_RETRIES", "1"))

    print("=== 1. 자격 증명 감사 ===")
    leaked = audit_env(env)
    print("secret 유사 환경변수:", leaked or "없음")
    for k in sorted(k for k in env if k.startswith("AZURE_")):
        print(f"  {k}={env[k]}")

    try:
        print("=== 2. 투영된 ServiceAccount 토큰 클레임 ===")
        claims = decode_claims(env["AZURE_FEDERATED_TOKEN_FILE"])
        for k in ("iss", "sub", "aud"):
            print(f"  {k}: {claims.get(k)}")

        print("=== 3. Foundry 모델 호출 (DefaultAzureCredential) ===")
        from azure.identity import DefaultAzureCredential, get_bearer_token_provider
        from openai import AzureOpenAI

        cred = DefaultAzureCredential()
        with_retry(lambda: cred.get_token(SCOPE), retries, 20)
        client = AzureOpenAI(
            azure_endpoint=env["FOUNDRY_ENDPOINT"],
            azure_ad_token_provider=get_bearer_token_provider(cred, SCOPE),
            api_version=API_VERSION,
        )
        resp = client.chat.completions.create(
            model=env["FOUNDRY_DEPLOYMENT"],
            messages=[{"role": "user", "content": "한 문장으로 인사해 주세요."}],
            max_tokens=60,
        )
        print("  응답:", resp.choices[0].message.content)
    except Exception as e:
        print(f"RESULT=FAIL {type(e).__name__}: {e}")
        return 1

    if leaked:
        print("RESULT=FAIL secret 유사 환경변수가 존재합니다")
        return 1
    print("RESULT=OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 통과 확인**

Run: `python -m unittest discover -s tests -p "test_*.py" -v`
Expected: PASS (전체 테스트)

- [ ] **Step 5: 커밋**

```bash
git add app/demo.py tests/test_demo.py
git commit -m "feat: add keyless Foundry demo app"
```

---

### Task 5: Azure 인프라(01-azure-infra.sh)

**Files:**
- Create: `scripts/01-azure-infra.sh`

**Interfaces:**
- Consumes: Task 1의 `preflight`, `save_state` 및 이름 변수.
- Produces(state에 저장): `TENANT_ID SUBSCRIPTION_ID CLIENT_ID PRINCIPAL_ID ISSUER_URL FOUNDRY_ID FOUNDRY_ENDPOINT VM_IP MY_IP`. `ISSUER_URL`은 끝 슬래시 없는 정적 웹 URL.

- [ ] **Step 1: 구현**

`scripts/01-azure-infra.sh`:

```bash
#!/usr/bin/env bash
# RG, UAMI, Storage(정적 웹), Foundry(+gpt-4o-mini, 키 인증 차단), RBAC, VM 생성
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
preflight

save_state TENANT_ID "$(az account show --query tenantId -o tsv)"
save_state SUBSCRIPTION_ID "$(az account show --query id -o tsv)"
save_state MY_IP "$(curl -fsS https://api.ipify.org)"

echo "[1/6] 리소스 그룹: $RG ($LOCATION)"
az group create -n "$RG" -l "$LOCATION" -o none

echo "[2/6] User-assigned Managed Identity: $UAMI"
az identity create -g "$RG" -n "$UAMI" -l "$LOCATION" -o none
save_state CLIENT_ID "$(az identity show -g "$RG" -n "$UAMI" --query clientId -o tsv)"
save_state PRINCIPAL_ID "$(az identity show -g "$RG" -n "$UAMI" --query principalId -o tsv)"

echo "[3/6] Storage 정적 웹사이트(OIDC issuer 호스팅): $STORAGE"
az storage account create -g "$RG" -n "$STORAGE" -l "$LOCATION" \
  --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 -o none
az storage blob service-properties update --account-name "$STORAGE" \
  --static-website --index-document index.html --auth-mode key -o none
web_url="$(az storage account show -g "$RG" -n "$STORAGE" --query primaryEndpoints.web -o tsv)"
save_state ISSUER_URL "${web_url%/}"

echo "[4/6] Foundry(AIServices) + $MODEL_NAME 배포, 키 인증 차단"
az cognitiveservices account create -g "$RG" -n "$FOUNDRY" -l "$LOCATION" \
  --kind AIServices --sku S0 --custom-domain "$FOUNDRY" --yes -o none
save_state FOUNDRY_ID "$(az cognitiveservices account show -g "$RG" -n "$FOUNDRY" --query id -o tsv)"
az resource update --ids "$FOUNDRY_ID" --set properties.disableLocalAuth=true -o none
az cognitiveservices account deployment create -g "$RG" -n "$FOUNDRY" \
  --deployment-name "$MODEL_NAME" --model-name "$MODEL_NAME" --model-version "$MODEL_VERSION" \
  --model-format OpenAI --sku-name "$MODEL_SKU" --sku-capacity "$MODEL_CAPACITY" -o none
save_state FOUNDRY_ENDPOINT "https://${FOUNDRY}.openai.azure.com"

echo "[5/6] RBAC: UAMI → Cognitive Services OpenAI User"
az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services OpenAI User" --scope "$FOUNDRY_ID" -o none

echo "[6/6] VM(k3s 호스트, 관리 ID 없음) — SSH는 현재 공인 IP($MY_IP)만 허용"
az vm create -g "$RG" -n "$VM_NAME" -l "$LOCATION" --image Ubuntu2204 --size "$VM_SIZE" \
  --admin-username "$ADMIN_USER" --generate-ssh-keys --public-ip-sku Standard --nsg-rule NONE -o none
az network nsg rule create -g "$RG" --nsg-name "${VM_NAME}NSG" -n allow-ssh-from-me --priority 1000 \
  --access Allow --protocol Tcp --direction Inbound --source-address-prefixes "$MY_IP" \
  --destination-port-ranges 22 -o none
save_state VM_IP "$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)"

echo "완료: issuer=$ISSUER_URL, endpoint=$FOUNDRY_ENDPOINT, vm=$VM_IP"
```

- [ ] **Step 2: 구문 검사**

Run: `python -m unittest tests.test_scripts_syntax -v`
Expected: PASS

- [ ] **Step 3: 실제 실행 검증**

Run: `bash scripts/01-azure-infra.sh`
Expected: 마지막 줄 `완료: issuer=https://stwif….web.core.windows.net, endpoint=https://foundry-wif-….openai.azure.com, vm=<IP>`. 이어서 확인:
`az cognitiveservices account show -g $RG -n $FOUNDRY --query properties.disableLocalAuth` → `true`, 재실행해도 오류 없이 끝남(멱등).
모델이 리전에서 불가하면 preflight 메시지가 나오고 중단 — `LOCATION=swedencentral bash scripts/01-azure-infra.sh`로 재시도(단 `.state`와 리전을 일관되게 유지).

- [ ] **Step 4: 커밋**

```bash
git add scripts/01-azure-infra.sh
git commit -m "feat: add Azure infra provisioning script"
```

---

### Task 6: k3s 설치와 OIDC 공개(02, 03)

**Files:**
- Create: `scripts/02-install-k3s.sh`, `scripts/03-publish-oidc.sh`

**Interfaces:**
- Consumes: state `ISSUER_URL VM_IP STORAGE`, `vm_ssh/vm_scp/vm_kubectl`, `scripts/lib/make_jwks.py`, `scripts/lib/check_jwks.py`.
- Produces: 동작 중인 k3s(`--service-account-issuer=$ISSUER_URL`, `--service-account-jwks-uri=$ISSUER_URL/openid/v1/jwks`), Blob 정적 웹의 `.well-known/openid-configuration`과 `openid/v1/jwks`.

- [ ] **Step 1: 02-install-k3s.sh 작성**

```bash
#!/usr/bin/env bash
# VM에 k3s 설치: ServiceAccount issuer/JWKS URI 를 Blob 정적 웹 URL 로 지정
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state ISSUER_URL VM_IP

echo "[1/3] VM SSH 대기"
for i in $(seq 1 30); do vm_ssh true 2>/dev/null && break; sleep 10; [[ $i -lt 30 ]] || { echo "SSH 연결 실패" >&2; exit 1; }; done

echo "[2/3] k3s 설정 파일 배포"
cat > "$STATE_DIR/k3s-config.yaml" <<EOF
write-kubeconfig-mode: "0644"
kube-apiserver-arg:
  - "service-account-issuer=${ISSUER_URL}"
  - "service-account-jwks-uri=${ISSUER_URL}/openid/v1/jwks"
EOF
vm_scp "$STATE_DIR/k3s-config.yaml" /tmp/k3s-config.yaml
vm_ssh "sudo mkdir -p /etc/rancher/k3s && sudo mv /tmp/k3s-config.yaml /etc/rancher/k3s/config.yaml"

echo "[3/3] k3s 설치"
vm_ssh "curl -sfL https://get.k3s.io | sudo sh -"
vm_kubectl wait --for=condition=Ready node --all --timeout=180s
vm_kubectl get nodes
```

- [ ] **Step 2: 03-publish-oidc.sh 작성**

```bash
#!/usr/bin/env bash
# k3s SA 서명 공개키로 JWKS 를 만들고 discovery 문서와 함께 Blob 정적 웹에 업로드 후 검증
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state ISSUER_URL VM_IP STORAGE
[[ -n "$PY" ]] || { echo "python 필요" >&2; exit 1; }

echo "[1/4] SA 서명 공개키 추출 → JWKS 생성"
pem="$(vm_ssh 'for f in service.current.key service.key; do p=/var/lib/rancher/k3s/server/tls/$f; sudo test -f $p && sudo openssl rsa -in $p -pubout 2>/dev/null || true; done')"
printf '%s\n' "$pem" | "$PY" "$ROOT_DIR/scripts/lib/make_jwks.py" > "$STATE_DIR/jwks.json"

echo "[2/4] discovery 문서 생성"
cat > "$STATE_DIR/openid-configuration" <<EOF
{
  "issuer": "${ISSUER_URL}",
  "jwks_uri": "${ISSUER_URL}/openid/v1/jwks",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"]
}
EOF

echo "[3/4] 업로드(운영자 작업용 storage 인증. 워크로드는 키를 쓰지 않음)"
(
  cd "$STATE_DIR"
  az storage blob upload --account-name "$STORAGE" --auth-mode key -c '$web' \
    -f openid-configuration -n .well-known/openid-configuration --content-type application/json --overwrite -o none
  az storage blob upload --account-name "$STORAGE" --auth-mode key -c '$web' \
    -f jwks.json -n openid/v1/jwks --content-type application/json --overwrite -o none
)

echo "[4/4] 공개 URL 확인 + 실제 SA 토큰의 iss/kid 대조"
for i in $(seq 1 12); do
  curl -fsS "${ISSUER_URL}/.well-known/openid-configuration" >/dev/null 2>&1 && \
  curl -fsS "${ISSUER_URL}/openid/v1/jwks" >/dev/null 2>&1 && break
  sleep 5; [[ $i -lt 12 ]] || { echo "공개 URL 접근 실패" >&2; exit 1; }
done
token="$(vm_kubectl -n default create token default --audience api://AzureADTokenExchange)"
"$PY" "$ROOT_DIR/scripts/lib/check_jwks.py" --issuer "$ISSUER_URL" --token "$token"
```

- [ ] **Step 3: 구문 검사**

Run: `python -m unittest tests.test_scripts_syntax -v`
Expected: PASS

- [ ] **Step 4: 실제 실행 검증**

Run: `bash scripts/02-install-k3s.sh && bash scripts/03-publish-oidc.sh`
Expected: 노드 `Ready` 출력, 마지막에 `OK: 토큰의 iss/kid 가 공개된 issuer/JWKS 와 일치합니다`.
실패 시: `iss 불일치`면 k3s 기본 issuer가 남은 것 — VM에서 `sudo cat /etc/rancher/k3s/config.yaml`과 `sudo journalctl -u k3s | grep service-account-issuer`로 확인하고 `sudo systemctl restart k3s` 후 03 재실행.

- [ ] **Step 5: 커밋**

```bash
git add scripts/02-install-k3s.sh scripts/03-publish-oidc.sh
git commit -m "feat: add k3s install and OIDC issuer publishing scripts"
```

---

### Task 7: webhook, federated credential, 앱 배포(04, 05, 06)

**Files:**
- Create: `scripts/04-install-webhook.sh`, `scripts/05-federate.sh`, `scripts/06-deploy-demo.sh`, `k8s/base.yaml.tpl`, `k8s/job.yaml.tpl`

**Interfaces:**
- Consumes: state `TENANT_ID CLIENT_ID ISSUER_URL RG UAMI NS SA_NAME`.
- Produces: 네임스페이스 `wif-demo`, ServiceAccount `wif-sa`/`wif-other-sa`(둘 다 client-id 어노테이션), ConfigMap `wif-demo-app`(`demo.py`), Job 템플릿 플레이스홀더 `__NAME__ __NS__ __SA__ __ENDPOINT__ __DEPLOYMENT__ __RETRIES__`.

- [ ] **Step 1: 04-install-webhook.sh**

```bash
#!/usr/bin/env bash
# Azure Workload Identity webhook 설치(helm)
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state TENANT_ID VM_IP

vm_ssh 'command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash'
vm_ssh "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; \
  helm repo add azure-workload-identity https://azure.github.io/azure-workload-identity/charts --force-update && \
  helm repo update && \
  helm upgrade --install workload-identity-webhook azure-workload-identity/workload-identity-webhook \
    --namespace azure-workload-identity-system --create-namespace \
    --set azureTenantID=${TENANT_ID} --wait --timeout 5m"
vm_kubectl -n azure-workload-identity-system get pods
```

- [ ] **Step 2: 05-federate.sh**

```bash
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
```

- [ ] **Step 3: k8s 템플릿**

`k8s/base.yaml.tpl`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: __NS__
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wif-sa
  namespace: __NS__
  annotations:
    azure.workload.identity/client-id: __CLIENT_ID__
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: wif-other-sa
  namespace: __NS__
  annotations:
    azure.workload.identity/client-id: __CLIENT_ID__
```

`k8s/job.yaml.tpl`:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: __NAME__
  namespace: __NS__
spec:
  backoffLimit: 0
  template:
    metadata:
      labels:
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: __SA__
      restartPolicy: Never
      containers:
        - name: demo
          image: python:3.12-slim
          command: ["sh", "-c", "pip install -q --disable-pip-version-check azure-identity openai && python /app/demo.py"]
          env:
            - name: FOUNDRY_ENDPOINT
              value: "__ENDPOINT__"
            - name: FOUNDRY_DEPLOYMENT
              value: "__DEPLOYMENT__"
            - name: WIF_RETRIES
              value: "__RETRIES__"
          volumeMounts:
            - name: app
              mountPath: /app
      volumes:
        - name: app
          configMap:
            name: wif-demo-app
```

- [ ] **Step 4: 06-deploy-demo.sh**

```bash
#!/usr/bin/env bash
# Namespace/ServiceAccount 와 데모 코드 ConfigMap 배포 — Secret 은 만들지 않는다
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
require_state CLIENT_ID VM_IP

sed "s|__NS__|${NS}|g; s|__CLIENT_ID__|${CLIENT_ID}|g" "$ROOT_DIR/k8s/base.yaml.tpl" | vm_kubectl apply -f -
vm_scp "$ROOT_DIR/app/demo.py" /tmp/demo.py
vm_kubectl -n "$NS" create configmap wif-demo-app --from-file=demo.py=/tmp/demo.py --dry-run=client -o yaml | vm_kubectl apply -f -
vm_kubectl -n "$NS" get sa,configmap
echo "Secret 목록(비어 있어야 함):"
vm_kubectl -n "$NS" get secrets
```

- [ ] **Step 5: 구문 검사**

Run: `python -m unittest tests.test_scripts_syntax -v`
Expected: PASS

- [ ] **Step 6: 실제 실행 검증**

Run: `bash scripts/04-install-webhook.sh && bash scripts/05-federate.sh && bash scripts/06-deploy-demo.sh`
Expected: webhook 파드 `Running`, federated credential의 issuer/subject/audience 출력(issuer에 끝 슬래시 없음), 06 마지막에 `No resources found in wif-demo namespace.`(Secret 없음).

- [ ] **Step 7: 커밋**

```bash
git add scripts/04-install-webhook.sh scripts/05-federate.sh scripts/06-deploy-demo.sh k8s/
git commit -m "feat: add webhook, federated credential and demo deploy scripts"
```

---

### Task 8: 종단 검증과 정리(07, 99)

**Files:**
- Create: `scripts/07-verify.sh`, `scripts/99-cleanup.sh`

**Interfaces:**
- Consumes: `app/demo.py` 출력 계약(`RESULT=OK` / `RESULT=FAIL …`), `k8s/job.yaml.tpl` 플레이스홀더, state `FOUNDRY_ENDPOINT`.
- Produces: 종료코드 0이면 4개 검증 모두 통과.

- [ ] **Step 1: 07-verify.sh**

```bash
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
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'api-key: not-a-real-key' -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":5}' \
  "${FOUNDRY_ENDPOINT}/openai/deployments/${MODEL_NAME}/chat/completions?api-version=2024-10-21")"
[[ "$code" == "401" || "$code" == "403" ]] || fail "키 호출이 거부되지 않음 (HTTP $code)"
pass "키 호출 HTTP $code"

echo "🎉 모든 검증 통과: keyless WIF 증명 완료"
```

- [ ] **Step 2: 99-cleanup.sh**

```bash
#!/usr/bin/env bash
# 리소스 그룹 전체 삭제 및 로컬 상태 제거
source "$(dirname "${BASH_SOURCE[0]}")/00-env.sh"
read -r -p "리소스 그룹 $RG 를 삭제합니다. 계속할까요? (yes/no) " ans
[[ "$ans" == "yes" ]] || { echo "취소"; exit 0; }
az group delete -n "$RG" --yes --no-wait
rm -rf "$STATE_DIR"
echo "삭제 요청됨. Foundry 이름은 soft-delete 되며 SUFFIX 가 매번 달라 충돌하지 않습니다."
```

- [ ] **Step 3: 구문 검사**

Run: `python -m unittest discover -s tests -p "test_*.py"`
Expected: 모든 테스트 PASS

- [ ] **Step 4: 종단 실행 검증**

Run: `bash scripts/07-verify.sh`
Expected: 4단계 모두 `✅ 통과`, 마지막 `🎉 모든 검증 통과`. 양성 로그에는 `secret 유사 환경변수: 없음`, `iss: https://stwif….web.core.windows.net`, `sub: system:serviceaccount:wif-demo:wif-sa`, 모델 응답, `RESULT=OK`가 포함된다. 전파 지연으로 실패하면 몇 분 뒤 재실행.

- [ ] **Step 5: 커밋**

```bash
git add scripts/07-verify.sh scripts/99-cleanup.sh
git commit -m "feat: add end-to-end verification and cleanup scripts"
```

---

### Task 9: README와 스펙 정합

**Files:**
- Create: `README.md`
- Modify: `docs/superpowers/specs/2026-11-06-k3s-wif-foundry-demo-design.md` (§4 표의 02/03 순서와 순서 의존성 문단)

- [ ] **Step 1: 스펙 갱신**

§4 표에서 `02-oidc-issuer.sh`/`03-install-k3s.sh` 행을 `02-install-k3s.sh`(VM에 k3s 설치, issuer 플래그 포함)와 `03-publish-oidc.sh`(SA 공개키로 JWKS 생성·discovery와 업로드 후 토큰 iss/kid 검증) 순서로 교체하고, "순서 의존성" 문단을 "issuer URL은 01(Storage)에서 확정되고, JWKS는 k3s가 만든 키가 필요하므로 02(k3s) 이후 03에서 업로드한다"로 바꾼다. 또한 표에 `scripts/lib/make_jwks.py`, `scripts/lib/check_jwks.py`, `k8s/*.tpl` 행을 추가한다.

- [ ] **Step 2: README.md 작성(한국어)**

다음 섹션을 모두 채운다(실제 내용, 플레이스홀더 금지).
1. 개요와 아키텍처 다이어그램(스펙 §3의 도식 재사용)
2. 사전 요구사항: Azure CLI 로그인(`az login`), Bash(Git Bash/WSL/Cloud Shell), `ssh/scp/curl`, Python 3 + `pip install -r requirements-dev.txt`, 구독에 Foundry/`gpt-4o-mini GlobalStandard` 쿼터
3. 실행 순서 표: `01` → `02` → `03` → `04` → `05` → `06` → `07` → `99` 각 단계의 목적 한 줄
4. "무엇을 증명하는가": 4가지 검증 결과(양성, Secret 없음, 음성 2건)와 기대 출력 예시
5. 동작 원리: 토큰의 `iss/sub/aud`가 federated credential과 대조되는 과정, 키가 없는 이유(VM에 관리 ID 없음, `disableLocalAuth=true`)
6. 트러블슈팅: `AADSTS700211`(issuer 불일치/끝 슬래시), `AADSTS700213`(subject 불일치), `AADSTS70021`/전파 지연(수 분 후 재시도), `iss` 불일치(k3s 기본 issuer 잔존), Blob 정적 웹 404, 모델 리전 미지원(`LOCATION` 변경)
7. 정리: `bash scripts/99-cleanup.sh`, 비용 메모(VM B2s, Storage, 소량 호출)
8. 한계: 단일 노드/실제 온프레미스 네트워크 미포함, 운영 환경에서는 issuer에 커스텀 도메인·키 회전 절차 필요

- [ ] **Step 3: 전체 테스트 확인**

Run: `python -m unittest discover -s tests -p "test_*.py"`
Expected: 모든 테스트 PASS

- [ ] **Step 4: 커밋**

```bash
git add README.md docs/superpowers/specs/2026-11-06-k3s-wif-foundry-demo-design.md
git commit -m "docs: add README and align spec script ordering"
```

---

## 자체 검토 결과

- **스펙 커버리지**: 성공 기준 1~3은 Task 4·8, 4는 Task 9(README)와 99(cleanup). OIDC(Blob), UAMI+FIC, 신규 Foundry+`disableLocalAuth`, webhook+`DefaultAzureCredential`, 재시도, 사전 점검(`preflight`), SSH 제한 모두 대응. 스펙의 02/03 순서는 Task 9에서 정정.
- **플레이스홀더**: 없음(README는 섹션별 필수 내용을 명시).
- **타입/이름 일관성**: `build_jwks`, `check_token`, `audit_env`, `with_retry`, `decode_claims`, `RESULT=OK|FAIL` 계약, `save_state/require_state/vm_*` 및 state 변수명이 모든 Task에서 일치.
