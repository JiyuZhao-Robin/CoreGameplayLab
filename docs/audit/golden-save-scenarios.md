# Golden Scenario Registry

These are deterministic automated scenarios, not hand-maintained PASS declarations. The referenced tests create legal state through Domain setup/commands and are executed by `tests/run_core_complete.sh`.

| Scenario | Contract | Automated evidence |
| --- | --- | --- |
| 01 | New Save -> first steel | `golden_path_test.tscn`: fresh save, real mining/industry sequence and `FIRST_STEEL` journey event. |
| 02 | Raw ore direct haul -> logistics bottleneck | `content_planner_contract_test.gd` route-capacity trace plus `headless_test.gd` freight-service saturation cases. |
| 03 | Remote preprocessing -> power/maintenance pressure | `golden_path_test.tscn::_establish_belt_preprocessing_base` and location O&M tests. |
| 04 | Foundry upgrade -> logistics bottleneck | `headless_test.gd::_test_industry_and_capital_cycles` constrains local handling and verifies slower real cycle duration. |
| 05 | Logistics upgrade -> smelting bottleneck | `headless_test.gd` Logistics Hub completion test plus Planner bottleneck trace. |
| 06 | R&D program requires new material | staged R&D contract and prototype/article tests in `headless_test.gd` and `content_planner_contract_test.gd`. |
| 07 | Remote Survey -> Site Development | Survey access/state tests and shared Construction Site Development tests in `headless_test.gd`. |
| 08 | Remote base insufficient supply | remote tranche, in-transit material and maintenance shortage tests in `headless_test.gd`. |
| 09 | Large ship manufacturing | batch `Build x20`, fitted-hull BOM and parallel Shipyard tests in `headless_test.gd`. |
| 10 | Megastructure Phase 1 -> Final | `golden_path_test.tscn` completes all eight phases and asserts intermediate journey events. |

Scenario 04 and 05 deliberately exercise different constraints: increasing factory throughput raises handling demand, while increasing handling capacity removes that multiplier and exposes the production-method/factory limit. Neither upgrade is a universal scalar bonus.

