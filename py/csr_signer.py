# SPDX-FileCopyrightText: 2024 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0

from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.asymmetric.padding import PKCS1v15
from datetime import datetime, timedelta

def load_csr(csr_name):
    with open (csr_name, 'rb') as file:
        csr_pem=file.read()
    print(csr_pem)
    csr=x509.load_pem_x509_csr(csr_pem)
    return csr

def load_private_key(key_name, password=None):
    with open(key_name, 'rb') as file:
        key_pem=file.read()
    print(key_pem)
    private_key = serialization.load_pem_private_key(
        key_pem,
        password=password)
    return private_key

def sign_csr(csr, private_key, issuer_name, issuer_private_key, valid_days=365):
    subject=csr.subject
    issuer=issuer_name

    cert = x509.CertificateBuilder().subject_name(
            subject
        ).issuer_name(
            issuer
        ).public_key(
            csr.public_key()
        ).serial_number(
            x509.random_serial_number()
        ).not_valid_before(
            datetime.utcnow()
        ).not_valid_after(
            datetime.utcnow()+timedelta(days=valid_days)
        ).add_extension(
            x509.BasicConstraints(ca=False, path_length=None), critical=True,
        ).sign(private_key=issuer_private_key, algorithm=hashes.SHA256())

    return cert

csr = load_csr("test.csr")
private_key = load_private_key("mykey.pem")

issuer_name = x509.Name([
    x509.NameAttribute(NameOID.COUNTRY_NAME, u"FI"),
    x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, u"Tampere"),
    x509.NameAttribute(NameOID.LOCALITY_NAME, u"Tampere"),
    x509.NameAttribute(NameOID.ORGANIZATION_NAME, u"Ghaf"),
    x509.NameAttribute(NameOID.COMMON_NAME, u"Ghaf"),
])

certificate = sign_csr(csr, private_key, issuer_name, private_key)

with open("signed_cert.pem", "wb") as file:
    file.write(certificate.public_bytes(serialization.Encoding.PEM))
