# Economy Graph Audit

Audit date: 2026-08-28. Source of truth: `data/content.json`, `ContentDatabase`, `SimulationEngine` and `EconomyPlanner`.

The checked graph contains 75 player-economy products. The generated, exhaustive producer/consumer/technology/device/facility/construction/maintenance/megastructure tables are in [generated-economy-audit.md](generated-economy-audit.md). Re-run them with:

```text
godot --headless --path <project> --script res://tools/economy_audit.gd -- --no-persistence
```

## Layered dependency model

```text
Surveyed resource potential
  -> extraction method / extraction ship / permanent extraction network
  -> raw ore, gas, ice and strategic feedstock
  -> refining and separation
  -> ingots, propellant, ceramics and concentrates
  -> machine tools, structural sections, electronics and logistics equipment
  -> factories, storage, power, cooling, logistics and construction capacity
  -> research articles, prototypes, ship modules and fitted hulls
  -> remote industry and advanced materials
  -> eight material-backed Stellar Energy Megastructure phases
```

Every repeatable industrial product has at least one deterministic producer or an explicitly classified exploration/salvage source. Waste, unique recovered equipment and hostile-route rewards are classified as special sinks/sources rather than false graph errors. Every consumed item has a valid source, and every normal product has a gameplay sink.

## Shared calculation contract

- Runtime and Planner both use `SimulationEngine.nominal_production_method_cycles_per_hour`, location-aware facility throughput and the same device/method/environment checks.
- Megastructure planning and runtime share `megastructure_effective_site_requirements`; `stellar_thermal_routing` now changes real phase power/cooling requirements.
- Staged R&D costs have one owner: stage BOMs. Duplicate project-level cost authority was removed.
- `dark_matter` is no longer a ghost ingredient: it is consumed by the thermal-routing endgame stage.
- Orphan `ship_prototype_component` and `anomaly_sample` definitions were removed.

## Automated result

```text
products=75
findings=0
critical=0
```

Checked detector classes: `UNREACHABLE_PRODUCT`, `NO_PRODUCER`, `NO_CONSUMER`, `SELF_BOOTSTRAP_DEADLOCK`, `TECH_WITHOUT_IMPLEMENTATION`, `DEVICE_WITHOUT_METHOD`, `METHOD_WITHOUT_DEVICE`, `CONSTRUCTION_DEADLOCK`, and `MISSING_LOCALIZATION`.

