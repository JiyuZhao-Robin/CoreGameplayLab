# Player Action Registry

`data/player_action_registry.json` is the machine-readable inventory of player actions audited across `src/ui/main.gd` and `src/application/game.gd`. It records the player-facing entry point, Domain command, required context, unlock conditions, persistence relevance, and explicit success/failure contracts.

## Coverage boundary

The registry claim is `STATIC_SOURCE_CONTRACT_ONLY`.

For a core action, `verified: true` means static source tracing found both:

1. A concrete player-facing `Control` callback in `src/ui/main.gd` that references the action's `Game.*` command.
2. A matching command function in `src/application/game.gd` plus non-empty success and failure contracts in the registry.

It does **not** mean a runtime UI Journey was executed. Top-level `uiJourneyCoverage` therefore remains `UNVERIFIED`. A future Journey may claim runtime coverage only when it instantiates the real UI, reaches the control by normal navigation, executes it against a legal Domain scenario, observes the gameplay result and rejection feedback, and performs save/load checks where applicable.

`tests/player_action_registry_test.gd` is intentionally a static contract/source test. It prevents missing or relabelled core actions, dead Domain symbols, empty entry points, empty outcome contracts, and accidental runtime-verification claims. It does not simulate clicks or claim visual/interaction coverage.

## Corrected audit conclusions

### Retired production AUTO action

`SET_PRODUCTION_CONTROL_AUTO` is not a player action and is absent from the registry.

- The UI only builds `PINNED` and `OFF` controls at `src/ui/main.gd:604-607`.
- `Game.set_production_line_control()` explicitly accepts only `PINNED` and `OFF` at `src/application/game.gd:619-625`.
- Authorized automation uses normal pause/resume commands and does not restore an `AUTO` alias.

### Ship-module install and removal

Both actions have real player-facing controls and are statically verified:

- `INSTALL_SHIP_MODULE`: the Fleet roster builds named `InstallModule_*` buttons and binds `Game.install_ship_module` at `src/ui/main.gd:2160-2172`; the command is defined at `src/application/game.gd:1695-1703`.
- `REMOVE_SHIP_MODULE`: the Fleet roster builds named `RemoveModule_*` buttons and binds `Game.remove_ship_module` at `src/ui/main.gd:2173-2186`; the command is defined at `src/application/game.gd:1706-1716`.

The separate runtime harness now verifies both named actions against real Starport refit projects. This static section remains intentionally distinct from runtime evidence.

## Declared core player actions

The fixed core inventory contains 57 actions. The test requires this exact inventory, so an action cannot be hidden by changing `coreGameplay` to `false`.

| System | Core actions |
| --- | --- |
| Persistence | `SAVE_GAME` |
| Survey and extraction | `START_SURVEY_MISSION`, `DEVELOP_SITE`, `START_EXTRACTION`, `STOP_EXTRACTION`, `INTEGRATE_EXTRACTION_SITE` |
| Production and industrial growth | `START_PRODUCTION`, `STOP_PRODUCTION`, `CHANGE_PRODUCTION_METHOD`, `ADD_PRODUCTION_LINE`, `CHANGE_PRODUCTION_PRIORITY`, `SET_PRODUCTION_CONTROL_PINNED`, `SET_PRODUCTION_CONTROL_OFF`, `EXPAND_FACTORY`, `UPGRADE_SCALE_STAGE`, `ADOPT_INDUSTRIAL_TRANSFORMATION`, `UPGRADE_LOCATION_CAPACITY`, `INSTALL_FACILITY_MODULE`, `INSTALL_MANUFACTURING_MODULE`, `UNINSTALL_MANUFACTURING_MODULE`, `SET_ADVANCED_POWER_PRIORITY` |
| Logistics | `SET_LOGISTICS_POLICY`, `CLEAR_LOGISTICS_POLICY`, `CHANGE_TRANSPORT_MODE`, `ASSIGN_LOGISTICS_SHIP`, `CHANGE_ROUTE_PRIORITY`, `SET_ROUTE_PAUSED` |
| Construction | `START_CONSTRUCTION`, `PAUSE_CONSTRUCTION`, `RESUME_CONSTRUCTION`, `CHANGE_PROJECT_PRIORITY`, `CANCEL_CONSTRUCTION`, `ASSIGN_CONSTRUCTION_SUPPORT`, `RELEASE_CONSTRUCTION_SUPPORT` |
| Research | `START_RESEARCH`, `SELECT_RESEARCH_ROUTE`, `STOP_RESEARCH` |
| Ships and fleet readiness | `BUILD_SHIP`, `REORDER_SHIP_BUILD`, `CANCEL_SHIP_BUILD`, `ASSIGN_SHIP`, `SET_FLEET_SUPPLY_PLAN`, `RESUPPLY_FLEET`, `SET_FLEET_DOCTRINE`, `SET_RETREAT_POLICY`, `SET_COMBAT_ZONE`, `APPLY_SHIP_LOADOUT`, `REPLACE_SHIP_MODULE`, `INSTALL_SHIP_MODULE`, `REMOVE_SHIP_MODULE`, `CANCEL_SHIP_REFIT` |
| Expedition and combat | `START_EXPEDITION`, `RECALL_EXPEDITION`, `START_COMBAT_ACTION` |
| Megastructure | `SELECT_MEGASTRUCTURE_SITE`, `START_MEGASTRUCTURE_PHASE`, `CANCEL_MEGASTRUCTURE_PHASE` |

Support actions such as game speed, reset, maintenance state, loadout naming/deletion, scrap, and automation-rule administration remain registered but are not part of the fixed core inventory. Public Domain APIs without a reachable player control remain non-core and unverified; a helper function alone is not accepted as a UI entry point.

## Contract fields

| Field | Meaning |
| --- | --- |
| `actionId` | Stable action identifier. |
| `domainCommand` | Concrete `Game.*` write command reached by the UI. |
| `requiredContext` | State required before the action is meaningful. |
| `uiEntryPoints` | Player navigation/control description plus source location. |
| `unlockedBy` | Progression or capability gates. |
| `expectedSuccessResult` | Observable gameplay consequence after Domain acceptance. |
| `expectedFailureReasons` | Required rejection contract; every core action has at least one reason. |
| `saveRelevant` | Whether the gameplay consequence belongs to persistent state. |
| `coreGameplay` | Membership in the fixed 57-action core inventory. |
| `verified` | Static UI-to-Domain source trace only. |

## Runtime UI Journey requirements

A future action Journey must:

1. Build a legal scenario through ordinary Domain setup and commands.
2. Instantiate the actual game shell and navigate to the registered surface.
3. Find the real enabled control, not call the callback or Domain command directly.
4. Activate the control and observe success feedback plus the authoritative state change.
5. Exercise at least one legal rejection and observe the player-facing failure message.
6. For persistent actions, save/load and confirm the UI derives the same result.
7. Record runtime coverage separately without changing static source evidence into a Journey claim.

Directly invoking a target action through `Game.*`, assigning runtime state, manufacturing a fake button, or only parsing this JSON cannot satisfy those requirements. Round 7 uses direct normal Construction commands only as disclosed scenario setup for the otherwise unreachable `INDUSTRIAL_COMPLEX` prerequisite; the target Add Line action itself still enters through the real named MainScene control.

## Runtime four-case evidence

`tests/ui_action_coverage_test.gd` is the separate runtime evidence harness. It instantiates the real `MainScene`, navigates through visible controls, and records the following four independent gates per action:

1. **Success** — a visible, enabled control submits an accepted Domain command.
2. **Failure** — a visible disabled control prevents an invalid submission, or a still-live visible control receives a structured Domain rejection that is rendered in Alerts / Timeline.
3. **Consequence** — the authoritative `SpaceGameState` reflects the intended gameplay result.
4. **Persistence** — `SpaceGameState.to_dictionary()` → `from_dictionary()` retains that result.

For ordinary gameplay actions, the fourth gate is deliberately labelled `DOMAIN_SERIALIZE_DESERIALIZE_ONLY` in `artifacts/test-results/ui-action-coverage.json`; it is not a disk Save/Load claim. `SAVE_GAME` is the sole exception: its Success, Consequence, and Persistence gates are imported only from the separately passed `artifacts/test-results/ui-persistence-audit.json`, whose writer and reader run with uniquely redirected `APPDATA` / `LOCALAPPDATA`. That evidence proves the visible `SaveButton` wrote the isolated `LocalSaveRepository`, startup restored the same save identity/revision, and the UI-created fleet assignment was present in the loaded Domain state and visible Ships page. The no-persistence action suite independently proves Save's structured unavailable failure and never writes `user://`. Golden Scenario checkpoints are likewise only legal, invariant-preserving test setup; they are not counted as Fresh Save Journey coverage.

The current bounded suite verifies all **57 / 57** core actions. Every row has independent Success, player-visible Failure, authoritative Consequence, and Persistence evidence. Static mappings are not counted, and the machine artifact retains each quadrant rather than only the aggregate number. Locked Ship plans provide a visible disabled failure surface while repeat production of an unlocked plan remains legal. Project-style actions use rapid duplicate submissions to receive structured rejections and assert that only one physical project was created.

Round 6 adds real MainScene evidence for the production and extraction controls. Permanent extraction proves exclusive physical-ship ownership and release; Production start/stop proves real device/input commitments and their release; Production control and priority use their visible selected-state disabled controls as failure surfaces; Factory expansion proves the UI queues a `FACILITY_EXPANSION` Construction runtime with a non-empty material plan and does not increase Factory level before completion.

The two Round 6 production-surface gaps are closed and independently verified:

- `CHANGE_PRODUCTION_METHOD` uses the named `SelectProductionMethod_2_fabricate_data_core` control on a raw-IDLE stable line, observes its Method, physical Production Device and input commitments, rejects the stale duplicate, and round-trips the line.
- `ADD_PRODUCTION_LINE` begins at `prototype_complete`, advances the Factory through ordinary material-backed `FACILITY_EXPANSION` and `SCALE_STAGE_UPGRADE` Domain projects to a real `INDUSTRIAL_COMPLEX`, then uses `AddProductionLine_makeshift_workshop_fabricate_repair_material`. Two visible valid Add actions fill its extra line slots; the same named control remains visible and disabled with a scale/capacity explanation when full. Setup funding and direct Construction advancement are disclosed in the machine artifact and are not Fresh Save Journey evidence.

Round 7 also proves:

- `DEVELOP_SITE` and `UPGRADE_LOCATION_CAPACITY` create material-backed projects in the shared Construction queue rather than mutating completed infrastructure.
- `ASSIGN_SHIP` preserves exclusive physical Fleet ownership, while `START_EXPEDITION` owns that Ship in the persistent route runtime and consumes real propellant.
- `INSTALL_MANUFACTURING_MODULE` and `UNINSTALL_MANUFACTURING_MODULE` move a physical module between an idle Factory and module storage through Domain transactions.
- `CANCEL_MEGASTRUCTURE_PHASE` cancels exactly one shared Construction runtime, clears `active_project_id`, and preserves the cancellation ledger through the Domain round trip.

The active-route Recall gap is closed. `RecallExpeditionRoute_lunar_route` calls the existing `Game.stop_activity("expedition")` transaction. Runtime evidence proves the assigned Ship returns docked to its persistent Expedition Fleet, the route/activity/node/phase/combat ownership is cleared, recoverable cargo uses the normal unload path, a stale duplicate receives the structured no-active rejection, and the recalled state survives Domain round-trip.

Round 8 also proves reciprocal ownership and physical-asset consequences:

- `INTEGRATE_EXTRACTION_SITE` writes both the mastered Site's `integrated_network_id` and the unlocked Extraction Network's `integrated_site_ids`, then rejects duplicate integration.
- `ASSIGN_CONSTRUCTION_SUPPORT` / `RELEASE_CONSTRUCTION_SUPPORT` exclusively move the real mobile-constructor Ship and respectively add/remove its authoritative Location construction-capacity contribution.
- `SELECT_MEGASTRUCTURE_SITE` commits a Deep-Surveyed candidate, records Phase-zero history and advances to Phase 1 without creating a free Construction project.
- `INSTALL_SHIP_MODULE` is formed from a legal full-hull checkpoint by first using a visible Remove control and normal Simulation completion to create an empty slot. After canonical BOM funding, the named Install control creates a persistent full-loadout refit. `REMOVE_SHIP_MODULE` independently creates a corresponding refit, and `CANCEL_SHIP_REFIT` restores original physical-module ownership without refunding the already committed fabrication BOM.

`SET_LOGISTICS_POLICY` and `CLEAR_LOGISTICS_POLICY` have stable named controls and full four-case evidence. Set compares normalized canonical values and rejects an unchanged second submission; Clear rejects a second submission when the valid item policy is already absent. Both rejection reasons are rendered in Alerts / Timeline, while the first command's authoritative policy change/removal survives Domain round-trip.

`PauseLogisticsRoute_*` and `ResumeLogisticsRoute_*` reach the real persistent Domain service state through the registered `SET_ROUTE_PAUSED` action. An idempotent duplicate submission is rejected as a structured unchanged-state failure.

Transport Mode coverage clicks the localized live mode control, observes the route Service change to `bulk_tug`, confirms its physical freight ship, checks a locked earlier-game mode as the disabled failure, and round-trips the service. Logistics Ship coverage first assigns that physical ship through the visible per-ship control, then confirms the non-public Bulk Tug service disables removal of its last transport asset.

`CHANGE_ROUTE_PRIORITY` has full four-case evidence. The visible strategy button changes the authoritative route service and survives Domain round-trip; after rebuild, the selected strategy remains visible but disabled with a localized unchanged-strategy tooltip.

Fleet supply is also fully covered. `SET_FLEET_SUPPLY_PLAN` changes a named `FleetSupplyTarget_*` through `SetFleetSupplyPlan_*`, rejects the same quantity as an unchanged intent, and round-trips the target. `RESUPPLY_FLEET` moves real owned inventory into fleet supply, proves aggregate conservation and round-trip, while an empty Expedition roster leaves the named action visible and disabled with an explicit reason.

Round 4b independently established **10 / 56** before `SET_ROUTE_PAUSED` joined the inventory. Round 5 established **14 / 57**; Round 6 established **22 / 57**; Round 7 established **31 / 57**; Round 8f established **39 / 57**; Round 9a established **51 / 57**. Round10d is the final **57 / 57 PASS** in `.audit-logs/ui-action-coverage-round10d.log`, with Godot exit code 0, zero `SCRIPT ERROR`, zero `FAIL:`, and no residual Godot process. The current machine result is `artifacts/test-results/ui-action-coverage.json`; isolated disk persistence evidence is `artifacts/test-results/ui-persistence-audit.json`. This percentage is strict action-runtime evidence only and must not be substituted for Fresh Save Journey Coverage.
