extends "res://tests/full_gameplay_ui_test.gd"

# Fast diagnostic only. This starts from a state captured by the no-cheat Golden
# Path and exercises the same visible Megastructure controls/helpers as the fresh
# journey. Its result is never written to the fresh-save evidence artifact.
func _run() -> void:
	Game.persistence_enabled = false
	var builder := GameplayScenarioBuilder.new(Game.content)
	var scenario_id := "megastructure_phase_1"
	var raw_probe_item := ""
	for argument_value in OS.get_cmdline_user_args():
		var argument := String(argument_value)
		if argument.begins_with("--scenario="):
			scenario_id = argument.trim_prefix("--scenario=")
		elif argument.begins_with("--raw-probe="):
			raw_probe_item = argument.trim_prefix("--raw-probe=")
	_check(builder.activate(scenario_id), "legal Golden Scenario %s activates for UI endgame diagnostics" % scenario_id)
	var main := MainScene.instantiate() as Control
	add_child(main)
	await _settle_ui()
	if not raw_probe_item.is_empty():
		# Require more than the one-unit lunar checkpoint seed so this focused
		# diagnostic necessarily exercises a physical mining cycle and freight.
		var target := Game.state.item_quantity(raw_probe_item, SpaceGameState.MAIN_BASE_LOCATION_ID) + 10
		var replenished := await _ensure_raw_resource_ui(main, raw_probe_item, target)
		_check(replenished, "scenario diagnostic replenishes %s through visible mining and logistics controls" % raw_probe_item)
		main.queue_free()
		await get_tree().process_frame
		if failures.is_empty():
			print("PASS: UI raw-resource scenario diagnostic completed")
			get_tree().quit(0)
		else:
			for failure in failures:
				print(failure)
			get_tree().quit(1)
		return
	var completed := await _complete_megastructure_ui(main)
	_check(completed, "scenario diagnostic reaches Megastructure completion through visible UI controls")
	_check(bool(Game.state.game_complete), "scenario diagnostic observes the real game-complete consequence")
	main.queue_free()
	await get_tree().process_frame
	if failures.is_empty():
		print("PASS: UI endgame scenario diagnostic completed; not fresh-save certification evidence")
		get_tree().quit(0)
	else:
		for failure in failures:
			print(failure)
		get_tree().quit(1)
