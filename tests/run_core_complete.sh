#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
evidence_run_id="core-complete-$(date -u +%Y%m%dT%H%M%SZ)-$$"

python3 -m json.tool data/content.json >/dev/null
python3 -m json.tool data/localization_zh_CN.json >/dev/null
python3 -m json.tool data/localization_en.json >/dev/null

zsh tools/run_ui_persistence_audit.sh

godot --headless --path . --log-file /tmp/helios-content-planner.log --script res://tests/content_planner_contract_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-core-integrity.log --script res://tests/core_integrity_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-asset-conservation.log --script res://tests/asset_conservation_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-headless.log --script res://tests/headless_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-location-inventory.log --script res://tests/location_inventory_test.gd -- --no-persistence

for scene in \
  res://tests/playflow_test.tscn \
  res://tests/location_ui_smoke_test.tscn \
  res://tests/ui_playflow_test.tscn \
  res://tests/localization_catalog_test.tscn \
  res://tests/gameplay_journey_registry_test.tscn \
  res://tests/player_action_registry_test.tscn \
  res://tests/ui_action_coverage_test.tscn \
  res://tests/ui_state_registry_test.tscn \
  res://tests/ui_state_coverage_test.tscn \
  res://tests/ui_domain_integrity_test.tscn \
  res://tests/ui_input_accessibility_test.tscn \
  res://tests/industrial_network_projection_test.tscn \
  res://tests/industrial_network_ui_test.tscn \
  res://tests/ui_localization_audit_test.tscn \
  res://tests/ui_chinese_localization_smoke_test.tscn
do
  godot --headless --path . --log-file "/tmp/helios-${scene:t:r}.log" "$scene" -- --no-persistence --locale=zh_CN
done

godot --headless --path . --log-file /tmp/helios-ui-english.log res://tests/ui_english_localization_smoke_test.tscn -- --no-persistence --locale=en
godot --headless --path . --log-file /tmp/helios-economy-audit.log --script res://tools/economy_audit.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-ui-performance.log --script res://tests/ui_performance_contract_test.gd -- --no-persistence
godot --path . --resolution 1920x1080 --log-file /tmp/helios-full-gameplay-ui.log res://tests/full_gameplay_ui_test.tscn -- --no-persistence --locale=en --evidence-run-id="$evidence_run_id"

# The no-cheat end-to-end simulation is intentionally last: it exercises the
# real production, logistics, research, remote-base and eight-phase endgame.
godot --headless --path . --log-file /tmp/helios-golden-path.log res://tests/golden_path_test.tscn -- --no-persistence --emit-scenarios
godot --headless --path . --log-file /tmp/helios-scenario-builder.log res://tests/gameplay_scenario_builder_test.tscn -- --no-persistence --require-generated-scenarios
