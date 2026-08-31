#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="$project_dir/artifacts/ui-industrial-network"
godot_bin="${GODOT_BIN:-godot}"
mkdir -p "$output_dir"

capture_fresh() {
  local resolution="$1"
  local locale="$2"
  "$godot_bin" --path "$project_dir" --resolution "$resolution" --position 8,8 res://src/ui/main.tscn -- \
    --no-persistence --locale="$locale" --industry-section=production --industry-view=network \
    --capture-view=industry --capture-output="$output_dir/${resolution}_${locale}_fresh.png"
}

capture_scenario() {
  local resolution="$1"
  local locale="$2"
  local state="$3"
  local scenario="establish_industry"
  local extra_args=()
  if [[ "$state" == "late_network" ]]; then
    scenario="complete_stellar_energy"
  else
    extra_args+=(--network-run-activity=manufacture_kinetic_munitions)
    if [[ "$state" == "bottleneck_focus" ]]; then
      extra_args+=(--network-state=input_shortage --network-focus-bottleneck)
    elif [[ "$state" == "reduced_motion" ]]; then
      extra_args+=(--network-state=running --reduced-motion)
    else
      extra_args+=(--network-state="$state")
    fi
    if [[ "$state" != "bottleneck_focus" ]]; then
      extra_args+=(--network-focus-activity=manufacture_kinetic_munitions)
    fi
  fi
  "$godot_bin" --path "$project_dir" --resolution "$resolution" --position 8,8 res://tests/ui_scenario_capture.tscn -- \
    --no-persistence --ui-scenario="$scenario" --locale="$locale" --industry-section=production --industry-view=network \
    --capture-view=industry --capture-output="$output_dir/${resolution}_${locale}_${state}.png" "${extra_args[@]}"
}

for resolution in 1366x768 1920x1080 2560x1440; do
  for locale in en zh_CN; do
    capture_fresh "$resolution" "$locale"
    for state in running input_shortage output_full power_limited logistics_congested bottleneck_focus late_network reduced_motion; do
      capture_scenario "$resolution" "$locale" "$state"
    done
  done
done

for phase in 0.00 0.42 0.84; do
  "$godot_bin" --path "$project_dir" --resolution 1920x1080 --position 8,8 res://tests/ui_scenario_capture.tscn -- \
    --no-persistence --ui-scenario=establish_industry --network-run-activity=manufacture_kinetic_munitions \
    --network-state=running --network-visual-phase="$phase" --locale=en --industry-section=production --industry-view=network \
    --network-focus-activity=manufacture_kinetic_munitions \
    --capture-view=industry --capture-output="$output_dir/1920x1080_en_animation_phase_${phase}.png"
done

echo "INDUSTRIAL_NETWORK_CAPTURE_MATRIX_COMPLETE: $output_dir"
