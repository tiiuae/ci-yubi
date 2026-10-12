#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def resolve_store_file(path: Path) -> Path:
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to("/nix/store") or not resolved.is_file():
        raise ValueError(
            f"Input must be a regular file in the immutable Nix store: {path}"
        )
    return resolved


def validate_manifest(path: Path, manifest: dict) -> None:
    # Keep these rules aligned with Ghaf's ghaf-update-manifest validation.
    # Do not execute tooling from the checkout being signed.
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be an object")
    if (
        type(manifest.get("manifest_version")) is not int
        or manifest["manifest_version"] != 2
    ):
        raise ValueError("manifest_version must be 2")
    for field in ("system", "target", "version"):
        if not isinstance(manifest.get(field), str) or not manifest[field].strip():
            raise ValueError(f"manifest {field} must be a non-empty string")
    for field in ("target", "version"):
        if re.fullmatch(r"[A-Za-z0-9._-]+", manifest[field]) is None:
            raise ValueError(
                f"manifest {field} must contain only ASCII letters, digits, '.', '_' or '-'"
            )
    if "build-system" in manifest and (
        not isinstance(manifest["build-system"], str)
        or not manifest["build-system"].strip()
    ):
        raise ValueError("manifest build-system must be a non-empty string")
    generation = manifest.get("generation")
    if type(generation) is not int or not 0 < generation < 2**64:
        raise ValueError("manifest generation must be a positive 64-bit integer")
    root_hash = manifest.get("root_verity_hash")
    if (
        not isinstance(root_hash, str)
        or re.fullmatch(r"[0-9a-fA-F]{64}", root_hash) is None
    ):
        raise ValueError("root_verity_hash must be exactly 64 hexadecimal characters")

    names = [path.name, path.name + ".sig"]
    for kind in ("root", "verity", "kernel"):
        entry = manifest.get(kind)
        if not isinstance(entry, dict):
            raise ValueError(f"manifest {kind} entry must be an object")
        name = entry.get("file")
        if (
            not isinstance(name, str)
            or not name
            or name != os.path.basename(name)
            or name in (".", "..")
            or "\0" in name
        ):
            raise ValueError(f"manifest {kind} file must be a safe basename")
        names.append(name)
        for field in ("packed_size", "unpacked_size"):
            size = entry.get(field)
            if type(size) is not int or not 0 < size < 2**64:
                raise ValueError(
                    f"manifest {kind} {field} must be a positive 64-bit integer"
                )
        digest = entry.get("sha256")
        if (
            not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-fA-F]{64}", digest) is None
        ):
            raise ValueError(
                f"manifest {kind} sha256 must be exactly 64 hexadecimal characters"
            )
    if len(names) != len(set(names)):
        raise ValueError("Artifact file names must be distinct from release metadata")
    if manifest["kernel"]["packed_size"] != manifest["kernel"]["unpacked_size"]:
        raise ValueError("manifest kernel packed and unpacked sizes must match")


def sha256_file(path: Path) -> str:
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def cmd_sign(args: argparse.Namespace) -> None:
    manifest_path = resolve_store_file(Path(args.manifest))
    with manifest_path.open(encoding="utf-8") as file:
        manifest = json.load(file)
    validate_manifest(manifest_path, manifest)
    # sbverify needs the public certificate as a file, while the private key can
    # still be selected through the existing PKCS#11 provider configuration.
    certificate = Path(args.cert).resolve(strict=True)
    output = Path(args.output_dir).resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError("Output directory must be empty")

    with tempfile.TemporaryDirectory(prefix=".sysupdate-", dir=output) as temporary:
        staging = Path(temporary)
        for kind in ("root", "verity", "kernel"):
            entry = manifest[kind]
            source = resolve_store_file(manifest_path.parent / entry["file"])
            artifact = staging / entry["file"]
            shutil.copyfile(source, artifact)
            if artifact.stat().st_size != entry["packed_size"]:
                raise ValueError(
                    f"{kind} packed size does not match the immutable manifest"
                )
            if sha256_file(artifact) != entry["sha256"].lower():
                raise ValueError(f"{kind} hash does not match the immutable manifest")

        kernel = staging / manifest["kernel"]["file"]
        # A separate directory avoids colliding with any manifest artifact name.
        with tempfile.TemporaryDirectory(dir=staging) as signing_directory:
            signed_kernel = Path(signing_directory) / "signed.efi"
            subprocess.run(
                [
                    "systemd-sbsign",
                    "sign",
                    "--private-key-source",
                    "provider:pkcs11" if args.pkey.startswith("pkcs11:") else "file",
                    "--private-key",
                    args.pkey,
                    "--certificate-source",
                    "file",
                    "--certificate",
                    str(certificate),
                    "--output",
                    str(signed_kernel),
                    str(kernel),
                ],
                check=True,
            )
            subprocess.run(
                ["sbverify", "--cert", str(certificate), str(signed_kernel)], check=True
            )
            signed_kernel.replace(kernel)

        # Match ghaf-update-manifest rehash semantics, preserving release metadata
        # and the root/verity unpacked sizes supplied by the immutable build.
        for kind in ("root", "verity", "kernel"):
            entry = manifest[kind]
            artifact = staging / entry["file"]
            entry.update(
                sha256=sha256_file(artifact), packed_size=artifact.stat().st_size
            )
            if kind == "kernel":
                entry["unpacked_size"] = entry["packed_size"]
        validate_manifest(manifest_path, manifest)
        finalized_manifest = staging / manifest_path.name
        with finalized_manifest.open("w", encoding="utf-8") as file:
            json.dump(manifest, file, indent=2, sort_keys=True)
            file.write("\n")
            file.flush()
            os.fsync(file.fileno())
        for kind in ("root", "verity", "kernel"):
            (staging / manifest[kind]["file"]).replace(output / manifest[kind]["file"])
        # Publish the manifest last, atomically, only after the bundle is complete.
        finalized_manifest.replace(output / manifest_path.name)
    print(f"Wrote signed sysupdate bundle to {output}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate a manifest-v2 Nix bundle, sign its UKI, and rehash the bundle.",
        usage="%(prog)s CERT KEY MANIFEST OUTPUT_DIR",
    )
    parser.add_argument("cert", help="Public signing certificate file")
    parser.add_argument("pkey", help="Private key file or PKCS#11 URI")
    parser.add_argument("manifest", help="Manifest in an immutable Nix build output")
    parser.add_argument("output_dir", help="New or empty output directory")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    try:
        cmd_sign(parse_args(argv))
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
