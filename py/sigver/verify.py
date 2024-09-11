# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0

import sys

from sha256tree import sha256sum
import requests
import json
import base64

CERTIFICATE_NAME="INT-Ghaf-Devenv-Common"
url = "https://ghaf-devenv-microsign-aleksandrtserepo-app.azurewebsites.net/api/verify-signature"

def show_help():
    print(f"Usage: {sys.argv[0]} [options] ")
    print()
    print("Options:")
    print("          --path=<path>             = Path to verify")
    print("          --cert=<certname>         = (optional) Name of the certificate to be used")
    print("          --sigfile=<filename>      = Signature filename")
    print("")
    sys.exit(0)


def main():
    args = sys.argv[:]
    path = "."
    certificate_name = CERTIFICATE_NAME
    sigfile = "signature.bin"

    args.pop(0)

    while args and args[0].startswith("--"):
        if args[0] == "--help":
            show_help()
        if args[0].startswith("--path="):
            args[0] = args[0].removeprefix("--path=")
            path = args[0]
        elif args[0].startswith("--cert="):
            args[0] = args[0].removeprefix("--cert=")
            certificate_name = args[0]
        elif args[0].startswith("--sigfile="):
            args[0] = args[0].removeprefix("--sigfile=")
            sigfile = args[0]
        else:
            print(f"Invalid argument: {args[0]}", file=sys.stderr)
            sys.exit(1)

        args.pop(0)

    digest = base64.b64encode(sha256sum(path, 1024 * 1024, True)).decode('utf-8')

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
        response = requests.post(url, headers=headers, data=json.dumps(data))

        if response.status_code == 200:
            print("Signature verification result:", response.json())
        else:
            print(f"Error: {response.status_code}, Response: {response.text}")
    except Exception as e:
        print(f"An error occurred while making the request: {str(e)}")


if __name__ == "__main__":
    main()
