"""Bake the four approved local building candidates into small production frames.

All inputs are pinned project assets. No network or external checkout is needed.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil

from PIL import Image, ImageChops

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets/art_calibration/building_candidates'
PACK = ROOT / 'assets/ui/factory/approved_industry'
RESOURCE = 'res://assets/ui/factory/approved_industry/'
GENERATOR = 'tools/build_approved_industry_art.py'
FAMILIES = ('manufacturer', 'fuel-refinery', 'chemical-stager', 'thermal-plant')
MAX_DIMENSION = 256


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def generator_sha():
    return hashlib.sha256((ROOT / GENERATOR).read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def source_rect(entry):
    # All four reviewed sources use 0.5 px scale, i.e. 64 native px/tile.
    assert entry['source_scale'] == 0.5
    width, height = entry['frame_size']
    return [entry['shift_tiles'][0] * 64 - width / 2,
            entry['shift_tiles'][1] * 64 - height / 2, width, height]


def geometry(candidate):
    definitions = {entry['id']: entry for entry in candidate['layers']}
    rects = {name: source_rect(entry) for name, entry in definitions.items()}
    visible = [rects[name] for name in ('base', 'mask', 'emission')]
    left = math.floor(min(r[0] for r in visible))
    top = math.floor(min(r[1] for r in visible))
    width = math.ceil(max(r[0] + r[2] for r in visible)) - left
    height = math.ceil(max(r[1] + r[3] for r in visible)) - top
    base = rects['base']
    tiles = candidate['footprint_tiles']
    anchor = [0.0, 0.0]
    if candidate['id'] == 'thermal-plant':
        tiles = [5, 6]
        anchor = [base[0] + base[2] * 0.5, base[1] + base[3] * 0.55]
    ground = [base[2], base[2] * tiles[1] / tiles[0]]
    body_relative = [(left - anchor[0] + ground[0] / 2) / ground[0],
                     (top - anchor[1] + ground[1] / 2) / ground[1],
                     width / ground[0], height / ground[1]]
    shadow = rects['shadow']
    shadow_relative = [(shadow[0] - left) / width, (shadow[1] - top) / height,
                       shadow[2] / width, shadow[3] / height]
    scale = MAX_DIMENSION / max(width, height)
    output = [max(1, round(width * scale)), max(1, round(height * scale))]
    return {'source_body_rect': [left, top, width, height],
            'source_ground_anchor': anchor, 'source_ground_size': ground,
            'reference_footprint_tiles': tiles, 'body_rect_normalized': body_relative,
            'shadow_rect_normalized': shadow_relative, 'frame_size': output}, rects


def check():
    manifest = json.loads((PACK / 'manifest.json').read_text(encoding='utf8'))
    assert manifest['generator_sha256_lf'] == generator_sha(), 'generator changed'
    for relative, digest in manifest['source_files'].items():
        assert sha(ROOT / relative) == digest, relative
    for relative, digest in manifest['files'].items():
        assert sha(PACK / relative) == digest, relative
    catalog = json.loads((SOURCE / 'manifest.json').read_text(encoding='utf8'))
    for family in FAMILIES:
        info = manifest['families'][family]
        candidate = next(c for c in catalog['candidates'] if c['id'] == family)
        expected, _ = geometry(candidate)
        for key, value in expected.items():
            assert info[key] == value, (family, key)
        count = math.lcm(*(layer['frame_count'] for layer in candidate['layers']))
        assert info['frame_count'] == count
        assert max(info['frame_size']) == MAX_DIMENSION
        assert len(info['layers']['body']['textures']) == count
        assert len(info['layers']['working']['textures']) == count
        changed = False
        for index in range(count):
            with Image.open(PACK / f'{family}/body/{index:03d}.png') as body, Image.open(PACK / f'{family}/working/{index:03d}.png') as working:
                assert body.mode == working.mode == 'RGBA'
                assert list(body.size) == list(working.size) == info['frame_size']
                assert body.getchannel('A').getbbox(), (family, index, 'empty silhouette')
                assert body.getchannel('A').tobytes() == working.getchannel('A').tobytes(), 'working alpha drift'
                changed |= body.convert('RGB').tobytes() != working.convert('RGB').tobytes()
        assert changed, (family, 'missing working emission')
        print(f'APPROVED_INDUSTRY_ASSETS_PASS: {family}, {count} body + working frames, geometry and local hashes')


def build():
    catalog = json.loads((SOURCE / 'manifest.json').read_text(encoding='utf8'))
    PACK.mkdir(parents=True, exist_ok=True)
    (PACK / '.gitattributes').write_text('* -text whitespace=cr-at-eol\n', encoding='utf8')
    source_files = {str((SOURCE / name).relative_to(ROOT).as_posix()): sha(SOURCE / name)
                    for name in ('LICENSE.txt', 'manifest.json')}
    families = {}
    for candidate in catalog['candidates']:
        family = candidate['id']
        if family not in FAMILIES:
            continue
        definitions = {layer['id']: layer for layer in candidate['layers']}
        originals = {}
        for layer in candidate['layers']:
            for key in ('texture', 'definition'):
                path = SOURCE / layer[key]
                assert sha(path) == catalog['files'][layer[key]], 'source pin mismatch: ' + str(path)
                source_files[path.relative_to(ROOT).as_posix()] = sha(path)
            originals[layer['id']] = Image.open(SOURCE / layer['texture']).convert('RGBA')
        info, rects = geometry(candidate)
        left, top, width, height = info['source_body_rect']
        count = math.lcm(*(entry['frame_count'] for entry in definitions.values()))
        layers = {name: {'textures': []} for name in ('body', 'working')}
        for name in layers:
            (PACK / family / name).mkdir(parents=True, exist_ok=True)

        def frame(name, index):
            entry = definitions[name]
            fw, fh = entry['frame_size']
            index %= entry['frame_count']
            x, y = index % entry['columns'] * fw, index // entry['columns'] * fh
            return originals[name].crop((x, y, x + fw, y + fh))

        def place(canvas, layer, name):
            x, y = rects[name][0] - left, rects[name][1] - top
            assert x == round(x) and y == round(y), 'subpixel source alignment needs explicit resampling'
            canvas.alpha_composite(layer, (round(x), round(y)))

        for index in range(count):
            body = Image.new('RGBA', (width, height))
            place(body, frame('base', index), 'base')
            mask = frame('mask', index)
            tint = ImageChops.multiply(mask.convert('RGB'), Image.new('RGB', mask.size, (196, 147, 82))).convert('RGBA')
            tint.putalpha(mask.getchannel('A'))
            place(body, tint, 'mask')
            light = Image.new('RGBA', (width, height))
            place(light, frame('emission', index), 'emission')
            light_rgb = ImageChops.multiply(light.convert('RGB'), light.getchannel('A').convert('RGB'))
            working = ImageChops.add(body.convert('RGB'), light_rgb).convert('RGBA')
            working.putalpha(body.getchannel('A'))
            # Resize both alpha channels identically: emission never changes silhouette.
            for name, image in (('body', body), ('working', working)):
                relative = f'{family}/{name}/{index:03d}.png'
                image.resize(info['frame_size'], Image.Resampling.LANCZOS).save(PACK / relative)
                layers[name]['textures'].append(RESOURCE + relative)
        shadow = frame('shadow', 0)
        scale = MAX_DIMENSION / max(width, height)
        shadow.resize((round(shadow.width * scale), round(shadow.height * scale)), Image.Resampling.LANCZOS).save(PACK / family / 'shadow.png')
        layers['shadow'] = {'texture': RESOURCE + family + '/shadow.png'}
        info.update(frame_count=count, fps=candidate['fps'], layers=layers)
        families[family] = info
        for original in originals.values():
            original.close()
    shutil.copyfile(SOURCE / 'LICENSE.txt', PACK / 'LICENSE.txt')
    (PACK / 'ATTRIBUTION.md').write_text(
        '# Approved industrial building production art\n\n'
        'Artwork © Hurricane046, [Factorio Buildings](https://www.figma.com/proto/y1IQG08ZG2jIeJ5sTyF4MP/Factorio-Buildings), '
        '[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).\n\n'
        'Source layers processed by brickbrycebrick / [Nullius Hurricane Reskins](https://github.com/SmokeStackGG/nullius-visual-overhaul), '
        f'revision `{catalog["source_revision"]}`. See [LICENSE.txt](LICENSE.txt) for upstream notices and MIT definition license.\n\n'
        'Derived locally from the four approved candidates: crop all animation frames, preserve source offsets on the union of body, mask and emission bounds, '
        'apply copper-gold mask #c49352, add emission while retaining body alpha, and resize each frame to 256 px maximum body dimension. '
        'Shadows remain separate at original offsets (caller uses opacity 0.48). Timing is the reviewed local 30 fps. '
        'Thermal Plant uses the reviewed 5×6 ground rectangle centered at (0.5, 0.55) of its source base; other candidates retain their reviewed square ground references. '
        'Runtime uses uniform fitting to preserve proportions. Art metadata does not define gameplay collision, recipes or rates.\n\n'
        'Rebuild: `python tools/build_approved_industry_art.py`; verify: add `--check`. All inputs live inside this project.\n', encoding='utf8')
    files = {path.relative_to(PACK).as_posix(): sha(path) for path in sorted(PACK.rglob('*'))
             if path.is_file() and path.name != 'manifest.json' and not path.name.endswith('.import')}
    manifest = {'schema_version': 1, 'families': families, 'source_repository': catalog['source_repository'],
                'source_revision': catalog['source_revision'], 'source_files': source_files,
                'generator': GENERATOR, 'generator_sha256_lf': generator_sha(),
                'generator_hash_normalization': 'CRLF replaced with LF', 'files': files}
    (PACK / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf8')
    check()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    check() if args.check else build()
