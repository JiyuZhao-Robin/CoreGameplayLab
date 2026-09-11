#!/usr/bin/env python3
"""Read-only structural verification for Factory natural art assets.

Run with: ``python tests/factory_natural_assets_test.py``.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
NATURAL = ROOT / "assets" / "ui" / "factory" / "natural"


def import_natural_importer():
    sys.dont_write_bytecode = True
    source = ROOT / "tools" / "import_factory_natural_art.py"
    spec = importlib.util.spec_from_file_location("factory_natural_importer_test", source)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def crop_hash(image: Image.Image, box: tuple[int, int, int, int]) -> str:
    return hashlib.sha256(image.crop(box).tobytes()).hexdigest()


def assert_mipmaps_enabled(path: Path) -> None:
    importer = path.with_name(path.name + ".import")
    assert importer.is_file(), "Godot importer config missing: %s" % importer
    assert "mipmaps/generate=true" in importer.read_text(encoding="utf-8"), (
        "mipmaps are required for the 4K Factory terrain shader: %s" % importer
    )


def alpha_coverage(image: Image.Image, box: tuple[int, int, int, int]) -> int:
    alpha = image.crop(box).getchannel("A")
    values = alpha.get_flattened_data() if hasattr(alpha, "get_flattened_data") else alpha.getdata()
    return sum(1 for value in values if value > 24)


def dense_cell_measurements(image: Image.Image, column: int) -> tuple[int, float, float]:
    cell = image.crop((column * 128, 0, (column + 1) * 128, 128))
    alpha = cell.getchannel("A")
    box = alpha.point(lambda value: 255 if value > 24 else 0).getbbox()
    assert box is not None
    pixels = cell.get_flattened_data() if hasattr(cell, "get_flattened_data") else cell.getdata()
    visible = [
        (red + green + blue) / 3
        for red, green, blue, value in pixels
        if value > 24
    ]
    visible.sort()
    return box[2] - box[0], sum(visible) / len(visible), visible[int((len(visible) - 1) * 0.9)]


def tree_hashes(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


def assert_preflight_mismatch_has_no_writes(receipt: dict[str, object]) -> None:
    """Exercise main() in a disposable project, not the production directory."""
    source_root = Path("D:/project")
    with tempfile.TemporaryDirectory(prefix="factory-natural-preflight-") as temporary_directory:
        project = Path(temporary_directory) / "project"
        temporary_natural = project / "assets" / "ui" / "factory" / "natural"
        temporary_tools = project / "tools"
        temporary_tools.mkdir(parents=True)
        shutil.copy2(ROOT / "tools" / "render_factory_minerals.py", temporary_tools / "render_factory_minerals.py")
        for relative in (
            "source/boulder/boulder_01_2k.blend",
            "source/boulder/textures/boulder_01_diff_2k.jpg",
            "ores/iron-ore.png",
            "ores/copper-ore.png",
        ):
            destination = temporary_natural / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(NATURAL / relative, destination)
        sentinel_ground = temporary_natural / "ground" / "soil.jpg"
        sentinel_ground.parent.mkdir(parents=True, exist_ok=True)
        sentinel_ground.write_bytes(b"sentinel-ground-must-not-change")
        manifest = temporary_natural / "manifest.json"
        manifest.write_bytes(b"sentinel-manifest-must-not-change")
        tampered = json.loads(json.dumps(receipt))
        tampered["inputs"]["source_blend"]["sha256"] = "0" * 64
        receipt_path = temporary_natural / "source" / "render-receipt.json"
        receipt_path.write_text(json.dumps(tampered), encoding="utf-8")
        before = tree_hashes(temporary_natural)
        result = subprocess.run(
            [
                sys.executable,
                str(ROOT / "tools" / "import_factory_natural_art.py"),
                "--project-root",
                str(project),
                "--source-root",
                str(source_root),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0, result.stdout + result.stderr
        assert "receipt" in (result.stdout + result.stderr).lower()
        assert tree_hashes(temporary_natural) == before, "preflight mismatch wrote production targets"


def main() -> int:
    manifest_path = NATURAL / "manifest.json"
    assert manifest_path.is_file(), "natural-art manifest is missing"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["schema_version"] == 1
    assert "goblin" in json.dumps(manifest["excluded_sources"]).lower()
    assert (NATURAL / "ATTRIBUTION.md").is_file()

    receipt_path = NATURAL / "source" / "render-receipt.json"
    assert receipt_path.is_file(), "mineral render receipt is missing"
    receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    assert receipt["schema_version"] == 1
    assert receipt["kind"] == "factory_natural_mineral_render_receipt"
    assert receipt["generator"]["path"] == "tools/render_factory_minerals.py"
    assert receipt["generator"]["sha256"] == sha256(ROOT / "tools" / "render_factory_minerals.py")
    importer = import_natural_importer()
    assert importer.validate_render_receipt(receipt_path, receipt["generator"]["sha256"]) == receipt
    with tempfile.TemporaryDirectory(prefix="factory-natural-receipt-") as temporary_directory:
        tampered = json.loads(json.dumps(receipt))
        tampered["outputs"]["iron"]["sha256"] = "0" * 64
        tampered_path = Path(temporary_directory) / "render-receipt.json"
        tampered_path.write_text(json.dumps(tampered), encoding="utf-8")
        try:
            importer.validate_render_receipt(tampered_path, receipt["generator"]["sha256"])
        except RuntimeError as error:
            assert "output hash" in str(error)
        else:
            raise AssertionError("tampered render receipt was accepted")
    assert_preflight_mismatch_has_no_writes(receipt)

    ground = {record["id"]: record for record in manifest["ground"]}
    assert set(ground) == {"ground_soil", "ground_grass", "ground_sand", "ground_rock"}
    for record in ground.values():
        path = ROOT / record["path"]
        assert path.is_file(), path
        assert sha256(path) == record["output_sha256"]
        assert_mipmaps_enabled(path)
        with Image.open(path) as image:
            assert image.size == (2048, 2048), (path, image.size)
            assert image.mode == "RGB", (path, image.mode)
        assert record["license"] == "CC0 1.0"

    source_models = {record["id"]: record for record in manifest["source_models"]}
    for source_id in ("boulder_model", "boulder_diffuse", "boulder_normal", "boulder_roughness"):
        record = source_models[source_id]
        path = ROOT / record["path"]
        assert path.is_file(), path
        assert sha256(path) == record["output_sha256"]

    ores = {record["id"]: record for record in manifest["ores"]}
    ice = ores["ice_ore"]
    ice_path = ROOT / ice["path"]
    assert ice_path.is_file()
    assert sha256(ice_path) == ice["output_sha256"]
    assert_mipmaps_enabled(ice_path)
    assert ice["license"] == "MIT"
    assert ice["source_revision"] == "3374aae38673dcf5bcd265e446f5ab5a3a24db87"
    assert ice["source_blob"] == "61e90762b8abfdde6425515b86d468f04471a447"
    with Image.open(ice_path) as image:
        assert image.size == (1024, 1024)
        assert image.mode == "RGBA"

    for mineral in ("iron", "copper"):
        record = ores[mineral + "_ore"]
        path = ROOT / record["path"]
        assert path.is_file(), path
        assert sha256(path) == record["output_sha256"]
        assert_mipmaps_enabled(path)
        assert record["derived"] is True
        assert record["generator"] == receipt["generator"]
        assert record["render_receipt"] == {
            "path": "assets/ui/factory/natural/source/render-receipt.json",
            "sha256": sha256(receipt_path),
            "settings": receipt["settings"],
        }
        grid = record["grid"]
        assert grid == {
            "sheet_width": 1024,
            "sheet_height": 512,
            "cell_px": 128,
            "columns": 8,
            "rows": 4,
            "variation_count": 8,
            "density_stages": 4,
            "row_order": "top row 0 is dense; bottom row 3 is sparse",
            "frame_semantics": "static deterministic variants; never animation frames",
        }
        with Image.open(path) as image:
            assert image.size == (1024, 512), image.size
            assert image.mode == "RGBA", image.mode
            row_hashes = [crop_hash(image, (column * 128, 0, (column + 1) * 128, 128)) for column in range(8)]
            assert len(set(row_hashes)) >= 6, "%s lacks meaningful variations" % mineral
            dense_measurements = [dense_cell_measurements(image, column) for column in range(8)]
            assert min(width for width, _, _ in dense_measurements) >= 100, (
                "%s dense ore clusters do not fill their cells" % mineral
            )
            assert min(mean for _, mean, _ in dense_measurements) >= 58.0, (
                "%s dense ore clusters are too dark to read over Factory terrain" % mineral
            )
            assert min(p90 for _, _, p90 in dense_measurements) >= 92.0, (
                "%s lacks readable mineral highlights" % mineral
            )
            dense = sum(alpha_coverage(image, (column * 128, 0, (column + 1) * 128, 128)) for column in range(8))
            sparse = sum(alpha_coverage(image, (column * 128, 384, (column + 1) * 128, 512)) for column in range(8))
            assert dense > sparse * 1.4, "%s density stages are not visually distinct" % mineral

    print("PASS factory natural assets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
