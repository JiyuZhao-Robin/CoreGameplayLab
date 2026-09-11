# Planetary development core: elevator with logistics crown

The deployed `grid_planetary_core`, its placement ghost, palette and inspector use
this project-local sprite pack. The original 20 x 20 footprint and all startup,
inventory, power and drone rules remain authoritative.

## Construction

- Lower machinery and tower: Earendel's Space Exploration elevator model as
  adapted/textured by Hurricane for [FUE5](https://github.com/FUE5BASE/FUE5).
- Upper docking platform: the upper section of the user-supplied Dyson Sphere
  Program planetary logistics station, retaining original geometry and UVs.
- Underground geometry is cut at ground level. The original repeatable spire is
  extended and fitted beneath the docking crown. DSP paint is tinted engineering
  yellow with metal roughness variation to match the lower machinery.
- 24 transparent 768 x 1024 Cycles frames, played at 12 fps, with one fixed camera,
  lighting setup and ground anchor. The source antenna rotation and repeating
  spire translation are baked into actual geometry movement. The crown is fixed.
- These are building presentation animations. No train, spaceship launch, or new
  interstellar transport gameplay is implemented by this art change.

## Reproduction and provenance

Run Blender 4.5 LTS in background with `tools/render_space_elevator.py` to reproduce
the frames. Add `-- --preview` for one review render. Source FBX, OBJ, textures and
source records are under `assets/models/space_elevator/source/`, excluded from
Godot's importer by `.gdignore`; runtime depends only on the baked local PNGs.

The FUE5 source manifest pins the upstream revision and file hashes and retains
its original license. The DSP source folder records the user's existing local
extraction. This composite is prepared for the project's stated learning use;
the authorship and original terms are preserved, not replaced by a new license.

Verification: `tests/factory_space_elevator_art_test.gd` checks real frames,
selection/culling above the footprint, animation gates and state isolation.
`tests/factory_space_elevator_capture.gd` deploys the core through the real game
command and captures it in the production workspace beside industrial buildings.
