"""Import pinned, unmodified MK2 and Core Extractor sprite sheets for two demos.

The selection contains source-derived layout parameters and explicitly labelled
local calibration choices. No image generation or resampling is performed.
--check validates the local pack without requiring the external reference drive.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "assets/art_calibration/reference_miners"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_size(path):
    with path.open("rb") as stream:
        header = stream.read(26)
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"Not a PNG: {path}")
    return list(struct.unpack(">II", header[16:24]))


def validate_layout(manifest, source_sizes=None):
    ids = {}
    for candidate_id, candidate in manifest["candidates"].items():
        for direction, definition in candidate["directions"].items():
            for layer in definition["layers"]:
                if layer["id"] in ids and ids[layer["id"]] != layer:
                    raise ValueError(f"Layer id conflict: {layer['id']}")
                ids[layer["id"]] = layer
                total = 0
                for sheet in layer["sheets"]:
                    path = ROOT / sheet["texture"].removeprefix("res://")
                    if source_sizes is None:
                        width, height = png_size(path)
                    else:
                        if sheet["texture"] not in source_sizes:
                            raise ValueError(f"Source frame sheet missing: {sheet['texture']}")
                        width, height = source_sizes[sheet["texture"]]
                    fw, fh = layer["frame_size"]
                    count = sheet["frame_count"]
                    columns = layer["columns"]
                    if fw * columns > width or ((count + columns - 1) // columns) * fh > height:
                        raise ValueError(f"Frame layout exceeds {path}: {candidate_id}/{direction}")
                    total += count
                if total != layer["frame_count"]:
                    raise ValueError(f"Split sheets have wrong frame count: {layer['id']}")
                if any(not isinstance(index, int) or not 0 <= index < total for index in layer.get("frame_sequence", [])):
                    raise ValueError(f"Frame sequence exceeds source frames: {layer['id']}")
    return len(ids)


def preflight(reference_root, selection, check):
    """Read all local evidence and external sources before any destination write."""
    evidence = []
    for entry in selection.get("local_evidence", []):
        path = PACK / entry["path"]
        if not path.is_file() or sha(path) != entry["sha256"]:
            raise ValueError(f"Layout or attribution evidence changed: {path}")
        evidence.append(entry)

    pinned = []
    source_sizes = {}
    if not check:
        for entry in selection["files"]:
            source = reference_root / entry["source"]
            if not source.is_file():
                raise ValueError(f"Pinned reference missing: {source}")
            digest = sha(source)
            if digest != entry["sha256"]:
                raise ValueError(f"Pinned reference changed: {source}")
            size = png_size(source) if Path(entry["destination"]).suffix == ".png" else None
            if size is not None:
                source_sizes["res://assets/art_calibration/reference_miners/" + entry["destination"]] = size
            pinned.append((entry, source, digest, size))
    return evidence, pinned, source_sizes


def build(reference_root, check):
    selection_path = PACK / "selection.json"
    selection = json.loads(selection_path.read_text(encoding="utf-8"))
    evidence, pinned, source_sizes = preflight(reference_root, selection, check)
    layers = None
    if not check:
        # Validate every source PNG against the candidate frame contract before
        # any destination directory is created or source file is copied.
        preflight_records = [
            {**entry, "dimensions": source_size, "modifications": "None; byte-for-byte source copy."}
            for entry, _, _, source_size in pinned
        ]
        preflight_manifest = {
            "schema_version": 1, "status": "independent_reference_demos",
            "candidates": selection["candidates"], "ground": selection["ground"], "ore": selection["ore"],
            "provenance": selection["provenance"], "files": preflight_records,
            "local_evidence": evidence, "selection_sha256": sha(selection_path),
        }
        layers = validate_layout(preflight_manifest, source_sizes)
    records = []
    for index, entry in enumerate(selection["files"]):
        destination = PACK / entry["destination"]
        if not check:
            _, source, _, source_size = pinned[index]
            destination.parent.mkdir(parents=True, exist_ok=True)
            if not destination.exists() or sha(destination) != entry["sha256"]:
                shutil.copyfile(source, destination)
        if not destination.is_file() or sha(destination) != entry["sha256"]:
            raise ValueError(f"Missing or modified reference file: {destination}")
        records.append({**entry, "dimensions": source_size if not check else (png_size(destination) if destination.suffix == ".png" else None),
                        "modifications": "None; byte-for-byte source copy."})
    manifest = {"schema_version": 1, "status": "independent_reference_demos",
                "candidates": selection["candidates"], "ground": selection["ground"], "ore": selection["ore"],
                "provenance": selection["provenance"], "files": records, "local_evidence": evidence,
                "selection_sha256": sha(selection_path)}
    if check:
        layers = validate_layout(manifest)
    rendered = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    target = PACK / "manifest.json"
    if check:
        if target.read_text(encoding="utf-8") != rendered:
            raise ValueError("Manifest differs from pinned selection")
    else:
        target.write_text(rendered, encoding="utf-8")
    print(f"REFERENCE_MINERS_IMPORT_{'CHECK_PASS' if check else 'PASS'}: {len(records)} pinned files; {layers} unique layers")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, default=Path("D:/Project"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    build(args.reference_root, args.check)
