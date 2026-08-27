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
	var initial_loadout: Array = Game.state.saved_loadouts[selected_loadout_id].get("modules", [])
	var initial_loadout_bom: Dictionary = Game.simulation.loadout_fabrication_costs(initial_loadout)
	for item_id_value in initial_loadout_bom.keys():
		Game.state.add_item(str(item_id_value), int(initial_loadout_bom[item_id_value]))
	_check(Game.apply_ship_loadout(ship_id, selected_loadout_id), "a named Loadout commits a real fabrication-and-installation refit")
	_check(Game.state.refit_projects[0].get("consumed_bom", {}) == initial_loadout_bom and Game.state.ship_by_id(ship_id).get("modules", []).is_empty(), "applying even the current configuration consumes its complete ordinary-plugin BOM and dismantles the old configuration")
	Game.simulation.advance(Game.state, 1000000.0)
	_check(str(Game.state.ship_by_id(ship_id).get("current_loadout_id", "")) == selected_loadout_id, "Ship Entity persists its Current Loadout after refit completion")
	_check(Game.state.ship_by_id(ship_id).has("commissioned_at_ms"), "Ship Entity persists its Commission Date")
	Game.state.completed_activities["assemble_frame"] = 1
	var refit_desired: Array = Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id))
	refit_desired[refit_desired.find("mining_laser")] = "cargo_expansion"
	var refit_bom: Dictionary = Game.simulation.loadout_fabrication_costs(refit_desired)
	for item_id_value in refit_bom.keys():
		Game.state.add_item(str(item_id_value), int(refit_bom[item_id_value]))
	var tracked_item := str(refit_bom.keys()[0])
	var tracked_before := Game.state.item_quantity(tracked_item)
	_check(Game.begin_ship_refit(ship_id, refit_desired), "a refit fabricates the selected complete Loadout without requiring module inventory")
	var refit_project_id := str(Game.state.refit_projects[0].get("project_id", ""))
	_check(Game.cancel_ship_refit(refit_project_id), "a running refit can be cancelled through the shared Game transaction")
	_check(Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)).has("mining_laser") and Game.state.item_quantity(tracked_item) == tracked_before - int(refit_bom[tracked_item]) and Game.state.item_quantity("cargo_expansion") == 0, "refit cancellation restores the original Loadout without refunding committed materials or creating plugin stock")

	var plan_id := "construct_lunar_pathfinder"
	var plan: Dictionary = Game.content.ship_construction_projects[plan_id]
	Game.state.unlock_ship_plan(plan_id)
	var construction_totals: Dictionary = Game.simulation.ship_construction_material_totals(plan)
	for item_id_value in construction_totals.keys():
		Game.state.add_item(str(item_id_value), int(construction_totals[item_id_value]))
	for fixed_value in plan.get("fixed_costs", []):
		Game.state.add_item(str((fixed_value as Dictionary).get("item", "")), int((fixed_value as Dictionary).get("quantity", 0)))
	_check(Game.enqueue_unlocked_ship_plan(plan_id), "a Shipyard order includes its initial Loadout BOM directly in fitted-hull construction")
	var shipyard_project_id := str(Game.state.shipyard_queue[0].get("project_id", ""))
	_check(not Game.state.shipyard_queue[0].has("module_escrow") and Game.cancel_shipyard_project(shipyard_project_id), "a Shipyard order can be cancelled without any module-asset escrow")
	var retirement := Game.state._create_ship_instance("patchwork_prospector", ["cargo_expansion"], "ISS Loadout Retirement Audit")
	_check(Game.scrap_ship(str(retirement.get("instance_id", ""))), "scrapping a docked ship uses the real lifecycle transaction")
	_check(Game.state.item_quantity("cargo_expansion") == 0, "scrapping a fitted ship never turns its ordinary Loadout definitions into inventory")

	_check(Game.set_ship_fleet_assignment(ship_id, "mining"), "starter ship can join the mining fleet")
	_check(Game.start_extraction_operation("earth_resource_cluster_prospect"), "mining fleet can start permanent extraction")
	Game.simulation.advance(Game.state, 10001.0)
	_check(Game.state.item_quantity("mixed_raw_ore") >= 2, "the first extraction cycle produces mixed raw ore")
	_check(Game.start_industry_operation(0, "separate_iron_ore"), "the first mined feedstock can enter workshop separation")
	Game.simulation.advance(Game.state, 5001.0)
	_check(Game.state.item_quantity("iron_ore") >= 2, "the first industrial cycle produces iron ore")

	var production_slot := int(Game.runtime_for_domain("industry").get("slot", -1))
	_check(Game.set_production_line_control(production_slot, "PINNED", false), "a Production Line can explicitly authorize limited automation")
	var current_iron := Game.state.item_quantity("iron_ore")
	_check(Game.add_automation_rule(
		{"type":"INVENTORY_STATE", "location_id":SpaceGameState.MAIN_BASE_LOCATION_ID, "product_id":"iron_ore", "field":"stock", "operator":"GTE", "threshold":current_iron},
		{"type":"PAUSE_FACTORY", "slot":production_slot},
		1000.0,
		1.0
	), "limited Automation accepts only a pre-authorized normal transaction")
	_check(Game.run_automation_rules() == 1 and str(Game.state.industrial_operations[production_slot].get("control_mode", "")) == "OFF" and not Game.state.automation_audit.is_empty(), "Automation pauses the real Production Line and records before/after audit data")
	var revision_after_trigger := Game.state.revision
	_check(Game.run_automation_rules() == 0 and Game.state.revision == revision_after_trigger, "an unchanged active condition does not spam transactions or retrigger its action")
	_check(Game._automation_condition_active_with_hysteresis({"value":10.5, "threshold":10.0, "operator":"LT"}, {"hysteresis":1.0}, true) and not Game._automation_condition_active_with_hysteresis({"value":11.0, "threshold":10.0, "operator":"LT"}, {"hysteresis":1.0}, true), "Automation hysteresis holds the active edge until the reset boundary")

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
