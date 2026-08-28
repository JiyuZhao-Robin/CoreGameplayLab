extends Node

const Builder := preload("res://tests/gameplay_scenario_builder.gd")


func _ready() -> void:
	var builder := Builder.new(Game.content)
	var scenarios := builder.available_scenarios()
	if OS.get_cmdline_user_args().has("--require-generated-scenarios"):
		var required := ["establish_industry", "prototype_complete", "megastructure_phase_1", "megastructure_phase_5", "megastructure_phase_8"]
		for scenario_id in required:
			if scenario_id not in scenarios or builder.load_state(scenario_id) == null:
				push_error("FAIL: missing or invalid generated Scenario: %s" % scenario_id)
				get_tree().quit(1)
				return
	print("PASS: GameplayScenarioBuilder accepts only normalized Golden Path states; generated=%d" % scenarios.size())
	get_tree().quit(0)
