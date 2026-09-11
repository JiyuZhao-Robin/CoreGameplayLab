# Core Extractor — production Factory derivative

Art by **Hurricane046**, selected by the player from the second mining demo.
Original source: [Factorio Buildings](https://www.figma.com/proto/y1IQG08ZG2jIeJ5sTyF4MP/Factorio-Buildings),
[source download folder](https://drive.google.com/drive/folders/1_hRfTbC6fo4L-e-mvCXao2ok_g7nJege).
Source metadata declares **CC BY**, without specifying a version; this record
does not infer one. Original files and unchanged attribution evidence are kept
in [the reference pack](../../../../art_calibration/reference_miners/ATTRIBUTION.md).

The original body/emission sheets are 704×704 pixels per frame, 120 frames,
split 64 + 56. The independent shadow is 1400×1400. Layout facts and the pinned
Lunar Landings source revision are in that pack's `evidence/core-layout-source.json`.
No upstream gameplay code is redistributed in this derivative.

`tools/build_core_extractor_factory_art.gd` crops the original frame sequence,
reduces each frame to 256×256 using Lanczos, and creates a 512×512 shadow.
`working/` contains the body plus alpha-weighted additive emission, clamped to
the normal display range, preserving the body's transparent silhouette. Source
emission has an opaque black background suitable only for additive blending;
its alpha is not copied into the working sprite. This retains building painter
order. Original color and timing (30 fps, four-second loop) are retained.
The shadow uses its original 1400/704 spatial ratio, independent of export size.
This is a derived sprite asset, not a newly generated model or new AI artwork.

`manifest.json` records every source and derived PNG SHA-256, generator hash,
processing method, source layout and attribution. Rebuild from the project root:

```powershell
& D:\Godot\godot.exe --headless --path D:\Projects\standalone\core_gameplay_lab --script res://tools/build_core_extractor_factory_art.gd -- --no-persistence
& D:\Godot\godot.exe --headless --path D:\Projects\standalone\core_gameplay_lab --editor --import --quit -- --no-persistence
```

Production only loads requested isolated frames through one shared cache.
Three 120-frame RGBA8 mipmapped layers plus one shadow bound the cache at 361
textures (about 121.4 MiB uncompressed GPU texture data if every layer is used).
Normal running machines share the working frames and do not load the emission
layer. Palette/ghost/item icons use body frame zero. Nothing reads `D:/Project`
at runtime. Following the player's additional size request, newly deployed
machines in the selected family use an 11×11 physical footprint and an 18-tile
radius circular mining area. Canonical IDs, costs and recipes stay intact.
