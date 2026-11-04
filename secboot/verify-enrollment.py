# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
import datetime
import pathlib
import ssl
import struct
import subprocess
import sys
import tempfile
import uuid


PKCS7_GUID = uuid.UUID("4aafd29d-68df-49ee-8aa9-347d375665a7").bytes_le
X509_GUID = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072").bytes_le
GLOBAL_GUID = uuid.UUID("8be4df61-93ca-11d2-aa0d-00e098032b8c").bytes_le
IMAGE_SECURITY_GUID = uuid.UUID("d719b2cb-3d3a-4596-a3bc-dad00e67656f").bytes_le
TIME_BASED_ATTRIBUTES = 0x27  # NV | BS | RT | time-based authenticated write
APPEND_ATTRIBUTES = TIME_BASED_ATTRIBUTES | 0x40


def der_length(length):
    if length < 128:
        return bytes((length,))
    encoded = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes((0x80 | len(encoded),)) + encoded


def wrap_signed_data(signature):
    # UEFI accepts both a bare PKCS#7 SignedData and a ContentInfo wrapper.
    signed_data_oid = bytes.fromhex("06092a864886f70d010702")
    explicit = b"\xa0" + der_length(len(signature)) + signature
    body = signed_data_oid + explicit
    return b"\x30" + der_length(len(body)) + body


def check_der_sequence(data):
    if len(data) < 2 or data[0] != 0x30:
        raise ValueError("authentication signature is not DER PKCS#7")
    first = data[1]
    if first < 128:
        size, start = first, 2
    else:
        count = first & 0x7F
        if not 1 <= count <= 4 or len(data) < 2 + count:
            raise ValueError("invalid PKCS#7 DER length")
        size = int.from_bytes(data[2 : 2 + count], "big")
        start = 2 + count
        if size < 128 or data[2] == 0:
            raise ValueError("noncanonical PKCS#7 DER length")
    if start + size != len(data):
        raise ValueError("truncated PKCS#7 or trailing signature data")


def check_timestamp(timestamp, append):
    year, month, day, hour, minute, second, pad1, nanosecond, timezone, daylight, pad2 = struct.unpack(
        "<HBBBBBBIhBB", timestamp
    )
    if pad1 or nanosecond or timezone or daylight or pad2:
        raise ValueError("invalid authentication timestamp fields")
    # The UEFI append-write form may use an all-zero timestamp.
    if append and timestamp == bytes(16):
        return
    if not 1900 <= year <= 9999:
        raise ValueError("invalid authentication timestamp year")
    try:
        datetime.datetime(year, month, day, hour, minute, second)
    except ValueError as error:
        raise ValueError("invalid authentication timestamp") from error


def verify_signature(directory, name, timestamp, payload, signature):
    check_der_sequence(signature)
    signer = "KEK" if name == "db" else "PK"
    guid = IMAGE_SECURITY_GUID if name == "db" else GLOBAL_GUID
    # efitools may create KEK/db enrollment as a replacement or an append.
    attributes = (TIME_BASED_ATTRIBUTES,) if name == "PK" else (
        TIME_BASED_ATTRIBUTES,
        APPEND_ATTRIBUTES,
    )
    with tempfile.TemporaryDirectory() as temporary:
        temporary = pathlib.Path(temporary)
        signature_file = temporary / "signature.der"
        content_file = temporary / "signed-content"
        for attribute in attributes:
            try:
                check_timestamp(timestamp, attribute == APPEND_ATTRIBUTES)
            except ValueError:
                continue
            content_file.write_bytes(
                name.encode("utf-16-le")
                + guid
                + struct.pack("<I", attribute)
                + timestamp
                + payload
            )
            for candidate in (signature, wrap_signed_data(signature)):
                signature_file.write_bytes(candidate)
                result = subprocess.run(
                    [
                        "openssl", "cms", "-verify", "-binary", "-inform", "DER",
                        "-in", str(signature_file), "-content", str(content_file),
                        "-nointern", "-certfile", str(directory / f"{signer}.crt"),
                        # The exact signer certificate is pinned above; do not
                        # substitute PKI path validation for UEFI authorization.
                        "-noverify", "-out", str(temporary / "verified-content"),
                    ],
                    capture_output=True,
                    check=False,
                )
                if result.returncode == 0:
                    return
    raise ValueError(f"invalid authentication signature or timestamp (expected {signer} signer)")


def verify(directory, name):
    auth = (directory / f"{name}.auth").read_bytes()
    certificate = ssl.PEM_cert_to_DER_cert((directory / f"{name}.crt").read_text())
    if len(auth) < 41:
        raise ValueError("truncated authentication header")
    length, revision, kind = struct.unpack_from("<IHH", auth, 16)
    if (
        length <= 24
        or 16 + length >= len(auth)
        or revision != 0x200
        or kind != 0xEF1
        or auth[24:40] != PKCS7_GUID
    ):
        raise ValueError("invalid authentication header")
    payload = auth[16 + length :]
    if len(payload) < 44:
        raise ValueError("truncated enrollment payload")
    size, header_size, signature_size = struct.unpack_from("<III", payload, 16)
    if (
        payload[:16] != X509_GUID
        or header_size != 0
        or size != len(payload)
        or size != 28 + signature_size
        or signature_size != 16 + len(certificate)
        or payload[44:] != certificate
    ):
        raise ValueError("enrollment payload does not match certificate")
    verify_signature(directory, name, auth[:16], payload, auth[40 : 16 + length])


if len(sys.argv) != 2:
    sys.exit("Usage: verify-enrollment.py KEY_DIRECTORY")
for name in ("PK", "KEK", "db"):
    try:
        verify(pathlib.Path(sys.argv[1]), name)
    except (OSError, ValueError, struct.error) as error:
        sys.exit(f"Invalid {name}.auth: {error}")
