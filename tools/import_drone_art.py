"""Copy pinned, openly licensed drone art and validate the runtime pack.

Only writes assets/models/drone_tower and assets/ui/factory/drone_tower.
Tower PNG files remain byte-for-byte identical. The OpenHV drone palette is
resolved using its original colors.pal and TransparentIndex 255 world rule.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / 'assets/ui/factory/drone_tower'
SOURCE = ROOT / 'assets/models/drone_tower'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check():
    manifest = json.loads((PACK / 'manifest.json').read_text(encoding='utf8'))
    for name, entry in manifest['files'].items():
        path = PACK / name
        assert sha(path) == entry['sha256'], name
        with Image.open(path) as image:
            assert list(image.size) == entry['size'], name
            # Upstream PNGs may use indexed palettes with transparency.
            assert image.convert('RGBA').getchannel('A').getextrema()[0] == 0, name
    for name, digest in manifest['provenance_files'].items():
        assert sha(SOURCE / name) == digest, name
    assert manifest['tower']['body']['size'] == [240, 300]
    assert manifest['tower']['animation']['frames'] == 8
    assert manifest['drone']['directions'] * manifest['drone']['frames_per_direction'] == 16
    print('PASS drone art: original PNG hashes, dimensions, alpha, provenance, frame metadata')


def build(k2, openhv):
    PACK.mkdir(parents=True, exist_ok=True)
    SOURCE.mkdir(parents=True, exist_ok=True)
    mappings = {
        'tower.png': k2 / 'buildings/small-roboport/small-roboport.png',
        'tower-shadow.png': k2 / 'buildings/small-roboport/small-roboport-sh.png',
        'tower-idle.png': k2 / 'buildings/small-roboport/small-roboport-animation.png',
        'tower-light.png': k2 / 'buildings/small-roboport/small-roboport-animation-light.png',
        'drone.png': openhv / 'mods/hv/bits/sprites/aircraft/drone2.png',
    }
    files = {}
    for name, source in mappings.items():
        shutil.copyfile(source, PACK / name)
        if name == 'drone.png':
            shutil.copyfile(source, SOURCE / 'OPENHV-drone2-original.png')
            palette_path = openhv / 'mods/hv/bits/palettes/colors.pal'
            shutil.copyfile(palette_path, SOURCE / 'OPENHV-colors.pal')
            palette = []
            for line in palette_path.read_text().splitlines()[3:]:
                parts = [int(value) for value in line.split()]
                palette.append(tuple(parts if len(parts) == 4 else parts + [255]))
            assert len(palette) == 256
            palette[255] = (0, 0, 0, 0)
            with Image.open(source) as indexed:
                rgba = Image.new('RGBA', indexed.size)
                rgba.putdata([palette[index] for index in indexed.get_flattened_data()])
                rgba.save(PACK / name)
        with Image.open(PACK / name) as image:
            files[name] = {'sha256': sha(PACK / name), 'original_sha256': sha(source), 'size': list(image.size), 'original_path': str(source.relative_to(k2 if name.startswith('tower') else openhv)).replace('\\', '/')}
    shutil.copyfile(k2 / 'LICENSE', SOURCE / 'KRASTORIO-LGPL-3.0.txt')
    shutil.copyfile(k2 / 'info.json', SOURCE / 'KRASTORIO-info.json')
    shutil.copyfile(openhv / 'mods/hv/bits/sprites/aircraft/drone2.yaml', SOURCE / 'OPENHV-drone2.yaml')
    # Keep the exact source sequence alongside the per-sprite attribution.
    sequence = (openhv / 'mods/hv/sequences/aircraft.yaml').read_text(encoding='utf8')
    (SOURCE / 'OPENHV-drone2-sequence.yaml').write_text('drone2:' + sequence.split('drone2:', 1)[1].split('\nbattleship:', 1)[0] + '\n', encoding='utf8')
    rules = (openhv / 'mods/hv/rules/world.yaml').read_text(encoding='utf8')
    (SOURCE / 'OPENHV-palette-rule.yaml').write_text('PaletteFromGimpOrJascFile@Player:' + rules.split('PaletteFromGimpOrJascFile@Player:', 1)[1].split('\tPaletteFromGimpOrJascFile@Effect:', 1)[0], encoding='utf8')
    manifest = {
        'schema_version': 1,
        'asset_type': 'pre-rendered 2D model sprites; no editable 3D source supplied upstream',
        'modifications': 'Tower PNGs unchanged. Drone indexed palette resolved through original colors.pal with index 255 transparent, per upstream world rule. Runtime framing and scale adapted to Factory.',
        'tower': {
            'author': 'Linver, Krastor, raiguard (Krastorio 2 Assets)',
            'source': 'https://codeberg.org/raiguard/Krastorio2Assets',
            'commit': 'bbb0ac6a2783b5b9d86301f60a8fd874ea36c316',
            'license': 'LGPL-3.0',
            'reference_footprint_tiles': [2, 2],
            'native_pixels_per_tile': 128,
            'body': {'size': [240, 300], 'shift_tiles': [0, -0.1]},
            'shadow': {'size': [322, 166], 'shift_tiles': [0.48, 0.43]},
            'animation': {'size': [110, 80], 'shift_tiles': [0, -0.92], 'frames': 8, 'fps': 6},
        },
        'drone': {
            'author': 'Pawel Dzierzanowski',
            'source': 'https://github.com/OpenHV/OpenHV',
            'commit': '91b39d484416562c6cb0e660632bfa0873fb0631',
            'license': 'CC-BY-SA-4.0',
            'license_url': 'https://creativecommons.org/licenses/by-sa/4.0/',
            'frame_size': [12, 12], 'columns': 4, 'directions': 8,
            'frames_per_direction': 2, 'fps': 8,
            'direction_order': 'clockwise from north; 2 consecutive animation frames per direction',
        },
        'files': files,
        'provenance_files': {p.name: sha(p) for p in SOURCE.iterdir() if p.is_file() and p.suffix != '.import'},
    }
    (PACK / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    check()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--krastorio', type=Path, default=Path('D:/project/Krastorio2Assets'))
    parser.add_argument('--openhv', type=Path, default=Path('D:/project/OpenHV'))
    args = parser.parse_args()
    check() if args.check else build(args.krastorio, args.openhv)
