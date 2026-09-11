"""Check pinned source bytes, real animation frames and split-sheet boundaries."""
import json
from pathlib import Path
import runpy

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "assets/art_calibration/reference_miners"


def sample(layer, index):
    for sheet in layer["sheets"]:
        count = sheet["frame_count"]
        if index >= count:
            index -= count
            continue
        with Image.open(ROOT / sheet["texture"].removeprefix("res://")) as atlas:
            width, height = layer["frame_size"]
            x, y = (index % layer["columns"]) * width, (index // layer["columns"]) * height
            return atlas.crop((x, y, x + width, y + height)).convert("RGBA")
    raise AssertionError("Frame exceeds split-sheet count")


def check():
    importer = runpy.run_path(str(ROOT / "tools/import_reference_miners.py"))
    importer["build"](None, True)
    ui_text = (ROOT / "src/ui/art_calibration/reference_mining_demo.gd").read_text(encoding="utf-8")
    assert chr(0xfffd) not in ui_text, "UI source is valid, uncorrupted UTF-8"
    manifest = json.loads((PACK / "manifest.json").read_text(encoding="utf-8"))
    mk2, core = manifest["candidates"]["mk2"], manifest["candidates"]["core"]
    assert all("?" not in candidate["subtitle"] for candidate in [mk2, core]), "UTF-8 display metadata"
    assert set(mk2["directions"]) == {"N", "E", "S", "W"}
    assert mk2["frame_count"] == 195 and mk2["source_frame_count"] == 30 and core["frame_count"] == 120
    assert mk2["fps"] == 24 and core["fps"] == 30
    for candidate in [mk2, core]:
        for direction in candidate["directions"].values():
            assert {"base", "shadow", "emission"}.issubset({layer["role"] for layer in direction["layers"]})
            for layer in direction["layers"]:
                if layer["role"] != "base" or layer["frame_count"] <= 1 or layer.get("running_only", False):
                    continue
                first = sample(layer, 0)
                later = sample(layer, min(15, layer["frame_count"] - 1))
                assert first.getchannel("A").getbbox(), layer["id"]
                assert first.tobytes() != later.tobytes(), f"Static image pretending to animate: {layer['id']}"
                if "frame_sequence" in layer:
                    assert len(layer["frame_sequence"]) == 195
                    assert layer["frame_sequence"][:4] == [0,0,0,1]
                    assert layer["frame_sequence"][-3:] == [0,0,0]
    layers = core["directions"]["authored"]["layers"]
    body = next(layer for layer in layers if layer["role"] == "base")
    assert body["frame_size"] == [704, 704]
    assert [sheet["frame_count"] for sheet in body["sheets"]] == [64, 56]
    assert sample(body, 63).tobytes() != sample(body, 64).tobytes()
    assert sample(body, 119).getchannel("A").getbbox()
    # Full bounds are validated by the importer, including layer-specific
    # offsets/sizes. Source sprites and documentation remain distinct assets.
    assert all(not file["destination"].endswith(".blend") for file in manifest["files"])
    print("REFERENCE_MINING_ASSETS_TEST_PASS: real directional MK2 sprites and 120-frame split-sheet Core Extractor")


if __name__ == "__main__":
    check()
