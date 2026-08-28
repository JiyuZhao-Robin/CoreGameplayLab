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
	var main := MainScene.instantiate()
	add_child(main)
	print("UI_SCENARIO_CAPTURE_READY: %s" % scenario_id)
