# Dyson Sphere Program local extraction

This directory contains a local, untracked extraction from:

`D:\steam\steamapps\common\Dyson Sphere Program\DSPGAME_Data`

- Extractor: UnityPy 1.25.3
- Unity player version detected separately: 2022.3.62f3
- Exported forms: Texture2D/Sprite to PNG, Mesh to OBJ, Material metadata to JSON,
  Shader text, and embedded Font data.
- These files remain copyrighted by their respective rights holders. Possession of
  the game does not automatically grant redistribution or commercial-use rights.
- The repository's existing `.gitignore` excludes this directory from Git.
- No encrypted archive, DRM, or executable code was modified or bypassed.

`manifest.jsonl` maps every successfully exported file back to its Unity object.
`errors.jsonl` lists objects that the open-source decoder could not export.
`inventory.json` contains source object counts, including non-visual Unity objects.
