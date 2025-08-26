#!/usr/bin/env bash
set -e

# Create Keypair for PK (the root or top CA key)
openssl genrsa -out keys/pk.key 2048

# Create self-signed certificate for PK
openssl req -new -x509 -days 3650 -key keys/pk.key -out keys/pk.crt -config conf/create_PK_cert.ini

# Create keypair for KEK (intermediate)
openssl genrsa -out keys/kek.key 2048

# Create CSR for KEK
openssl req -new -key keys/kek.key -out keys/kek.csr -config conf/create_KEK_cert.ini

# Sign KEK CSR with PK (acts as CA)
openssl x509 -req -in keys/kek.csr -CA keys/pk.crt -CAkey keys/pk.key -CAcreateserial -out keys/kek.crt -days 3650 -extfile conf/sign_KEK_csr.ini -extensions v3_req

# Create keypair for DB (leaf)
openssl genrsa -out keys/db.key 2048

# Create CSR for DB
openssl req -new -key keys/db.key -out keys/db.csr -config conf/create_DB_cert.ini

# Sign DB CSR with KEK
openssl x509 -req -in keys/db.csr -CA keys/kek.crt -CAkey keys/kek.key -CAcreateserial -out keys/db.crt -days 3650 -extfile conf/sign_DB_csr.ini -extensions v3_req

openssl x509 -in keys/pk.crt  -outform DER -out keys/pk.der
openssl x509 -in keys/kek.crt -outform DER -out keys/kek.der
openssl x509 -in keys/db.crt  -outform DER -out keys/db.der
