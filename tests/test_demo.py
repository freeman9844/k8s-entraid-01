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

        def fn():
            raise RuntimeError("x")

        with self.assertRaises(RuntimeError):
            demo.with_retry(fn, 1, 9, sleep=sleeps.append)
        self.assertEqual(sleeps, [])


class DecodeClaimsTest(unittest.TestCase):
    def test_reads_payload(self):
        claims_in = {"iss": "https://i", "sub": "system:serviceaccount:a:b", "aud": ["api://AzureADTokenExchange"]}
        token = f"{seg({'alg': 'RS256'})}.{seg(claims_in)}.sig"
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
