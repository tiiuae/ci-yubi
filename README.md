# ci-yubi

YubiHSM/Yubikey related code for CI/CD use

## Usage with nix

The `sigver` scripts are callable as nix apps:

```sh
nix run github:tiiuae/ci-yubi#sign -- --help

nix run github:tiiuae/ci-yubi#verify -- --help
```
