# Master Core Audit

Audit date: 2026-08-28. Coordinator synthesis of independent Architecture, Economy, Asset/Logistics, Construction, Research/Survey, Progression, Save/Offline, Localization and Test/Performance reviews.

## Certification scope

This document certifies the Domain/core repair stage only. Player-UI completeness is certified separately in `docs/ui-audit/final-certification.md`; the project must not be labeled `READY FOR ART PRODUCTION` until that later certificate passes.

## P0 findings and disposition

| Finding | Root cause | Repair | Evidence |
| --- | --- | --- | --- |
| Survey vessel double-spend after transaction/save | assignment normalization converted an active mission ship back to docked | preserve authoritative Survey assignment and reject refit/reassignment | `asset_conservation_test.gd` transaction and save/load cases |
| Fleet resupply spent Reserved stock and misreported transfers as consumption | direct inventory subtraction in resupply helper | shared reserve-safe inventory-to-fleet ownership transfer | asset ledger tests |
| Offline time beyond 24h could remain unpaid | application ignored Simulation capped remainder | shared `Game.advance_game_time` drains all chunks and automation boundaries | 30-hour playflow test |
| 60min differed from 60x1min at maintenance shortage | maintenance boundary absent from next-event integration | include maintenance consumption boundary | core integrity equivalence test |
| Survey bypassed strategic access | mission validation lacked access contract and completion granted access | require access before launch; completion only changes intelligence | headless Survey tests |
| Construction ship was a passive global bonus | capability scan counted any parked hull | explicit same-Location assignment plus maintenance requirement | headless construction-support test |
| Infrastructure module granted capacity instantly | install command directly consumed stock and mutated facility | queue `FACILITY_MODULE_INSTALL` in normal Construction | headless 100-cycle installation test |

Current core P0 count: **0 open**.

## P1 findings and disposition

- Resolved: staged research double cost authority; ghost endgame ingredients/technology; Logistics Hub not affecting local handling; free Survey staging; unsafe full-storage fleet unload; scrap over-capacity recovery; read query mutating demand; Planner/runtime Location mismatch; legacy `AUTO` control alias; identity counter collisions on load.
- Scheduled in the explicit UI implementation/audit stages: complete Gameplay Action surface, structured Blocker/Alert contract, root-cause navigation, template-first anti-Excel UX, full zh/en dynamic text migration, screenshot matrix and UI-only fresh-save playthrough.

No unresolved Domain P1 is known to prevent a legal fresh-save completion. UI P0/P1 are intentionally not waived: they remain failing until the later UI certificate supplies executable evidence.

## Architecture classification

| Class | Items |
| --- | --- |
| KEEP | `SpaceGameState` invariants/serialization, `SimulationEngine` event-boundary integration, `ContentDatabase` validation, `EconomyPlanner` read-only queries, `GameStateTransaction` commit path. |
| REFACTOR | Split large `Game` and `SimulationEngine` facades after contracts stabilize; replace string notices with structured command results; cache mature-save logistics/planner snapshots. |
| MERGE | Planner/runtime formulas (partly completed), graph implementations, global and Location facility projections. |
| DELETE | Retired `AUTO` mode, orphan content items, no-op specialization/automation APIs, unused abstractions only after call-site gate proves zero use. |
| UNCERTAIN | Legacy save/archive fields retained for migration compatibility; do not delete without historical fixtures. |

## Regression evidence required for closure

- content/planner contract
- core integrity and migration
- headless Domain suite
- asset conservation
- playflow/offline orchestrator
- localization catalog
- fresh-save golden path through eight megastructure phases

The final commands and exact PASS/FAIL matrix are recorded in the final certification, not inferred from compilation.

