# 4K playability and complete UI review

## Acceptance contract (user request, 2026-09-10)

- Primary visual acceptance target: 3840 × 2160, 16:9. Reconcile the old
  1440 × 900 design contract before implementation; never add per-workspace
  window-scale compensation or separate drawing/input transforms.
- Whole workspaces, navigation and primary actions must fit without page-level
  scrolling. Growing lists may scroll inside explicitly bounded panels.
- Review every top-level page, local tab and material modal state with rendered
  screenshots. Record each surface, findings, design target and final result.
- Improve information density through purposeful consolidation, not filler.
- Concept → independent design review → implementation → screenshot review.
- Use short focused functional/flow tests, not J1–J10 or release umbrellas.

## Pre-wave baseline

Prior industrial-refactor changes remain uncommitted and must be preserved:
application/factory domain, Main/shell, factory workspace/palette/canvas, locale
catalogs, content, focused tests, new operations projection/presenter/overview,
original art and concept/QA documents. These belong to the previous accepted
iteration; new edits must build on them rather than reverting to Git HEAD.

An additional pre-existing user change in `project.godot` removes the explicit
`window/stretch/aspect="keep"` setting. Do not silently discard this change;
resolve it deliberately as part of the new 4K design/scaling contract.

### Discovery wave ownership

| Track | Writer / ownership | Existing dirty paths | Verification effects |
| --- | --- | --- | --- |
| Primary | this record; later capture harness and shared integration | previous industrial work, plus user project setting above | serialized Godot, `.godot`, ignored `artifacts/ui/4k-review/` and logs |
| Surface inventory explorer | read-only; all page/tab/modal routes and capture fixtures | no write ownership | none; no Godot |
| Canvas/scaling explorer | read-only; transforms, grids, scale policy and tests | no write ownership | none; no Godot |
| Fleet/research layout explorer | read-only; overflow, empty regions and extraction seams | no write ownership | none; no Godot |

Writing-wave assignments will be recorded after shared contracts and designs
are established. Only the primary runs Godot in this shared checkout.

## Proposed design for independent review

### Released-game references and adaptation

- [Factorio FFF 405](https://www.factorio.com/blog/post/fff-405) uses a network
  overview with local logistics information while leaving ordinary building
  controls available. Adaptation here: contextual inventory details and
  independent list panels beside the active work surface, not another global
  navigation page for every small function.
- [Factorio FFF 348](https://www.factorio.com/blog/post/fff-348) discusses its
  coordinated GUI update and higher-resolution icons for 200% UI rendering.
  Adaptation: test actual 4K raster output, retain high-resolution placed ship
  artwork and lightweight library previews, and do not stretch the concept PNG
  into an interactive interface.
- [Stellaris Aquatics/3.2 notes](https://www.paradoxinteractive.com/games/stellaris/news/aquatics-species-pack-releases-november-22nd)
  describe fleet-manager fixes around real command limits and single-ship
  fleets. Our design inference: the roster must remain useful with the one real
  starter ship; show real assignment and maintenance actions rather than
  illustrative fleet counts or invented ship specifications.

The reference material supports interaction principles, not copying another
game's assets. The three generated concepts in `docs/art/4k/` are original
layout studies, reviewed for placeholder data before implementation.

- One 1920 × 1080 logical design, rendered at exactly 2× in 3840 × 2160.
  Preserve `canvas_items`/`keep`, manual accessibility scale and independent
  world cameras; remove no-scale exceptions calibrated to old fleet captures.
- Compact full-width shell: status header, six purpose-group navigation entries
  (territory, industry, supply, research, fleet, engineering), diagnostics as a
  utility action. Keep all existing route IDs and command nodes as deep links.
- No permanent duplicated resource rail, location inspector and large command
  dock around every page. Context appears where decisions use it; retain useful
  research selection inspector and a compact universal status/Back/task strip.
- Research: current-project command strip above a bounded graph; selection
  details beside it. Replace the duplicate horizontal all-project button strip
  with a compact project chooser/search without removing node actions.
- Fleet: Registry, Task Force, Shipyard; archive becomes contextual service
  content rather than a full persistent tab. Registry lower area contains real
  dispatch/maintenance/formation information. No fake telemetry or filler.
- Shipyard: elastic three-column editor plus bounded horizontal design/build/
  refit handoff dock, not a second page below a minimum-680px editor.
- Operational pages use dense rows and semantic side-by-side sections, with
  pinned titles/search/actions and internal list scrolling only.
- Industry: retain the approved command-center visual language, expand to16:9,
  fix grid/tile/hit alignment and remove misleading minimum-size icon hit areas.

### Art/design wave ownership

| Owner | Exclusive write paths | Pre-existing dirty paths | Side effects |
| --- | --- | --- | --- |
| Primary | shared proposal, capture harness; fleet/master concept | existing baseline above | generated concept images; serial Godot |
| Research art worker | new `docs/art/4k/research-command-concept.png`, new `docs/art/4k/research-concept-prompt.md` | none | built-in ImageGen cache + the two owned files; no Godot |
| Independent reviewer | read-only proposal and screenshot review | none owned | none |

The art directory is under the existing `docs/art/.gdignore`; concepts do not
become runtime textures. Final implementation contracts are frozen after review.

## Review disposition / frozen integration contract

Both independent reviews accept 1920×1080 logical → 4K exactly2×. Baseline
runtime still forces keep-aspect despite the missing project setting, explaining
the observed3456×2160 content rather than distortion. The project setting will
be made explicit under the new16:9 contract, not restored as an unexplained edit.

Adopt review conditions: visible group-level sibling navigation and route
context; preserve all deep links; no hiding/clipping to fake workspace fit;
explicit named internal scrolling regions; active build/refit/service always
discoverable without archive; dense inventory rows; bounded stage/details for
engineering; contextual rather than duplicated guide paragraphs.

The fleet concept was inspected by primary. Accept layout/material language,
but reject its illustrative food/population/currency and invented specifications
as runtime content. Existing authoritative telemetry and original ship artwork
remain the implementation source. Reviewer checks for all remaining concepts
and final screenshots are required.

### Implementation wave A ownership

| Owner | Exclusive write paths | Pre-existing dirty paths | Verification effects |
| --- | --- | --- | --- |
| Primary | Main/shell/theme/policy/project, shared navigation/locales, operational page composition, capture and integration tests, documentation | all prior industrial integration changes; user project setting | all Godot runs serialized; `.godot`, ignored artifacts/logs |
| Factory 4K worker | `src/ui/workspaces/factory/factory_canvas.gd`; new `tests/factory_canvas_grid_contract_test.gd` | canvas contains accepted prior art/LOD/operational-framing changes, preserve them | static checks only; primary runs Godot |
| Ship editor worker | `src/ui/components/ship_assembly_blueprint_editor.gd`, `ship_assembly_library.gd`, `ship_assembly_data_panel.gd`, `ship_assembly_map_view.gd`, `ship_assembly_connection_layer.gd`; new focused `tests/ship_editor_fit_contract_test.gd` | none | static checks only; primary runs Godot |

Factory worker fixes coordinate/selection/texture contracts without changing
overview layout. Ship editor keeps public signals/nodes/domain commands stable;
Main owns outer shipyard handoff and fleet roster consolidation.

Wave A handoffs received: Factory and Ship Editor ownership released. Factory
follow-up fixes visual-icon selection separately from physical footprint, with
the same two-file ownership and no Godot side effects. Ship editor follow-up
owns only clean `src/ui/components/research_tree_view.gd` and new
`tests/research_camera_contract_test.gd` for bounded height and stable camera;
all other paths forbidden, no Godot or generated verification output. Research
agent reviews concepts and short-test coverage read-only. Primary remains sole
owner of Main, catalogs, layout contracts, and serial runtime verification.

Following read-only audit, Research agent owns only focused test expectation
updates in `responsive_ui_policy_test.gd`, `responsive_ui_matrix_test.gd`, and
`ui_scale_contract_test.gd`; matrix prior industrial changes are preserved.
No Godot runs or artifact writes delegated. All product paths are forbidden.

Wave B: Factory worker owns only prior-dirty
`factory_operations_overview.gd` (preserve accepted snapshot/actions/art) and new
`tests/factory_overview_fit_contract_test.gd`. It replaces whole-overview
scrolling with bounded regions after the first 4K screenshot review. All other
paths forbidden; static checks only. Primary owns every integration/test run.

Wave C QA: Factory worker has released all product ownership and owns only new
`tests/command_workspace_flow_test.gd` and its scene. It validates real command
effects, grouped navigation and bounded controls without running Godot.
No pre-existing dirty paths in this lane; all other paths forbidden.

Wave C corrective writer: Research agent owns only prior-dirty
`src/ui/workspaces/factory/factory_workspace.gd` and new
`tests/factory_empty_state_actions_test.gd`, preserving accepted industrial
changes. Adds empty-state build intents through the existing UI adapter; no
simulation/state authority changes. All other files forbidden, static only.

Art worker follow-up owns only new `docs/art/4k/operations-layout-board.png`
and `docs/art/4k/operations-layout-prompts.md` (no existing dirty files), plus
built-in ImageGen cache. Four coordinated layout studies cover Territory,
Supply, Industry and Engineering. No product edits or Godot runs permitted.
# Final correction wave

Pre-wave status: the industrial baseline and this turn's 4K changes remain dirty; no Git operations are authorized. All existing edits are preserved.

| Owner | Exclusive write paths | Existing changes | Verification side effects |
| --- | --- | --- | --- |
| Primary | main.gd, locales, capture harness, report | Current integrated 4K work | Serial Godot `.godot`, ignored artifacts |
| Ship editor worker | ship_assembly_blueprint_editor.gd, ship_editor_fit_contract_test.gd | Its accepted 4K editor implementation | Static only; primary runs Godot |
| Factory QA worker | command_workspace_flow_test.gd/.tscn | New test from preceding wave | Static only; primary runs Godot |
| Industrial reviewer | factory_build_palette.gd | Existing industrial palette | Static only; primary runs Godot |

After QA test handoff, Factory QA ownership moves exclusively to the existing
`tests/ui_4k_review_capture.gd` to extend transient/modal coverage. Primary stops
editing that file until handoff; all product files remain forbidden to QA.

## Final implementation and acceptance

The production Main scene now uses the 1920 × 1080 design surface and exact
2× presentation at 3840 × 2160. The former 1440 × 900 content occupied only
3456 × 2160 at 4K. No physical-window breakpoints, automatic text scaling or
workspace-specific input compensation were introduced.

- Six main destinations replace the long peer-tab strip; Diagnostics is a
  utility destination. Territory and Supply expose contextual sibling routes.
- Fleet has three working tabs. Missions, Expeditions and Service/Archive are
  explicit contextual actions; the roster includes live dispatch/maintenance.
- Research keeps its graph, project selector, progress and local inspector on
  one screen. Shipyard uses library/canvas/engineering columns with an attached
  designs/orders dock. Inventory is an aligned ledger with an in-place inspector.
- System Map, locations, logistics, expeditions, engineering and diagnostics
  use bounded content regions. Outer workspace scrolling is disabled only after
  their content is fitted; the capture harness checks actual content bounds,
  minimum sizes and interactive descendants, not merely hidden scrollbars.
- Factory overview, production, construction and canvas were rechecked. Grid
  rendering, footprint placement, hit testing, links and world-origin texture
  phase share the same projection; icon hit assistance does not enlarge an
  authoritative building footprint. Empty production/construction pages emit
  existing build intents, not simulation mutations.
- Unsaved ship drafts, names, selection, library tab and world camera survive
  editor reconstruction. Main preserves this UI-only session across page/locale
  rebuilds and explicit accessibility reloads; no duplicate saved-design authority.
- Final visual review corrected locale-dependent roster truncation, fragmented
  formation captions, stale location tab focus, duplicate research headings,
  palette-count clipping and insufficient destructive-confirmation emphasis.

Original ImageGen concept studies influenced the panel hierarchy, navy/cyan
material language, roster image/data balance and graph/inspector composition.
Runtime controls remain native and consume real state; concept placeholder
statistics and invented ship specifications were deliberately not implemented.

### Screenshot evidence

All paths below are under `artifacts/ui/4k-review/`. These are ignored generated
evidence, not runtime assets or committed screenshots. Each review index records
the physical image size, logical viewport, active page/content rectangles,
bounded scroll regions and strict failures.

| Final collection | PNGs | Coverage | Result |
| --- | ---: | --- | --- |
| `final-fresh/` | 34 | All Main pages/local tabs, assembly selections, seven roster transients, dispatch and reset | PASS; strict failures 0 |
| `final-english/` | 34 | Same inventory with longer English copy | PASS; strict failures 0; text issues corrected and independently re-reviewed |
| `final-developed/` | 31 | Existing `open_jovian` snapshot, larger inventory/fleet and contextual empty states | PASS; strict failures 0 |
| `final-factory/` | 8 | Real command-built devices, power/cargo links, production and construction; selected machine/order | PASS |
| `final-research-active/` | 3 | Recorded prototype-blocked research, selected project and reset modal | PASS; strict failures 0 |
| `final-megastructure-active/` | 2 | Phase-four project/worksite bottleneck and reset modal | PASS; strict failures 0 |

Total: **112 final-state 3840 × 2160 images**. Repeated pages across locales and
states are intentional coverage, not 112 distinct game pages. Every indexed Main
tab has a screenshot; this is not a claim to enumerate every possible simulation
state or development-only standalone demo scene.

Representative baseline whole-page vertical overflow was Research 335 logical
pixels, Shipyard 152, Expedition 1429 and Megastructure 1087; the final captured
workspace outer overflow is 0. Graph cameras and explicitly bounded lists still
scroll by design. All final fresh/English surfaces received independent manual
image review; the primary inspected representative final developed, active
research/engineering and command-built industrial images and owns acceptance.

The old recorded development fixtures predate current Factory bootstrap and may
have no Factory world. Their honest initialization/empty state was reviewed;
industrial execution evidence comes from `final-factory`, which builds through
normal application commands rather than fabricating screenshot values.

### Primary-run focused verification

All checks below were actually run by the primary, with unrestricted direct
Godot execution, captured output and successful exit codes. Final accepted runs
contained no script errors. Tests run in seconds, not hours. Static-only agent
reports are separate from these runtime results.

| Test | Result |
| --- | --- |
| `responsive_ui_policy_test.tscn` | PASS: fixed 16:9 design/letterboxing, no window-driven Theme changes |
| `ui_scale_contract_test.tscn` | PASS: explicit scales and reachable persistent actions |
| `responsive_ui_matrix_test.tscn` | PASS: six physical window sizes; unchanged shell and Factory/Ship cameras |
| `factory_canvas_grid_contract_test.gd` | PASS: nonzero origins, exact footprints, selection, port endpoints, grid/texture phase |
| `factory_overview_fit_contract_test.gd` | PASS: overview fits; only named internal lists scroll |
| `factory_empty_state_actions_test.gd` | PASS: empty-state actions return to real build flow |
| `ship_editor_fit_contract_test.gd` | PASS: 100/125/150% component fit and UI-only draft/session restoration |
| `research_camera_contract_test.gd` | PASS: initial focus, selection, refresh and camera preservation |
| `command_workspace_flow_test.gd` | PASS: visible navigation/Supply, real Fleet commands, assembly, page/locale session retention and research refresh |
| `factory_workspace_main_integration_test.gd` | PASS: selected world, guidance, canvas/inspector and fixed-layout integration |
| `factory_industrial_loop_test.gd` | PASS: focused industrial loop |
| `factory_grid_simulation_test.gd` | PASS: mining/production/logistics/construction foundation |
| `asset_conservation_test.gd` | PASS: Factory bootstrap, fleet/shipment custody and consumption |
| `operational_formation_test.gd` | PASS: real tactical formation and Factory-only work boundary |
| `ui_domain_integrity_test.tscn` | PASS: static state-authority/source contracts |
| `localization_catalog_test.tscn` | PASS: bilingual key alignment |

`git diff --check` passed. Earlier parser failures and one stale test expecting
page-level AUTO scrolling were corrected and rerun; those failed runs are not
counted as acceptance. The invalid newly created SceneTree-as-Node test scene
was removed; its retained `.gd` entry point is run using `--script`.

No J1–J10 runtime chain, release umbrella or full-game progression/balance claim
was made. The older aggregate UI accessibility/ship-assembly suites still encode
retired rail/tab/page-scroll expectations and were not used as this feature's
acceptance gate. Some genuinely empty initial lists still have spare room;
we do not invent telemetry to fill it. Deep content progression and sustained
late-game performance remain separate from this UI/playability handoff.

### Reproduce

For SceneTree tests use `--script`; `.tscn` entries run as scenes. On Windows
pipe direct Godot output to `Out-Host` so PowerShell waits for the GUI executable,
then propagate `$LASTEXITCODE`. Rendered screenshot runs must not use headless.

```powershell
& D:/Godot/godot.exe --path D:/Projects/standalone/core_gameplay_lab --script res://tests/ui_4k_review_capture.gd -- --no-persistence --ui-scale=1.25 --ui-audit-fast-refresh --review-strict --review-output=res://artifacts/ui/4k-review/final-fresh | Out-Host
exit $LASTEXITCODE
```
