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
