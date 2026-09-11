# Kenney Nature Kit: Earth tree art

- Artist/source: **Kenney**, [official Nature Kit page](https://kenney.nl/assets/nature-kit).
- License: **CC0-1.0**. The original pack license is retained verbatim in `License.txt`; commercial use and modifications are allowed.
- Downloaded: 2026-09-11. The archive's license identifies **Nature Kit 2.1**.
- Official archive: `https://kenney.nl/media/pages/assets/nature-kit/37ac38a37b-1677698939/kenney_nature-kit.zip`.
- Archive SHA-256: `fa7974a0d342bfe63c38664ba9f8ec1a4aab8ea25f099bdc56870e33588c4d9d` (10,537,521 bytes).
- `source/kenney_nature-kit.zip` preserves the complete original pack, including its other model formats and isometric art.
- `source/models/` exposes 72 original GLB files: trees, tree stumps, and logs. Embedded materials remain unmodified. `source_manifest.json` records their archive paths and SHA-256 hashes.
- `source/.gdignore` avoids importing all source assets into the runtime. The selected models are rendered into a compact production texture.

## Derived production art

`kenney_earth_canopies_v1.png` is a **2048×2048 RGBA, 2×2 atlas**, rendered from original Kenney geometry in Blender 4.5.9 LTS. Row-major cells are `tree_oak`, `tree_detailed`, `tree_default`, and `tree_pineRoundC`. This replaces the prior AI tree atlas reference; no Factorio, DSP, or AI-generated art was used as input.

Rendering uses Cycles, 64 samples, orthographic projection at 70° elevation, transparent background, and warm upper-left sunlight. Crowns fit within their own 1024×1024 cells with transparent gutters. Original GLB materials use turquoise foliage and metallic=1; the derived Blender scene adapts them to four Earth greens, brown bark, metallic=0 and roughness=0.88. Exact linear RGBA values and placement are in `render_manifest.json`. Original source files remain unchanged.

Atlas SHA-256: `1910766f2b18ca490e428d5a73a07a2efb1359971bea6f85b5dedc5f1f6e5686`.

Reproduce from the repository root:

```text
python tools/import_kenney_nature.py --archive assets/ui/factory/natural/kenney_nature/source/kenney_nature-kit.zip
blender --background --python tools/render_kenney_nature.py
```

The renderer also retains `source/earth_canopies.blend`, containing geometry, derived materials, camera and lights. Tree harvesting, fall animation, saved removal, and terrain excavation are separate unfinished gameplay requirements; this adoption supplies their art sources and the current static forest view.
