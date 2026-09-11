#!/usr/bin/env python3
"""Regression coverage for zero-write source preflight in art importers.

All fixtures live in the system temporary directory.  The checked-in art packs
are never passed to a write-mode importer during this test.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_hashes(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): sha256_file(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def load_tool(name: str, filename: str):
    sys.dont_write_bytecode = True
    source = ROOT / "tools" / filename
    spec = importlib.util.spec_from_file_location(name, source)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_layer_definition(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        '\n'.join([
            '["width"] = 128', '["height"] = 128', '["sprite_count"] = 1',
            '["line_length"] = 1', '["scale"] = 1', '["shift"] = {0, 0}',
        ]),
        encoding="utf-8",
    )


def art_calibration_mismatch_writes_nothing() -> None:
    importer = load_tool("art_calibration_import_preflight", "import_art_calibration.py")
    with tempfile.TemporaryDirectory(prefix="art-calibration-preflight-") as temporary_directory:
        temporary = Path(temporary_directory)
        destination = temporary / "destination"
        reference = temporary / "reference"
        evidence = destination / "evidence.txt"
        evidence.parent.mkdir(parents=True)
        evidence.write_text("kept", encoding="utf-8")
        selection = {
            "local_evidence": [{"path": "evidence.txt", "sha256": sha256_file(evidence)}],
            "files": [
                {"source": "valid.bin", "destination": "copied/valid.bin", "sha256": sha256_bytes(b"valid")},
                {"source": "tampered.bin", "destination": "copied/tampered.bin", "sha256": sha256_bytes(b"expected")},
            ],
            "ground": {}, "ore": {}, "smoke": {}, "provenance": {},
        }
        (destination / "selection.json").write_text(json.dumps(selection), encoding="utf-8")
        (destination / "manifest.json").write_bytes(b"manifest-sentinel")
        sentinel = destination / "copied" / "valid.bin"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_bytes(b"target-sentinel")
        (reference / "valid.bin").parent.mkdir(parents=True)
        (reference / "valid.bin").write_bytes(b"valid")
        (reference / "tampered.bin").write_bytes(b"changed")
        for layer in ("shadow", "base", "mask", "emission"):
            write_layer_definition(
                reference / "nullius-visual-overhaul/graphics/entity/chemical-stager" /
                ("chemical-stager-" + layer + ".lua")
            )
        before = tree_hashes(destination)
        importer.DEST = destination
        try:
            importer.build(reference, check=False)
        except ValueError as error:
            assert "Pinned source changed" in str(error)
        else:
            raise AssertionError("tampered art-calibration source was accepted")
        assert tree_hashes(destination) == before, "art calibration preflight wrote a destination target"


def reference_miners_mismatch_writes_nothing() -> None:
    importer = load_tool("reference_miners_import_preflight", "import_reference_miners.py")
    with tempfile.TemporaryDirectory(prefix="reference-miners-preflight-") as temporary_directory:
        temporary = Path(temporary_directory)
        pack = temporary / "pack"
        reference = temporary / "reference"
        evidence = pack / "evidence.txt"
        evidence.parent.mkdir(parents=True)
        evidence.write_text("kept", encoding="utf-8")
        selection = {
            "local_evidence": [{"path": "evidence.txt", "sha256": sha256_file(evidence)}],
            "files": [
                {"source": "valid.bin", "destination": "copied/valid.bin", "sha256": sha256_bytes(b"valid")},
                {"source": "tampered.bin", "destination": "copied/tampered.bin", "sha256": sha256_bytes(b"expected")},
            ],
            "candidates": {}, "ground": {}, "ore": {}, "provenance": {},
        }
        (pack / "selection.json").write_text(json.dumps(selection), encoding="utf-8")
        (pack / "manifest.json").write_bytes(b"manifest-sentinel")
        sentinel = pack / "copied" / "valid.bin"
        sentinel.parent.mkdir(parents=True)
        sentinel.write_bytes(b"target-sentinel")
        (reference / "valid.bin").parent.mkdir(parents=True)
        (reference / "valid.bin").write_bytes(b"valid")
        (reference / "tampered.bin").write_bytes(b"changed")
        before = tree_hashes(pack)
        importer.PACK = pack
        try:
            importer.build(reference, check=False)
        except ValueError as error:
            assert "Pinned reference changed" in str(error)
        else:
            raise AssertionError("tampered reference-miners source was accepted")
        assert tree_hashes(pack) == before, "reference-miners preflight wrote a destination target"


def main() -> int:
    art_calibration_mismatch_writes_nothing()
    reference_miners_mismatch_writes_nothing()
    print("PASS art import preflight")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
