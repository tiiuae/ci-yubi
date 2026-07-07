#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import cast


@dataclass
class SignArgs(argparse.Namespace):
    cert: str = ""
    pkey: str = ""
    kernel: str = ""
    output_kernel: str = ""


@dataclass
class RehashArgs(argparse.Namespace):
    kernel: str = ""
    manifest: str = ""
    output_manifest: str = ""


def cmd_rehash(args: RehashArgs) -> None:
    kernel = Path(args.kernel).resolve()
    manifest_path = Path(args.manifest).resolve()
    output_manifest = Path(args.output_manifest).resolve()

    if not kernel.is_file():
        raise FileNotFoundError(f"Kernel artifact not found: {kernel}")

    with manifest_path.open("r", encoding="utf-8") as f:
        manifest = cast(dict[str, object], json.load(f))

    kernel_entry = manifest.get("kernel")
    if not isinstance(kernel_entry, dict):
        raise ValueError("manifest must contain kernel")
    kernel_entry = cast(dict[str, object], kernel_entry)

    h = hashlib.sha256()
    with kernel.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)

    kernel_entry["sha256"] = h.hexdigest()
    kernel_entry["unpacked_size"] = kernel.stat().st_size

    output_manifest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=output_manifest.parent, delete=False
    ) as tmp:
        json.dump(manifest, tmp, indent=2, sort_keys=True)
        _ = tmp.write("\n")
        tmp_path = Path(tmp.name)
    _ = tmp_path.replace(output_manifest)
    print(f"Wrote rehashed manifest to {output_manifest}")


def cmd_sign(args: SignArgs) -> None:
    kernel = Path(args.kernel).resolve()
    output_kernel = Path(args.output_kernel).resolve()

    if not kernel.is_file():
        raise FileNotFoundError(f"Kernel artifact not found: {kernel}")

    output_kernel.parent.mkdir(parents=True, exist_ok=True)
    pkey_source = "provider:pkcs11" if args.pkey.startswith("pkcs11:") else "file"
    cert_source = "provider:pkcs11" if args.cert.startswith("pkcs11:") else "file"

    print(f"Signing {kernel.name}")
    _ = subprocess.run(
        [
            "systemd-sbsign",
            "sign",
            "--private-key-source",
            pkey_source,
            "--private-key",
            args.pkey,
            "--certificate-source",
            cert_source,
            "--certificate",
            args.cert,
            "--output",
            str(output_kernel),
            str(kernel),
        ],
        check=True,
    )
    print(f"Wrote signed kernel to {output_kernel}")


def parse_args(argv: list[str]) -> SignArgs | RehashArgs:
    if argv and argv[0] == "rehash":
        parser = argparse.ArgumentParser(
            prog=f"{Path(sys.argv[0]).name} rehash",
            description="Recompute kernel hash/size and write an updated manifest.",
        )
        _ = parser.add_argument("kernel")
        _ = parser.add_argument("manifest")
        _ = parser.add_argument("output_manifest")
        args = RehashArgs()
        _ = parser.parse_args(argv[1:], namespace=args)
        return args

    parser = argparse.ArgumentParser(
        description="Sign a sysupdate UKI or rehash a sysupdate manifest.",
        usage=(
            "%(prog)s <CERT> <PKEY> <KERNEL_EFI> <OUT_EFI>\n"
            "       %(prog)s rehash <KERNEL_EFI> <MANIFEST> <OUT_MANIFEST>"
        ),
    )
    _ = parser.add_argument("cert")
    _ = parser.add_argument("pkey")
    _ = parser.add_argument("kernel")
    _ = parser.add_argument("output_kernel")
    args = SignArgs()
    _ = parser.parse_args(argv, namespace=args)
    return args


def main(argv: list[str]) -> int:
    try:
        args = parse_args(argv)
        if isinstance(args, RehashArgs):
            cmd_rehash(args)
        else:
            cmd_sign(args)
    except (OSError, subprocess.CalledProcessError, ValueError) as e:
        print(e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
