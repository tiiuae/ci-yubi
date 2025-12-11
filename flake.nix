# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0

{
  description = "YubiHSM/Yubikey related code for CI/CD use";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
    sbsigntools.url = "github:tiiuae/sbsigntools";
    akvengine.url = "github:tiiuae/AzureKeyVaultManagedHSMEngine";
  };

  outputs =
    {
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

        tii-sbsign = sbsigntools.packages.${system}.default;
        akvenginePkg = akvengine.packages.${system}.default;

        systemd-sbsign = pkgs.stdenv.mkDerivation {
          name = "systemd-sbsign";
          # noop unpackPhase as there is no $src aside of systemd
          unpackPhase = "true";
          buildInputs = [ pkgs.systemd ];
          installPhase = ''
            mkdir -p $out/bin
            ln -s ${pkgs.systemd}/lib/systemd/systemd-sbsign $out/bin/systemd-sbsign
          '';
          meta.mainProgram = "systemd-sbsign";
        };

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

        uefisign = pkgs.writeShellApplication {
          name = "uefisign";
          runtimeInputs =
            (with pkgs; [
              coreutils
              gawk
              util-linux
              mtools
              zstd
              systemdUkify
              openssl
            ])
            ++ [
              systemd-sbsign
            ];
          text = builtins.readFile ./secboot/uefi-sign.sh;
        };

        uefisigniso = pkgs.writeShellApplication {
          name = "uefisigniso";
          runtimeInputs =
            (with pkgs; [
              coreutils
              gawk
              util-linux
              mtools
              zstd
              systemdUkify
              openssl
              xorriso
              squashfsTools
              binutils
              findutils
              dosfstools
            ])
            ++ [
              systemd-sbsign
              uefisign
            ];
          text = builtins.readFile ./secboot/uefi-sign-iso.sh;
        };

        uefikeygen = pkgs.writeShellApplication {
          name = "uefikeygen";
          runtimeInputs = with pkgs; [
            openssl
          ];
          runtimeEnv = {
            CONF = "${./secboot/conf}";
          };
          text = builtins.readFile ./secboot/keygen.sh;
        };

        cert-to-auth = pkgs.writeShellApplication {
          name = "cert-to-auth";
          runtimeInputs = with pkgs; [
            efitools
            openssl
          ];
          text = builtins.readFile ./secboot/cert-to-auth.sh;
        };

        # only used as dependency of uefisign-azure
        uefisign-azure-iso = pkgs.writeShellApplication {
          name = "uefisign-azure-iso";
          text = builtins.readFile ./secboot/uefi-sign-azure-iso.sh;
        };

        uefisign-azure = pkgs.writeShellApplication {
          name = "uefisign-azure";
          runtimeInputs =
            (with pkgs; [
              util-linux # for fdisk, losetup, etc.
              mtools
              gawk
              xorriso
              systemdUkify
            ])
            ++ [
              tii-sbsign
              akvenginePkg
              uefisign-azure-iso
            ];

          runtimeEnv = {
            OPENSSL_CONF = toString (
              pkgs.writeText "openssl_conf" ''
                openssl_conf = openssl_init

                [openssl_init]
                engines = engine_section

                [engine_section]
                akv = akv_section

                [akv_section]
                engine_id = akv
                dynamic_path = ${akvenginePkg}/lib/engines-3/e_akv.so
                init = 1
              ''
            );
          };

          text = ''
            exec ${./secboot/uefi-sign-azure.sh} ${./secboot/uefi-signing-cert.pem} "$@"
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          name = "ci-yubi";
          packages =
            (with pkgs; [
              azure-cli
            ])
            ++ pythonDependencies;
        };

        formatter = pkgs.nixfmt-tree;

        packages = {
          inherit
            sigver
            uefisign
            uefisigniso
            uefikeygen
            uefisign-azure
            cert-to-auth
            ;
        };

        apps = {
          sign = {
            type = "app";
            program = "${sigver}/bin/sign";
            meta.description = "Sign a file using Azure Keyvault";
          };

          verify = {
            type = "app";
            program = "${sigver}/bin/verify";
            meta.description = "Verify a file using Azure Keyvault";
          };
        };
      }
    );
}
