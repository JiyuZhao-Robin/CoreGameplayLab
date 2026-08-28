# Repair Backlog

Audit date: 2026-08-28. Items are ordered by severity and dependency.

## P0

No open Domain P0. UI P0 remains owned by the Core UI implementation/audit stage until its executable coverage gate passes.

## P1

1. Unified `PlayerActionAvailability` and structured `BlockerInfo`, including Location/entity navigation targets.
2. Complete all core Domain-command UI entry points and remove/deprecate any dead public player action.
3. Replace per-SKU remote administration with visible Industrial Template apply/clear controls and exception-only overrides.
4. Integrate Logistics service/policy/shipment, extraction, maintenance, Survey, Shipyard and Megastructure blockers into Diagnostics and Alert lifecycle.
5. Move remaining player-facing dynamic strings to stable zh-CN/en keys and verify natural English terminology.
6. Build a real UI-only fresh-save playthrough with PlayerActionExecutionLog and all mandatory journey events.

## P2

- Split God-object files behind stable query/command facades.
- Add historical save fixtures for every supported schema transition.
- Optimize mature-save five-second logistics boundaries and graph/path caches.
- Commit experimental prototype/field-test assets to explicit physical ownership where the design requires recoverability.
- Remove confirmed dead APIs/fields after migration compatibility review.
- Persist selected UI Location/page and Developer Details preference.

## P3

- Wording, spacing, minor animation and post-art visual polish.
- Expand optional/action-variant journey tests beyond the mandatory core path.

Every closure follows `reproduce -> failing test -> implementation -> focused pass -> regression suite`.

