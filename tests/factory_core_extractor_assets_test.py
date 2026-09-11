"""Read-only checks of pinned production derivatives (no image modifications)."""
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageChops, ImageStat

ROOT = Path(__file__).resolve().parents[1]
PACK = ROOT / 'assets/ui/factory/miner/core_extractor'


def local(path):
    return ROOT / path.removeprefix('res://')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    manifest = json.loads((PACK / 'manifest.json').read_text(encoding='utf-8'))
    assert manifest['frame_count'] == 120 and manifest['fps'] == 30
    assert manifest['frame_size'] == [256, 256]
    assert abs(manifest['shadow_to_body_scale'] - 1400 / 704) < 1e-9
    provenance = manifest['provenance']
    selection_path = local(provenance['selection'])
    selection = json.loads(selection_path.read_text(encoding='utf-8'))
    pinned = {str((selection_path.parent / row['destination']).relative_to(ROOT)).replace('\\', '/'): row['sha256']
              for row in selection['files'] if row['destination'].startswith('core/')}
    assert sha(local(provenance['generator'])) == provenance['generator_sha256']
    assert len(provenance['sources']) == 5
    for path, digest in provenance['sources'].items():
        assert sha(local(path)) == digest, path
        assert digest == pinned[path.removeprefix('res://')], 'derivative must use the pinned original, not silently approve changed inputs'
    assert len(manifest['files']) == 361
    for path, digest in manifest['files'].items():
        filename = local(path)
        assert sha(filename) == digest, path
        with Image.open(filename) as frame:
            assert frame.size == ((512, 512) if 'shadow' in path else (256, 256))
            if '/emission/' not in path:
                assert frame.convert('RGBA').getextrema()[3][0] == 0, path
        assert 'mipmaps/generate=true' in Path(str(filename) + '.import').read_text()
    for layer in ('body', 'emission', 'working'):
        paths = manifest['layers'][layer]['textures']
        assert len(paths) == len(set(paths)) == 120
        for i in (0, 63, 64, 119):
            assert paths[i].endswith(f'/{i:04d}.png')
        first, second = (Image.open(local(paths[i])).convert('RGB') for i in (0, 30))
        assert sum(ImageStat.Stat(ImageChops.difference(first, second)).sum) > 1000
    body = Image.open(PACK / 'body/0000.png').convert('RGB')
    working = Image.open(PACK / 'working/0000.png').convert('RGB')
    assert sum(ImageStat.Stat(working).sum) > sum(ImageStat.Stat(body).sum), 'working light must be visible'
    for i in range(120):
        base_alpha = Image.open(PACK / f'body/{i:04d}.png').convert('RGBA').getchannel('A')
        work_alpha = Image.open(PACK / f'working/{i:04d}.png').convert('RGBA').getchannel('A')
        assert base_alpha.tobytes() == work_alpha.tobytes(), 'opaque emission background must not cover the terrain'
    print('PASS: Core Extractor source/derivative hashes, 120-frame layers, transparency, mipmaps and working emission')


if __name__ == '__main__':
    main()
