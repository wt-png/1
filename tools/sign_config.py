#!/usr/bin/env python3
"""
sign_config.py — HMAC-SHA256 signing and verification of MSPB .set files.

Usage:
  python tools/sign_config.py sign   <file.set> [--key-env VAR | --key SECRET]
  python tools/sign_config.py verify <file.set> [--key-env VAR | --key SECRET]
  python tools/sign_config.py info   <file.set>

The signature is stored in a sidecar file:  <file.set>.sig

Sidecar format (JSON):
  {
    "file": "MSPB_Expert_Advisor.set",
    "sha256": "<hex digest of file content>",
    "hmac_sha256": "<hex HMAC-SHA256(key, sha256_hex)>",
    "signed_at": "2026-04-19T10:00:00Z",
    "ea_version": "17.0"
  }

Security model:
  - The plain SHA-256 digest detects accidental corruption.
  - The HMAC-SHA256 authenticates that the signer held the secret key.
  - The key should be a random 32+ byte secret shared only between the
    signing operator and the verification step (e.g. stored in an
    environment variable or a secrets manager).
  - Never commit the key to version control.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
import re


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_VERSION_RE = re.compile(r'#property\s+version\s+"([^"]+)"', re.IGNORECASE)
_SET_VERSION_RE = re.compile(r';\s*MSPB_Expert_Advisor\.set.*?v([\d.]+)', re.IGNORECASE)


def _sha256_file(path: Path) -> str:
    """Return the SHA-256 hex digest of *path*."""
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _hmac_sign(key: bytes, message: str) -> str:
    """Return HMAC-SHA256(key, message) as a hex string."""
    return hmac.new(key, message.encode(), hashlib.sha256).hexdigest()


def _load_key(args: argparse.Namespace) -> bytes:
    """Resolve the signing key from CLI args or raise SystemExit."""
    raw: str | None = None
    if args.key:
        raw = args.key
    elif args.key_env:
        raw = os.environ.get(args.key_env)
        if raw is None:
            sys.exit(f"ERROR: environment variable '{args.key_env}' is not set.")
    else:
        sys.exit("ERROR: provide --key or --key-env.")
    if len(raw) < 16:
        sys.exit("ERROR: key is too short (minimum 16 characters).")
    return raw.encode()


def _sidecar_path(set_path: Path) -> Path:
    return set_path.with_suffix(set_path.suffix + ".sig")


def _detect_version(set_path: Path) -> str:
    """Try to read the EA version from a nearby .mq5 or from the .set header."""
    mq5 = set_path.parent / "MSPB_Expert_Advisor.mq5"
    if mq5.exists():
        try:
            for line in mq5.open(encoding="utf-8", errors="ignore"):
                m = _VERSION_RE.search(line)
                if m:
                    return m.group(1)
        except OSError:
            pass
    # fall back to .set header comment
    try:
        first_lines = set_path.read_text(encoding="utf-8", errors="ignore")[:500]
        m = _SET_VERSION_RE.search(first_lines)
        if m:
            return m.group(1)
    except OSError:
        pass
    return "unknown"


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

def cmd_sign(set_path: Path, key: bytes) -> None:
    if not set_path.exists():
        sys.exit(f"ERROR: file not found: {set_path}")
    digest = _sha256_file(set_path)
    sig = _hmac_sign(key, digest)
    payload = {
        "file": set_path.name,
        "sha256": digest,
        "hmac_sha256": sig,
        "signed_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ea_version": _detect_version(set_path),
    }
    out = _sidecar_path(set_path)
    out.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"OK: signed '{set_path.name}' → '{out.name}'")
    print(f"    SHA-256:   {digest[:16]}…")
    print(f"    HMAC:      {sig[:16]}…")
    print(f"    Version:   {payload['ea_version']}")
    print(f"    Signed at: {payload['signed_at']}")


def cmd_verify(set_path: Path, key: bytes) -> None:
    if not set_path.exists():
        sys.exit(f"ERROR: file not found: {set_path}")
    sidecar = _sidecar_path(set_path)
    if not sidecar.exists():
        sys.exit(
            f"ERROR: signature file not found: {sidecar}\n"
            "       Run 'sign_config.py sign' first."
        )
    try:
        payload = json.loads(sidecar.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        sys.exit(f"ERROR: invalid signature file: {exc}")

    # 1. Check file hash
    actual_digest = _sha256_file(set_path)
    expected_digest: str = payload.get("sha256", "")
    if not hmac.compare_digest(actual_digest, expected_digest):
        sys.exit(
            "FAIL: file content has changed since signing.\n"
            f"      Expected SHA-256: {expected_digest[:32]}…\n"
            f"      Actual   SHA-256: {actual_digest[:32]}…"
        )

    # 2. Check HMAC
    expected_hmac: str = payload.get("hmac_sha256", "")
    actual_hmac = _hmac_sign(key, actual_digest)
    if not hmac.compare_digest(actual_hmac, expected_hmac):
        sys.exit(
            "FAIL: HMAC mismatch — wrong key or tampered signature file.\n"
            "      The .set file may have been signed with a different key."
        )

    print(f"OK: signature valid (sha256-hmac)")
    print(f"    File:      {set_path.name}")
    print(f"    Version:   {payload.get('ea_version', 'unknown')}")
    print(f"    Signed at: {payload.get('signed_at', 'unknown')}")


def cmd_info(set_path: Path) -> None:
    sidecar = _sidecar_path(set_path)
    if not sidecar.exists():
        sys.exit(f"ERROR: no signature file found: {sidecar}")
    try:
        payload = json.loads(sidecar.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        sys.exit(f"ERROR: invalid signature file: {exc}")

    # Check file hash without key
    if set_path.exists():
        actual_digest = _sha256_file(set_path)
        hash_ok = hmac.compare_digest(actual_digest, payload.get("sha256", ""))
        hash_status = "OK (unchanged)" if hash_ok else "CHANGED since signing"
    else:
        hash_status = "file not found"

    print(f"File:       {payload.get('file', set_path.name)}")
    print(f"EA version: {payload.get('ea_version', 'unknown')}")
    print(f"Signed at:  {payload.get('signed_at', 'unknown')}")
    print(f"SHA-256:    {payload.get('sha256', '')}")
    print(f"HMAC:       {payload.get('hmac_sha256', '')} (key required to verify)")
    print(f"Hash check: {hash_status}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="sign_config.py",
        description="HMAC-SHA256 signing and verification of MSPB .set files.",
    )
    sub = p.add_subparsers(dest="command", required=True)

    key_args = argparse.ArgumentParser(add_help=False)
    key_group = key_args.add_mutually_exclusive_group()
    key_group.add_argument("--key", metavar="SECRET", help="Signing key (plain text)")
    key_group.add_argument(
        "--key-env",
        metavar="VAR",
        default="MSPB_SIGNING_KEY",
        help="Environment variable containing the key (default: MSPB_SIGNING_KEY)",
    )

    sign_p = sub.add_parser("sign", parents=[key_args], help="Sign a .set file")
    sign_p.add_argument("file", type=Path, help="Path to .set file")

    verify_p = sub.add_parser("verify", parents=[key_args], help="Verify a .set file")
    verify_p.add_argument("file", type=Path, help="Path to .set file")

    info_p = sub.add_parser("info", help="Show signature metadata (no key needed)")
    info_p.add_argument("file", type=Path, help="Path to .set file")

    return p


def main(argv: list[str] | None = None) -> None:
    parser = _build_parser()
    args = parser.parse_args(argv)
    set_path: Path = args.file

    if args.command == "sign":
        key = _load_key(args)
        cmd_sign(set_path, key)
    elif args.command == "verify":
        key = _load_key(args)
        cmd_verify(set_path, key)
    elif args.command == "info":
        cmd_info(set_path)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
