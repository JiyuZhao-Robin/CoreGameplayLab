#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
godot_bin="${GODOT_BIN:-godot}"
temp_base="${TMPDIR:-/tmp}"
isolated_root="$(mktemp -d "$temp_base/helios-ui-persistence-audit-XXXXXX")"
isolation_token="${isolated_root:t}"
result_artifact="$project_dir/artifacts/test-results/ui-persistence-audit.json"

cleanup() {
  local resolved="${isolated_root:A}"
  if [[ "${resolved:t}" == helios-ui-persistence-audit-* && ( "$resolved" == /tmp/* || "$resolved" == /private/tmp/* || "$resolved" == /private/var/folders/* ) ]]; then
    rm -rf -- "$resolved"
  fi
}
trap cleanup EXIT

rm -f -- "$result_artifact"
mkdir -p "$project_dir/artifacts/test-results"

run_phase() {
  local phase="$1"
  local log_path="/tmp/helios-ui-persistence-${phase}.log"
  "$godot_bin" --headless --path "$project_dir" --log-file "$log_path" \
    --scene res://tests/ui_persistence_audit_test.tscn -- \
    --ui-persistence-phase="$phase" \
    --ui-persistence-isolation-token="$isolation_token" \
    --ui-persistence-root="$isolated_root"
  if rg -q "SCRIPT ERROR|Parse Error|FAIL:" "$log_path"; then
    print -u2 "UI persistence $phase phase reported an error; see $log_path"
    return 1
  fi
}

run_phase write
sleep 2
run_phase read
print "UI_PERSISTENCE_AUDIT_PASS"
