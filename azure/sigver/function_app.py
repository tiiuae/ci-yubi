import logging
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.keyvault.keys import KeyClient
from azure.keyvault.keys.crypto import CryptographyClient, SignatureAlgorithm

import json
import base64

app = func.FunctionApp()

credential = DefaultAzureCredential()

@app.route(route="VerifySignature", auth_level=func.AuthLevel.ANONYMOUS)
def VerifySignature(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Python HTTP trigger function processed a request.')

    try:
        req_body = req.get_json()
        if not all(field in req_body for field in ['keyvault', 'certificateName', 'Signature', 'Hash']):
            return func.HttpResponse(
                body=json.dumps({'error': 'Missing required fields', 'message': 'Expected keyvault, certificateName, Signature, and Hash'}),
                mimetype="application/json",
                status_code=400
            )

        keyvault = req_body['keyvault']
        certificate_name = req_body['certificateName']
        b64signature = req_body['Signature']
        b64hash_value = req_body['Hash']
        logging.info ("Req data: b64Signature: "+b64signature+" b64Hash: "+b64hash_value)

        key_vault_url='https://'+keyvault+'.vault.azure.net/'
        
        key_client = KeyClient(vault_url=key_vault_url, credential=credential)

        key = key_client.get_key(certificate_name)
        crypto_client = CryptographyClient(key, credential)

        signature = base64.b64decode(b64signature)
        digest = base64.b64decode(b64hash_value)

        result = crypto_client.verify(SignatureAlgorithm.es256, digest, signature)
        logging.info ("Verification Result: "+str(result.is_valid))

        return func.HttpResponse(
            body=json.dumps({'message':'Signature Verification Result', 'is_valid': result.is_valid}),
            mimetype="application/json",
            status_code=200
        )

    except Exception as e:
        logging.error(f"An error occurred: {e}")
        return func.HttpResponse(
            body=json.dumps({'message': 'An error occurred during signature verification', 'error': str(e)}),
            mimetype="application/json",
            status_code=500
        )
