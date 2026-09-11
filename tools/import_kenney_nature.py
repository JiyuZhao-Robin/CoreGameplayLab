"""Fetch and retain the user-selected, official CC0 Kenney Nature Kit."""
from pathlib import Path, PurePosixPath
import argparse
import hashlib
import json
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "assets/ui/factory/natural/kenney_nature"
URL = "https://kenney.nl/media/pages/assets/nature-kit/37ac38a37b-1677698939/kenney_nature-kit.zip"
SHA256 = "fa7974a0d342bfe63c38664ba9f8ec1a4aab8ea25f099bdc56870e33588c4d9d"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, help="Reuse an already downloaded official archive")
    args = parser.parse_args()
    data = args.archive.read_bytes() if args.archive else urllib.request.urlopen(URL, timeout=90).read()
    assert hashlib.sha256(data).hexdigest() == SHA256, "Official archive changed; review before importing"
    source = DEST / "source"
    source.mkdir(parents=True, exist_ok=True)
    (source / ".gdignore").write_text("", encoding="utf-8")
    archive = source / "kenney_nature-kit.zip"
    archive.write_bytes(data)
    retained = {}
    with zipfile.ZipFile(archive) as pack:
        for name in pack.namelist():
            path = PurePosixPath(name)
            selected_model = name.startswith("Models/GLTF format/") and path.suffix == ".glb" and path.stem.startswith(("tree_", "stump", "log"))
            if name != "License.txt" and not selected_model:
                continue
            target = DEST / "License.txt" if name == "License.txt" else source / "models" / path.name
            target.parent.mkdir(parents=True, exist_ok=True)
            content = pack.read(name)
            target.write_bytes(content)
            retained[target.relative_to(DEST).as_posix()] = {"archive_path": name, "sha256": hashlib.sha256(content).hexdigest()}
    manifest = {"source_page": "https://kenney.nl/assets/nature-kit", "download_url": URL, "download_date": "2026-09-11", "archive_sha256": SHA256, "archive_bytes": len(data), "pack_version_from_license": "2.1", "license": "CC0-1.0", "retained_files": retained}
    (DEST / "source_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"Retained archive and {len(retained)} licensed model/license files in {DEST}")


if __name__ == "__main__":
    main()
