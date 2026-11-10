# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
"""Cryptographic regression tests for UEFI Secure Boot enrollment files."""

import pathlib
import ssl
import struct
import subprocess
import sys
import tempfile
import unittest
import uuid


VERIFIER = pathlib.Path(__file__).with_name("verify-enrollment.py")
PKCS7_GUID = uuid.UUID("4aafd29d-68df-49ee-8aa9-347d375665a7").bytes_le
X509_GUID = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072").bytes_le
GLOBAL_GUID = uuid.UUID("8be4df61-93ca-11d2-aa0d-00e098032b8c").bytes_le
IMAGE_SECURITY_GUID = uuid.UUID("d719b2cb-3d3a-4596-a3bc-dad00e67656f").bytes_le


def der_item(data, offset):
    tag = data[offset]
    size = data[offset + 1]
    start = offset + 2
    if size & 0x80:
        count = size & 0x7F
        size = int.from_bytes(data[start : start + count], "big")
        start += count
    return tag, data[start : start + size], start + size


def bare_signed_data(cms):
    tag, content, end = der_item(cms, 0)
    assert tag == 0x30 and end == len(cms)
    tag, oid, offset = der_item(content, 0)
    assert tag == 0x06 and oid == bytes.fromhex("2a864886f70d010702")
    tag, explicit, end = der_item(content, offset)
    assert tag == 0xA0 and end == len(content)
    return explicit


class EnrollmentVerifierTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory()
        cls.directory = pathlib.Path(cls.scratch.name)
        for name in ("PK", "KEK", "db"):
            subprocess.run(
                [
                    "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                    "-days", "1", "-subj", f"/CN={name}",
                    "-keyout", str(cls.directory / f"{name}.key"),
                    "-out", str(cls.directory / f"{name}.crt"),
                ],
                check=True,
                capture_output=True,
            )

    @classmethod
    def tearDownClass(cls):
        cls.scratch.cleanup()

    def setUp(self):
        self.auth = {}
        for name in ("PK", "KEK", "db"):
            self.auth[name] = self.make_auth(name)

    def make_auth(self, name, signer=None, timestamp=None, append=None, bare=False):
        signer = signer or ("KEK" if name == "db" else "PK")
        append = (name != "PK") if append is None else append
        if timestamp is None:
            timestamp = bytes(16) if append else struct.pack(
                "<HBBBBBBIhBB", 2026, 10, 22, 12, 0, 0, 0, 0, 0, 0, 0
            )
        certificate = ssl.PEM_cert_to_DER_cert(
            (self.directory / f"{name}.crt").read_text()
        )
        payload = (
            X509_GUID
            + struct.pack("<III", 44 + len(certificate), 0, 16 + len(certificate))
            + bytes(16)
            + certificate
        )
        guid = IMAGE_SECURITY_GUID if name == "db" else GLOBAL_GUID
        attributes = 0x27 | (0x40 if append else 0)
        signed_content = (
            name.encode("utf-16-le")
            + guid
            + struct.pack("<I", attributes)
            + timestamp
            + payload
        )
        signature = subprocess.run(
            [
                "openssl", "cms", "-sign", "-binary", "-outform", "DER",
                "-signer", str(self.directory / f"{signer}.crt"),
                "-inkey", str(self.directory / f"{signer}.key"),
                "-noattr", "-nosmimecap",
            ],
            input=signed_content,
            check=True,
            capture_output=True,
        ).stdout
        if bare:
            signature = bare_signed_data(signature)
        return (
            timestamp
            + struct.pack("<IHH", 24 + len(signature), 0x200, 0xEF1)
            + PKCS7_GUID
            + signature
            + payload
        )

    def run_verifier(self):
        for name, auth in self.auth.items():
            (self.directory / f"{name}.auth").write_bytes(auth)
        return subprocess.run(
            [sys.executable, str(VERIFIER), str(self.directory)],
            capture_output=True,
            text=True,
        )

    def test_valid_replace_append_and_bare_signed_data(self):
        self.auth["PK"] = self.make_auth("PK", bare=True)
        self.auth["KEK"] = self.make_auth("KEK", append=False)
        self.assertEqual(self.run_verifier().returncode, 0)

    def test_bogus_one_byte_signature(self):
        original = self.auth["PK"]
        length = struct.unpack_from("<I", original, 16)[0]
        self.auth["PK"] = (
            original[:16]
            + struct.pack("<IHH", 25, 0x200, 0xEF1)
            + PKCS7_GUID
            + b"\x00"
            + original[16 + length :]
        )
        self.assertNotEqual(self.run_verifier().returncode, 0)

    def test_trailing_signature_garbage(self):
        original = self.auth["PK"]
        length = struct.unpack_from("<I", original, 16)[0]
        self.auth["PK"] = (
            original[:16]
            + struct.pack("<IHH", length + 1, 0x200, 0xEF1)
            + PKCS7_GUID
            + original[40 : 16 + length]
            + b"\x00"
            + original[16 + length :]
        )
        self.assertNotEqual(self.run_verifier().returncode, 0)

    def test_changed_timestamp(self):
        auth = bytearray(self.auth["PK"])
        auth[5] = 1  # Valid-looking minute, but not the signed minute.
        self.auth["PK"] = bytes(auth)
        self.assertNotEqual(self.run_verifier().returncode, 0)

    def test_invalid_but_signed_timestamp(self):
        invalid = struct.pack("<HBBBBBBIhBB", 2026, 13, 22, 12, 0, 0, 0, 0, 0, 0, 0)
        self.auth["PK"] = self.make_auth("PK", timestamp=invalid)
        self.assertNotEqual(self.run_verifier().returncode, 0)

    def test_wrong_signer_for_kek_and_db(self):
        for name, signer in (("KEK", "KEK"), ("db", "db")):
            with self.subTest(name=name):
                self.auth[name] = self.make_auth(name, signer=signer)
                self.assertNotEqual(self.run_verifier().returncode, 0)
                self.auth[name] = self.make_auth(name)

    def test_changed_payload(self):
        auth = bytearray(self.auth["db"])
        auth[-1] ^= 1
        self.auth["db"] = bytes(auth)
        self.assertNotEqual(self.run_verifier().returncode, 0)


if __name__ == "__main__":
    unittest.main()
