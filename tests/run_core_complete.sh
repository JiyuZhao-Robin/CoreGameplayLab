#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"
python3 -m json.tool data/content.json >/dev/null
python3 -m json.tool data/localization_zh_CN.json >/dev/null
python3 -m json.tool data/localization_en.json >/dev/null

godot --headless --path . --log-file /tmp/helios-content-planner.log --script res://tests/content_planner_contract_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-factory-grid.log --script res://tests/factory_grid_simulation_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-factory-workspace-contract.log --script res://tests/factory_workspace_contract_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-factory-workspace-ui.log --script res://tests/factory_workspace_ui_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-factory-main-integration.log --script res://tests/factory_workspace_main_integration_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-location-ui-smoke.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/location_ui_smoke_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-ui-chinese-smoke.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/ui_chinese_localization_smoke_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-ui-english-smoke.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/ui_english_localization_smoke_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-localization-catalog.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/localization_catalog_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-ui-localization-audit.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/ui_localization_audit_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-player-actions.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/player_action_registry_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-ui-states.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/ui_state_registry_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-gameplay-journeys.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/gameplay_journey_registry_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-ui-domain-integrity.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/ui_domain_integrity_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-ship-assembly-editor.log --script res://tests/scene_test_runner.gd -- --test-scene=res://tests/ship_assembly_editor_test.tscn --no-persistence
godot --headless --path . --log-file /tmp/helios-operational-formations.log --script res://tests/operational_formation_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-wreck-sites.log --script res://tests/wreck_site_system_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-core-integrity.log --script res://tests/core_integrity_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-asset-conservation.log --script res://tests/asset_conservation_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-core-gameplay-runtime.log --script res://tests/core_gameplay_runtime_gate_test.gd -- --no-persistence

# The retired Headless, Golden Path, Playflow and industrial UI state/action suites asserted the removed
# location-level mining, Production Line, Extraction Network and generic
# Construction behavior. They are deliberately not a post-cutover gate. The
# Factory workspace contract, intent-only UI, MainScene integration, registries,
# localization and UI-domain guards above replace their industrial coverage.
# The final application-boundary runtime gate exercises all ten core Journeys
# through Game's transactional commands; focused UI suites remain responsible for
# pointer/keyboard presentation behavior.
