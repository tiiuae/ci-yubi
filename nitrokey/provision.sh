#!/bin/bash
SYSTEM_TIME="$(date -u +%FT%TZ)"
echo $SYSTEM_TIME
curl -k -X 'POST' \
  'https://ppclabz.net:8443/api/v1/provision' \
  -H 'accept: */*' \
  -H 'Content-Type: application/json' \
  -d '{
  "unlockPassphrase": "UnlockPassphrase",
  "adminPassphrase": "Administrator",
  "systemTime": "'${SYSTEM_TIME}'"
}'
