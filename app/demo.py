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
            max_completion_tokens=500,
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
