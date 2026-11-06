import glob
import os
import shutil
import subprocess
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = sorted(glob.glob(os.path.join(ROOT, "scripts", "*.sh")))


@unittest.skipUnless(shutil.which("bash"), "bash 필요")
class ScriptSyntaxTest(unittest.TestCase):
    def test_scripts_exist(self):
        self.assertTrue(SCRIPTS, "scripts/*.sh 가 없음")

    def test_all_scripts_parse(self):
        for path in SCRIPTS:
            with self.subTest(script=os.path.basename(path)):
                with open(path, "rb") as f:
                    r = subprocess.run(["bash", "-n"], stdin=f, capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)

    def test_env_defines_helpers(self):
        cmd = 'source scripts/00-env.sh\ntype save_state require_state preflight vm_ssh vm_scp vm_kubectl >/dev/null\necho "$RG"\n'
        r = subprocess.run(["bash"], input=cmd.encode(), cwd=ROOT, capture_output=True)
        r.stdout, r.stderr = r.stdout.decode(), r.stderr.decode()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(r.stdout.strip().startswith("rg-wif-demo-"), r.stdout)


if __name__ == "__main__":
    unittest.main()
