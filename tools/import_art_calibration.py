"""Copy the selected reference assets unchanged and normalize their metadata.

No image generation, resampling, recoloring, Lua execution or upstream edits.
Run with --check to verify the imported bytes and manifest without writing.
"""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re
import shutil
import struct

PROJECT = Path(__file__).resolve().parents[1]
DEST = PROJECT / "assets/art_calibration"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dimensions(path):
    raw = path.read_bytes()
    if raw[:8] == b"\x89PNG\r\n\x1a\n":
        return list(struct.unpack(">II", raw[16:24]))
    if raw[:2] == b"\xff\xd8":
        position = 2
        while position < len(raw):
            if raw[position] != 0xFF:
                raise ValueError(f"Malformed JPEG marker: {path}")
            while raw[position] == 0xFF:
                position += 1
            marker = raw[position]
            position += 1
            length = struct.unpack(">H", raw[position:position + 2])[0]
            if marker in (0xC0, 0xC1, 0xC2):
                height, width = struct.unpack(">HH", raw[position + 3:position + 7])
                return [width, height]
            position += length
        raise ValueError(f"JPEG dimensions missing: {path}")
    return None


def lua_definition(path):
    text = re.sub(r"--[^\n]*", "", path.read_text(encoding="utf-8"))
    result = {}
    for key in ("width", "height", "sprite_count", "line_length", "scale"):
        match = re.search(r'\["' + key + r'"\]\s*=\s*([0-9.]+)', text)
        if not match:
            raise ValueError(f"Missing {key}: {path}")
        result[key] = float(match[1]) if key == "scale" else int(match[1])
    shift = re.search(r'\["shift"\]\s*=\s*\{([^}]+)\}', text)
    def number(value):
        terms = value.strip().split("/")
        return float(Fraction(terms[0].strip()) / (Fraction(terms[1].strip()) if len(terms) == 2 else 1))
    result["shift"] = [number(v) for v in shift[1].split(",")]
    return result


def preflight(reference_root, selection):
    """Read every source/evidence dependency before build() can write a byte."""
    for evidence in selection["local_evidence"]:
        path = DEST / evidence["path"]
        if not path.is_file() or sha(path) != evidence["sha256"]:
            raise ValueError(f"Local attribution/license evidence missing or changed: {path}")

    pinned = []
    for item in selection["files"]:
        source = reference_root / item["source"]
        if not source.is_file():
            raise ValueError(f"Pinned source missing: {source}")
        digest = sha(source)
        if digest != item["sha256"]:
            raise ValueError(f"Pinned source changed: {source}")
        pinned.append((item, source, digest, dimensions(source)))

    definitions = []
    for layer in ["shadow", "base", "mask", "emission"]:
        source = reference_root / f"nullius-visual-overhaul/graphics/entity/chemical-stager/chemical-stager-{layer}.lua"
        if not source.is_file():
            raise ValueError(f"Pinned layer definition missing: {source}")
        definitions.append((layer, lua_definition(source)))
    return pinned, definitions


def build(reference_root, check):
    selection = json.loads((DEST / "selection.json").read_text(encoding="utf-8"))
    pinned, source_definitions = preflight(reference_root, selection)
    records = []
    definitions = []
    for item, source, digest, source_dimensions in pinned:
        target = DEST / item["destination"]
        if check:
            if not target.is_file() or sha(target) != digest:
                raise ValueError(f"Imported file differs: {target}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists() or sha(target) != digest:
                shutil.copyfile(source, target)
        records.append({**item, "dimensions": source_dimensions, "modifications": "Byte-for-byte copy; rendering parameters stored separately."})
    for layer, d in source_definitions:
        definitions.append({
            "id": layer, "texture": f"res://assets/art_calibration/building/chemical-stager-{layer}.png",
            "frame_size": [d["width"], d["height"]], "frame_count": d["sprite_count"],
            "columns": d["line_length"], "source_scale": d["scale"],
            "shift_tiles": d["shift"], "fps": 30 if d["sprite_count"] > 1 else 0,
            "blend": "add" if layer == "emission" else "mix",
            "running_only": layer == "emission", "provenance_id": "hurricane-nullius",
        })
    manifest = {
        "schema_version": 1, "status": "selected_for_calibration",
        "building": {"id": "calibration_chemical_stager", "footprint_tiles": [4, 4],
            "source_pixels_per_tile": 32, "fit_multiplier": 4 * 32 / (394 * 0.5),
            "anchor": "footprint_center", "directions": ["authored"], "layers": definitions,
            "notes": "4x4 is a calibration footprint, not a change to a production building. 30 fps is a local playback choice. Source scale and shifts are converted together."},
        "ground": selection["ground"], "ore": selection["ore"], "smoke": selection["smoke"],
        "provenance": selection["provenance"], "local_evidence": selection["local_evidence"], "files": records,
    }
    rendered = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    manifest_path = DEST / "manifest.json"
    if check:
        if manifest_path.read_text(encoding="utf-8") != rendered:
            raise ValueError("Manifest is not reproducible from pinned sources")
    else:
        manifest_path.write_text(rendered, encoding="utf-8")
    print(f"ART_CALIBRATION_IMPORT_{'CHECK_PASS' if check else 'PASS'}: {len(records)} pinned files; 4 independent building layers")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path, default=Path("D:/Project"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    build(args.reference_root, args.check)
