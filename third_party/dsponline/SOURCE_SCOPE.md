# DSPONLINE source scope and attribution

This directory records the source scope for the user-authorized, limited reuse
of mining and production implementation from the upstream **DSPONLINE** project.
It is attribution and provenance documentation; it does not brand this game as
DSPONLINE or as an official project.

## Upstream provenance

- Local source inspected: `/Volumes/T9/Developer/projects/DSPONLINE`
- Upstream package: `dsp-idle-network` version `1.1.5`
- Upstream repository declared by the package:
  `https://github.com/snowsnow0926/DSPONLINE.git`
- Upstream license source: `public/LICENSE.txt`
- Upstream commercial-use explanation: `COMMERCIAL_USE.md`
- Upstream trademark/name rules: `TRADEMARKS.md`

`LICENSE.txt` in this directory is a verbatim copy of the upstream license.
`NOTICE.txt` preserves its Required Notice as a separate plain-text notice.

## Authorized implementation scope

The local project may directly reuse, translate, or adapt only the mining and
production implementation families below, for its factory gameplay workspace:

- simulation sequencing and physical-goods/backpressure patterns from
  `src/game/engine.ts`, including miners, machines, belts, power, construction,
  and deterministic step ordering;
- factory node, resource-vein, machine, edge, belt-canvas, and interaction
  presentation patterns from `src/components/FactoryNodes.tsx`,
  `src/components/FactoryEdges.tsx`, `src/components/CanvasBeltLayer.tsx`, and
  `src/components/CanvasInteractionOverlay.tsx`;
- production, recipe, and construction workspace presentation patterns from
  `src/components/ProductionManagement.tsx`, `src/components/RecipeWorkspace.tsx`,
  and `src/components/ConstructionCenterWorkspace.tsx`;
- factory-only visual tokens, layout, states, and motion rules from
  `src/styles.css`.

The upstream project did not supply a standalone mining/production bitmap art
pack in the inspected source. Reuse in this scope is therefore principally code,
layout, canvas rendering, vector/geometric treatment, colors, and UI behavior.

## Exclusions

### 2026-09-10 user-authorized scope addition

The project user additionally requested the complete source building, mineral,
and production catalog. The adaptation now includes `src/game/content.ts`
(78 items, 39 buildings, 80 recipes, 42 construction references), its fuel and
proliferation constants, and factory-facing project behavior from `engine.ts`,
`endgame.ts`, and `systemSpaceStation.ts`. A reproducible importer and source
SHA-256 are recorded in `data/dsponline_industry.json`.

This is an adaptation to Location-owned inventory, roads, finished-building
deployment, and the existing research/stellar-logistics authorities, not a copy
of upstream account, online activity, branding, or full world/research systems.
New bitmap art was generated independently and its prompts are retained beside
the project assets. This addition records user direction, not a new license grant.

- Do not use upstream logos, official names, domains, similar branding,
  signatures, update channels, or account entry points as this game's branding.
- `public/icon.svg` and other official-logo/brand assets are explicitly outside
  this scope.
- All gameplay and UI outside mining, construction, factory logistics, and
  production are excluded unless separately authorized and recorded.
- This record does not grant a license to unrelated third-party dependencies
  that may be present in the upstream project.

## License and authorization boundary

The upstream project declares the PolyForm Noncommercial License 1.0.0. That
license is not a grant of commercial rights. The project user separately
confirmed authorization for the intended direct reuse, including commercial use;
that confirmation is local project direction, not an assertion that the upstream
license itself grants commercial rights or a substitute for the licensor's
separate written license.

Any redistribution must retain the upstream license terms and Required Notice.
Obtain and retain any legally required written permission from the upstream
licensor independently of this provenance record.
