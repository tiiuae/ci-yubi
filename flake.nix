# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0

{
  description = "YubiHSM/Yubikey related code for CI/CD use";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    sbsigntools.url = "github:tiiuae/sbsigntools";
    akvengine.url = "github:tiiuae/AzureKeyVaultManagedHSMEngine";
  };

  outputs =
    {
      # deadnix: skip
      self,
      nixpkgs,
      flake-utils,
      sbsigntools,
      akvengine,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        pythonDependencies = with pkgs.python3Packages; [
          azure-identity
          azure-keyvault-certificates
          azure-keyvault-keys
        ];

        sigver = pkgs.python3Packages.buildPythonPackage {
          pname = "sigver";
          version = "git";
          format = "setuptools";
          src = pkgs.lib.cleanSource ./py/sigver;
          propagatedBuildInputs = pythonDependencies;
        };

	sbsignPkg = sbsigntools.packages.${system}.default;
	akvenginePkg = akvengine.packages.${system}.default;

	signmeScript = pkgs.writeShellApplication {
	  name = "signme";
	  runtimeInputs = [
	    pkgs.util-linux     # for fdisk, losetup, etc.
	    pkgs.mtools
	    pkgs.gawk
	    sbsignPkg           # from flake input
    	    akvenginePkg        # from flake input
	    pkgs.xorriso
  	];

	text = ''
    	  set -euo pipefail

    	  tmpconf=$(mktemp)
    	  cat > "$tmpconf" <<EOF
openssl_conf = openssl_init

[openssl_init]
engines = engine_section

[engine_section]
akv = akv_section

[akv_section]
engine_id = akv
dynamic_path = ${akvenginePkg}/lib/engines-3/e_akv.so
init = 1
EOF

    export OPENSSL_CONF="$tmpconf"
    exec ${./secboot/signme.sh} ${./secboot/uefi-signing-cert.pem} "$@"
  '';
};

      in
      {
        devShells.default = pkgs.mkShell {
          name = "ci-yubi";
          packages = pythonDependencies;
        };

        packages = {
          inherit sigver;
        };

        apps = {
          sign = {
            type = "app";
            program = "${sigver}/bin/sign";
          };

          verify = {
            type = "app";
            program = "${sigver}/bin/verify";
          };

	  signme = {
	    type = "app";
	    program = "${signmeScript}/bin/signme";
	  };
        };
      }
    );
}
