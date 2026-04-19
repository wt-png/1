"""
tests for tools/sign_config.py — HMAC-SHA256 .set file signing.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import pytest

# Make tools/ importable regardless of working directory
sys.path.insert(0, str(Path(__file__).parent))
import sign_config as sc


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

KEY = b"test-signing-key-32-bytes-long!!"
KEY_STR = KEY.decode()


@pytest.fixture()
def set_file(tmp_path: Path) -> Path:
    p = tmp_path / "test.set"
    p.write_text(
        "; MSPB_Expert_Advisor.set — test\nInpRiskPercent=0.30\nInpMagic=20250213\n",
        encoding="utf-8",
    )
    return p


@pytest.fixture()
def signed_file(set_file: Path) -> Path:
    sc.cmd_sign(set_file, KEY)
    return set_file


# ---------------------------------------------------------------------------
# _sha256_file
# ---------------------------------------------------------------------------

def test_sha256_file_deterministic(tmp_path: Path) -> None:
    f = tmp_path / "a.txt"
    f.write_bytes(b"hello")
    d1 = sc._sha256_file(f)
    d2 = sc._sha256_file(f)
    assert d1 == d2


def test_sha256_file_changes_on_edit(tmp_path: Path) -> None:
    f = tmp_path / "b.txt"
    f.write_bytes(b"hello")
    d1 = sc._sha256_file(f)
    f.write_bytes(b"world")
    d2 = sc._sha256_file(f)
    assert d1 != d2


# ---------------------------------------------------------------------------
# _hmac_sign
# ---------------------------------------------------------------------------

def test_hmac_sign_deterministic() -> None:
    sig1 = sc._hmac_sign(KEY, "abc")
    sig2 = sc._hmac_sign(KEY, "abc")
    assert sig1 == sig2


def test_hmac_sign_different_keys() -> None:
    sig1 = sc._hmac_sign(b"key1", "abc")
    sig2 = sc._hmac_sign(b"key2", "abc")
    assert sig1 != sig2


def test_hmac_sign_different_messages() -> None:
    sig1 = sc._hmac_sign(KEY, "abc")
    sig2 = sc._hmac_sign(KEY, "abd")
    assert sig1 != sig2


def test_hmac_sign_returns_hex_string() -> None:
    sig = sc._hmac_sign(KEY, "abc")
    # hex string: 64 chars for SHA-256
    assert len(sig) == 64
    assert all(c in "0123456789abcdef" for c in sig)


# ---------------------------------------------------------------------------
# cmd_sign
# ---------------------------------------------------------------------------

def test_sign_creates_sidecar(set_file: Path) -> None:
    sc.cmd_sign(set_file, KEY)
    sidecar = sc._sidecar_path(set_file)
    assert sidecar.exists()


def test_sign_sidecar_valid_json(set_file: Path) -> None:
    sc.cmd_sign(set_file, KEY)
    payload = json.loads(sc._sidecar_path(set_file).read_text())
    assert "sha256" in payload
    assert "hmac_sha256" in payload
    assert "signed_at" in payload
    assert "file" in payload


def test_sign_sidecar_contains_filename(set_file: Path) -> None:
    sc.cmd_sign(set_file, KEY)
    payload = json.loads(sc._sidecar_path(set_file).read_text())
    assert payload["file"] == set_file.name


def test_sign_sha256_matches_file(set_file: Path) -> None:
    sc.cmd_sign(set_file, KEY)
    payload = json.loads(sc._sidecar_path(set_file).read_text())
    assert payload["sha256"] == sc._sha256_file(set_file)


def test_sign_overwrites_existing_sidecar(set_file: Path) -> None:
    sc.cmd_sign(set_file, KEY)
    p1 = json.loads(sc._sidecar_path(set_file).read_text())
    # sign again with different content
    set_file.write_text("InpRiskPercent=0.50\n", encoding="utf-8")
    sc.cmd_sign(set_file, KEY)
    p2 = json.loads(sc._sidecar_path(set_file).read_text())
    assert p1["sha256"] != p2["sha256"]


# ---------------------------------------------------------------------------
# cmd_verify
# ---------------------------------------------------------------------------

def test_verify_passes_on_valid_signature(signed_file: Path) -> None:
    # Should not raise or call sys.exit
    sc.cmd_verify(signed_file, KEY)


def test_verify_fails_on_tampered_file(signed_file: Path) -> None:
    signed_file.write_text("InpRiskPercent=0.99\n", encoding="utf-8")
    with pytest.raises(SystemExit) as exc:
        sc.cmd_verify(signed_file, KEY)
    assert "changed" in str(exc.value).lower()


def test_verify_fails_on_wrong_key(signed_file: Path) -> None:
    wrong_key = b"wrong-key-that-does-not-match!!"
    with pytest.raises(SystemExit) as exc:
        sc.cmd_verify(signed_file, wrong_key)
    assert "mismatch" in str(exc.value).lower() or "fail" in str(exc.value).lower()


def test_verify_fails_on_missing_sidecar(set_file: Path) -> None:
    # No sidecar created yet
    with pytest.raises(SystemExit) as exc:
        sc.cmd_verify(set_file, KEY)
    assert "not found" in str(exc.value).lower() or "signature" in str(exc.value).lower()


def test_verify_fails_on_missing_set_file(tmp_path: Path) -> None:
    ghost = tmp_path / "ghost.set"
    with pytest.raises(SystemExit):
        sc.cmd_verify(ghost, KEY)


def test_verify_fails_on_tampered_sidecar_hmac(signed_file: Path) -> None:
    sidecar = sc._sidecar_path(signed_file)
    payload = json.loads(sidecar.read_text())
    # Flip last hex char of hmac
    last = payload["hmac_sha256"]
    payload["hmac_sha256"] = last[:-1] + ("0" if last[-1] != "0" else "1")
    sidecar.write_text(json.dumps(payload), encoding="utf-8")
    with pytest.raises(SystemExit):
        sc.cmd_verify(signed_file, KEY)


def test_verify_fails_on_corrupt_sidecar_json(signed_file: Path) -> None:
    sidecar = sc._sidecar_path(signed_file)
    sidecar.write_text("not-json{{{", encoding="utf-8")
    with pytest.raises(SystemExit):
        sc.cmd_verify(signed_file, KEY)


# ---------------------------------------------------------------------------
# cmd_info
# ---------------------------------------------------------------------------

def test_info_shows_metadata(signed_file: Path, capsys: pytest.CaptureFixture) -> None:
    sc.cmd_info(signed_file)
    out = capsys.readouterr().out
    assert "Signed at:" in out
    assert "SHA-256:" in out


def test_info_detects_unchanged_file(signed_file: Path, capsys: pytest.CaptureFixture) -> None:
    sc.cmd_info(signed_file)
    out = capsys.readouterr().out
    assert "unchanged" in out.lower()


def test_info_detects_changed_file(signed_file: Path, capsys: pytest.CaptureFixture) -> None:
    signed_file.write_text("InpRiskPercent=0.99\n", encoding="utf-8")
    sc.cmd_info(signed_file)
    out = capsys.readouterr().out
    assert "changed" in out.lower()


def test_info_fails_on_missing_sidecar(set_file: Path) -> None:
    with pytest.raises(SystemExit):
        sc.cmd_info(set_file)


# ---------------------------------------------------------------------------
# _load_key
# ---------------------------------------------------------------------------

def test_load_key_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TEST_KEY_VAR", "my-super-secret-key-long-enough")
    args = _fake_args(key=None, key_env="TEST_KEY_VAR")
    k = sc._load_key(args)
    assert k == b"my-super-secret-key-long-enough"


def test_load_key_from_arg() -> None:
    args = _fake_args(key="direct-key-32-bytes-long!!!!!!", key_env=None)
    k = sc._load_key(args)
    assert k == b"direct-key-32-bytes-long!!!!!!"


def test_load_key_missing_env_raises(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("MISSING_KEY_VAR", raising=False)
    args = _fake_args(key=None, key_env="MISSING_KEY_VAR")
    with pytest.raises(SystemExit):
        sc._load_key(args)


def test_load_key_too_short_raises() -> None:
    args = _fake_args(key="short", key_env=None)
    with pytest.raises(SystemExit):
        sc._load_key(args)


def test_load_key_no_source_raises() -> None:
    args = _fake_args(key=None, key_env=None)
    with pytest.raises(SystemExit):
        sc._load_key(args)


# ---------------------------------------------------------------------------
# CLI end-to-end via main()
# ---------------------------------------------------------------------------

def test_main_sign_verify_roundtrip(set_file: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MSPB_SIGNING_KEY", KEY_STR)
    sc.main(["sign", str(set_file), "--key-env", "MSPB_SIGNING_KEY"])
    sc.main(["verify", str(set_file), "--key-env", "MSPB_SIGNING_KEY"])  # should not raise


def test_main_verify_tampered_fails(set_file: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MSPB_SIGNING_KEY", KEY_STR)
    sc.main(["sign", str(set_file), "--key-env", "MSPB_SIGNING_KEY"])
    set_file.write_text("InpRiskPercent=0.99\n", encoding="utf-8")
    with pytest.raises(SystemExit):
        sc.main(["verify", str(set_file), "--key-env", "MSPB_SIGNING_KEY"])


def test_main_info_no_key_needed(set_file: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MSPB_SIGNING_KEY", KEY_STR)
    sc.main(["sign", str(set_file), "--key-env", "MSPB_SIGNING_KEY"])
    sc.main(["info", str(set_file)])  # no key arg — should not raise


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

class _FakeArgs:
    def __init__(self, key, key_env):
        self.key = key
        self.key_env = key_env


def _fake_args(key, key_env):
    return _FakeArgs(key, key_env)
