extends Node

const MainScene := preload("res://src/ui/main.tscn")
const ScenarioBuilder := preload("res://tests/gameplay_scenario_builder.gd")


func _ready() -> void:
	var scenario_id := ""
	for argument_value in OS.get_cmdline_user_args():
		var argument := String(argument_value)
		if argument.begins_with("--ui-scenario="):
			scenario_id = argument.trim_prefix("--ui-scenario=")
	if scenario_id.is_empty():
		push_error("UI_SCENARIO_CAPTURE_ERROR: --ui-scenario is required")
		get_tree().quit(2)
		return
	var builder := ScenarioBuilder.new(Game.content)
	if not builder.activate(scenario_id):
		push_error("UI_SCENARIO_CAPTURE_ERROR: invalid generated Scenario %s" % scenario_id)
		get_tree().quit(3)
		return
	if not _prepare_industrial_network_state():
		get_tree().quit(4)
		return
	var main := MainScene.instantiate()
	add_child(main)
	print("UI_SCENARIO_CAPTURE_READY: %s" % scenario_id)


func _prepare_industrial_network_state() -> bool:
	var activity_id := ""
	var visual_state := ""
	var advance_ms := 0.0
	for argument_value in OS.get_cmdline_user_args():
		var argument := String(argument_value)
		if argument.begins_with("--network-run-activity="):
			activity_id = argument.trim_prefix("--network-run-activity=")
		elif argument.begins_with("--network-state="):
			visual_state = argument.trim_prefix("--network-state=")
		elif argument.begins_with("--network-advance-ms="):
			advance_ms = float(argument.trim_prefix("--network-advance-ms="))
	if activity_id.is_empty() and visual_state.is_empty():
		return true
	if activity_id.is_empty():
		activity_id = "separate_iron_ore"
	var activity: Dictionary = Game.content.activities.get(activity_id, {})
	if activity.is_empty():
		push_error("UI_SCENARIO_CAPTURE_ERROR: unknown network activity %s" % activity_id)
		return false
	var facility_id := str(activity.get("facility", ""))
	var location_id := SpaceGameState.MAIN_BASE_LOCATION_ID
	for argument_value in OS.get_cmdline_user_args():
		var argument := String(argument_value)
		if argument.begins_with("--network-location="):
			location_id = argument.trim_prefix("--network-location=")
	var slot := -1
	for index in Game.state.industrial_operations.size():
		var operation := Game.state.industrial_operations[index] as Dictionary
		if str(operation.get("facility_id", "")) == facility_id and str(operation.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == location_id:
			slot = index
			break
	if slot < 0:
		push_error("UI_SCENARIO_CAPTURE_ERROR: no production slot for %s at %s" % [facility_id, location_id])
		return false
	if str(Game.state.industrial_operations[slot].get("status", "IDLE")) in ["RUNNING", "BLOCKED"]:
		Game.stop_industry_operation(slot)
	if not Game.start_industry_operation(slot, activity_id):
		push_error("UI_SCENARIO_CAPTURE_ERROR: cannot start %s: %s" % [activity_id, Game.last_notice])
		return false
	match visual_state:
		"input_shortage":
			for cost_value in activity.get("costs", []):
				var item_id := str((cost_value as Dictionary).get("item", ""))
				var quantity := Game.state.item_quantity(item_id, location_id)
				if quantity > 0:
					Game.state.remove_item(item_id, quantity, location_id)
			advance_ms = maxf(advance_ms, float(activity.get("duration_ms", 1000.0)) * 2.2)
		"output_full":
			var output_id := str((activity.get("rewards", [{}])[0] as Dictionary).get("item", ""))
			var storage := Game.simulation.location_storage_snapshot(Game.state, location_id)
			var storage_class := Game.simulation.storage_class_for_item(output_id)
			var class_row: Dictionary = storage.get("classes", {}).get(storage_class, {})
			var free := maxi(0, int(floor(float(class_row.get("free", 0.0)))))
			if free > 0:
				Game.state.add_item(output_id, free, location_id)
			advance_ms = maxf(advance_ms, 1000.0)
		"power_limited":
			Game.state.location_state(location_id).get("industry", {})["power_capacity"] = 0.0
			advance_ms = maxf(advance_ms, 1000.0)
		"cooling_limited":
			Game.state.location_state(location_id).get("industry", {})["cooling_capacity"] = 0.0
			advance_ms = maxf(advance_ms, 1000.0)
		"logistics_congested":
			Game.state.location_state(location_id).get("logistics", {})["local_throughput_capacity"] = 0.0
			advance_ms = maxf(advance_ms, 1000.0)
	if advance_ms > 0.0:
		Game.advance_game_time(advance_ms)
	Game.simulation.refresh_location_summaries(Game.state)
	Game.state_changed.emit()
	print("UI_SCENARIO_NETWORK_STATE: %s activity=%s slot=%d" % [visual_state if not visual_state.is_empty() else "running", activity_id, slot])
	return true
