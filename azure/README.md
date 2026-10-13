# TPM-based Azure Client Authentication Setup (with flake.nix)

This guide walks through how to:

- Create an Azure App Registration
- Generate a TPM-backed signing key
- Upload a certificate to Azure
- Use flake.nix to obtain an access token

## 1. Azure App Registration

1. Go to Azure Portal

2. Navigate to Azure Active Directory → App registrations

3. Click "New registration"

- Name: (come up with some meaningful name, we will use tpm-client in this documentation)
- Leave other fields default, click "Register"

4. Note down:

- Application (client) ID
- Tenant ID

5. Go to Certificates & secrets → Certificates

- Leave this tab open — you will upload the cert here later.

## 2. Generate TPM-backed key

```
tpm2_createprimary -C o -c primary.ctx
tpm2_create -G rsa -u azure-client.pub -r azure-client.priv -C primary.ctx
tpm2_load -C primary.ctx -u azure-client.pub -r azure-client.priv -c sign.ctx
sudo tpm2_evictcontrol --tcti=device:/dev/tpm0 --hierarchy=o -c sign.ctx 0x81000002
```

## 3. Generate a dummy x509 for Azure

Azure requires a .crt file to associate with the JWT signing key.

```
openssl genrsa -out dummy.key 2048
openssl req -new -x509 -key dummy.key -out azure-client.crt -subj "/CN=TPM RSA Key"
```

Upload azure-client.crt in the portal under Certificates & secrets → Certificates.

## 4. Test with Azure app

Update the following lines in flake.nix with your APP's IDs:

```
export AZURE_CLIENT_ID="<your-client-id>"
export AZURE_TENANT_ID="<your-tenant-id>"
```

run

```
nix develop
env | grep AZURE
```

You should see AZURE_CLI_ACCESS_TOKEN in the list with non-empty value.
