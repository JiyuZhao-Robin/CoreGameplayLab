#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
godot_bin=${GODOT_BIN:-}
if [ -z "$godot_bin" ]; then
    if command -v godot >/dev/null 2>&1; then
        godot_bin=$(command -v godot)
    elif command -v godot4 >/dev/null 2>&1; then
        godot_bin=$(command -v godot4)
    elif [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
        godot_bin=/Applications/Godot.app/Contents/MacOS/Godot
    else
        printf '%s\n' 'Godot not found. Set GODOT_BIN to your Godot executable path.' >&2
        exit 1
    fi
fi

# Generate local import caches before loading textures from the pulled sources.
"$godot_bin" --headless --editor --import --path "$project_dir" -- --no-persistence
exec "$godot_bin" --path "$project_dir" \
    res://src/ui/art_calibration/building_candidates/building_candidates.tscn \
    -- --no-persistence "--candidate=${1:-arc-furnace}"
