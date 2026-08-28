# UI State Registry

`data/ui_state_registry.json` is the stable machine-readable contract for 43 player-facing core gameplay states. `tests/ui_state_coverage_test.gd` generates separate runtime evidence so a passing schema check cannot be mistaken for a working gameplay/UI journey.

Latest runtime result: **43 / 43 VERIFIED**. The generated evidence is `artifacts/test-results/ui-state-coverage.json`, with one result row for every registry definition. The test never assigns a runtime status/blocker, edits a control's text, or treats a snapshot filename as proof of its contents.

## Evidence threshold

An entry is `VERIFIED` only when all four JSON flags are true in one scenario:

1. `domainStateFormed`: an authoritative selector matches after legal setup/commands and Simulation advancement.
2. `uiStateVisible`: a live `MainScene` visibly exposes the state.
3. `explanationVisible`: the same live UI exposes Domain-derived activity, project, route, measurement, resource disclosure or blocker context.
4. `navigationControlVisible`: a visible enabled control lets the player inspect, continue or resolve the state.

Fresh paths use `Game.reset_game()`, public `SpaceGameState` inventory APIs, real `Game` commands and `Game.advance_game_time()` (milliseconds). Late-game paths may start from `GameplayScenarioBuilder`, but only when the artifact envelope states `invariant_source=normal_domain_commands_and_simulation`. Every such row records the exact `artifacts/ui-scenarios/<id>.json` provenance in `formationTrace` and explicitly says that checkpoint loading is legal setup, not a replay of the preceding Golden Journey.

## Current numerator / denominator

| System | Verified | Registry total | Verified states |
| --- | ---: | ---: | --- |
| Production | 9 | 9 | `RUNNING`, `BLOCKED_INPUT`, `BLOCKED_OUTPUT`, `POWER_LIMITED`, `COOLING_LIMITED`, `LOGISTICS_LIMITED`, `PAUSED`, `BUILDING`, `DISABLED` |
| Construction | 6 | 6 | `WAITING_MATERIAL`, `WAITING_CAPACITY`, `BUILDING`, `PAUSED`, `COMPLETED`, `CANCELLED` |
| Research | 9 | 9 | `AVAILABLE`, `LOCKED`, `ACTIVE`, `WAITING_MATERIAL`, `WAITING_FACILITY`, `WAITING_PROTOTYPE`, `WAITING_FIELD_TEST`, `PAUSED`, `COMPLETED` |
| Logistics | 7 | 7 | `ACTIVE`, `UNDERUTILIZED`, `SATURATED`, `BLOCKED_SOURCE`, `BLOCKED_DESTINATION`, `NO_TRANSPORT`, `PAUSED` |
| Survey | 4 | 4 | `UNKNOWN`, `DETECTED`, `SURVEYED`, `DEEP_SURVEYED` |
| Megastructure | 8 | 8 | `LOCKED`, `RESEARCH_REQUIRED`, `SITE_PREPARATION`, `WAITING_MATERIAL`, `BUILDING`, `INTEGRATION`, `COMMISSIONING`, `COMPLETED` |
| **Total** | **43** | **43** | Complete runtime UI evidence for the current core registry |

## Golden checkpoint coverage

### Survey

- `DETECTED`: load `open_deep`; fund the real mission costs through `SpaceGameState.add_item`; use `Game.survey_mission_availability` and `Game.start_survey_mission` for Inner Solar Orbit; advance by the authoritative mission duration in milliseconds. The System Map and Location Overview show `DETECTED` plus preliminary environment data, with Ships navigation when no immediately usable follow-up mission button exists.
- `DEEP_SURVEYED`: load `open_deep`; legally advance the already Surveyed Asteroid Belt with the deep-survey vessel and real mission costs. The Location Resources page must expose at least one real exact resource profile. The resource-less Earth-Sun Lagrange checkpoint is deliberately not used to pretend that ore details exist there.

### Logistics

`megastructure_phase_2` provides discovered Earth/Lagrange endpoints and an invariant-valid public General Cargo service.

- `UNDERUTILIZED`: the real `service_snapshot` reports positive capacity and zero measured utilization; the Location Logistics page shows the route, status, capacity/utilization and policy navigation.
- `ACTIVE`: public inventory APIs supply Iron Ingot and propellant; legal source/demand policies are locked to `earth_lagrange_freight`; one 5000 ms dispatch interval produces measured utilization between 25% and 99.9%.
- `SATURATED`: the same legal flow requests one full dispatch capacity; the Simulation reports utilization `1.0` and the live route card exposes `SATURATED`.

- `BLOCKED_SOURCE`: the destination demand has no source policy, so `_dispatch` writes `NO_SUPPLY_SOURCE`. The UI consumes the Domain normalization, exposes `BLOCKED_SOURCE`, the source-side reason and a live `Why? -> Open resolution` control.
- `BLOCKED_DESTINATION`: a real owned shipment is dispatched, destination storage is filled through the public inventory API, and `settle_ready` preserves it as `BLOCKED_OUTPUT/STORAGE_FULL`. The UI exposes normalized `BLOCKED_DESTINATION`, the unloading blocker and enabled destination-storage navigation.

### Megastructure

- `BUILDING`: from `megastructure_phase_2`, `Game.start_megastructure_phase` creates the actual Construction runtime and `project.status=BUILDING`; the live page exposes the phase description and cancellation control.
- `WAITING_MATERIAL`: after a legal phase start, all phase inputs are removed through public inventory APIs and Simulation produces a real `INPUT_SHORTAGE` Construction blocker. The page consumes the unified gameplay state, exposes `WAITING_MATERIAL`, the blocker and cancellation.
- `INTEGRATION`: `megastructure_phase_6` authoritatively resolves the current phase id to `stellar_grid_integration`; the page exposes the stage/BOM and an enabled phase-start control.
- `COMMISSIONING`: `megastructure_phase_7` resolves to `stellar_commissioning`; its stage and BOM are visible. The blocked Start button is deliberately not counted as navigation. The enabled `MegastructureOpenWorksite` control is the valid inspection/resolution path and is recorded in `uiEvidence`.
- `COMPLETED`: `megastructure_phase_8` contains `megastructures.stellar_energy=true`, `game_complete=true`, all eight phase-history rows and aggregate contribution totals; the completion page and System navigation are live.

`RESEARCH_REQUIRED` is formed by starting the real Stellar Energy Program and reaching its materials milestone without granting the technology. `SITE_PREPARATION` is formed after legal R&D completion but before the forward-base prerequisite exists. Both are asserted through the live Megastructure page and enabled resolution navigation.

## Closed coverage gaps

- Production constraints are formed by legal material-backed workshop expansion plus normal power/cooling/logistics projects. `BUILDING` uses an active facility project; `DISABLED` uses the public module uninstall path and the shared Domain selector `SimulationEngine.production_gameplay_state`.
- Construction `WAITING_CAPACITY` uses competing legal projects that exhaust real engineering capacity.
- Research waiting states use normalized Golden scenario checkpoints whose provenance is the normal Domain-command simulation path; `LOCKED` and `PAUSED` are formed from normal prerequisite and pause commands.
- Logistics `NO_TRANSPORT` and `PAUSED` use public service configuration and pause commands; no raw service status is assigned.
- The former `RESEARCH.WAITING_KNOWLEDGE` registry row was removed from the core denominator after reachability analysis proved no valid current content stage can form it: all technology-domain knowledge gates are baseline-satisfied. The Domain/localization compatibility branch remains for future content, but a future-only placeholder is not counted as a current core state.

Construction history is now covered: legal `COMPLETE` and `CANCELLED` rows are visible with their status/material or cancellation accounting and enabled `ConstructionHistory_<project_id>` ledger controls.

## Commands and evidence

```powershell
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_state_registry_test.tscn -- --no-persistence
& 'D:\Godot\godot.exe' --headless --path 'D:\Projects\standalone\core_gameplay_lab' res://tests/ui_state_coverage_test.tscn -- --no-persistence
```

The final run exits `0` with no `SCRIPT ERROR`, prints `UI_STATE_COVERAGE=43/43`, and is captured in `.audit-logs/ui-state-coverage-final43.log`. The artifact retains all 43 rows and independent evidence flags. The registry's static `runtimeCoverage: UNVERIFIED` values remain conservative; only the generated result claims the 43 runtime/UI proofs.
