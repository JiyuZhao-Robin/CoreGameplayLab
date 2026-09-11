"""Verify the authored model, real animation channels and reproducible asset ledger."""
import hashlib
import json
import math
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / "assets/models/helix_miner"


def check():
    ledger = json.loads((PACK / "provenance.json").read_text(encoding="utf-8"))
    assert ledger["generation_mode"] == "full_bake"
    assert ledger["blender_version"] == "4.5.9 LTS"
    assert hashlib.sha256((ROOT / "tools/build_helix_miner.py").read_bytes()).hexdigest() == ledger["generator_sha256"]
    for file in ledger["files"]:
        assert hashlib.sha256((PACK / file["path"]).read_bytes()).hexdigest() == file["sha256"], file["path"]
    manifest = json.loads((PACK / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["building"]["footprint_tiles"] == [4, 4]
    assert manifest["building"]["anchor"] == "ground_origin"
    for clip, count in [("startup", 24), ("working", 60), ("shutdown", 24)]:
        definition = manifest["clips"][clip]
        assert len(definition["textures"]) == definition["frame_count"] == count
        for resource in definition["textures"]:
            path = ROOT / resource.removeprefix("res://")
            raw = path.read_bytes()
            assert raw[:8] == b"\x89PNG\r\n\x1a\n"
            assert struct.unpack(">II", raw[16:24]) == (512, 512)
            assert raw[25] == 6, "Each bake retains RGBA transparency"
    assert (PACK / "source/helix_miner.blend").read_bytes().startswith(b"BLENDER")
    assert (PACK / "source/.gdignore").exists(), "Blender source does not need an editor dependency at game startup"
    raw = (PACK / "helix_miner.glb").read_bytes()
    magic, version, size = struct.unpack_from("<III", raw, 0)
    assert magic == 0x46546C67 and version == 2 and size == len(raw)
    length, kind = struct.unpack_from("<II", raw, 12)
    assert kind == 0x4E4F534A
    gltf = json.loads(raw[20:20 + length])
    binary = raw[28 + length:]
    nodes = gltf["nodes"]
    names = {node["name"] for node in nodes}
    assert {"HELIX_01_ROOT", "DRILL_ROTOR", "FEED_CARRIAGE", "COOLING_FAN"}.issubset(names)
    assert len(gltf["meshes"]) >= 100, "Actual detailed model meshes, not a billboard"
    assert all("uri" not in buffer for buffer in gltf["buffers"]), "Self-contained GLB"
    channels = gltf["animations"][0]["channels"]
    assert len(channels) == 5
    targets = {(nodes[c["target"]["node"]]["name"], c["target"]["path"]) for c in channels}
    assert ("DRILL_ROTOR", "rotation") in targets
    assert ("FEED_CARRIAGE", "translation") in targets
    assert ("COOLING_FAN", "rotation") in targets

    def accessor(index):
        data = gltf["accessors"][index]
        view = gltf["bufferViews"][data["bufferView"]]
        assert data["componentType"] == 5126
        components = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[data["type"]]
        offset = view.get("byteOffset", 0) + data.get("byteOffset", 0)
        stride = view.get("byteStride", components * 4)
        return [struct.unpack_from("<" + "f" * components, binary, offset + i * stride) for i in range(data["count"])]

    for channel in channels:
        sampler = gltf["animations"][0]["samplers"][channel["sampler"]]
        times = accessor(sampler["input"])
        values = accessor(sampler["output"])
        assert len(times) == len(values) == 108
        assert all(abs(time[0] - (index + 1) / 30) < 0.00001 for index, time in enumerate(times)), "30 fps source frames 1 through 108"
        assert all(a[0] < b[0] for a, b in zip(times, times[1:])), "Strictly increasing sample times"
        assert all(math.isfinite(x) for value in values for x in value)
        name = nodes[channel["target"]["node"]]["name"]
        if name in {"DRILL_ROTOR", "COOLING_FAN"} and channel["target"]["path"] == "rotation":
            assert min(abs(sum(a * b for a, b in zip(values[0], value))) for value in values) < 0.8, "Rotor and fan have actual quaternion rotation"
        if name == "FEED_CARRIAGE" and channel["target"]["path"] == "translation":
            assert max(v[1] for v in values) - min(v[1] for v in values) > 0.7, "GLB feed travels in glTF Y-up space"
            assert max(abs(a - b) for a, b in zip(values[23], values[24])) < 0.001, "startup joins work without positional jump"
            assert max(abs(a - b) for a, b in zip(values[0], values[-1])) < 0.001, "shutdown returns to parked pose"
    print(f"MINER_ASSET_CONTRACT_PASS: {len(gltf['meshes'])} meshes; {len(channels)} animated channels; 108 RGBA frames; ledger hashes match")


if __name__ == "__main__":
    check()
