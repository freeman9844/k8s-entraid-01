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
