# Drone tower art provenance

The production tower uses **Krastorio 2 Assets / small-roboport** by Linver,
Krastor and raiguard, under **GNU LGPL version 3**. The flying drone uses
**OpenHV / drone2** by **Pawel Dzierzanowski**, under **CC BY-SA 4.0**.

These are actual pre-rendered game sprites, not debug geometry. An editable 3D
tower mesh is **not** included or claimed; the original author distributes the
selected tower as PNG model renders. Tower runtime files are copied byte-for-byte
into `assets/ui/factory/drone_tower/`, which also serves as their editable sprite
source. The drone's original indexed PNG and palette are preserved here; its
runtime PNG resolves that palette into RGBA. Replacing the runtime PNG files
requires no change to simulation code.

## Original sources

- Tower assets: <https://codeberg.org/raiguard/Krastorio2Assets>, commit
  `bbb0ac6a2783b5b9d86301f60a8fd874ea36c316` (version 2.1.1).
- Tower geometry: <https://codeberg.org/raiguard/Krastorio2/src/branch/trunk/prototypes/buildings/small-roboport.lua>.
  A verbatim snapshot retrieved 2026-09-11 is included as
  `upstream-small-roboport.lua`; the runtime manifest hashes this snapshot.
- Drone: <https://github.com/OpenHV/OpenHV>, commit
  `91b39d484416562c6cb0e660632bfa0873fb0631`.
  Original image: `mods/hv/bits/sprites/aircraft/drone2.png`.
  Original attribution metadata and animation sequence are preserved here.
- Drone license: <https://creativecommons.org/licenses/by-sa/4.0/>.

The existing `hub_candidates` previews were reviewed without modification.
They concern the distinct planetary/space transport core. The chosen compact
roboport provides a recognizable charging tower for local delivery drones.

## Adaptation and geometry

Tower PNG pixels were not edited. The drone was decoded using the original
`colors.pal` and transparent palette index 255, as specified in OpenHV's world
rule (preserved here). Other changes are runtime scaling, sprite frame selection,
applying the source light layer with 0.6 alpha, and projecting the drone's own
silhouette as a translucent shadow. Those adaptations to the OpenHV sprite are
also available under CC BY-SA 4.0.

The tower's original selection box is 2 by 2 tiles. Source scale 0.25 and 32
Factorio pixels per tile produce 128 source pixels per tile. Body, shadow, and
idle-light shifts are copied from the upstream definition, not inferred from
transparent bounds. The adapter uniformly fits this reference to the game's
actual tower footprint, preserving the original overhang and ground anchor.

The tower idle layer contains 8 horizontal frames at 110 by 80 pixels. Upstream
animation speed 0.1 at 60 ticks/second gives 6 frames/second. The flying drone
contains 8 clockwise facings, each with 2 consecutive 12 by 12 pixel frames.

`FactoryDroneArt.draw_tower(canvas, footprint_rect, tint)` draws the model.
`icon_texture()` returns a full-body AtlasTexture.
`draw_drone(canvas, position, heading, scale_factor)` accepts canvas radians
(east 0, south PI/2) and uses an 18-pixel base size. Visual animation uses wall
time only; no economic or saved state is accessed or changed.

## Reproduction and checks

`python tools/import_drone_art.py` recopies the two pinned local author checkouts
into the owned asset pack and records hashes. `--krastorio` and `--openhv` accept
alternative local checkout roots. The upstream Lua and license snapshots here
are retained. `python tools/import_drone_art.py --check` validates hashes, alpha,
dimensions, frame metadata, and source/attribution files without external paths.

The integration agent runs Godot import and UI verification serially. No game
runtime or screenshot is claimed by the asset-only validator.
