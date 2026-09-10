# DSP Online icon atlases — provenance

Generated on 2026-09-10 with the built-in `image_gen.imagegen` tool
(`gpt-image-2.0`).  These are raster source assets, not placeholder geometry.
The source-order below is the canonical `art_index` row-major order supplied by
the content lane.  UV consumers must use normalized coordinates because the
generator selected non-integer cell pixel dimensions.

## `buildings_atlas_v1.png`

- Grid: 8 columns × 5 rows (40 cells)
- Output: 1586 × 992 RGBA PNG
- Cells 0–38: source building order; cell 39: `unknown`
- Built-in output copied from: `/Users/zhaojiyu/.codex-personal/generated_images/01a08924-f1be-77a0-abd7-b837172cc740/exec-02f469b7-068b-4c9e-baa1-f8f2ca4e5084.png`

### Prompt submitted

```text
Use case: stylized-concept
Asset type: production game building icon atlas with genuine transparent background
Primary request: Create exactly one strict 8 columns by 5 rows atlas of 40 isolated sci-fi industrial building icons. Every cell has equal size, equal generous transparent padding, and contains one individually recognizable physical building. All cells must be transparent outside their object; no colored cell backgrounds, no grid lines, no gutters, no borders, no labels, no numbers, no text. Use a consistent polished 3D-painted three-quarter top-down strategy-game icon camera and visual language: dark gunmetal, brushed steel, olive panels, cyan/teal energy emissives, restrained orange indicators, readable at 160px.
Composition/framing: exact row-major order with 8 equal columns and 5 equal rows, icons centered in their invisible cells, no overlap across cells. This is an atlas, not a single scene.
Row 1 cells 0-7: 0 wind_turbine: slim industrial mast with three visible turbine blades; 1 solar_panel: compact tilted blue solar array; 2 geothermal_power_station: reinforced geothermal drill head with heat pipes; 3 thermal_power_plant: compact furnace generator with paired smokestacks; 4 mini_fusion_power_plant: small contained fusion reactor with teal chamber; 5 artificial_star: advanced glowing stellar reactor sphere in a heavy cradle; 6 accumulator: industrial battery block with cyan charge indicator; 7 energy_exchanger: power exchange tower with capacitor coils.
Row 2 cells 8-15: 8 mining_machine: tracked ore drill with cutter head; 9 arc_smelter: arc furnace with orange molten opening; 10 plane_smelter: advanced flat blue-white energy smelter; 11 assembling_machine_mk1: small simple robotic assembly cabinet; 12 assembling_machine_mk2: medium assembler with more arms and teal panels; 13 assembling_machine_mk3: large premium assembler with advanced teal core; 14 spray_coater: compact belt spray applicator with nozzle; 15 matrix_lab: research laboratory with colored matrix cube chamber.
Row 3 cells 16-23: 16 oil_extractor: oil derrick and pump pipes; 17 oil_refinery: refinery tower with tanks and pipework; 18 water_pump: shoreline pump station with intake pipe; 19 chemical_plant: chemical reactor vessels and pipes; 20 quantum_chemical_plant: advanced chemical plant with cyan and violet reactor glow; 21 fractionator: tall fractional distillation column; 22 miniature_particle_collider: compact circular particle accelerator rings; 23 em_rail_ejector: long electromagnetic rail launcher with dish-like launch end.
Row 4 cells 24-31: 24 ray_receiver: large tilted energy receiver dish; 25 vertical_launching_silo: vertical rocket launch silo and gantry; 26 planetary_logistics_station: compact logistics hub with drone pads; 27 interstellar_logistics_station: taller logistics hub with vessel docking towers; 28 orbital_collector: orbital gas collector with collector arms; 29 storage_mk1: small reinforced storage warehouse; 30 material_delivery_hub: material distribution hub with conveyor docking ports; 31 orbital_cargo_terminal: orbital freight terminal with cargo berth.
Row 5 cells 32-39: 32 storage_tank: tall cylindrical liquid tank; 33 splitter_4way: small four-way belt splitter module; 34 construction_center: construction manufacturing center with gantry crane; 35 galactic_material_exporter: monumental industrial export gate; 36 micro_black_hole_connector: compact containment frame around a dark teal gravity core; 37 time_warp_device: circular time-warp apparatus with luminous ring; 38 space_station_construction_launcher: heavy space-station construction launch platform; 39 Unknown: neutral fallback unidentified industrial artifact, clearly distinct but with no question mark or text.
Lighting/mood: neutral studio top light, high legibility, controlled cyan and orange highlights.
Constraints: exactly 40 individual icons in the exact specified 8×5 row-major order; physical architecture only, no emoji, no glyph substitutes, no random repeated buildings, no scene background, no people, no vehicles, no logos, no watermark, no text or symbols. Preserve alpha transparency.
```

### Canonical row-major index order

| Index | ID | Index | ID | Index | ID | Index | ID |
| ---: | --- | ---: | --- | ---: | --- | ---: | --- |
| 0 | `wind_turbine` | 1 | `solar_panel` | 2 | `geothermal_power_station` | 3 | `thermal_power_plant` |
| 4 | `mini_fusion_power_plant` | 5 | `artificial_star` | 6 | `accumulator` | 7 | `energy_exchanger` |
| 8 | `mining_machine` | 9 | `arc_smelter` | 10 | `plane_smelter` | 11 | `assembling_machine_mk1` |
| 12 | `assembling_machine_mk2` | 13 | `assembling_machine_mk3` | 14 | `spray_coater` | 15 | `matrix_lab` |
| 16 | `oil_extractor` | 17 | `oil_refinery` | 18 | `water_pump` | 19 | `chemical_plant` |
| 20 | `quantum_chemical_plant` | 21 | `fractionator` | 22 | `miniature_particle_collider` | 23 | `em_rail_ejector` |
| 24 | `ray_receiver` | 25 | `vertical_launching_silo` | 26 | `planetary_logistics_station` | 27 | `interstellar_logistics_station` |
| 28 | `orbital_collector` | 29 | `storage_mk1` | 30 | `material_delivery_hub` | 31 | `orbital_cargo_terminal` |
| 32 | `storage_tank` | 33 | `splitter_4way` | 34 | `construction_center` | 35 | `galactic_material_exporter` |
| 36 | `micro_black_hole_connector` | 37 | `time_warp_device` | 38 | `space_station_construction_launcher` | 39 | `unknown` |

## `materials_atlas_v1.png`

- Grid: 10 columns × 8 rows (80 cells)
- Output: 1402 × 1122 RGBA PNG
- Cells 0–77: source item order; cells 78–79: transparent reserved slots
- Built-in output copied from: `/Users/zhaojiyu/.codex-personal/generated_images/01a08924-f1be-77a0-abd7-b837172cc740/exec-9fb95c06-f42a-483e-aedb-cd694ab81e30.png`

### Consumption correction

The alpha-preserving image generator draft contains an extra unreferenced cyan
crystal in its first visual row.  It is therefore **not** a uniform 10×8 source
atlas despite its canvas aspect.  The checked-in asset must be consumed only via
[`materials_atlas_regions.json`](materials_atlas_regions.json): it supplies one
explicit top-left pixel rect for every canonical item ID and intentionally
omits the spurious illustration.  A subsequent in-tool rearrangement attempt
was rejected because it baked a checkerboard into an RGB image rather than
preserving alpha; that rejected output was not copied into this repository.

### Prompt submitted

```text
Use case: stylized-concept
Asset type: production game material icon atlas with genuine transparent background
Primary request: Create exactly one strict 10 columns by 8 rows atlas of 80 isolated, individually identifiable physical material/product icons. Cells 0 through 77 must follow the exact row-major order below. Cells 78 and 79 are fully transparent empty reserved slots. Every used cell has equal generous transparent padding and one centered icon; no colored cell backgrounds, no grid lines, no gutters, no borders, no labels, no letters, no numbers, no text.
Style/medium: polished detailed 3D-painted sci-fi industrial game inventory icons, consistent at 160px, dark gunmetal supports only where necessary, distinct material colors, sharp silhouettes, controlled teal energy and restrained orange metal accents. Do not make emoji or repeated generic gemstones.
Composition/framing: exact 10 equal columns by 8 equal rows, atlas only, transparent background, no overlap between invisible cells.
Row 1 cells 0-9: 0 iron_ore gray metallic ore chunks; 1 copper_ore rust-orange ore chunks; 2 coal black carbon lumps; 3 stone pale gray stone chunks; 4 crude_oil sealed dark amber oil canister; 5 silicon_ore pale green silicon rocks; 6 titanium_ore violet-gray titanium rocks; 7 fire_ice cyan frozen gas crystal; 8 kimberlite_ore diamond-bearing dark rock; 9 fractal_silicon mint fractal lattice crystal.
Row 2 cells 10-19: 10 optical_grating_crystal gold ridged optical crystal; 11 spiniform_stalagmite_crystal long gray-green nanotube-like crystal spikes; 12 unipolar_magnet blue magnetic stone with field ring; 13 water clear cyan industrial fluid canister; 14 sulfuric_acid yellow-green acid bottle; 15 iron_ingot silver metal ingot; 16 copper_ingot copper ingot; 17 magnet industrial blue-red permanent magnet; 18 stone_brick tan masonry brick; 19 glass translucent teal glass pane.
Row 3 cells 20-29: 20 steel dark structural steel plate; 21 gear brass engineering gear; 22 magnetic_coil wound copper electromagnetic coil; 23 circuit_board green printed circuit board; 24 prism transparent triangular optical prism; 25 plasma_exciter orange-cyan plasma excitation device; 26 energetic_graphite black dense graphite bars; 27 refined_oil amber refined-oil barrel; 28 hydrogen pale-cyan pressurized gas cylinder; 29 high_purity_silicon clean teal silicon crystalline ingot.
Row 4 cells 30-39: 30 titanium_ingot lavender titanium bar; 31 titanium_alloy layered titanium alloy billet; 32 microcrystalline_component green microcrystalline component; 33 processor dark advanced CPU chip; 34 logistics_drone tiny teal logistics flying drone; 35 logistics_vessel compact orange cargo vessel; 36 space_warper purple warp torus device; 37 accumulator uncharged industrial battery; 38 charged_accumulator glowing charged battery; 39 graphene stacked black hexagonal graphene sheets.
Row 5 cells 40-49: 40 carbon_nanotube curled carbon nanotube bundle; 41 proliferator_mk1 olive spray reagent capsule; 42 proliferator_mk2 green enhanced spray capsule; 43 proliferator_mk3 blue premium spray capsule; 44 crystal_silicon pale green lattice silicon crystal; 45 particle_broadband violet particle data-fiber bundle; 46 electric_motor blue industrial electric motor; 47 electromagnetic_turbine teal electromagnetic turbine; 48 super_magnetic_ring bright cyan magnetic containment ring; 49 particle_container glass-and-metal particle containment cylinder.
Row 6 cells 50-59: 50 deuterium cyan isotope pressure flask; 51 hydrogen_fuel_rod light-blue fuel rod; 52 deuteron_fuel_rod saturated-blue nuclear fuel rod; 53 titanium_glass reinforced translucent titanium glass panel; 54 casimir_crystal green-blue quantum crystal; 55 plane_filter blue planar filter frame; 56 quantum_chip deep-blue quantum processor chip; 57 strange_matter purple exotic matter vial; 58 graviton_lens green gravity lens; 59 photon_combiner gold optical photon-combining device.
Row 7 cells 60-69: 60 solar_sail folded gold reflective solar sail; 61 critical_photon bright white photon containment orb; 62 antimatter magenta anti-matter containment vial; 63 annihilation_constraint_sphere dark contained annihilation sphere with braces; 64 antimatter_fuel_rod violet-black fuel rod; 65 frame_material teal structural truss frame; 66 dyson_sphere_component advanced triangular Dyson construction module; 67 small_carrier_rocket compact orange launch rocket; 68 diamond brilliant clear diamond crystal; 69 plastic pale polymer pellets pack.
Row 8 cells 70-79: 70 organic_crystal green organic crystal cluster; 71 titanium_crystal lavender titanium crystal; 72 electromagnetic_matrix glowing blue research matrix cube; 73 energy_matrix glowing red research matrix cube; 74 structure_matrix glowing yellow research matrix cube; 75 information_matrix glowing purple research matrix cube; 76 gravity_matrix glowing green research matrix cube; 77 universe_matrix luminous white multicolor final research matrix cube; 78 empty transparent reserved cell; 79 empty transparent reserved cell.
Constraints: exactly 80 cells in the exact specified 10×8 row-major order; actual physical materials, containers, electronics, fuel rods, vehicles, and matrix cubes must be visibly distinct; no official DSPONLINE logos, no emoji, no glyph substitutes, no random repeated shapes, no scene background, no UI frame, no watermark, no text. Preserve alpha transparency.
```

### Canonical row-major index order

| Index | ID | Index | ID | Index | ID | Index | ID | Index | ID |
| ---: | --- | ---: | --- | ---: | --- | ---: | --- | ---: | --- |
| 0 | `iron_ore` | 1 | `copper_ore` | 2 | `coal` | 3 | `stone` | 4 | `crude_oil` |
| 5 | `silicon_ore` | 6 | `titanium_ore` | 7 | `fire_ice` | 8 | `kimberlite_ore` | 9 | `fractal_silicon` |
| 10 | `optical_grating_crystal` | 11 | `spiniform_stalagmite_crystal` | 12 | `unipolar_magnet` | 13 | `water` | 14 | `sulfuric_acid` |
| 15 | `iron_ingot` | 16 | `copper_ingot` | 17 | `magnet` | 18 | `stone_brick` | 19 | `glass` |
| 20 | `steel` | 21 | `gear` | 22 | `magnetic_coil` | 23 | `circuit_board` | 24 | `prism` |
| 25 | `plasma_exciter` | 26 | `energetic_graphite` | 27 | `refined_oil` | 28 | `hydrogen` | 29 | `high_purity_silicon` |
| 30 | `titanium_ingot` | 31 | `titanium_alloy` | 32 | `microcrystalline_component` | 33 | `processor` | 34 | `logistics_drone` |
| 35 | `logistics_vessel` | 36 | `space_warper` | 37 | `accumulator` | 38 | `charged_accumulator` | 39 | `graphene` |
| 40 | `carbon_nanotube` | 41 | `proliferator_mk1` | 42 | `proliferator_mk2` | 43 | `proliferator_mk3` | 44 | `crystal_silicon` |
| 45 | `particle_broadband` | 46 | `electric_motor` | 47 | `electromagnetic_turbine` | 48 | `super_magnetic_ring` | 49 | `particle_container` |
| 50 | `deuterium` | 51 | `hydrogen_fuel_rod` | 52 | `deuteron_fuel_rod` | 53 | `titanium_glass` | 54 | `casimir_crystal` |
| 55 | `plane_filter` | 56 | `quantum_chip` | 57 | `strange_matter` | 58 | `graviton_lens` | 59 | `photon_combiner` |
| 60 | `solar_sail` | 61 | `critical_photon` | 62 | `antimatter` | 63 | `annihilation_constraint_sphere` | 64 | `antimatter_fuel_rod` |
| 65 | `frame_material` | 66 | `dyson_sphere_component` | 67 | `small_carrier_rocket` | 68 | `diamond` | 69 | `plastic` |
| 70 | `organic_crystal` | 71 | `titanium_crystal` | 72 | `electromagnetic_matrix` | 73 | `energy_matrix` | 74 | `structure_matrix` |
| 75 | `information_matrix` | 76 | `gravity_matrix` | 77 | `universe_matrix` | 78 | `reserved_empty` | 79 | `reserved_empty` |
