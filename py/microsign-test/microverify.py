from sha256tree import sha256sum
import requests
import json
import base64

url = "https://ghaf-devenv-microsign-aleksandrtserepo-app.azurewebsites.net/api/verify-signature"

with open('signature.sig', 'rb') as file:
    sig = file.read()

signature = base64.b64encode(sig).decode('utf-8')

digest = base64.b64encode(sha256sum('/home/alextserepov/Downloads/nixos-sd-image-24.1\
1.20240802.c488d21-aarch64-linux.img.zst', 1024*1024, True)).decode('utf-8')

print (f"signature: {signature}")
print (f"digest: {digest}")

data = {
    "certificateName": "INT-Ghaf-Devenv-Common", 
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
