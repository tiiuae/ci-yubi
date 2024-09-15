# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0
""" Signature Verification Script """
import argparse

import sys
import os

import json
import base64
import requests

from sha256tree import sha256sum

# Default certificate to be used if no argument is given
CERTIFICATE_NAME="INT-Ghaf-Devenv-Common"

# Azure Function (verify-signature) URL
URL = "https://ghaf-devenv-microsign-aleksandrtserepo-app.azurewebsites.net/api/verify-signature"

def show_help():
    """Show help messsage"""
    print(f"Usage: {sys.argv[0]} [options] ")
    print()
    print("Options:")
    print("          --path=<path>             = Path to verify")
    print("          --cert=<certname>         = (optional) Name of the certificate to be used")
    print("          --sigfile=<filename>      = Signature filename")
    print("")
    sys.exit(0)

def main():
    """Send REST API request to VerifySignature Azure Function"""
    path = "."
    certificate_name = CERTIFICATE_NAME
    sigfile = "signature.bin"

    parser = argparse.ArgumentParser(description="Parse arguments")
    parser.add_argument("--path", default=".",
                        help="Specify the path. Default is current directory.")
    parser.add_argument("--cert", default=CERTIFICATE_NAME, help="Specify the certificate name.")
    parser.add_argument("--sigfile", default="signature.bin", help="Specify the signature file.")

    args = parser.parse_args()

    path=args.path
    certificate_name = args.cert
    sigfile = args.sigfile

    digest = base64.b64encode(sha256sum(path, 1024 * 1024, True)).decode('utf-8')
    if os.path.getsize(sigfile) != 64:
        print("Wrong signature size!")
        return -3

    with open(sigfile, "rb") as file:
        sig = file.read()

    signature = base64.b64encode(sig).decode('utf-8')

    data = {
        "certificateName": certificate_name, 
        "Hash": digest,
        "Signature": signature
    }

    headers = {"Content-Type": "application/json"}
    print (json.dumps(data))

    try:
        response = requests.post(URL, headers=headers, data=json.dumps(data), timeout=20)

        if response.status_code != 200:
            print(f"Error: {response.status_code}, Response: {response.text}")
            return -2
        print("Signature verification result:", response.json())
        return 0 if response.json().get('is_valid', False) else 1
    except requests.exceptions.RequestException as e:
        print(f"An error occurred while making the request: {str(e)}")
        return -2


if __name__ == "__main__":
    sys.exit(main())
