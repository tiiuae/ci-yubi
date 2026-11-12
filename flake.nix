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

        x86_64Pkgs = nixpkgs.legacyPackages.x86_64-linux;
        aarch64Pkgs = nixpkgs.legacyPackages.aarch64-linux;
        systemdEfiStubs = pkgs.runCommand "systemd-efi-stubs" { } ''
          mkdir -p "$out/lib/systemd/boot/efi"

          cp \
              ${x86_64Pkgs.systemd}/lib/systemd/boot/efi/linuxx64.efi.stub \
              "$out/lib/systemd/boot/efi/linuxx64.efi.stub"

          cp \
              ${aarch64Pkgs.systemd}/lib/systemd/boot/efi/linuxaa64.efi.stub \
              "$out/lib/systemd/boot/efi/linuxaa64.efi.stub"
        '';

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

        uefiRawImageLib = builtins.readFile ./secboot/uefi-raw-image-lib.sh;

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
              file
            ])
            ++ [
              uefisignraw
              uefisigniso
            ];
          text = builtins.readFile ./secboot/uefi-sign.sh;
        };

        uefisign-simple = pkgs.writeShellApplication {
          name = "uefisign-simple";
          runtimeInputs = [ uefisignraw ];
          text = builtins.readFile ./secboot/uefi-sign-simple.sh;
        };

        uefisign-orin = pkgs.writeShellApplication {
          name = "uefisign-orin";
          runtimeInputs =
            (with pkgs; [
              coreutils
              gawk
              util-linux
              mtools
              zstd
              android-tools
              openssl
              sbsigntool
            ])
            ++ [
              systemd-sbsign
            ];
          text = uefiRawImageLib + "\n" + builtins.readFile ./secboot/uefi-sign-orin.sh;
        };

        uefi-sign-sysupdate = pkgs.writeShellApplication {
          name = "uefi-sign-sysupdate";
          runtimeInputs = [
            pkgs.python3
            pkgs.sbsigntool
            systemd-sbsign
          ];
          text = ''
            exec ${pkgs.python3}/bin/python3 ${./secboot/uefi-sign-sysupdate.py} "$@"
          '';
        };

        uefi-sign-x86-ab = pkgs.writeShellApplication {
          name = "uefi-sign-x86-ab";
          runtimeInputs =
            (with pkgs; [
              bmaptool
              coreutils
              diffutils
              findutils
              gnugrep
              jq
              mtools
              openssl
              python3
              sbsigntool
              zstd
            ])
            ++ [ systemd-sbsign ];
          runtimeEnv = {
            UEFI_VERIFY_ENROLLMENT = "${./secboot/verify-enrollment.py}";
          };
          text = uefiRawImageLib + "\n" + builtins.readFile ./secboot/uefi-sign-x86-ab.sh;
        };

        uefisignraw = pkgs.writeShellApplication {
          name = "uefisignraw";
          runtimeInputs =
            (with pkgs; [
              coreutils
              gawk
              util-linux
              mtools
              zstd
              systemdUkify
              openssl
              e2fsprogs
              file
              gnugrep
              gnused
              findutils
            ])
            ++ [
              systemd-sbsign
            ];
          runtimeEnv = {
            UEFISIGN_STUB_DIR = "${systemdEfiStubs}/lib/systemd/boot/efi";
          };
          text = uefiRawImageLib + "\n" + builtins.readFile ./secboot/uefi-sign-raw.sh;
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
              bmaptool
            ])
            ++ [
              systemd-sbsign
              uefisignraw
            ];
          text = uefiRawImageLib + "\n" + builtins.readFile ./secboot/uefi-sign-iso.sh;
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
              coreutils
              curl
              jq
              util-linux # for fdisk, losetup, etc.
              mtools
              gawk
              xorriso
              systemdUkify
              zstd
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
            export UEFISIGN_AZURE_CERT=${./secboot/uefi-signing-cert.pem}
            ${uefiRawImageLib}
            ${builtins.readFile ./secboot/uefi-sign-azure.sh}
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

        checks.enrollment-verifier =
          pkgs.runCommand "enrollment-verifier-tests"
            {
              nativeBuildInputs = [
                pkgs.python3
                pkgs.openssl
              ];
            }
            ''
              cp ${./secboot/verify-enrollment.py} verify-enrollment.py
              cp ${./secboot/test_verify_enrollment.py} test_verify_enrollment.py
              python3 test_verify_enrollment.py
              touch "$out"
            '';

        checks.uefi-sign-x86-ab-bmap =
          pkgs.runCommand "uefi-sign-x86-ab-bmap-tests"
            {
              nativeBuildInputs = with pkgs; [
                bmaptool
                coreutils
                gptfdisk
                zstd
              ];
            }
            ''
              truncate -s 8M input.raw
              sgdisk --new=1:1MiB:+1MiB --typecode=1:ef00 input.raw
              truncate -s 1M esp.img
              printf 'signed EFI data' | dd of=esp.img conv=notrunc status=none
              bmaptool create input.raw -o input.bmap
              zstd -q input.raw -o input.raw.zst
              cp input.raw expected.raw
              dd if=esp.img of=expected.raw bs=1M seek=1 conv=notrunc status=none
              . ${./secboot/uefi-raw-image-lib.sh}
              uefisign_write_signed_raw_image \
                input.raw.zst zst esp.img 1048576 1048576 signed.raw.zst zst

              uefisign_regenerate_bmap signed.raw.zst input.bmap signed.bmap "$PWD"

              zstd -q -dc signed.raw.zst | cmp expected.raw -
              bmaptool copy --bmap signed.bmap signed.raw.zst reconstructed.raw
              cmp expected.raw reconstructed.raw
              touch "$out"
            '';

        packages = {
          inherit
            sigver
            uefisign
            uefisignraw
            uefisigniso
            uefisign-simple
            uefisign-orin
            uefi-sign-sysupdate
            uefi-sign-x86-ab
            uefikeygen
            uefisign-azure
            cert-to-auth
            systemd-sbsign
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

          uefi-sign-sysupdate = {
            type = "app";
            program = "${uefi-sign-sysupdate}/bin/uefi-sign-sysupdate";
            meta.description = "Validate and sign manifest-v2 sysupdate bundles";
          };

          uefi-sign-x86-ab = {
            type = "app";
            program = "${uefi-sign-x86-ab}/bin/uefi-sign-x86-ab";
            meta.description = "Sign the EFI boot chain in a Ghaf x86 secure A/B disk image";
          };
        };
      }
    );
}
