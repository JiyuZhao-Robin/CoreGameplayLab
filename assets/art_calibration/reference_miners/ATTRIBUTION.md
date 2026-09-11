# Two mining-machine reference demos

The selected sprite sheets are copied without pixel modifications. Runtime frame
extraction, per-frame mipmaps, layer placement and playback are local adapters.
These references are separate from the original HELIX-01 model prototype.

## Electric Mining Drill MK2

Source: Krastorio 2 Assets, `buildings/electric-mining-drill-mk2/`.
Repository: <https://codeberg.org/raiguard/Krastorio2Assets>
Pinned revision: `bbb0ac6a2783b5b9d86301f60a8fd874ea36c316`.
Credit: **Linver, Krastor, raiguard** and the Krastorio 2 contributors; package author metadata
is retained in `evidence/krastorio-info.json`.
Repository license text is retained unchanged in `evidence/krastorio-LICENSE`.
The upstream package declares LGPL-3.0; this is recorded for this source only.

The dry machine's assembly definitions are recorded with source evidence. The
demo does not reproduce mining recipes, resource depletion, fluid overlays,
sound, gameplay electricity or the original mod's simulation.

## Core Extractor

Author: **Hurricane046**.
Source: <https://www.figma.com/proto/y1IQG08ZG2jIeJ5sTyF4MP/Factorio-Buildings>
Download: <https://drive.google.com/drive/folders/1_hRfTbC6fo4L-e-mvCXao2ok_g7nJege>
Local reference download date: 2026-09-10.
Original metadata is retained unchanged in `evidence/hurricane-SOURCE.json` and
`evidence/hurricane-README-LOCAL.md`; it describes the license as **CC BY** without
fixing the license version. No license version is inferred from other packs.
Only the selected Core Extractor body, emission and shadow sheets are used here.

Frame layout source: Lunar Landings `prototypes/core-extractor.lua`, revision
`ed3ee60cea84dd1eca008ac9f398154b1690f11b`. Its URL, file hash and factual layout
parameters are recorded in `evidence/core-layout-source.json`; the mod's Lua is
not redistributed in this pack. It declares 120 frames, 704×704,
scale 0.5, 11×11 selection bounds and no layer shifts. The second source sheet
contains only the final 56 valid frames; empty cells are not loaded. The demo
adapts the working light and stop behavior for visual review only.

## Shared environment

Ground: **Rob Tuytel / Poly Haven**, Aerial Sand, CC0.
Ore: **Malcolm Riley**, crushed iron ore, CC BY 4.0.
The demos reuse the already imported files in `assets/art_calibration/`.
Their original links and license records remain in
[`../ATTRIBUTION.md`](../ATTRIBUTION.md).

## Rebuild and review

`selection.json` pins every source file and records the sprite assembly choices.
`tools/import_reference_miners.py` copies the selected bytes and validates frame
bounds. `--check` verifies the local pack without accessing the reference drive.
No standalone demo changes production Factory content, inventory or saves.
