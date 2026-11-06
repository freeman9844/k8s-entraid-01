"""파드 안에서 실행: Client Secret(Kubernetes Secret 에 저장된 문자열)으로 Foundry 모델을 호출한다."""
import os
import re
import sys
import time

SCOPE = "https://cognitiveservices.azure.com/.default"
API_VERSION = "2024-10-21"
FORBIDDEN = re.compile(r"(API_?KEY|PASSWORD)", re.IGNORECASE)


def audit_env(environ):
    """Foundry API Key / 비밀번호 유사 환경변수만 찾는다 (AZURE_CLIENT_SECRET 은 이 방식의 정상 구성 요소)."""
    return [k for k in environ if FORBIDDEN.search(k)]


def mask(key, value):
    return f"****(길이 {len(value)})" if "SECRET" in key.upper() else value


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
    retries = int(env.get("TOKEN_RETRIES", "1"))

    print("=== 1. 자격 증명 감사 ===")
    leaked = audit_env(env)
    print("Foundry API Key 유사 환경변수:", leaked or "없음")
    for k in sorted(k for k in env if k.startswith("AZURE_")):
        print(f"  {k}={mask(k, env[k])}")

    try:
        print("=== 2. Foundry 모델 호출 (DefaultAzureCredential → EnvironmentCredential) ===")
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
        print("RESULT=FAIL API Key 유사 환경변수가 존재합니다")
        return 1
    print("RESULT=OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
