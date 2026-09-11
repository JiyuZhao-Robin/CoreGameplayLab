# MK2 and Core Extractor demos

Run both independent demos in one comparison window:

```powershell
.\tools\run_reference_miners.ps1
```

The launcher refreshes Godot imports and starts the standalone scene with
`--no-persistence`. Each panel has its own running/paused state, frame slider,
camera zoom, direction selector and layer controls. Closing the scene restores
any Game processing/persistence flags it temporarily suspended. Production
Factory buildings, roads, inventory and deployment are not changed.

## Source fidelity

- **Krastorio 2 MK2:** dry N/E/S/W assemblies, 3×3 source footprint, integration
  patch, casing, drill back/front, output, shadows, source dust and status LED.
  Its 30 source drill frames play through the original 195-step sequence at
  24 steps/second. The 21-frame shadow follows its separate 195-step sequence.
  Source waypoint positions and hold/transition durations drive presentation
  movement, with continuous fractional-time interpolation.
- **Hurricane Core Extractor:** 11×11 source footprint, 704×704 body and additive
  emission, two sheets with 64+56 valid frames, 30 fps, one authored direction.
  The 1400×1400 static shadow shares the source centre with scale 0.5.
- The original PNGs remain byte-identical. `selection.json` pins the source
  hashes and assembly parameters; `manifest.json` is the reproducible runtime
  form. Attribution, original metadata and factual source-layout evidence are
  retained alongside the pack. See [ATTRIBUTION.md](ATTRIBUTION.md).

This is a visual adapter, not the original Factorio mining simulation. Stop
freezes the pose immediately and hides working effects. Dust tint and the green
additive LED are local presentation choices; original engine fade-in/out,
resource targeting, wet mining and gameplay power are not reproduced. The
source frames and waypoint clocks are driven independently in this demo.

Each panel displays its current zoom and source footprint. Initial views are
200% for the smaller MK2 and 85% for Core Extractor so both can be inspected.
At large zoom, MK2's lower source resolution is visible; no new high-resolution
details or sharpening have been invented. Both panels use the same ground and
ore references, and preserve the source building colors.

## Verification / rebuild

```powershell
python tools/import_reference_miners.py --check
python tests/reference_mining_assets_test.py
.\tools\run_reference_miners.ps1 -Capture
```

`--check` needs only the local project pack. Re-copying from the original pinned
reference library uses `python tools/import_reference_miners.py --reference-root
D:/Project`. The image-content contract test uses Pillow. Normal-renderer
captures go to ignored `artifacts/ui/reference-miners/` at 3840×2160. Per-frame
textures are prepared in memory for this review tool; this is not a shipping
streaming/LOD or large-factory memory benchmark.
