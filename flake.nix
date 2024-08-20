# SPDX-FileCopyrightText: 2023 Technology Innovation Institute (TII)
# SPDX-License-Identifier: Apache-2.0

{
  description = "YubiHSM/Yubikey related code for CI/CD use";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      # deadnix: skip
      self,
      nixpkgs,
      flake-utils,
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
        };
      }
    );
}
