# Approved industrial building production art

Artwork © Hurricane046, [Factorio Buildings](https://www.figma.com/proto/y1IQG08ZG2jIeJ5sTyF4MP/Factorio-Buildings), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

Source layers processed by brickbrycebrick / [Nullius Hurricane Reskins](https://github.com/SmokeStackGG/nullius-visual-overhaul), revision `852d736052fbf32c22cb04102ce82367b12800d0`. See [LICENSE.txt](LICENSE.txt) for upstream notices and MIT definition license.

Derived locally from the four approved candidates: crop all animation frames, preserve source offsets on the union of body, mask and emission bounds, apply copper-gold mask #c49352, add emission while retaining body alpha, and resize each frame to 256 px maximum body dimension. Shadows remain separate at original offsets (caller uses opacity 0.48). Timing is the reviewed local 30 fps. Thermal Plant uses the reviewed 5×6 ground rectangle centered at (0.5, 0.55) of its source base; other candidates retain their reviewed square ground references. Runtime uses uniform fitting to preserve proportions. Art metadata does not define gameplay collision, recipes or rates.

Rebuild: `python tools/build_approved_industry_art.py`; verify: add `--check`. All inputs live inside this project.
