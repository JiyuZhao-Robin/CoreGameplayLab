# RETIRED_POST_FACTORY_CUTOVER: this legacy aggregate-industry flow is kept as
# migration reference only. It is intentionally excluded from release gates
# until its extraction/production/automation section is rewritten against the
# public Factory workspace command contract.
extends Node

var failures: Array[String] = []


func _ready() -> void:
	Game.persistence_enabled = false
	Game.reset_game()
	var ship: Dictionary = Game.state.ships[0]
	var ship_id := str(ship.get("instance_id", ""))
	_check(str(ship.get("blueprint_id", "")) == "patchwork_prospector", "new game starts with the mining-first prospector")
	_check(Game.state.ship_module_definition_ids(ship).has("light_autocannon"), "starter ship already carries its baseline combat Component Design")
	var starter_world: Dictionary = Game.state.factory_worlds.get("earth-surface-grid", {})
	var starter_depot: Dictionary = starter_world.get("entities", {}).get("starter-depot", {})
	_check(
		Game.state.item_quantity("scrap_metal") == 0
		and int(starter_depot.get("inventory", {}).get("scrap_metal", 0)) == 44
		and int(starter_depot.get("inventory", {}).get("electronics", 0)) == 16
		and Game.state.item_quantity("data_core") == 2,
		"founding stockpile has one physical owner and covers the finite remote-industry bootstrap"
	)
	var selected_loadout_id := _save_starter_blueprint("Prospector Patrol")
	var second_design_id := _save_starter_blueprint("Prospector Escort")
	_check(not selected_loadout_id.is_empty() and not second_design_id.is_empty(), "one Hull can save multiple named blueprints")
	_check(Game.state.ship_designs.size() == 2 and selected_loadout_id != second_design_id, "saved blueprints have independent persistent identities")
	var initial_loadout: Array = Game.state.ship_designs[selected_loadout_id].get("modules", [])
	var initial_loadout_bom: Dictionary = Game.simulation.loadout_fabrication_costs(initial_loadout)
	_check(not initial_loadout_bom.is_empty(), "starter Loadout has a physical fabrication BOM")
	var shortage_item_id := str(initial_loadout_bom.keys()[0])
	var temporarily_removed := Game.state.item_quantity(shortage_item_id)
	if temporarily_removed > 0:
		Game.state.remove_item(shortage_item_id, temporarily_removed)
	var initial_availability := Game.ship_design_refit_availability(selected_loadout_id, ship_id)
	_check(not bool(initial_availability.get("allowed", true)) and str(initial_availability.get("reason_code", "")) == "FABRICATION_INPUT_SHORTAGE", "blueprint refit availability rejects the same missing full-BOM resources as the refit transaction")
	if temporarily_removed > 0:
		Game.state.add_item(shortage_item_id, temporarily_removed)
	for item_id_value in initial_loadout_bom.keys():
		Game.state.add_item(str(item_id_value), int(initial_loadout_bom[item_id_value]))
	_check(bool(Game.ship_design_refit_availability(selected_loadout_id, ship_id).get("allowed", false)), "blueprint refit availability becomes ready once every full-BOM input is physically available")
	_check(Game.begin_ship_design_refit(selected_loadout_id, ship_id), "a named blueprint commits a real fabrication-and-installation refit")
	_check(Game.state.refit_projects[0].get("consumed_bom", {}) == initial_loadout_bom and Game.state.ship_by_id(ship_id).get("modules", []).is_empty(), "applying even the current configuration consumes its complete ordinary-plugin BOM and dismantles the old configuration")
	Game.simulation.advance(Game.state, 1000000.0)
	_check(str(Game.state.ship_by_id(ship_id).get("current_loadout_id", "")) == selected_loadout_id, "Ship Entity persists its Current Loadout after refit completion")
	_check(Game.state.ship_by_id(ship_id).has("commissioned_at_ms"), "Ship Entity persists its Commission Date")
	Game.state.completed_activities["assemble_frame"] = 1
	var refit_desired: Array = Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id))
	refit_desired[refit_desired.find("civilian_shield")] = "cargo_expansion"
	var refit_bom: Dictionary = Game.simulation.loadout_fabrication_costs(refit_desired)
	for item_id_value in refit_bom.keys():
		Game.state.add_item(str(item_id_value), int(refit_bom[item_id_value]))
	var tracked_item := str(refit_bom.keys()[0])
	var tracked_before := Game.state.item_quantity(tracked_item)
	_check(Game.begin_ship_refit(ship_id, refit_desired), "a refit fabricates the selected complete Loadout without requiring module inventory")
	var refit_project_id := str(Game.state.refit_projects[0].get("project_id", ""))
	_check(Game.cancel_ship_refit(refit_project_id), "a running refit can be cancelled through the shared Game transaction")
	_check(Game.state.ship_module_definition_ids(Game.state.ship_by_id(ship_id)).has("light_autocannon") and Game.state.item_quantity(tracked_item) == tracked_before - int(refit_bom[tracked_item]) and Game.state.item_quantity("cargo_expansion") == 0, "refit cancellation restores the original Loadout without refunding committed materials or creating plugin stock")

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

	Game.reset_game()
	var catchup := Game.advance_game_time(30.0 * 60.0 * 60.0 * 1000.0)
	_check(is_equal_approx(float(catchup.get("simulated_ms", 0.0)), 30.0 * 60.0 * 60.0 * 1000.0) and float(catchup.get("unprocessed_ms", -1.0)) <= 0.001, "the shared online/offline orchestrator drains time beyond the Simulation 24-hour chunk cap before player commands can reorder history")

	if failures.is_empty():
		print("Gameplay Lab flow test passed")
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		get_tree().quit(1)


func _save_starter_blueprint(display_name: String) -> String:
	var nodes: Array = [{"node_id":"ship_design_hull", "kind":"hull", "definition_id":"patchwork_prospector", "position":{"x":600.0, "y":260.0}}]
	var fittings := [
		["light_autocannon", "socket_weapon_0"],
		["civilian_shield", "socket_shield_0"],
		["basic_drive", "socket_drive_0"],
		["civilian_reactor_core", "socket_core_0"]
	]
	var connections: Array = []
	for index in fittings.size():
		var node_id := "ship_design_module_%04d" % (index + 1)
		nodes.append({"node_id":node_id, "kind":"module", "definition_id":str(fittings[index][0]), "position":{"x":80.0 + float(index % 2) * 300.0, "y":80.0 + float(index / 2) * 140.0}})
		connections.append({"module_node_id":node_id, "socket_id":str(fittings[index][1])})
	if not Game.save_ship_design("", display_name, "construct_patchwork_prospector", nodes, connections):
		return ""
	return Game.last_saved_ship_design_id


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append("FAIL: " + message)
