"""Copy five attributed Hurricane/Nullius building candidates without changing images.

Initial import needs --source-root; --check validates only the checked-in pack.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / 'assets/art_calibration/building_candidates'
CANDIDATES = [
    ('arc-furnace', '电弧炉', '锻炉 / 冶炼', '建议用于基础冶炼或进阶熔炼；请确认炉体轮廓与工作亮度。', 4),
    ('manufacturer', '制造工厂', '自动制造机 / 装配', '建议用于零件与建筑成品制造；请确认机械动作与体量。', 4),
    ('fuel-refinery', '燃料精炼厂', '炼油 / 燃料加工', '建议用于原油精炼与燃料加工；请确认储罐和管线造型。', 5),
    ('chemical-stager', '化工处理站', '化工 / 材料处理', '建议用于化工合成；已有独立标定素材，此页便于逐项确认。', 5),
    ('thermal-plant', '热能工厂', '火力发电 / 热能设施', '建议用于燃料发电；仅为外观候选，未变更发电规则。', 5),
]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def definition(path):
    raw = path.read_text(encoding='utf-8')
    values = {}
    for key in ('width', 'height', 'sprite_count', 'line_length', 'scale'):
        values[key] = float(re.search(r'\["' + key + r'"\]\s*=\s*([0-9.]+)', raw)[1])
    shift = re.search(r'\["shift"\]\s*=\s*\{([^}]+)\}', raw)[1]
    def number(term):
        parts = term.strip().split('/')
        return float(parts[0]) / (float(parts[1]) if len(parts) == 2 else 1)
    return {'frame_size': [int(values['width']), int(values['height'])],
            'frame_count': int(values['sprite_count']), 'columns': int(values['line_length']),
            'source_scale': values['scale'], 'shift_tiles': [number(t) for t in shift.split(',')]}

def check():
    manifest = json.loads((PACK / 'manifest.json').read_text(encoding='utf-8'))
    for relative, digest in manifest['files'].items():
        assert sha(PACK / relative) == digest, relative
    for candidate in manifest['candidates']:
        for layer in candidate['layers']:
            assert definition(PACK / layer['definition']) == {key: layer[key] for key in definition(PACK / layer['definition'])}
    print('BUILDING_CANDIDATES_CHECK_PASS:', len(manifest['files']), 'pinned local files')

def build(source):
    records = []
    copies = []
    for identifier, title, role, recommendation, footprint in CANDIDATES:
        layers = []
        for layer_id in ('shadow', 'base', 'mask', 'emission'):
            relative = f'graphics/entity/{identifier}/{identifier}-{layer_id}'
            lua = source / (relative + '.lua')
            png = source / (relative + '.png')
            assert lua.is_file() and png.is_file(), relative
            layer = {'id': layer_id, **definition(lua), 'texture': f'{identifier}/{layer_id}.png',
                     'definition': f'{identifier}/{layer_id}.lua', 'source_relative': relative + '.png'}
            layers.append(layer)
            copies.extend([(lua, layer['definition']), (png, layer['texture'])])
        records.append({'id': identifier, 'title': title, 'role': role, 'recommendation': recommendation,
                        'footprint_tiles': [footprint, footprint], 'footprint_authority': 'local visual proposal, not approved gameplay footprint',
                        'fps': 30, 'fps_authority': 'local preview clock, not an upstream simulation claim', 'layers': layers})
    copies.append((source / 'LICENSE', 'LICENSE.txt'))
    pinned = [(origin, target, sha(origin)) for origin, target in copies]
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    for origin, target, digest in pinned:
        destination = PACK / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin, destination)
        assert sha(destination) == digest
    manifest = {'schema_version': 1, 'status': 'awaiting_individual_visual_acceptance',
                'author': 'Hurricane046', 'processor': 'brickbrycebrick / Nullius Hurricane Reskins',
                'source_repository': 'https://github.com/SmokeStackGG/nullius-visual-overhaul',
                'source_revision': revision, 'art_license': 'CC BY 4.0', 'definition_license': 'MIT',
                'modifications': 'PNG and Lua copied byte-for-byte. Local preview uses copper-gold mask tint, additive emission, static stopped frame, and proposed footprints.',
                'candidates': records, 'files': {target: digest for _, target, digest in pinned}}
    (PACK / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    (PACK / 'ATTRIBUTION.md').write_text('# Building candidates\n\nArtwork © Hurricane046, [Factorio Buildings](https://www.figma.com/proto/y1IQG08ZG2jIeJ5sTyF4MP/Factorio-Buildings), CC BY 4.0.\n\nProcessed sprite layers and MIT Lua definitions from brickbrycebrick / [Nullius Hurricane Reskins](https://github.com/SmokeStackGG/nullius-visual-overhaul), revision `' + revision + '`. Full original notice: [LICENSE.txt](LICENSE.txt).\n\nPNGs and Lua metadata are unchanged copies. Runtime applies copper-gold mask tint, additive working light, and proposed placement sizes. 30 fps is a local preview choice. No production replacement has been approved.\n\nRuntime and `python tools/import_building_candidates.py --check` use only project files. Re-import requires an explicit `--source-root` pointing to the recorded upstream checkout.\n', encoding='utf-8')
    check()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    if args.check:
        check()
    elif args.source_root:
        build(args.source_root)
    else:
        parser.error('initial import requires --source-root; local verification uses --check')
