#!/usr/bin/env python3
"""Copy and document the licensed source art used by Factory natural terrain.

This intentionally does not transform source images.  It keeps the original
2K ground maps and the source boulder files in the project, then records both
source and output hashes so a later checkout can be audited or rebuilt.
Run after ``render_factory_minerals.py`` to include the derived ore atlases in
the manifest:

    python tools/import_factory_natural_art.py
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parents[1]
NATURAL_ROOT = PROJECT_ROOT / "assets" / "ui" / "factory" / "natural"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def project_path(path: Path) -> str:
    return path.resolve().relative_to(PROJECT_ROOT.resolve()).as_posix()


def copy_exact(source: Path, output: Path) -> dict[str, Any]:
    if not source.is_file():
        raise FileNotFoundError("Natural-art source is missing: %s" % source)
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, output)
    source_hash = sha256(source)
    output_hash = sha256(output)
    if source_hash != output_hash:
        raise RuntimeError("Copy hash mismatch: %s" % output)
    return {
        "path": project_path(output),
        "source_local_path": str(source),
        "source_sha256": source_hash,
        "output_sha256": output_hash,
        "bytes": output.stat().st_size,
    }


def source_record(
    copied: dict[str, Any],
    *,
    asset_id: str,
    purpose: str,
    author: str,
    license_name: str,
    license_url: str,
    source_url: str,
    source_revision: str | None = None,
    source_blob: str | None = None,
    derived: bool = False,
) -> dict[str, Any]:
    record = dict(copied)
    record.update(
        {
            "id": asset_id,
            "purpose": purpose,
            "author": author,
            "license": license_name,
            "license_url": license_url,
            "source_url": source_url,
            "derived": derived,
        }
    )
    if source_revision:
        record["source_revision"] = source_revision
    if source_blob:
        record["source_blob"] = source_blob
    return record


def generated_ore_record(
    mineral: str,
    source_assets: list[dict[str, Any]],
    receipt: dict[str, Any],
    receipt_file: Path,
) -> dict[str, Any] | None:
    output = NATURAL_ROOT / "ores" / (mineral + "-ore.png")
    if not output.is_file():
        return None
    return {
        "id": mineral + "_ore",
        "path": project_path(output),
        "output_sha256": sha256(output),
        "bytes": output.stat().st_size,
        "derived": True,
        "purpose": "Factory irregular resource field sprite atlas",
        "license": "CC0 source; project-authored material derivation",
        "source_assets": [
            {
                "path": item["path"],
                "source_sha256": item["source_sha256"],
                "output_sha256": item["output_sha256"],
            }
            for item in source_assets
        ],
        "generator": dict(receipt["generator"]),
        "render_receipt": {
            "path": project_path(receipt_file),
            "sha256": sha256(receipt_file),
            "settings": receipt["settings"],
        },
        "grid": {
            "sheet_width": 1024,
            "sheet_height": 512,
            "cell_px": 128,
            "columns": 8,
            "rows": 4,
            "variation_count": 8,
            "density_stages": 4,
            "row_order": "top row 0 is dense; bottom row 3 is sparse",
            "frame_semantics": "static deterministic variants; never animation frames",
        },
        "material_derivation": {
            "iron": "blue-gray ore mineral tint over the CC0 boulder albedo",
            "copper": "orange-brown ore mineral tint over the CC0 boulder albedo",
        }[mineral],
    }


def validate_render_receipt(receipt_file: Path, generator_hash: str) -> dict[str, Any]:
    """Return a verified mineral-render receipt or raise without changing assets.

    A receipt binds the two current PNG atlases to the exact checked-in boulder
    blend and diffuse texture that Blender used, and to the current renderer
    implementation.  Existence of a PNG alone is never provenance evidence.
    """
    if not receipt_file.is_file():
        raise RuntimeError("Mineral render receipt is missing: %s" % receipt_file)
    try:
        receipt = json.loads(receipt_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise RuntimeError("Mineral render receipt is invalid: %s" % receipt_file) from error
    if receipt.get("schema_version") != 1 or receipt.get("kind") != "factory_natural_mineral_render_receipt":
        raise RuntimeError("Mineral render receipt has an unsupported schema: %s" % receipt_file)

    generator = receipt.get("generator", {})
    if generator.get("path") != "tools/render_factory_minerals.py" or generator.get("sha256") != generator_hash:
        raise RuntimeError("Mineral render receipt does not match the current renderer")

    expected_inputs = {
        "source_blend": NATURAL_ROOT / "source" / "boulder" / "boulder_01_2k.blend",
        "albedo_texture": NATURAL_ROOT / "source" / "boulder" / "textures" / "boulder_01_diff_2k.jpg",
    }
    inputs = receipt.get("inputs", {})
    for label, input_path in expected_inputs.items():
        record = inputs.get(label, {})
        if record.get("path") != project_path(input_path):
            raise RuntimeError("Mineral render receipt has a different %s path" % label)
        if not input_path.is_file() or record.get("sha256") != sha256(input_path):
            raise RuntimeError("Mineral render receipt %s hash does not match the current source" % label)

    expected_outputs = {
        mineral: NATURAL_ROOT / "ores" / (mineral + "-ore.png")
        for mineral in ("iron", "copper")
    }
    outputs = receipt.get("outputs", {})
    for mineral, output_path in expected_outputs.items():
        record = outputs.get(mineral, {})
        if record.get("path") != project_path(output_path):
            raise RuntimeError("Mineral render receipt has a different %s output path" % mineral)
        if not output_path.is_file() or record.get("sha256") != sha256(output_path):
            raise RuntimeError("Mineral render receipt %s output hash does not match" % mineral)

    settings = receipt.get("settings", {})
    grid = settings.get("grid", {})
    if (
        grid.get("sheet_width"),
        grid.get("sheet_height"),
        grid.get("cell_px"),
        grid.get("columns"),
        grid.get("rows"),
    ) != (1024, 512, 128, 8, 4):
        raise RuntimeError("Mineral render receipt grid does not match the Factory atlas contract")
    return receipt


def preflight_source_evidence(
    source_paths: dict[str, Path],
    poly_root: Path,
    ambient_root: Path,
    free_root: Path,
) -> None:
    """Fail before any copy when reviewed source inputs or evidence are absent."""
    missing = ["%s (%s)" % (label, path) for label, path in source_paths.items() if not path.is_file()]
    if missing:
        raise FileNotFoundError("Natural-art source inputs are missing: " + "; ".join(missing))
    for evidence_path, required_license in (
        (poly_root / "SOURCE.json", "CC0"),
        (ambient_root / "SOURCE.json", "CC0"),
    ):
        if not evidence_path.is_file():
            raise FileNotFoundError("Natural-art source evidence is missing: %s" % evidence_path)
        try:
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise RuntimeError("Natural-art source evidence is invalid: %s" % evidence_path) from error
        if evidence.get("license") != required_license:
            raise RuntimeError("Natural-art source evidence has an unexpected license: %s" % evidence_path)
    curator_readme = free_root.parents[1] / "README.md"
    if not curator_readme.is_file() or "Petraspace" not in curator_readme.read_text(encoding="utf-8"):
        raise RuntimeError("Petraspace local source evidence is missing: %s" % curator_readme)


def preflight_existing_ore_receipt(
    generator_hash: str,
    source_paths: dict[str, Path],
) -> dict[str, Any] | None:
    """Verify current ore provenance and upcoming boulder inputs before copying."""
    ore_outputs = [NATURAL_ROOT / "ores" / (mineral + "-ore.png") for mineral in ("iron", "copper")]
    if not any(path.exists() for path in ore_outputs):
        return None
    if not all(path.is_file() for path in ore_outputs):
        raise RuntimeError("Both iron and copper ore atlases must exist before manifest provenance is recorded")
    receipt = validate_render_receipt(
        NATURAL_ROOT / "source" / "render-receipt.json", generator_hash
    )
    for receipt_label, source_label in (("source_blend", "boulder_model"), ("albedo_texture", "boulder_diffuse")):
        if receipt["inputs"][receipt_label]["sha256"] != sha256(source_paths[source_label]):
            raise RuntimeError(
                "Upcoming %s source does not match the existing mineral render receipt" % source_label
            )
    return receipt


def write_attribution(manifest: dict[str, Any]) -> None:
    text = """# Factory natural terrain art attribution

This directory contains source copies and project-authored sprite atlases used
for Factory terrain.  The ground files are kept as unmodified originals.
`iron-ore.png` and `copper-ore.png` are not third-party ore art: they are
project-authored Blender renders of instances of the CC0 Poly Haven
`boulder_01` model, with explicitly documented iron and copper material
derivations.

## CC0 sources

* **Poly Haven contributors** — `aerial_grass_rock`, `aerial_sand`, and
  `boulder_01`; CC0 1.0. <https://polyhaven.com/license>
* **ambientCG contributors** — `Ground037` and `Rock030`; CC0 1.0.
  <https://docs.ambientcg.com/license/>

## MIT source

* **Petrak / gamma-delta** — `ice-ore.png` from `the-first-frontier`, MIT.
  The precise upstream revision and blob hash are recorded in `manifest.json`.

Every copied or generated output has an SHA-256 in `manifest.json`.  It also
records the direct source URL, license, input hashes, source revision where one
exists, and Blender generator settings.  Derived ore entries are only written
after `source/render-receipt.json` proves that the current model, diffuse
texture, generator source, and both atlas outputs all match their recorded
SHA-256 values.
"""
    (NATURAL_ROOT / "ATTRIBUTION.md").write_text(text, encoding="utf-8")


def main() -> int:
    global NATURAL_ROOT, PROJECT_ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path("D:/project"),
        help="directory containing the reviewed source collections",
    )
    parser.add_argument(
        "--project-root",
        type=Path,
        default=PROJECT_ROOT,
        help="project root; defaults to the repository containing this script",
    )
    args = parser.parse_args()

    PROJECT_ROOT = args.project_root.resolve()
    NATURAL_ROOT = PROJECT_ROOT / "assets" / "ui" / "factory" / "natural"
    source_root = args.source_root.resolve()
    generator = PROJECT_ROOT / "tools" / "render_factory_minerals.py"
    if not generator.is_file():
        raise FileNotFoundError("Mineral renderer is missing: %s" % generator)

    poly_root = source_root / "PolyHaven-Samples"
    ambient_root = source_root / "ambientCG-Samples"
    free_root = source_root / "factorio_free_graphics_for_modders" / "decoratives_resources" / "resources"
    source_paths = {
        "ground_soil": ambient_root / "Ground037" / "Ground037_2K-JPG_Color.jpg",
        "ground_grass": poly_root / "aerial_grass_rock" / "textures" / "aerial_grass_rock_diff_2k.jpg",
        "ground_sand": poly_root / "aerial_sand" / "textures" / "aerial_sand_diff_2k.jpg",
        "ground_rock": ambient_root / "Rock030" / "Rock030_2K-JPG_Color.jpg",
        "boulder_model": poly_root / "boulder_01" / "boulder_01_2k.blend",
        "boulder_diffuse": poly_root / "boulder_01" / "textures" / "boulder_01_diff_2k.jpg",
        "boulder_normal": poly_root / "boulder_01" / "textures" / "boulder_01_nor_gl_2k.exr",
        "boulder_roughness": poly_root / "boulder_01" / "textures" / "boulder_01_rough_2k.exr",
        "ice_ore": free_root / "Petraspace (MIT) - Petraspace - ice-ore.png",
    }
    preflight_source_evidence(source_paths, poly_root, ambient_root, free_root)
    generator_hash = sha256(generator)
    # This is deliberately before the first copy_exact call.  A receipt/input
    # mismatch leaves all existing Factory targets and manifest.json untouched.
    preflight_receipt = preflight_existing_ore_receipt(generator_hash, source_paths)

    ground = [
        source_record(
            copy_exact(
                source_paths["ground_soil"],
                NATURAL_ROOT / "ground" / "soil.jpg",
            ),
            asset_id="ground_soil",
            purpose="continuous industrial soil base",
            author="ambientCG contributors",
            license_name="CC0 1.0",
            license_url="https://docs.ambientcg.com/license/",
            source_url="https://ambientcg.com/get?file=Ground037_2K-JPG.zip",
        ),
        source_record(
            copy_exact(
                source_paths["ground_grass"],
                NATURAL_ROOT / "ground" / "grass.jpg",
            ),
            asset_id="ground_grass",
            purpose="continuous grass and gravel terrain base",
            author="Poly Haven contributors",
            license_name="CC0 1.0",
            license_url="https://polyhaven.com/license",
            source_url=(
                "https://dl.polyhaven.org/file/ph-assets/Textures/jpg/2k/"
                "aerial_grass_rock/aerial_grass_rock_diff_2k.jpg"
            ),
        ),
        source_record(
            copy_exact(
                source_paths["ground_sand"],
                NATURAL_ROOT / "ground" / "sand.jpg",
            ),
            asset_id="ground_sand",
            purpose="continuous arid sand terrain base",
            author="Poly Haven contributors",
            license_name="CC0 1.0",
            license_url="https://polyhaven.com/license",
            source_url=(
                "https://dl.polyhaven.org/file/ph-assets/Textures/jpg/2k/"
                "aerial_sand/aerial_sand_diff_2k.jpg"
            ),
        ),
        source_record(
            copy_exact(
                source_paths["ground_rock"],
                NATURAL_ROOT / "ground" / "rock.jpg",
            ),
            asset_id="ground_rock",
            purpose="continuous rocky terrain base",
            author="ambientCG contributors",
            license_name="CC0 1.0",
            license_url="https://docs.ambientcg.com/license/",
            source_url="https://ambientcg.com/get?file=Rock030_2K-JPG.zip",
        ),
    ]

    boulder = [
        source_record(
            copy_exact(
                source_paths["boulder_model"],
                NATURAL_ROOT / "source" / "boulder" / "boulder_01_2k.blend",
            ),
            asset_id="boulder_model",
            purpose="source model for project-authored ore cluster renders",
            author="Poly Haven contributors",
            license_name="CC0 1.0",
            license_url="https://polyhaven.com/license",
            source_url=(
                "https://dl.polyhaven.org/file/ph-assets/Models/blend/2k/"
                "boulder_01/boulder_01_2k.blend"
            ),
        ),
        source_record(
            copy_exact(
                source_paths["boulder_diffuse"],
                NATURAL_ROOT / "source" / "boulder" / "textures" / "boulder_01_diff_2k.jpg",
            ),
            asset_id="boulder_diffuse",
            purpose="source boulder albedo for project-authored ore cluster renders",
            author="Poly Haven contributors",
            license_name="CC0 1.0",
            license_url="https://polyhaven.com/license",
            source_url=(
                "https://dl.polyhaven.org/file/ph-assets/Models/jpg/2k/"
                "boulder_01/boulder_01_diff_2k.jpg"
            ),
        ),
        source_record(
            copy_exact(
                source_paths["boulder_normal"],
                NATURAL_ROOT / "source" / "boulder" / "textures" / "boulder_01_nor_gl_2k.exr",
            ),
            asset_id="boulder_normal",
            purpose="source normal map retained for reproducible boulder rendering",
            author="Poly Haven contributors",
            license_name="CC0 1.0",
            license_url="https://polyhaven.com/license",
            source_url=(
                "https://dl.polyhaven.org/file/ph-assets/Models/exr/2k/"
                "boulder_01/boulder_01_nor_gl_2k.exr"
            ),
        ),
        source_record(
            copy_exact(
                source_paths["boulder_roughness"],
                NATURAL_ROOT / "source" / "boulder" / "textures" / "boulder_01_rough_2k.exr",
            ),
            asset_id="boulder_roughness",
            purpose="source roughness map retained for reproducible boulder rendering",
            author="Poly Haven contributors",
            license_name="CC0 1.0",
            license_url="https://polyhaven.com/license",
            source_url=(
                "https://dl.polyhaven.org/file/ph-assets/Models/exr/2k/"
                "boulder_01/boulder_01_rough_2k.exr"
            ),
        ),
    ]

    ice = source_record(
        copy_exact(
            source_paths["ice_ore"],
            NATURAL_ROOT / "ores" / "ice-ore.png",
        ),
        asset_id="ice_ore",
        purpose="static ice resource field sprite atlas",
        author="Petrak; gamma-delta/the-first-frontier distribution",
        license_name="MIT",
        license_url=(
            "https://github.com/gamma-delta/the-first-frontier/blob/"
            "3374aae38673dcf5bcd265e446f5ab5a3a24db87/LICENSE.txt"
        ),
        source_url=(
            "https://raw.githubusercontent.com/gamma-delta/the-first-frontier/"
            "3374aae38673dcf5bcd265e446f5ab5a3a24db87/graphics/entities/ice-ore.png"
        ),
        source_revision="3374aae38673dcf5bcd265e446f5ab5a3a24db87",
        source_blob="61e90762b8abfdde6425515b86d468f04471a447",
    )

    render_receipt = preflight_receipt
    render_receipt_file = NATURAL_ROOT / "source" / "render-receipt.json"
    render_input_assets = [
        record for record in boulder if record["id"] in {"boulder_model", "boulder_diffuse"}
    ]
    if render_receipt is not None:
        receipt_input_hashes = {
            "boulder_model": render_receipt["inputs"]["source_blend"]["sha256"],
            "boulder_diffuse": render_receipt["inputs"]["albedo_texture"]["sha256"],
        }
        for record in render_input_assets:
            if record["source_sha256"] != receipt_input_hashes[record["id"]]:
                raise RuntimeError("Boulder source changed after mineral receipt preflight")

    manifest = {
        "schema_version": 1,
        "package": "factory_natural_art",
        "package_purpose": "Licensed terrain and resource field art for Factory",
        "excluded_sources": [
            {
                "id": "factorio_plus_goblin_ore",
                "reason": "The upstream FactorioPlus repository is AGPL-3.0; local curator metadata claiming MIT is not authoritative.",
                "source_url": "https://github.com/FishyB/FactorioPlus/blob/main/LICENSE",
            },
            {
                "id": "wube_factorio_resource_sprites",
                "reason": "Official Factorio art is a rules/layout reference only and is not imported.",
            },
        ],
        "ground": ground,
        "source_models": boulder,
        "ores": [ice],
        "generator_sha256": generator_hash,
    }
    if render_receipt is not None:
        for mineral in ("iron", "copper"):
            generated = generated_ore_record(
                mineral, render_input_assets, render_receipt, render_receipt_file
            )
            if generated is None:
                raise RuntimeError("Verified mineral receipt has no current %s output" % mineral)
            manifest["ores"].append(generated)

    NATURAL_ROOT.mkdir(parents=True, exist_ok=True)
    (NATURAL_ROOT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    write_attribution(manifest)
    print("Imported %d ground maps, %d boulder sources, and %d ore atlases to %s" % (
        len(ground), len(boulder), len(manifest["ores"]), NATURAL_ROOT
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
