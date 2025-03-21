# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0
""" Signature Verification Script """
import argparse

import logging

import sys
import os

import json
import requests

LOG = logging.getLogger(os.path.abspath(__file__))


# Default certificate to be used if no argument is given
CERTIFICATE_NAME="INT-Ghaf-Devenv-Common"

# Azure Function (verify-signature) URL
URL = "https://ghaf-devenv-microsign-aleksandrtserepo-app.azurewebsites.net/api/verify-signature"
#URL = "http://localhost:7071/api/VerifySignature"
#URL = "https://ghaf-devenv-signverify.azurewebsites.net/api/verifysignature"

def main():
    """Send REST API request to VerifySignature Azure Function"""
    certificate_name = CERTIFICATE_NAME

    parser = argparse.ArgumentParser(description="Parse arguments")
    parser.add_argument("--url", default=URL, help="Microservice URL.")

    args = parser.parse_args()

    url=args.url

    certificate_name = CERTIFICATE_NAME
    digest = "oHvFcUwrDx0TbFdPa2oSd5h43r++xeyx7ffMUTT5Dl8="
    signature = "Alw/bIUjMP0iGUXLn9QU8DZ30sVApKx85qyYzCy/EysepzTgpD1HSY6jWfYyAI/cgsmHY8nUNkqfbiJ04IeSxg==" # pylint: disable=line-too-long
    data = {
        "certificateName": certificate_name, 
        "Hash": digest,
        "Signature": signature
    }

    headers = {"Content-Type": "application/json"}
    LOG.error (json.dumps(data))
    LOG.error(url)

    try:
        response = requests.post(url, headers=headers, data=json.dumps(data), timeout=20)

        if response.status_code == 503:
            LOG.error("Error: Resource not available")
            return -5

        if response.status_code != 200:
            LOG.error("Error: %s, Response: %s", response.status_code, response.text)
            return -1
        LOG.error("Signature verification result: %s", response.json())
        return 0 if response.json().get('is_valid', False) else 1
    except requests.exceptions.RequestException as e:
        LOG.error("An error occurred while making the request: %s", str(e))
        return -2


if __name__ == "__main__":
    sys.exit(main())
