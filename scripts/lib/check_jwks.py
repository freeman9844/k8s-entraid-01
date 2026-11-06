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
