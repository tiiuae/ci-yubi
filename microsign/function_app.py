import logging
import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.keyvault.keys import KeyClient
from azure.keyvault.keys.crypto import CryptographyClient, SignatureAlgorithm
import json
import base64

app = func.FunctionApp()

key_vault_url = "https://ghaf-devenv-ca.vault.azure.net/"
credential = DefaultAzureCredential()
key_client = KeyClient(vault_url=key_vault_url, credential=credential)

@app.function_name(name="VerifySignatureFunction") 
@app.route(route="verify-signature", methods=["POST"], auth_level=func.AuthLevel.ANONYMOUS) 
def verify_signature(req: func.HttpRequest) -> func.HttpResponse:
    logging.info('Received an HTTP request to verify signature.')

    try:
        req_body = req.get_json()
        certificate_name = req_body['certificateName']
        signature = req_body['Signature']
        hash_value = req_body['Hash']
        logging.info("SIGNATURE: "+signature)
        logging.info("HASH: "+hash_value)

        key = key_client.get_key(certificate_name)
        crypto_client = CryptographyClient(key, credential)

        sig = base64.b64decode(signature)
        digest = base64.b64decode(hash_value)
#        logging.info("decoded SIG: "+str(sig))
#        logging.info("decoded HASH: "+str(digest))
        result = crypto_client.verify(SignatureAlgorithm.es256, digest, sig)
        logging.info("Verification result: "+ str(result.is_valid))


        return func.HttpResponse(
            body=json.dumps({'is_valid': result.is_valid, 'message': 'Signature verification result'}),
            mimetype="application/json",
            status_code=200
        )

    except Exception as e:
        logging.error(f"An error occurred: {e}")
        return func.HttpResponse(
            body=json.dumps({'error': str(e), 'message': 'An error occurred during signature verification'}),
            mimetype="application/json",
            status_code=500
        )
