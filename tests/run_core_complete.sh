#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
cd "$project_dir"

python3 -m json.tool data/content.json >/dev/null
python3 -m json.tool data/localization_zh_CN.json >/dev/null
python3 -m json.tool data/localization_en.json >/dev/null

godot --headless --path . --log-file /tmp/helios-content-planner.log --script res://tests/content_planner_contract_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-core-integrity.log --script res://tests/core_integrity_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-headless.log --script res://tests/headless_test.gd -- --no-persistence
godot --headless --path . --log-file /tmp/helios-location-inventory.log --script res://tests/location_inventory_test.gd -- --no-persistence

for scene in \
  res://tests/playflow_test.tscn \
  res://tests/location_ui_smoke_test.tscn \
  res://tests/ui_playflow_test.tscn \
  res://tests/localization_catalog_test.tscn \
  res://tests/ui_chinese_localization_smoke_test.tscn
do
  godot --headless --path . --log-file "/tmp/helios-${scene:t:r}.log" "$scene" -- --no-persistence --locale=zh_CN
done

godot --headless --path . --log-file /tmp/helios-ui-english.log res://tests/ui_english_localization_smoke_test.tscn -- --no-persistence --locale=en

# The no-cheat end-to-end simulation is intentionally last: it exercises the
# real production, logistics, research, remote-base and eight-phase endgame.
godot --headless --path . --log-file /tmp/helios-golden-path.log res://tests/golden_path_test.tscn -- --no-persistence
