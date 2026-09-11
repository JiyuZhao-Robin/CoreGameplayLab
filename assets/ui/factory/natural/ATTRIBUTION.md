# Factory natural terrain art attribution

This directory contains source copies and project-authored sprite atlases used
for Factory terrain.  The ground files are kept as unmodified originals.
`iron-ore.png` and `copper-ore.png` are not third-party ore art: they are
project-authored Blender renders of instances of the CC0 Poly Haven
`boulder_01` model, with explicitly documented iron and copper material
derivations.

## CC0 sources

* **Poly Haven contributors** — `aerial_grass_rock`, `aerial_sand`, and
  `boulder_01`; CC0 1.0. <https://polyhaven.com/license>
* **ambientCG contributors** — `Ground037` and `Rock030`; CC0 1.0.
  <https://docs.ambientcg.com/license/>

## MIT source

* **Petrak / gamma-delta** — `ice-ore.png` from `the-first-frontier`, MIT.
  The precise upstream revision and blob hash are recorded in `manifest.json`.

Every copied or generated output has an SHA-256 in `manifest.json`.  It also
records the direct source URL, license, input hashes, source revision where one
exists, and Blender generator settings.  Derived ore entries are only written
after `source/render-receipt.json` proves that the current model, diffuse
texture, generator source, and both atlas outputs all match their recorded
SHA-256 values.
