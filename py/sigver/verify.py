# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0

import hashlib
import sys

from azure.identity import DefaultAzureCredential
from azure.keyvault.certificates import CertificateClient
from azure.keyvault.keys import KeyClient
from azure.keyvault.keys.crypto import CryptographyClient, SignatureAlgorithm

from sha256tree import sha256sum

KEY_VAULT_URL = "https://ghaf-devenv-ca.vault.azure.net/"
CERTIFICATE_NAME = "INT-lenovo-x1-carbon-gen11-debug-x86-64-linux"

def show_help():
    print(f"Usage: {sys.argv[0]} [options] ")
    print()
    print("Options:")
    print("          --path=<path>             = Path to be signed")
    print("          --cert=<certname>         = Name of the certificate to be used")
    print("          --keyvault=<keyvault url> = URL of the keyvault")
    print("          --sigfile=<filename>      = Signature filename")
    print("")
    sys.exit(0)

def main(args: list[str]):

    path="."
    key_vault_url = KEY_VAULT_URL
    certificate_name = CERTIFICATE_NAME
    sigfile = "signature.bin"

    args.pop(0)
    
    while args and args[0].startswith("--"):
        if args[0] == "--help":
            show_help()
        if args[0].startswith("--path="):
            args[0] = args[0].removeprefix("--path=")
            path=args[0]
        elif args[0].startswith("--cert="):
            args[0] = args[0].removeprefix("--cert=")
            certificate_name = args[0]
        elif args[0].startswith("--keyvault="):
            args[0] = args[0].removeprefix("--keyvault=")
            key_vault_url = args[0]
        elif args[0].startswith("--sigfile="):
            args[0] = args[0].removeprefix("--sigfile=")
            sigfile = args[0]
        else:
            print(f"Invalid argument: {args[0]}", file=sys.stderr)
            sys.exit(1)

        args.pop(0)

    credential = DefaultAzureCredential()

    certificate_client = CertificateClient(vault_url=key_vault_url, credential=credential)
    key_client = KeyClient(vault_url=key_vault_url, credential=credential)

    certificate = certificate_client.get_certificate(certificate_name)

    print(certificate.name)

    key = key_client.get_key(certificate_name)

    crypto_client = CryptographyClient(key, credential)

    digest = sha256sum(path, 1024*1024, True)

    with open(sigfile, "rb") as file:
        signature=file.read()

    result = crypto_client.verify(SignatureAlgorithm.es256, digest, signature)
    print ("Verification result: ", result.is_valid)
    assert result.is_valid

if __name__ == "__main__":
    main(sys.argv[:])
