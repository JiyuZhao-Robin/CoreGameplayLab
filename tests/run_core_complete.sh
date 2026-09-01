#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
python3 -m json.tool data/content.json >/dev/null
python3 -m json.tool data/localization_zh_CN.json >/dev/null
python3 -m json.tool data/localization_en.json >/dev/null

godot --headless --path . --log-file /tmp/helios-content-planner.log --script res://tests/content_planner_contract_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-factory-grid.log --script res://tests/factory_grid_simulation_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-operational-formations.log --script res://tests/operational_formation_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-wreck-sites.log --script res://tests/wreck_site_system_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-core-integrity.log --script res://tests/core_integrity_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-asset-conservation.log --script res://tests/asset_conservation_test.gd -- --no-persistence

# The 1.29 Headless, Golden Path and industrial UI suites asserted the removed
# location-level mining, Production Line, Extraction Network and generic
# Construction behavior. They are deliberately not a post-cutover gate. Replacement
# canvas/playflow suites must exercise FactoryGridSimulation through Game's
# transactional grid commands rather than resurrecting the retired runtime.
