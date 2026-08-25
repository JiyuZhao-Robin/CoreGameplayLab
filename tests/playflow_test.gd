extends Node

var failures: Array[String] = []


func _ready() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	var ship: Dictionary = Game.state.ships[0]
	var ship_id := str(ship.get("instance_id", ""))
	_check(str(ship.get("blueprint_id", "")) == "patchwork_prospector", "new game starts with the mining-first prospector")
	_check(Game.state.ship_module_definition_ids(ship).has("mining_laser"), "starter ship already carries its mining Component Design")
	_check(Game.state.item_quantity("scrap_metal") == 12 and Game.state.item_quantity("electronics") == 16 and Game.state.item_quantity("data_core") == 2, "founding stockpile covers the finite bootstrap requirements")
	_check(Game.save_ship_loadout(ship_id, "Prospector Mining") and Game.save_ship_loadout(ship_id, "Prospector Escort"), "one Hull can save multiple named Loadouts")
	_check(Game.state.saved_loadouts.size() == 2 and Game.state.saved_loadouts.keys()[0] != Game.state.saved_loadouts.keys()[1], "saved Loadouts have independent persistent identities")
	var selected_loadout_id := str(Game.state.saved_loadouts.keys()[0])
	_check(Game.apply_ship_loadout(ship_id, selected_loadout_id), "a named Loadout can be scheduled as a real Starport refit")
	Game.simulation.advance(Game.state, 40000.0)
	_check(str(Game.state.ship_by_id(ship_id).get("current_loadout_id", "")) == selected_loadout_id, "Ship Entity persists its Current Loadout after refit completion")
	_check(Game.state.ship_by_id(ship_id).has("commissioned_at_ms"), "Ship Entity persists its Commission Date")

	_check(Game.set_ship_fleet_assignment(ship_id, "mining"), "starter ship can join the mining fleet")
	_check(Game.start_extraction_operation("earth_resource_cluster_prospect"), "mining fleet can start permanent extraction")
	Game.simulation.advance(Game.state, 10001.0)
	_check(Game.state.item_quantity("mixed_raw_ore") >= 2, "the first extraction cycle produces mixed raw ore")
	_check(Game.start_industry_operation(0, "separate_iron_ore"), "the first mined feedstock can enter workshop separation")
	Game.simulation.advance(Game.state, 5001.0)
	_check(Game.state.item_quantity("iron_ore") >= 2, "the first industrial cycle produces iron ore")

	if failures.is_empty():
		print("Gameplay Lab flow test passed")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append("FAIL: " + message)
