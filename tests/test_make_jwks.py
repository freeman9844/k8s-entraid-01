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
