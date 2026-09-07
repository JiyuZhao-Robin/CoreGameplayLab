#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
output_dir="$project_dir/artifacts/ui-factory-workspace"
godot_bin="${GODOT_BIN:-godot}"
mkdir -p "$output_dir"

capture_factory() {
  local resolution="$1"
  local locale="$2"
  local state="$3"
  local extra_args=()
  if [[ "$state" == "reduced_motion" ]]; then
    extra_args+=(--reduced-motion)
  fi
  "$godot_bin" --path "$project_dir" --resolution "$resolution" --position 8,8 res://src/ui/main.tscn -- \
    --no-persistence --locale="$locale" --capture-view=industry \
    --capture-output="$output_dir/${resolution}_${locale}_${state}.png" "${extra_args[@]}"
}

for resolution in 1366x768 1920x1080 2560x1440; do
  for locale in en zh_CN; do
    for state in fresh reduced_motion; do
      capture_factory "$resolution" "$locale" "$state"
    done
  done
done

echo "FACTORY_WORKSPACE_CAPTURE_MATRIX_COMPLETE: $output_dir"
