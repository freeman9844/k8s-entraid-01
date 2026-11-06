"""파드 안에서 실행: Client Certificate(Secret 에 저장된 개인키)로 Foundry 모델을 호출한다."""
import os
import re
import sys
import time

SCOPE = "https://cognitiveservices.azure.com/.default"
API_VERSION = "2024-10-21"
STRICT_SECRET_LIKE = re.compile(r"(API_?KEY|SECRET|PASSWORD)", re.IGNORECASE)


def audit_env(environ):
    """인증서 방식에서도 허용되지 않는 값(API Key / Client Secret / 비밀번호)만 찾는다."""
    return [k for k in environ if STRICT_SECRET_LIKE.search(k)]


def cert_info(path):
    """마운트된 PEM 에 개인키가 들어 있는지와 인증서 썸프린트/만료일을 반환한다."""
    with open(path, "rb") as f:
        data = f.read()
    has_key = b"PRIVATE KEY" in data
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes

    cert = x509.load_pem_x509_certificate(data[data.index(b"-----BEGIN CERTIFICATE-----"):])
    return {
        "has_private_key": has_key,
        "thumbprint": cert.fingerprint(hashes.SHA1()).hex().upper(),
        "not_after": cert.not_valid_after_utc.isoformat(),
    }


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
    print("API Key/Client Secret 유사 환경변수:", leaked or "없음")
    for k in sorted(k for k in env if k.startswith("AZURE_")):
        print(f"  {k}={env[k]}")

    try:
        print("=== 2. 마운트된 클라이언트 인증서 ===")
        info = cert_info(env["AZURE_CLIENT_CERTIFICATE_PATH"])
        print(f"  개인키 포함: {info['has_private_key']} (← 이것이 파드에 저장된 비밀)")
        print(f"  thumbprint: {info['thumbprint']}")
        print(f"  not_after : {info['not_after']}")

        print("=== 3. Foundry 모델 호출 (DefaultAzureCredential → EnvironmentCredential) ===")
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
        print("RESULT=FAIL API Key/Client Secret 유사 환경변수가 존재합니다")
        return 1
    print("RESULT=OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
