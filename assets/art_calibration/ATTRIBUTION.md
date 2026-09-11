# Art calibration credits

These are selected third-party reference assets, not newly AI-generated artwork.
Images are copied byte-for-byte. The standalone scene applies runtime scale,
tint, shadow opacity, independent layer compositing and animation timing.

| Work | Credit and source | License and evidence |
| --- | --- | --- |
| Chemical Stager | Hurricane046, [Factorio Buildings](https://www.figma.com/proto/y1IQG08ZG2jIeJ5sTyF4MP/Factorio-Buildings); processed layers by brickbrycebrick / [Nullius Hurricane Reskins](https://github.com/SmokeStackGG/nullius-visual-overhaul/tree/852d736052fbf32c22cb04102ce82367b12800d0) | Artwork [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); bundled Lua definitions MIT. [Original notice](licenses/nullius-LICENSE.txt). |
| Crushed iron ore | Malcolm Riley, [Unused Renders](https://github.com/malcolmriley/unused-renders/tree/0d2c456803dbdf1f10dd282b1fb9356526feb276) | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), [original license](licenses/unused-renders-LICENSE.txt). |
| Aerial Sand | Rob Tuytel / [Poly Haven](https://polyhaven.com/a/aerial_sand) | [CC0](https://polyhaven.com/license), [checked evidence](licenses/polyhaven-evidence.md). |
| Blueish Smoke, frames 0001–0030 | rubberduck, [25 special effects rendered with Blender](https://opengameart.org/content/25-special-effects-rendered-with-blender) | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/), [original source page snapshot](licenses/rubberduck-SOURCE.html). |

The building's base, shadow, mask and emission all come from the same pinned
Nullius revision. That upstream project describes its splitting/recoloring and
repacking of Hurricane's originals. This project does not mix in another release.

The smoke shader desaturates the blue/green source for the in-scene exhaust;
the source-color swatch remains unmodified. Ore item renders are scattered for
occlusion comparison, not claimed to be an authored ore-deposit terrain set.

Per-file hashes, source-relative paths, upstream revisions, frame dimensions,
offsets and local playback choices are in `selection.json` and `manifest.json`.
Run `python tools/import_art_calibration.py --check` from the project root to
verify both copied bytes and reproducible metadata against the pinned library.
