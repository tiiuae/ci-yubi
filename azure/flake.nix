{
  description = "DevShell with TPM-based Azure login and OpenSSL engine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        enginePath = "/var/lib/jenkins/workspace/GhafSB-test/e_akv.so";

        opensslCnf = pkgs.writeText "openssl.cnf" ''
          openssl_conf = openssl_init

          [openssl_init]
          engines = engine_section

          [engine_section]
          e_akv = e_akv_section

          [e_akv_section]
          engine_id = e_akv
          dynamic_path = ${enginePath}
          init = 1
        '';
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            openssl
            curl
            util-linux
            gnu-efi
            jq
            parted
            mtools
            oras
            cosign
            tpm2-tools
	    xxd
          ];

          shellHook = ''
            echo "Loading OpenSSL engine 'e_akv'..."
            export OPENSSL_CONF=${opensslCnf}
            export PATH=$PATH:/bin
            export AZURE_TENANT_ID=
            export AZURE_CLIENT_ID=

            if [[ -z "$AZURE_CLIENT_ID" || -z "$AZURE_TENANT_ID" ]]; then
              echo "Set AZURE_CLIENT_ID and AZURE_TENANT_ID in environment."
              return 1
            fi

            echo "Generating JWT payload..."
            EXP=$(($(date +%s) + 600))
            JTI=$(uuidgen)

            PAYLOAD=$(jq -n \
              --arg aud "https://login.microsoftonline.com/$AZURE_TENANT_ID/v2.0" \
              --arg iss "$AZURE_CLIENT_ID" \
              --arg sub "$AZURE_CLIENT_ID" \
              --arg jti "$JTI" \
              --argjson exp $EXP \
              '{
                aud: $aud,
                iss: $iss,
                sub: $sub,
                jti: $jti,
                exp: $exp
              }')

	    CERT_SHA256=$(openssl x509 -in azure-client.crt -noout -fingerprint -sha256 \
	      | cut -d'=' -f2 | tr -d ':' | xxd -r -p | openssl base64 -A | tr '+/' '-_' | tr -d '=')

	      HEADER=$(jq -n \
	        --arg alg "RS256" \
  		--arg typ "JWT" \
  		--arg x5tS256 "$CERT_SHA256" \
  		'{alg: $alg, typ: $typ, "x5t#S256": $x5tS256}')

            ENCODE() {
              echo -n "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '='
            }

            HEADER_B64=$(ENCODE "$HEADER")
            PAYLOAD_B64=$(ENCODE "$PAYLOAD")

            SIGNING_INPUT="$HEADER_B64.$PAYLOAD_B64"
            echo -n "$SIGNING_INPUT" > /tmp/input.txt

	    echo "Signing JWT with TPM..."
	    tpm2_sign --tcti=device:/dev/tpm0 -c sign.key -g sha256 -o /tmp/sig.bin /tmp/input.txt

	    if [ ! -f /tmp/sig.bin ]; then
	      echo "TPM signing failed. sig.bin was not created." >&2
	      exit 1
	    fi

            SIG_B64=$(openssl base64 -A -in /tmp/sig.bin | tr '+/' '-_' | tr -d '=')

            JWT="$SIGNING_INPUT.$SIG_B64"

	    AZURE_RESPONSE=$(curl -s -X POST \
	      -H "Content-Type: application/x-www-form-urlencoded" \
	      -d "grant_type=client_credentials" \
  	      -d "client_id=$AZURE_CLIENT_ID" \
  	      -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
  	      --data-urlencode "client_assertion=$JWT" \
  	      -d "scope=https://vault.azure.net/.default" \
  	      "https://login.microsoftonline.com/$AZURE_TENANT_ID/oauth2/v2.0/token")

	    echo "Azure response:"
	    echo "$AZURE_RESPONSE"

	    export AZURE_CLI_ACCESS_TOKEN=$(echo "$AZURE_RESPONSE" | jq -r .access_token)

            echo "Token acquired and exported to \$AZURE_CLI_ACCESS_TOKEN"
          '';
        };
      });
}
