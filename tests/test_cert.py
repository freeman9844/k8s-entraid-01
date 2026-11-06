import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "app"))

import demo_cert  # noqa: E402
import demo_secret  # noqa: E402

BASH = r"C:\Program Files\Git\bin\bash.exe" if os.name == "nt" else "bash"


class MakeCertTest(unittest.TestCase):
    def test_openssl_outputs_key_cert_and_thumbprint(self):
        with tempfile.TemporaryDirectory() as d:
            out = subprocess.run(
                [BASH, "scripts/lib/make_cert.sh", "t", "2", d.replace("\\", "/"), "c"],
                cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
            self.assertRegex(out, r"^[0-9A-F]{40}$")
            pem = open(os.path.join(d, "c.pem"), "rb").read()
            crt = open(os.path.join(d, "c.crt"), "rb").read()
            self.assertIn(b"PRIVATE KEY", pem)
            self.assertNotIn(b"PRIVATE KEY", crt)  # Entra 에는 공개 인증서만 업로드
            info = demo_cert.cert_info(os.path.join(d, "c.pem"))
            self.assertEqual(info["thumbprint"], out)
            self.assertTrue(info["has_private_key"])


class DemoCertAuditTest(unittest.TestCase):
    def test_cert_path_env_is_allowed_but_secret_is_flagged(self):
        env = {"AZURE_CLIENT_CERTIFICATE_PATH": "/x", "AZURE_CLIENT_SECRET": "s", "OPENAI_API_KEY": "k"}
        self.assertEqual(sorted(demo_cert.audit_env(env)), ["AZURE_CLIENT_SECRET", "OPENAI_API_KEY"])


class DemoSecretTest(unittest.TestCase):
    def test_client_secret_allowed_but_api_key_flagged_and_masked(self):
        env = {"AZURE_CLIENT_SECRET": "abc", "AZURE_OPENAI_API_KEY": "k"}
        self.assertEqual(demo_secret.audit_env(env), ["AZURE_OPENAI_API_KEY"])
        self.assertNotIn("abc", demo_secret.mask("AZURE_CLIENT_SECRET", "abc"))


if __name__ == "__main__":
    unittest.main()
