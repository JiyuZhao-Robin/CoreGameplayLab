"""Bake approved local Arc Furnace layers into small production frames.

No network or external source checkout is needed. --check validates the pack.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets/art_calibration/building_candidates'
PACK = ROOT / 'assets/ui/factory/arc_furnace'
RESOURCE = 'res://assets/ui/factory/arc_furnace/'
GENERATOR = 'tools/build_arc_furnace_art.py'
FRAME_SIZE = 256


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generator_sha():
    return hashlib.sha256((ROOT / GENERATOR).read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def check():
    manifest = json.loads((PACK / 'manifest.json').read_text(encoding='utf8'))
    assert manifest['generator_sha256_lf'] == generator_sha(), 'generator changed'
    for relative, digest in manifest['source_files'].items():
        assert sha(ROOT / relative) == digest, relative
    for relative, digest in manifest['files'].items():
        assert sha(PACK / relative) == digest, relative
    for kind in ('body', 'working'):
        assert len(manifest['layers'][kind]['textures']) == 50
        for path in manifest['layers'][kind]['textures']:
            with Image.open(PACK / path.removeprefix(RESOURCE)) as image:
                assert image.mode == 'RGBA' and image.size == (FRAME_SIZE, FRAME_SIZE)
                assert image.getpixel((0, 0))[3] == 0, path
    for index in range(50):
        with Image.open(PACK / f'body/{index:03d}.png') as body, Image.open(PACK / f'working/{index:03d}.png') as working:
            assert body.getchannel('A').tobytes() == working.getchannel('A').tobytes(), 'working alpha drift'
    print('ARC_FURNACE_ASSETS_PASS: 50 body + 50 working frames, local provenance and shared alpha')


def build():
    catalog = json.loads((SOURCE / 'manifest.json').read_text(encoding='utf8'))
    candidate = next(row for row in catalog['candidates'] if row['id'] == 'arc-furnace')
    definitions = {layer['id']: layer for layer in candidate['layers']}
    originals = {}
    source_files = {}
    for layer in candidate['layers']:
        for key in ('texture', 'definition'):
            path = SOURCE / layer[key]
            assert sha(path) == catalog['files'][layer[key]], 'source pin mismatch: ' + str(path)
            source_files[path.relative_to(ROOT).as_posix()] = sha(path)
        originals[layer['id']] = Image.open(SOURCE / layer['texture']).convert('RGBA')
    for name in ('LICENSE.txt', 'manifest.json'):
        source_files[(SOURCE / name).relative_to(ROOT).as_posix()] = sha(SOURCE / name)
    assert definitions['base']['frame_size'] == [320, 315] and definitions['base']['frame_count'] == 50
    assert definitions['base']['shift_tiles'] == [0, 2.5 / 64]
    assert definitions['mask']['frame_size'] == [215, 186] and definitions['mask']['shift_tiles'] == [-2.5 / 64, -20 / 64]
    assert definitions['emission']['frame_size'] == [320, 320] and definitions['emission']['shift_tiles'] == [0, 0]
    assert definitions['shadow']['frame_size'] == [400, 323] and definitions['shadow']['shift_tiles'] == [45 / 64, 17.5 / 64]
    PACK.mkdir(parents=True, exist_ok=True)
    (PACK / '.gitattributes').write_text('* -text\n', encoding='utf8')
    layers = {name: {'textures': []} for name in ('body', 'working')}
    for name in layers:
        (PACK / name).mkdir(exist_ok=True)

    def frame(kind, index):
        entry = definitions[kind]
        width, height = entry['frame_size']
        index %= entry['frame_count']
        x, y = index % entry['columns'] * width, index // entry['columns'] * height
        return originals[kind].crop((x, y, x + width, y + height))

    mask = frame('mask', 0)
    tinted_rgb = ImageChops.multiply(mask.convert('RGB'), Image.new('RGB', mask.size, (196, 147, 82)))
    mask = tinted_rgb.convert('RGBA')
    mask.putalpha(frame('mask', 0).getchannel('A'))
    for index in range(50):
        body = Image.new('RGBA', (320, 320))
        body.alpha_composite(frame('base', index), (0, 5))
        body.alpha_composite(mask, (50, 47))
        light = frame('emission', index)
        # Add emission with its alpha, retaining the exact body silhouette. It
        # cannot create an opaque black square around transparent source pixels.
        light_rgb = ImageChops.multiply(light.convert('RGB'), light.getchannel('A').convert('RGB'))
        working = ImageChops.add(body.convert('RGB'), light_rgb).convert('RGBA')
        working.putalpha(body.getchannel('A'))
        for name, image in (('body', body), ('working', working)):
            relative = f'{name}/{index:03d}.png'
            image.resize((FRAME_SIZE, FRAME_SIZE), Image.Resampling.LANCZOS).save(PACK / relative)
            layers[name]['textures'].append(RESOURCE + relative)
    frame('shadow', 0).resize((320, 258), Image.Resampling.LANCZOS).save(PACK / 'shadow.png')
    layers['shadow'] = {'texture': RESOURCE + 'shadow.png'}
    shutil.copyfile(SOURCE / 'LICENSE.txt', PACK / 'LICENSE.txt')
    attribution = ('# Approved Arc Furnace production art\n\n'
        'Artwork © Hurricane046, [Factorio Buildings](https://www.figma.com/proto/y1IQG08ZG2jIeJ5sTyF4MP/Factorio-Buildings), '
        '[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).\n\n'
        'Source layers processed by brickbrycebrick / [Nullius Hurricane Reskins](https://github.com/SmokeStackGG/nullius-visual-overhaul), '
        f'revision `{catalog["source_revision"]}`. Original notice and MIT definition license: [LICENSE.txt](LICENSE.txt).\n\n'
        'Derived locally from the previously reviewed Arc Furnace candidate: crop 50 source frames, place source offsets on a transparent square, '
        'apply the approved copper-gold mask, bake working emission without changing body alpha, and downsample to 256 px. '
        'Shadow remains separate with its original relative offset. 30 fps is the same local preview timing. '
        'No footprint, recipe, or production rate is defined by this art pack.\n\n'
        'Rebuild: `python tools/build_arc_furnace_art.py`; verify: add `--check`. All input files are inside this project.\n')
    (PACK / 'ATTRIBUTION.md').write_text(attribution, encoding='utf8')
    files = {path.relative_to(PACK).as_posix(): sha(path) for path in sorted(PACK.rglob('*'))
             if path.is_file() and path.name != 'manifest.json' and not path.name.endswith('.import')}
    manifest = {'schema_version': 1, 'building_family': 'arc_furnace', 'frame_count': 50, 'fps': 30,
                'frame_size': [256, 256], 'body_anchor': [0.5, 0.5], 'source_body_rect': [-160, -160, 320, 320],
                'shadow_rect_normalized': [5 / 320, 16 / 320, 400 / 320, 323 / 320],
                'layers': layers, 'source_repository': catalog['source_repository'], 'source_revision': catalog['source_revision'],
                'source_files': source_files, 'generator': GENERATOR, 'generator_sha256_lf': generator_sha(),
                'generator_hash_normalization': 'CRLF replaced with LF', 'files': files}
    (PACK / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    check()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    check() if args.check else build()
