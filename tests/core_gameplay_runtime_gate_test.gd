extends SceneTree

## Fresh-save runtime gate for the ten declared core gameplay journeys.
##
## This test deliberately talks only to Game's public application boundary:
## versioned Factory workspace intents, public Game commands, and deterministic
## Game.advance_game_time windows.  It never seeds or mutates Game.state.

const PROTOCOL_VERSION := 1
const EARTH_WORLD_ID := "earth-surface-grid"
const EARTH_LOCATION_ID := "earth_orbit"
const STARTER_DEPOT_ID := "starter-depot"
const STARTER_SHIP_ID := "SHIP-001"
const PRIMARY_FORMATION_ID := "task_force_1"
const REQUIRED_JOURNEYS := ["J1", "J2", "J3", "J4", "J5", "J6", "J7", "J8", "J9", "J10"]
const RUNTIME_GATE_BUILD := "prototype-fuel-v1"

var failures: Array[String] = []
var observed_events: Array[Dictionary] = []
var passed_journeys := {}
var _command_sequence := 0
var game: Node
var pathfinder_ship_id := ""
var pathfinder_formation_id := ""
var belt_cruiser_ship_id := ""
var earth_bulk_depot_id := ""
var journey_limit := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("RUNTIME_GATE_BUILD=" + RUNTIME_GATE_BUILD)
	for argument in OS.get_cmdline_user_args():
		if str(argument).begins_with("--journey-limit="):
			journey_limit = str(argument).trim_prefix("--journey-limit=").to_upper()
	if not journey_limit.is_empty() and not REQUIRED_JOURNEYS.has(journey_limit):
		_check(false, "unknown journey limit must fail closed: %s" % journey_limit)
		_finish()
		return
	game = get_root().get_node("Game")
	game.persistence_enabled = false
	game.domain_event.connect(_on_domain_event)
	game.reset_game()
	_bootstrap_earth_factory()
	_finish()


func _bootstrap_earth_factory() -> void:
	var initial_snapshot := _snapshot(EARTH_WORLD_ID)
	_check(bool(initial_snapshot.get("valid", false)), "fresh reset exposes the canonical Earth Factory workspace")
	_check(int(initial_snapshot.get("protocol_version", 0)) == PROTOCOL_VERSION, "fresh Earth workspace uses Factory protocol v1")
	if not failures.is_empty():
		return

	var plans := [
		{"label":"power", "definition_id":"grid_solar_array", "recipe_id":"", "origin":{"x":0, "y":0}},
		{"label":"iron_mine", "definition_id":"grid_surface_mine", "recipe_id":"", "origin":{"x":32, "y":32}},
		{"label":"copper_mine", "definition_id":"grid_surface_mine", "recipe_id":"", "origin":{"x":72, "y":32}},
		{"label":"iron_refinery", "definition_id":"grid_engineering_works", "recipe_id":"grid_refine_iron", "origin":{"x":0, "y":100}},
		{"label":"copper_refinery", "definition_id":"grid_engineering_works", "recipe_id":"grid_refine_copper", "origin":{"x":20, "y":100}},
		{"label":"electronics", "definition_id":"grid_engineering_works", "recipe_id":"grid_fabricate_electronics", "origin":{"x":40, "y":100}},
		{"label":"frames", "definition_id":"grid_engineering_works", "recipe_id":"grid_assemble_frame", "origin":{"x":60, "y":100}}
	]
	var entities := {}
	for plan_value in plans:
		var plan := plan_value as Dictionary
		var queued := _factory_command("QUEUE_CONSTRUCTION", {
			"definition_id":plan.get("definition_id", ""),
			"recipe_id":plan.get("recipe_id", ""),
			"origin":plan.get("origin", {}),
			"priority":50
		})
		var label := str(plan.get("label", ""))
		var order_id := str(queued.get("result", {}).get("order_id", ""))
		var entity_id := str(queued.get("result", {}).get("entity_id", ""))
		_check(bool(queued.get("accepted", false)) and not order_id.is_empty() and not entity_id.is_empty(), "fresh Factory queues %s through protocol intent" % label)
		if not bool(queued.get("accepted", false)):
			continue
		entities[label] = entity_id
		var funded := _factory_command("FUND_CONSTRUCTION", {"order_id":order_id, "storage_id":STARTER_DEPOT_ID})
		_check(bool(funded.get("accepted", false)), "physical starter inventory funds %s through protocol intent" % label)
	if not failures.is_empty():
		return

	var construction_events := _advance(240000.0, "initial Factory construction")
	_check(_events_have_type(construction_events, "FactoryConstructionCompleted"), "time advancement completes initial Factory construction orders")
	var completed_snapshot := _snapshot(EARTH_WORLD_ID)
	_check((completed_snapshot.get("construction_orders", []) as Array).is_empty(), "completed initial construction leaves no pending Factory orders")

	var power_id := str(entities.get("power", ""))
	for label in ["iron_mine", "copper_mine", "iron_refinery", "copper_refinery", "electronics", "frames"]:
		_connect("POWER", power_id, str(entities.get(label, "")), "")
	_connect("CARGO", str(entities.get("iron_mine", "")), str(entities.get("iron_refinery", "")), "iron_ore")
	_connect("CARGO", str(entities.get("copper_mine", "")), str(entities.get("copper_refinery", "")), "copper_ore")
	for label in ["electronics", "frames"]:
		_connect("CARGO", str(entities.get("iron_refinery", "")), str(entities.get(label, "")), "iron_ingot")
		_connect("CARGO", str(entities.get("copper_refinery", "")), str(entities.get(label, "")), "copper_ingot")
	for item_id in ["iron_ingot", "copper_ingot"]:
		var source_label := "iron_refinery" if item_id == "iron_ingot" else "copper_refinery"
		_connect("CARGO", str(entities.get(source_label, "")), STARTER_DEPOT_ID, item_id)
	_connect("CARGO", str(entities.get("electronics", "")), STARTER_DEPOT_ID, "electronics")
	_connect("CARGO", str(entities.get("frames", "")), STARTER_DEPOT_ID, "structural_frame")
	if not failures.is_empty():
		return

	var production_events := _advance(300000.0, "initial Factory production")
	_check(_events_have_recipe(production_events, "grid_fabricate_electronics") and _events_have_recipe(production_events, "grid_assemble_frame"), "connected Factory machines complete the declared renewable electronics and structural-frame recipes")
	var production_snapshot := _snapshot(EARTH_WORLD_ID)
	var depot := _entity(production_snapshot, STARTER_DEPOT_ID)
	var inventory: Dictionary = depot.get("inventory", {})
	_check(int(inventory.get("electronics", 0)) > 6 and int(inventory.get("structural_frame", 0)) > 0, "fresh Factory produces renewable electronics and structural frames")
	_check(_ordered_types(["FactoryConstructionQueued", "FactoryConstructionFunded", "FactoryConstructionCompleted", "FactoryEntitiesConnected", "FactoryRecipeCompleted"]), "J1 preserves the executable construction, connection, and recipe causal order")
	_journey_pass("J1", "EARLY_INDUSTRY")
	if not failures.is_empty() or _journey_limit_reached("J1"):
		return
	_complete_industrial_coordination()
	if not failures.is_empty():
		return
	_complete_capital_expansion()
	if not failures.is_empty() or _journey_limit_reached("J2"):
		return
	_complete_logistics_bottleneck()
	if not failures.is_empty() or _journey_limit_reached("J3"):
		return
	_complete_bottleneck_shift()
	if not failures.is_empty() or _journey_limit_reached("J4"):
		return
	_complete_advanced_propulsion_program()
	if not failures.is_empty() or _journey_limit_reached("J5"):
		return
	_complete_ship_industry()
	if not failures.is_empty() or _journey_limit_reached("J6"):
		return
	_complete_asteroid_survey()
	if not failures.is_empty() or _journey_limit_reached("J7"):
		return
	_complete_remote_asteroid_industry()
	if not failures.is_empty() or _journey_limit_reached("J8"):
		return
	_complete_advanced_industry()
	if not failures.is_empty() or _journey_limit_reached("J9"):
		return
	_complete_megastructure_journey()


func _complete_industrial_coordination() -> void:
	_advance(1800000.0, "renewable starter production")
	var foundry := _queue_and_fund("grid_arc_smelter", "grid_refine_iron", {"x":100, "y":100}, "foundry", false)
	var electronics_works := _queue_and_fund("grid_electronics_works", "grid_fabricate_data_core", {"x":130, "y":100}, "electronics_works", false)
	var research_complex := _queue_and_fund("grid_research_complex", "", {"x":160, "y":100}, "research_complex", true)
	if foundry.is_empty() or electronics_works.is_empty() or research_complex.is_empty() or not failures.is_empty():
		return
	var construction_events := _advance(360000.0, "physical research-facility construction")
	_check(_events_have_type(construction_events, "FactoryConstructionCompleted"), "Factory construction completes the research capability adapters")
	for entity_value in [foundry, electronics_works, research_complex]:
		var entity := entity_value as Dictionary
		_connect("POWER", "ENTITY-000001", str(entity.get("entity_id", "")), "")
	if not failures.is_empty():
		return
	_isolate_power_for(str(research_complex.get("entity_id", "")))
	if not failures.is_empty():
		return
	_export_to_location("iron_ingot", 4, "industrial-coordination-iron")
	_export_to_location("electronics", 3, "industrial-coordination-electronics")
	if not failures.is_empty():
		return
	_check(bool(game.start_research_project("research_industrial_coordination")), "public Research command starts Industrial Coordination from Factory-backed inputs")
	var research_events := _advance(600000.0, "Industrial Coordination research")
	_check(_events_have_type(research_events, "ResearchCompleted"), "Industrial Coordination completes through public time advancement; blockers=%s guidance=%s" % [JSON.stringify(game.active_blockers()), JSON.stringify(game.guidance_snapshot())])
	_check(_events_have_type(observed_events, "ResearchStarted"), "research start is published through the public domain-event boundary")


func _queue_and_fund(definition_id: String, recipe_id: String, origin: Dictionary, label: String, include_location_inventory: bool, world_id: String = EARTH_WORLD_ID, storage_id: String = STARTER_DEPOT_ID) -> Dictionary:
	var queued := _factory_command("QUEUE_CONSTRUCTION", {
		"definition_id":definition_id,
		"recipe_id":recipe_id,
		"origin":origin,
		"priority":50
	}, world_id)
	var order_id := str(queued.get("result", {}).get("order_id", ""))
	var entity_id := str(queued.get("result", {}).get("entity_id", ""))
	_check(bool(queued.get("accepted", false)) and not order_id.is_empty() and not entity_id.is_empty(), "Factory queues %s through a versioned intent; result=%s" % [label, JSON.stringify(queued)])
	if not bool(queued.get("accepted", false)):
		return {}
	if not storage_id.is_empty():
		var funded := _factory_command("FUND_CONSTRUCTION", {"order_id":order_id, "storage_id":storage_id}, world_id)
		_check(bool(funded.get("accepted", false)), "renewable Factory storage funds %s; result=%s" % [label, JSON.stringify(funded)])
	if include_location_inventory:
		var location_funded := _factory_command("FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":order_id}, world_id)
		_check(bool(location_funded.get("accepted", false)), "same-location inventory completes physical funding for %s; result=%s" % [label, JSON.stringify(location_funded)])
	return {"order_id":order_id, "entity_id":entity_id}


func _export_to_location(item_id: String, quantity: int, label: String, world_id: String = EARTH_WORLD_ID, storage_id: String = STARTER_DEPOT_ID) -> void:
	var result := _factory_command("EXPORT_TO_LOCATION", {"storage_id":storage_id, "item_id":item_id, "quantity":quantity}, world_id)
	_check(bool(result.get("accepted", false)) and int(result.get("result", {}).get("moved", 0)) == quantity, "Factory exports %d %s for %s through the application boundary; result=%s" % [quantity, item_id, label, JSON.stringify(result)])


## Raise one public Location inventory item to a finite target from completed
## Factory storage only.  This is deliberately a bounded pass over the visible
## storage inventories: it neither manufactures nor injects cargo, and returns
## the exact physical source split for later custody assertions.
func _stage_location_shortfall_from_factory(item_id: String, target_available: int, label: String, world_id: String = EARTH_WORLD_ID) -> Dictionary:
	var before_snapshot := _snapshot(world_id)
	var before_available := int((before_snapshot.get("location_available_inventory", {}) as Dictionary).get(item_id, 0))
	var remaining := maxi(0, target_available - before_available)
	var source_breakdown := {}
	for entity_value in before_snapshot.get("entities", []):
		if remaining <= 0:
			break
		var entity := entity_value as Dictionary
		var source_id := str(entity.get("id", ""))
		var source_quantity := int((entity.get("inventory", {}) as Dictionary).get(item_id, 0))
		if source_id.is_empty() or source_quantity <= 0:
			continue
		var moved := mini(remaining, source_quantity)
		_export_to_location(item_id, moved, label, world_id, source_id)
		source_breakdown[source_id] = moved
		remaining -= moved
	var after_snapshot := _snapshot(world_id)
	var after_available := int((after_snapshot.get("location_available_inventory", {}) as Dictionary).get(item_id, 0))
	_check(remaining == 0 and after_available == target_available, "public Factory custody raises %s Location availability to its exact finite target for %s; before=%d target=%d after=%d sources=%s" % [item_id, label, before_available, target_available, after_available, JSON.stringify(source_breakdown)])
	return {"before":before_available, "after":after_available, "moved":target_available - before_available, "sources":source_breakdown}


func _import_from_location(item_id: String, quantity: int, storage_id: String, label: String, world_id: String = EARTH_WORLD_ID) -> void:
	var result := _factory_command("IMPORT_FROM_LOCATION", {"storage_id":storage_id, "item_id":item_id, "quantity":quantity}, world_id)
	_check(bool(result.get("accepted", false)) and int(result.get("result", {}).get("moved", 0)) == quantity, "Factory imports %d %s for %s through the application boundary; result=%s" % [quantity, item_id, label, JSON.stringify(result)])


func _isolate_power_for(target_entity_id: String, source_id: String = "ENTITY-000001", world_id: String = EARTH_WORLD_ID) -> void:
	_isolate_power_for_targets([target_entity_id], source_id, world_id)


func _isolate_power_for_targets(target_entity_ids: Array[String], source_id: String = "ENTITY-000001", world_id: String = EARTH_WORLD_ID) -> void:
	var snapshot := _snapshot(world_id)
	for link_value in snapshot.get("links", []):
		var link := link_value as Dictionary
		if str(link.get("kind", "")) != "POWER" or str(link.get("source_id", "")) != source_id or target_entity_ids.has(str(link.get("target_id", ""))):
			continue
		var result := _factory_command("REMOVE_LINK", {"link_id":str(link.get("id", ""))}, world_id)
		_check(bool(result.get("accepted", false)), "public Factory protocol retargets limited generation to the active Factory subgraph")


func _complete_capital_expansion() -> void:
	var journey_events_start := observed_events.size()
	var before := _snapshot(EARTH_WORLD_ID)
	var frame_machine := _entity_with_recipe(before, "grid_assemble_frame")
	_check(not frame_machine.is_empty(), "the renewable starter line exposes a completed machine for post-research reconfiguration")
	if frame_machine.is_empty():
		return
	var machine_id := str(frame_machine.get("id", ""))
	var changed := _factory_command("SET_RECIPE", {"entity_id":machine_id, "recipe_id":"grid_fabricate_basic_machine_tools"})
	_check(bool(changed.get("accepted", false)), "Industrial Coordination reconfigures an existing physical machine without requiring renewable scrap")
	if not bool(changed.get("accepted", false)):
		return
	_isolate_power_for(machine_id)
	_connect("POWER", "ENTITY-000001", machine_id, "")
	_connect("CARGO", STARTER_DEPOT_ID, machine_id, "electronics")
	_connect("CARGO", STARTER_DEPOT_ID, machine_id, "structural_frame")
	_connect("CARGO", machine_id, STARTER_DEPOT_ID, "industrial_machine_tools")
	var tool_events := _advance(40000.0, "first capital-good fabrication")
	_check(_events_have_recipe(tool_events, "grid_fabricate_basic_machine_tools"), "reconfigured starter machine produces the first industrial machine tools")
	var upgraded_power := _queue_and_fund("grid_power_substation_ii", "", {"x":200, "y":0}, "power_substation_ii", false)
	if upgraded_power.is_empty() or not failures.is_empty():
		return
	var construction_events := _advance(120000.0, "capital power expansion")
	_check(_events_have_type(construction_events, "FactoryConstructionCompleted"), "renewable capital goods fund and complete the first Factory expansion")
	_check(_ordered_types(["FactoryRecipeChanged", "FactoryRecipeCompleted", "FactoryConstructionQueued", "FactoryConstructionFunded", "FactoryConstructionCompleted"], _events_after(journey_events_start)), "J2 preserves the scoped recipe-change, fabrication, and capital-expansion causal order")
	if failures.is_empty():
		_journey_pass("J2", "CAPITAL_EXPANSION")


func _complete_logistics_bottleneck() -> void:
	var journey_events_start := observed_events.size()
	_check(bool(game.set_fleet_supply_plan("chemical_propellant", 4, PRIMARY_FORMATION_ID)), "public Fleet command reserves only the Lunar-route propellant before expedition launch")
	_check(bool(game.set_ship_formation_assignment(STARTER_SHIP_ID, PRIMARY_FORMATION_ID)), "public Fleet command assigns the canonical fresh-save starter ship to its primary formation")
	_check(_events_have_type(observed_events, "ShipFormationAssignmentChanged"), "fresh-save starter assignment publishes the canonical ship identity")
	if not failures.is_empty():
		return
	_check(bool(game.start_expedition_route("lunar_route")), "public Expedition command starts the Lunar route with the founding ship")
	var lunar_events := _advance(60000.0, "Lunar route")
	_check(_events_have_type(lunar_events, "ExpeditionRouteCompleted"), "the founding ship opens Lunar Space through normal game time")
	if not failures.is_empty():
		return
	_check(bool(game.configure_logistics_service("earth_lunar_freight", "general_cargo")), "public Logistics command configures the Earth-Lunar service")
	_export_to_location("iron_ingot", 12, "first Lunar freight manifest")
	if not failures.is_empty():
		return
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot", "SUPPLY", 0, 0, 70, 1)), "Earth publishes an iron supply policy through the public Logistics boundary")
	_check(bool(game.set_location_logistics_policy("lunar_space", "iron_ingot", "DEMAND", 0, 12, 90, 1)), "Lunar Space publishes an iron demand policy through the public Logistics boundary")
	var shipment_events := _advance(100000.0, "Earth-Lunar logistics dispatch and arrival")
	var dispatched: Dictionary = _first_event(shipment_events, "ShipmentDispatched")
	var arrived: Dictionary = _first_event(shipment_events, "ShipmentArrived")
	_check(not dispatched.is_empty() and not arrived.is_empty(), "configured public logistics service dispatches and settles a physical shipment; blockers=%s" % JSON.stringify(game.active_blockers("lunar_space")))
	_check(str(dispatched.get("shipment_id", "")) == str(arrived.get("shipment_id", "")) and str(dispatched.get("origin", "")) == EARTH_LOCATION_ID and str(arrived.get("destination", "")) == "lunar_space", "J3 preserves shipment identity and route endpoints across dispatch and arrival")
	_check((dispatched.get("cargo", {}) as Dictionary) == {"iron_ingot":12} and (arrived.get("cargo", {}) as Dictionary) == {"iron_ingot":12}, "J3 dispatch and arrival preserve the exact twelve-unit iron manifest")
	_check(_ordered_types(["LogisticsServiceConfigured", "ShipmentDispatched", "ShipmentArrived"], _events_after(journey_events_start)), "J3 observes its scoped public logistics configuration and shipment settlement sequence")
	if failures.is_empty():
		_journey_pass("J3", "LOGISTICS_BOTTLENECK")


func _complete_bottleneck_shift() -> void:
	var journey_events_start := observed_events.size()
	var machine_tools := _entity_with_recipe(_snapshot(EARTH_WORLD_ID), "grid_fabricate_basic_machine_tools")
	_check(not machine_tools.is_empty(), "the capital-good machine remains addressable through the Factory snapshot")
	if machine_tools.is_empty():
		return
	var machine_id := str(machine_tools.get("id", ""))
	var depot := _queue_and_fund("grid_bulk_depot", "", {"x":230, "y":0}, "bottleneck_bulk_depot", false)
	if depot.is_empty() or not failures.is_empty():
		return
	earth_bulk_depot_id = str(depot.get("entity_id", ""))
	var construction_events := _advance(80000.0, "post-bottleneck storage construction")
	_check(_events_have_type(construction_events, "FactoryConstructionCompleted"), "the physical storage expansion completes through Factory time advancement")
	var copper_refinery := _entity_with_recipe(_snapshot(EARTH_WORLD_ID), "grid_refine_copper")
	_check(not copper_refinery.is_empty(), "the constrained copper line remains addressable through the Factory snapshot")
	if copper_refinery.is_empty() or not failures.is_empty():
		return
	var shifted := _factory_command("SET_RECIPE", {"entity_id":machine_id, "recipe_id":"grid_reprocess_industrial_waste"})
	_check(bool(shifted.get("accepted", false)) and _events_have_type(shifted.get("events", []), "FactoryRecipeChanged"), "public Factory recipe change shifts the constrained machine to industrial-waste recovery")
	if not bool(shifted.get("accepted", false)):
		return
	_connect("CARGO", str(copper_refinery.get("id", "")), machine_id, "industrial_waste")
	var recovery_events := _advance(30000.0, "post-shift industrial-waste recovery")
	_check(_events_have_recipe(recovery_events, "grid_reprocess_industrial_waste"), "reconfigured machine completes the post-bottleneck recovery recipe")
	_check(_ordered_types(["FactoryConstructionQueued", "FactoryConstructionFunded", "FactoryConstructionCompleted", "FactoryRecipeChanged", "FactoryEntitiesConnected", "FactoryRecipeCompleted"], _events_after(journey_events_start)), "J4 observes its scoped construction, recipe-change, connection, and recovery-output causal order")
	if failures.is_empty():
		_journey_pass("J4", "BOTTLENECK_SHIFT")


func _complete_advanced_propulsion_program() -> void:
	var journey_events_start := observed_events.size()
	var lunar_world_id := ""
	var emergency_works := {}
	var earth_snapshot := _snapshot(EARTH_WORLD_ID)
	var research_complex := _entity_with_definition(earth_snapshot, "grid_research_complex")
	var capital_power := _entity_with_definition(earth_snapshot, "grid_power_substation_ii")
	_check(not research_complex.is_empty() and not capital_power.is_empty(), "the completed research complex and capital power source remain visible in the Factory snapshot")
	if not research_complex.is_empty() and not capital_power.is_empty():
		_connect("POWER", str(capital_power.get("id", "")), str(research_complex.get("id", "")), "")
	if not failures.is_empty():
		return
	_check(bool(game.set_fleet_supply_plan("chemical_propellant", 8, PRIMARY_FORMATION_ID)), "public Fleet command reserves both mandatory Lunar route fuel loads")
	_check(bool(game.start_expedition_route("lunar_relay_assault")), "public Expedition command resolves the Lunar relay assault needed for advanced materials")
	var assault_events := _advance(60000.0, "Lunar relay assault")
	_check(_events_have_type(assault_events, "ExpeditionRouteCompleted"), "Lunar relay assault completes through normal game time")
	if failures.is_empty():
		var renewable_snapshot := _snapshot(EARTH_WORLD_ID)
		var frame_machine := _entity_with_recipe(renewable_snapshot, "grid_reprocess_industrial_waste")
		var iron_refinery := _entity_with_recipe(renewable_snapshot, "grid_refine_iron")
		var copper_refinery := _entity_with_recipe(renewable_snapshot, "grid_refine_copper")
		var electronics_machine := _entity_with_recipe(renewable_snapshot, "grid_fabricate_electronics")
		_check(not frame_machine.is_empty() and not iron_refinery.is_empty() and not copper_refinery.is_empty() and not electronics_machine.is_empty(), "Factory snapshot exposes the renewable Earth machines needed for remote bootstrap cargo")
		if frame_machine.is_empty() or iron_refinery.is_empty() or copper_refinery.is_empty() or electronics_machine.is_empty():
			return
		var restored_frames := _factory_command("SET_RECIPE", {"entity_id":str(frame_machine.get("id", "")), "recipe_id":"grid_assemble_frame"})
		_check(bool(restored_frames.get("accepted", false)), "Factory protocol restores structural-frame fabrication after the bottleneck shift")
		for mine_value in _entities_with_definition(renewable_snapshot, "grid_surface_mine"):
			var mine := mine_value as Dictionary
			_connect("POWER", str(capital_power.get("id", "")), str(mine.get("id", "")), "")
		_connect("POWER", str(capital_power.get("id", "")), str(iron_refinery.get("id", "")), "")
		_connect("POWER", str(capital_power.get("id", "")), str(copper_refinery.get("id", "")), "")
		_connect("POWER", str(capital_power.get("id", "")), str(electronics_machine.get("id", "")), "")
		_connect("POWER", str(capital_power.get("id", "")), str(frame_machine.get("id", "")), "")
		_ensure_connection("CARGO", str(iron_refinery.get("id", "")), str(electronics_machine.get("id", "")), "iron_ingot")
		_ensure_connection("CARGO", str(copper_refinery.get("id", "")), str(electronics_machine.get("id", "")), "copper_ingot")
		_connect("CARGO", str(iron_refinery.get("id", "")), str(frame_machine.get("id", "")), "iron_ingot")
		_connect("CARGO", str(copper_refinery.get("id", "")), str(frame_machine.get("id", "")), "copper_ingot")
		_connect("CARGO", str(frame_machine.get("id", "")), STARTER_DEPOT_ID, "structural_frame")
		var renewable_events := _advance(240000.0, "renewable remote-bootstrap production")
		_check(_events_have_recipe(renewable_events, "grid_assemble_frame"), "Earth Factory renews the structural frames required for remote bootstrap")
		if not _events_have_recipe(renewable_events, "grid_assemble_frame"):
			return
		var restored_electronics := _factory_command("SET_RECIPE", {"entity_id":str(frame_machine.get("id", "")), "recipe_id":"grid_fabricate_electronics"})
		_check(bool(restored_electronics.get("accepted", false)), "Factory protocol reconfigures the proven Earth machine to renewable electronics")
		var competing_electronics := _entity_with_recipe(_snapshot(EARTH_WORLD_ID), "grid_fabricate_electronics")
		if not competing_electronics.is_empty() and str(competing_electronics.get("id", "")) != str(frame_machine.get("id", "")):
			var idle_competing_line := _factory_command("SET_RECIPE", {"entity_id":str(competing_electronics.get("id", "")), "recipe_id":"grid_reprocess_industrial_waste"})
			_check(bool(idle_competing_line.get("accepted", false)), "Factory protocol frees the shared copper feed for the dedicated renewable-electronics line")
		_clear_competing_cargo_inputs(STARTER_DEPOT_ID, "electronics", str(frame_machine.get("id", "")))
		_connect("CARGO", str(frame_machine.get("id", "")), STARTER_DEPOT_ID, "electronics")
		var electronics_events := _advance(180000.0, "renewable electronics production")
		_check(_events_have_recipe(electronics_events, "grid_fabricate_electronics"), "Earth Factory renews the electronic components required for remote bootstrap")
		var renewable_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		var renewable_electronics := int(renewable_depot.get("inventory", {}).get("electronics", 0))
		var renewable_machine := _entity(_snapshot(EARTH_WORLD_ID), str(frame_machine.get("id", "")))
		_check(renewable_electronics >= 5, "dedicated Factory electronics production stages three remote components and two fuel-cycle components before export; depot=%s machine=%s" % [JSON.stringify(renewable_depot.get("inventory", {})), JSON.stringify(renewable_machine)])
		var emergency_machine_id := str(frame_machine.get("id", ""))
		var clear_buffer_recipe := _factory_command("SET_RECIPE", {"entity_id":emergency_machine_id, "recipe_id":"grid_reprocess_industrial_waste"})
		_check(bool(clear_buffer_recipe.get("accepted", false)), "Factory protocol reuses the existing engineering works to physically clear its incompatible industrial-waste buffer")
		var buffer_clear_events := _advance(180000.0, "reused engineering-works buffer clearance")
		_check(_events_have_recipe(buffer_clear_events, "grid_reprocess_industrial_waste"), "the reused engineering works physically consumes its retained industrial-waste buffer before receiving emergency-propellant inputs")
		var cleared_machine := _entity(_snapshot(EARTH_WORLD_ID), emergency_machine_id)
		_check(int(cleared_machine.get("inputs", {}).get("industrial_waste", 0)) <= 1, "the reused engineering works consumes its retained industrial-waste buffer down to the one-unit odd remainder and restores input capacity; machine=%s" % JSON.stringify(cleared_machine))
		if not bool(clear_buffer_recipe.get("accepted", false)) or not failures.is_empty():
			return
		var emergency_recipe := _factory_command("SET_RECIPE", {"entity_id":emergency_machine_id, "recipe_id":"grid_manufacture_emergency_propellant"})
		_check(bool(emergency_recipe.get("accepted", false)), "Factory protocol reuses the proven engineering works for emergency propellant without consuming additional fresh scrap")
		emergency_works = {"entity_id":emergency_machine_id}
		if not bool(emergency_recipe.get("accepted", false)) or not failures.is_empty():
			return
	if failures.is_empty():
		_export_to_location("scrap_metal", 6, "Lunar bootstrap cargo")
		_export_to_location("electronics", 3, "Lunar bootstrap cargo")
		_export_to_location("structural_frame", 1, "Lunar bootstrap cargo")
		_export_to_location("iron_ingot", 8, "Lunar titanium refining cargo")
	if failures.is_empty():
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "scrap_metal", "SUPPLY", 0, 0, 85, 1)), "Earth publishes the finite scrap bootstrap supply policy")
		_check(bool(game.set_location_logistics_policy("lunar_space", "scrap_metal", "DEMAND", 0, 0, 95, 1)), "Lunar Space holds the scrap request until iron funds the first real bulk depot")
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "electronics", "SUPPLY", 0, 0, 85, 1)), "Earth publishes the electronics bootstrap supply policy")
		_check(bool(game.set_location_logistics_policy("lunar_space", "electronics", "DEMAND", 0, 3, 95, 1)), "Lunar Space requests electronic construction components")
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "structural_frame", "SUPPLY", 0, 0, 85, 1)), "Earth publishes the structural-frame bootstrap supply policy")
		_check(bool(game.set_location_logistics_policy("lunar_space", "structural_frame", "DEMAND", 0, 1, 95, 1)), "Lunar Space requests the foundry construction frame")
		var bootstrap_shipment_events := _advance(240000.0, "Lunar bootstrap logistics")
		_check(_events_have_type(bootstrap_shipment_events, "ShipmentDispatched") and _events_have_type(bootstrap_shipment_events, "ShipmentArrived"), "public logistics moves the staged remote-construction manifest")
	if failures.is_empty():
		var propellant_snapshot := _snapshot(EARTH_WORLD_ID)
		var propellant_iron_source := _entity_with_recipe(propellant_snapshot, "grid_refine_iron")
		_check(not emergency_works.is_empty() and not propellant_iron_source.is_empty(), "a reused Earth engineering works and an iron refinery remain available to physically replenish freight propellant")
		if emergency_works.is_empty() or propellant_iron_source.is_empty():
			return
		var propellant_machine_id := str(emergency_works.get("entity_id", ""))
		var propellant_machine := _entity(propellant_snapshot, propellant_machine_id)
		_check(str(propellant_machine.get("recipe_id", "")) == "grid_manufacture_emergency_propellant", "reused engineering works applies its requested emergency-propellant recipe through the Factory protocol")
		_clear_competing_cargo_inputs(propellant_machine_id, "iron_ingot", str(propellant_iron_source.get("id", "")))
		_clear_competing_cargo_inputs(propellant_machine_id, "electronics", STARTER_DEPOT_ID)
		_ensure_connection("POWER", str(capital_power.get("id", "")), propellant_machine_id, "")
		_ensure_connection("CARGO", str(propellant_iron_source.get("id", "")), propellant_machine_id, "iron_ingot")
		_connect("CARGO", STARTER_DEPOT_ID, propellant_machine_id, "electronics")
		_connect("CARGO", propellant_machine_id, STARTER_DEPOT_ID, "chemical_propellant")
		var propellant_events := _advance(180000.0, "emergency freight-propellant reserve fabrication")
		var propellant_runtime := _entity(_snapshot(EARTH_WORLD_ID), propellant_machine_id)
		_check(_events_have_recipe(propellant_events, "grid_manufacture_emergency_propellant"), "Earth Factory physically fabricates the propellant needed for subsequent logistics dispatches; runtime=%s" % JSON.stringify(propellant_runtime))
		var propellant_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		_check(int(propellant_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 18, "the emergency Factory line stages eighteen physical propellant units before public freight export; inventory=%s" % JSON.stringify(propellant_depot.get("inventory", {})))
		_export_to_location("chemical_propellant", 18, "Lunar bootstrap freight reserve")
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)), "Earth publishes the emergency freight-fuel supply policy")
		var repair_recipe := _factory_command("SET_RECIPE", {"entity_id":propellant_machine_id, "recipe_id":"grid_fabricate_repair_material"})
		_check(bool(repair_recipe.get("accepted", false)), "Factory protocol reconfigures the proven emergency line into renewable route-maintenance material fabrication")
		_ensure_connection("CARGO", str(propellant_iron_source.get("id", "")), propellant_machine_id, "iron_ingot")
		_clear_competing_cargo_inputs(propellant_machine_id, "copper_ingot", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", STARTER_DEPOT_ID, propellant_machine_id, "copper_ingot")
		_ensure_connection("CARGO", propellant_machine_id, STARTER_DEPOT_ID, "repair_material")
		var repair_events := _advance(240000.0, "renewable freight-maintenance material fabrication")
		var repair_runtime := _entity(_snapshot(EARTH_WORLD_ID), propellant_machine_id)
		_check(_events_have_recipe(repair_events, "grid_fabricate_repair_material"), "Earth Factory physically fabricates the maintenance material consumed per freight dispatch; runtime=%s" % JSON.stringify(repair_runtime))
		var repair_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		_check(int(repair_depot.get("inventory", {}).get("repair_material", 0)) >= 16, "the renewable Factory line stages sixteen maintenance units before public freight export; inventory=%s" % JSON.stringify(repair_depot.get("inventory", {})))
		_export_to_location("repair_material", 16, "Lunar bootstrap and return-route maintenance reserve")
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)), "Earth publishes the physically fabricated freight-maintenance supply policy")
	if failures.is_empty():
		_check(bool(game.initialize_surveyed_factory_world("lunar_space")), "public survey result initializes the sparse Lunar Factory world")
		var lunar_world_ids: Array[String] = game.factory_world_ids_for_location("lunar_space")
		_check(lunar_world_ids.size() == 1, "the public Factory-world query returns exactly one canonical Lunar workspace")
		if lunar_world_ids.is_empty():
			return
		lunar_world_id = str(lunar_world_ids[0])
		var lunar_snapshot := _snapshot(lunar_world_id)
		var lunar_available: Dictionary = lunar_snapshot.get("location_available_inventory", {})
		_check(int(lunar_available.get("electronics", 0)) >= 3 and int(lunar_available.get("structural_frame", 0)) >= 1 and int(lunar_available.get("iron_ingot", 0)) >= 10, "Lunar logistics first delivers component cargo and the iron needed to fund the real bulk depot; available=%s" % JSON.stringify(lunar_available))
		var titanium_field := _resource_field(lunar_snapshot, "titanium_ore")
		_check(not titanium_field.is_empty(), "the surveyed Lunar workspace exposes its canonical titanium resource field")
		if titanium_field.is_empty():
			return
		var lunar_depot := _queue_and_fund("grid_bulk_depot", "", {"x":0, "y":0}, "Lunar bulk depot", true, lunar_world_id, "")
		if lunar_depot.is_empty() or not failures.is_empty():
			return
		var depot_construction_events := _advance(120000.0, "Lunar bulk depot construction")
		_check(_events_have_type(depot_construction_events, "FactoryConstructionCompleted"), "Lunar bulk depot completes before finite staging accepts the scrap bootstrap")
		var lunar_depot_id := str(lunar_depot.get("entity_id", ""))
		_import_from_location("iron_ingot", 10, lunar_depot_id, "free Lunar staging for the six-scrap bootstrap", lunar_world_id)
		_check(bool(game.set_location_logistics_policy("lunar_space", "scrap_metal", "DEMAND", 0, 6, 95, 1)), "Lunar Space releases the finite scrap request after depot funding frees staging")
		_check(bool(game.set_location_logistics_policy("lunar_space", "chemical_propellant", "DEMAND", 0, 4, 100, 1)), "Lunar Space requests a bounded return-freight propellant reserve through the same public logistics service")
		_check(bool(game.set_location_logistics_policy("lunar_space", "repair_material", "DEMAND", 0, 4, 100, 1)), "Lunar Space requests the maintenance reserve that pays its own return-freight dispatches")
		var scrap_shipment_events := _advance(120000.0, "Lunar scrap bootstrap logistics")
		_check(_events_have_type(scrap_shipment_events, "ShipmentDispatched") and _events_have_type(scrap_shipment_events, "ShipmentArrived"), "public logistics moves scrap only after the finite Lunar BULK staging is free; blockers=%s" % JSON.stringify(game.active_blockers("lunar_space")))
		var scrap_available: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
		_check(int(scrap_available.get("scrap_metal", 0)) >= 6, "Lunar staging now holds the full six-scrap solar-and-mine bootstrap; available=%s" % JSON.stringify(scrap_available))
		var lunar_power := _queue_and_fund("grid_solar_array", "", {"x":224, "y":0}, "Lunar solar array", true, lunar_world_id, "")
		var lunar_mine := _queue_and_fund("grid_surface_mine", "", titanium_field.get("footprint", {}).get("origin", {}), "Lunar titanium mine", true, lunar_world_id, "")
		if lunar_power.is_empty() or lunar_mine.is_empty() or not failures.is_empty():
			return
		var lunar_construction_events := _advance(240000.0, "Lunar solar-and-mine Factory construction")
		_check(_events_have_type(lunar_construction_events, "FactoryConstructionCompleted"), "Lunar solar and mine construction completes through Factory time advancement")
		_export_to_location("iron_ingot", 20, "Lunar foundry and furnace freight manifests")
		_check(bool(game.set_location_logistics_policy("lunar_space", "iron_ingot", "DEMAND", 0, 6, 95, 1)), "Lunar Space requests the next bounded iron manifest after the depot consumes its initial staging")
		var foundry_iron_events := _advance(120000.0, "Lunar foundry iron logistics")
		_check(_events_have_type(foundry_iron_events, "ShipmentDispatched") and _events_have_type(foundry_iron_events, "ShipmentArrived"), "public logistics refills finite Lunar staging for the foundry without displacing bootstrap scrap; blockers=%s earth_available=%s lunar_available=%s events=%s" % [JSON.stringify(game.active_blockers("lunar_space")), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})), JSON.stringify(_snapshot(lunar_world_id).get("location_available_inventory", {})), JSON.stringify(foundry_iron_events)])
		var lunar_smelter := _queue_and_fund("grid_arc_smelter", "grid_refine_titanium", {"x":100, "y":100}, "Lunar titanium foundry", true, lunar_world_id, "")
		if lunar_smelter.is_empty() or not failures.is_empty():
			return
		var foundry_construction_events := _advance(240000.0, "Lunar titanium foundry construction")
		_check(_events_have_type(foundry_construction_events, "FactoryConstructionCompleted"), "Lunar titanium foundry completes through Factory time advancement")
		_check(bool(game.set_location_logistics_policy("lunar_space", "structural_frame", "STORAGE", 0, 0, 50, 1)), "Lunar Space retires the completed foundry-frame demand before the refinery freight cycle")
		_check(bool(game.set_location_logistics_policy("lunar_space", "iron_ingot", "DEMAND", 0, 8, 95, 1)), "Lunar Space requests the first finite eight-unit furnace-feed manifest after the four-unit Factory construction commitment")
		var furnace_iron_events := _advance(120000.0, "Lunar furnace-feed logistics")
		_check(_events_have_type(furnace_iron_events, "ShipmentDispatched") and _events_have_type(furnace_iron_events, "ShipmentArrived"), "public logistics delivers furnace feed after construction staging is released; blockers=%s earth_available=%s lunar_available=%s events=%s" % [JSON.stringify(game.active_blockers("lunar_space")), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})), JSON.stringify(_snapshot(lunar_world_id).get("location_available_inventory", {})), JSON.stringify(furnace_iron_events)])
		_import_from_location("iron_ingot", 8, lunar_depot_id, "first Lunar titanium furnace-feed batch", lunar_world_id)
		_check(bool(game.set_location_logistics_policy("lunar_space", "iron_ingot", "DEMAND", 0, 2, 95, 1)), "Lunar Space requests a separate two-unit second furnace-feed batch after the first batch clears finite staging")
		var second_furnace_iron_events := _advance(120000.0, "second Lunar furnace-feed logistics")
		_check(_events_have_type(second_furnace_iron_events, "ShipmentDispatched") and _events_have_type(second_furnace_iron_events, "ShipmentArrived"), "public logistics delivers the separate two-unit furnace-feed batch after the first batch is physically imported; blockers=%s lunar_available=%s" % [JSON.stringify(game.active_blockers("lunar_space")), JSON.stringify(_snapshot(lunar_world_id).get("location_available_inventory", {}))])
		_import_from_location("iron_ingot", 2, lunar_depot_id, "second Lunar titanium furnace-feed batch", lunar_world_id)
		_connect("POWER", str(lunar_power.get("entity_id", "")), str(lunar_mine.get("entity_id", "")), "", lunar_world_id)
		_connect("POWER", str(lunar_power.get("entity_id", "")), str(lunar_smelter.get("entity_id", "")), "", lunar_world_id)
		_connect("CARGO", str(lunar_mine.get("entity_id", "")), str(lunar_smelter.get("entity_id", "")), "titanium_ore", lunar_world_id)
		_connect("CARGO", lunar_depot_id, str(lunar_smelter.get("entity_id", "")), "iron_ingot", lunar_world_id)
		_connect("CARGO", str(lunar_smelter.get("entity_id", "")), lunar_depot_id, "titanium_alloy", lunar_world_id)
		var titanium_events := _advance(360000.0, "Lunar titanium refining")
		_check(_events_have_recipe(titanium_events, "grid_refine_titanium"), "Lunar Factory produces titanium alloy from its surveyed resource field")
		var titanium_snapshot := _snapshot(lunar_world_id)
		var titanium_depot_runtime := _entity(titanium_snapshot, lunar_depot_id)
		var titanium_smelter_runtime := _entity(titanium_snapshot, str(lunar_smelter.get("entity_id", "")))
		_check(int(titanium_depot_runtime.get("inventory", {}).get("titanium_alloy", 0)) >= 10, "Lunar Factory stages ten titanium alloy through the real powered mine, smelter, and depot chain; depot=%s smelter=%s" % [JSON.stringify(titanium_depot_runtime), JSON.stringify(titanium_smelter_runtime)])
		if not failures.is_empty():
			return
		# The surveyed Lunar package intentionally has only twenty BULK units.  The
		# six bootstrap scrap have been physically consumed by the solar array and
		# mine; return the remaining 2.5 units of furnace-feed iron to the depot so
		# the location can accept the 12.5 units of refined titanium.  Keep FLUID
		# freight costs at the location so the public return shipment remains payable.
		_import_from_location("iron_ingot", 2, lunar_depot_id, "release Lunar furnace-feed staging before titanium export", lunar_world_id)
		if not failures.is_empty():
			return
		_export_to_location("titanium_alloy", 10, "Advanced Propulsion and Pathfinder material transfer", lunar_world_id, lunar_depot_id)
		_check(bool(game.set_location_logistics_policy("lunar_space", "titanium_alloy", "SUPPLY", 0, 0, 95, 1)), "Lunar Space publishes its refined-titanium supply policy")
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "titanium_alloy", "DEMAND", 0, 10, 95, 1)), "Earth requests the Advanced Propulsion and Pathfinder titanium manifest")
		var titanium_shipment_events := _advance(240000.0, "Lunar-to-Earth titanium logistics")
		_check(_events_have_type(titanium_shipment_events, "ShipmentDispatched") and _events_have_type(titanium_shipment_events, "ShipmentArrived"), "public logistics returns refined titanium to Earth; blockers=%s earth_available=%s lunar_available=%s events=%s" % [JSON.stringify(game.active_blockers("lunar_space")), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})), JSON.stringify(_snapshot(lunar_world_id).get("location_available_inventory", {})), JSON.stringify(titanium_shipment_events)])
	if failures.is_empty():
		var research_supply_snapshot := _snapshot(EARTH_WORLD_ID)
		var research_supply_machine := _entity(research_supply_snapshot, str(emergency_works.get("entity_id", "")))
		var research_iron_source := _entity_with_recipe(research_supply_snapshot, "grid_refine_iron")
		var research_copper_source := _entity_with_recipe(research_supply_snapshot, "grid_refine_copper")
		_check(not research_supply_machine.is_empty() and not research_iron_source.is_empty() and not research_copper_source.is_empty(), "Factory retains the reused engineering works plus iron and copper providers for Advanced Propulsion research inputs")
		if research_supply_machine.is_empty() or research_iron_source.is_empty() or research_copper_source.is_empty():
			return
		var research_supply_machine_id := str(research_supply_machine.get("id", ""))
		_check(not earth_bulk_depot_id.is_empty(), "J4 retains the completed bulk depot that can accept the copper line's real industrial-waste byproduct")
		if earth_bulk_depot_id.is_empty():
			return
		# SET_RECIPE atomically removed J4's incompatible waste edge when this
		# machine was repurposed. Reconnect the copper byproduct to real bulk
		# storage before restoring its primary copper-output production.
		_ensure_connection("CARGO", str(research_copper_source.get("id", "")), earth_bulk_depot_id, "industrial_waste")
		if not failures.is_empty():
			return
		# The bootstrap depot is finite and has accumulated real iron. Drain that
		# physical buffer through the J4 depot so the same Factory CARGO network
		# has capacity to return precision electronics for research.
		var starter_iron_before_reroute := int(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}).get("iron_ingot", 0))
		_ensure_connection("CARGO", STARTER_DEPOT_ID, earth_bulk_depot_id, "iron_ingot")
		if not failures.is_empty():
			return
		_advance(20000.0, "copper industrial-waste rerouting")
		var waste_depot_runtime := _entity(_snapshot(EARTH_WORLD_ID), earth_bulk_depot_id)
		var copper_after_reroute := _entity(_snapshot(EARTH_WORLD_ID), str(research_copper_source.get("id", "")))
		var starter_iron_after_reroute := int(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}).get("iron_ingot", 0))
		_check(int(waste_depot_runtime.get("inventory", {}).get("industrial_waste", 0)) > 0 and int(waste_depot_runtime.get("inventory", {}).get("iron_ingot", 0)) > 0 and starter_iron_after_reroute < starter_iron_before_reroute and int(copper_after_reroute.get("outputs", {}).get("industrial_waste", 0)) < 63, "the completed Earth bulk depot physically receives both the copper line's waste byproduct and starter iron, releasing copper output and finite component-storage headroom; depot=%s starter_iron=%d->%d copper=%s" % [JSON.stringify(waste_depot_runtime), starter_iron_before_reroute, starter_iron_after_reroute, JSON.stringify(copper_after_reroute)])
		if not failures.is_empty():
			return
		# This reused machine still holds a finite J4/J5 buffer. Consume its real
		# electronics and frames into useful machine tools so copper can enter; do
		# not erase inputs or bypass the Factory's capacity authority.
		var buffer_tools_recipe := _factory_command("SET_RECIPE", {"entity_id":research_supply_machine_id, "recipe_id":"grid_fabricate_basic_machine_tools"})
		_check(bool(buffer_tools_recipe.get("accepted", false)), "Factory protocol assigns a compatible physical recipe to consume the reused machine's electronic and frame buffer")
		_clear_competing_cargo_inputs(research_supply_machine_id, "iron_ingot", "")
		_clear_competing_cargo_inputs(research_supply_machine_id, "electronics", "")
		_clear_competing_cargo_inputs(research_supply_machine_id, "structural_frame", "")
		_ensure_connection("POWER", str(capital_power.get("id", "")), research_supply_machine_id, "")
		_ensure_connection("CARGO", research_supply_machine_id, STARTER_DEPOT_ID, "industrial_machine_tools")
		var buffer_tools_events := _advance(40000.0, "reused-machine cached-component recovery")
		var buffer_recovered_machine := _entity(_snapshot(EARTH_WORLD_ID), research_supply_machine_id)
		_check(_events_have_recipe(buffer_tools_events, "grid_fabricate_basic_machine_tools") and int(buffer_recovered_machine.get("inputs", {}).get("structural_frame", 0)) == 0 and int(buffer_recovered_machine.get("inputs", {}).get("electronics", 0)) <= 7, "the reused machine physically converts cached frames and electronics into useful tools, freeing copper-input capacity; machine=%s" % JSON.stringify(buffer_recovered_machine))
		if not failures.is_empty():
			return
		var research_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":research_supply_machine_id, "recipe_id":"grid_fabricate_electronics"})
		_check(bool(research_electronics_recipe.get("accepted", false)), "Factory protocol returns the reused engineering works to renewable electronics before the Advanced Propulsion theory stage")
		if not bool(research_electronics_recipe.get("accepted", false)):
			return
		_ensure_connection("POWER", str(capital_power.get("id", "")), research_supply_machine_id, "")
		_ensure_connection("POWER", str(capital_power.get("id", "")), str(research_iron_source.get("id", "")), "")
		_ensure_connection("POWER", str(capital_power.get("id", "")), str(research_copper_source.get("id", "")), "")
		_clear_competing_cargo_inputs(research_supply_machine_id, "iron_ingot", str(research_iron_source.get("id", "")))
		_clear_competing_cargo_inputs(research_supply_machine_id, "copper_ingot", str(research_copper_source.get("id", "")))
		_ensure_connection("CARGO", str(research_iron_source.get("id", "")), research_supply_machine_id, "iron_ingot")
		_ensure_connection("CARGO", str(research_copper_source.get("id", "")), research_supply_machine_id, "copper_ingot")
		_ensure_connection("CARGO", research_supply_machine_id, STARTER_DEPOT_ID, "electronics")
		_isolate_power_for_targets([research_supply_machine_id, str(research_iron_source.get("id", "")), str(research_copper_source.get("id", ""))], str(capital_power.get("id", "")))
		var research_supply_events := _advance(180000.0, "Advanced Propulsion research-electronics fabrication")
		var research_supply_runtime := _entity(_snapshot(EARTH_WORLD_ID), research_supply_machine_id)
		_check(_events_have_recipe(research_supply_events, "grid_fabricate_electronics"), "Factory physically manufactures the two electronic inputs required across Advanced Propulsion theory and industrialization; events=%s machine=%s iron=%s copper=%s" % [JSON.stringify(research_supply_events), JSON.stringify(research_supply_runtime), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), str(research_iron_source.get("id", "")))), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), str(research_copper_source.get("id", ""))))])
		var research_supply_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		_check(int(research_supply_depot.get("inventory", {}).get("electronics", 0)) >= 2, "Factory stages both Advanced Propulsion research electronics before export; inventory=%s" % JSON.stringify(research_supply_depot.get("inventory", {})))
		_export_to_location("electronics", 2, "Advanced Propulsion theory and industrialization research inputs")
		if not failures.is_empty():
			return
		var research_complex_id := str(research_complex.get("id", ""))
		_isolate_power_for(research_complex_id, str(capital_power.get("id", "")))
		_ensure_connection("POWER", str(capital_power.get("id", "")), research_complex_id, "")
		if not failures.is_empty():
			return
		_check(bool(game.start_research_project("research_advanced_propulsion", "HIGH_THRUST")), "public Research command starts the multi-stage Advanced Propulsion program")
		var theory_events := _advance(60000.0, "Advanced Propulsion theory")
		_check(_events_have_type(theory_events, "ResearchStageCompleted"), "Advanced Propulsion completes its first real research stage; runtime=%s blockers=%s guidance=%s events=%s" % [JSON.stringify(game.research_runtime_snapshot()), JSON.stringify(game.active_blockers()), JSON.stringify(game.guidance_snapshot()), JSON.stringify(theory_events)])
		if not failures.is_empty():
			return
		var refreshed_earth := _snapshot(EARTH_WORLD_ID)
		var electronics_works := _entity_with_definition(refreshed_earth, "grid_electronics_works")
		var earth_bulk_depot := _entity(refreshed_earth, earth_bulk_depot_id)
		_check(not electronics_works.is_empty() and not earth_bulk_depot.is_empty(), "the completed Earth electronics works and J4 bulk depot remain addressable for the prototype article")
		if electronics_works.is_empty() or earth_bulk_depot.is_empty():
			return
		# J4's bulk depot is deliberately carrying the iron released from the finite
		# starter buffer. Stage this small prototype manifest in the now-released
		# starter depot instead of bypassing that real capacity constraint.
		_import_from_location("titanium_alloy", 2, STARTER_DEPOT_ID, "prototype chamber fabrication")
		if not failures.is_empty():
			return
		var set_article_recipe := _factory_command("SET_RECIPE", {"entity_id":str(electronics_works.get("id", "")), "recipe_id":"grid_fabricate_propulsion_test_article"})
		_check(bool(set_article_recipe.get("accepted", false)), "Factory protocol assigns the unlocked prototype-chamber recipe")
		_connect("POWER", str(capital_power.get("id", "")), str(electronics_works.get("id", "")), "")
		_connect("CARGO", STARTER_DEPOT_ID, str(electronics_works.get("id", "")), "titanium_alloy")
		_connect("CARGO", STARTER_DEPOT_ID, str(electronics_works.get("id", "")), "electronics")
		_connect("CARGO", str(electronics_works.get("id", "")), STARTER_DEPOT_ID, "propulsion_test_article")
		var article_events := _advance(180000.0, "prototype propulsion-chamber fabrication")
		_check(_events_have_recipe(article_events, "grid_fabricate_propulsion_test_article"), "Factory completes the required prototype propulsion chamber")
		_export_to_location("scrap_metal", 2, "post-prototype Lunar solar expansion material")
		if not failures.is_empty():
			return
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "scrap_metal", "SUPPLY", 0, 0, 100, 1)), "Earth publishes the finite post-prototype Lunar power material supply")
		_check(bool(game.set_location_logistics_policy("lunar_space", "scrap_metal", "DEMAND", 0, 2, 100, 1)), "Lunar Space requests the exact two-unit solar-expansion manifest")
		var lunar_power_manifest_events := _advance(120000.0, "post-prototype Lunar solar material logistics")
		_check(_events_have_type(lunar_power_manifest_events, "ShipmentDispatched") and _events_have_type(lunar_power_manifest_events, "ShipmentArrived"), "public logistics delivers the finite post-prototype Lunar solar manifest before Factory funding; blockers=%s lunar_available=%s events=%s" % [JSON.stringify(game.active_blockers("lunar_space")), JSON.stringify(_snapshot(lunar_world_id).get("location_available_inventory", {})), JSON.stringify(lunar_power_manifest_events)])
		if not failures.is_empty():
			return
		var post_prototype_power := _queue_and_fund("grid_solar_array", "", {"x":244, "y":0}, "post-prototype Lunar power expansion", true, lunar_world_id, "")
		if post_prototype_power.is_empty() or not failures.is_empty():
			return
		var post_prototype_construction_events := _advance(90000.0, "post-prototype Lunar power construction")
		_check(_events_have_type(post_prototype_construction_events, "FactoryConstructionCompleted"), "Factory completes the declared post-prototype construction milestone")
		_export_to_location("propulsion_test_article", 2, "Advanced Propulsion prototype stage")
		var prototype_resume_accepted := bool(game.start_research_project("research_advanced_propulsion", "HIGH_THRUST"))
		# EXPORT_TO_LOCATION refreshes Factory-dependent runtimes atomically. It may
		# already have resumed this blocked program before the explicit command
		# reaches Research; assert the public, identity-bearing runtime projection.
		var prototype_resume_runtime: Dictionary = game.research_runtime_snapshot()
		_check(str(prototype_resume_runtime.get("project_id", "")) == "research_advanced_propulsion" and str(prototype_resume_runtime.get("status", "")) == "RUNNING" and str(prototype_resume_runtime.get("stage_id", "")) == "prototype" and str(prototype_resume_runtime.get("route_id", "")) == "HIGH_THRUST", "Factory transfer restores the exact Advanced Propulsion prototype runtime before it progresses; start_accepted=%s runtime=%s" % [str(prototype_resume_accepted), JSON.stringify(prototype_resume_runtime)])
		var prototype_events := _advance(60000.0, "Advanced Propulsion prototype stage")
		_check(prototype_events.any(func(event_value):
			var event := event_value as Dictionary
			return str(event.get("type", "")) == "ResearchStageCompleted" and str(event.get("project_id", "")) == "research_advanced_propulsion" and str(event.get("stage_id", "")) == "prototype"
		), "Factory transfer advances the restored Advanced Propulsion program through its manufactured prototype stage")
		_check(bool(game.start_expedition_route("propulsion_proving_route")), "public Expedition command launches the required propulsion proving flight")
		var proving_events := _advance(60000.0, "propulsion proving flight")
		_check(_events_have_type(proving_events, "ExpeditionRouteCompleted"), "propulsion proving flight completes through normal game time")
		# The prototype recipe has completed, so release its old electronics input
		# port and keep the original iron/copper electronics line physically running.
		# This supplies the industrial-release component without inventing custody.
		_clear_competing_cargo_inputs(str(electronics_works.get("id", "")), "electronics", "")
		_ensure_connection("POWER", str(capital_power.get("id", "")), research_supply_machine_id, "")
		_ensure_connection("POWER", str(capital_power.get("id", "")), str(research_iron_source.get("id", "")), "")
		_ensure_connection("POWER", str(capital_power.get("id", "")), str(research_copper_source.get("id", "")), "")
		_clear_competing_cargo_inputs(research_supply_machine_id, "iron_ingot", str(research_iron_source.get("id", "")))
		_clear_competing_cargo_inputs(research_supply_machine_id, "copper_ingot", str(research_copper_source.get("id", "")))
		_ensure_connection("CARGO", str(research_iron_source.get("id", "")), research_supply_machine_id, "iron_ingot")
		_ensure_connection("CARGO", str(research_copper_source.get("id", "")), research_supply_machine_id, "copper_ingot")
		_ensure_connection("CARGO", research_supply_machine_id, STARTER_DEPOT_ID, "electronics")
		var industrial_electronics_events := _advance(60000.0, "Advanced Propulsion industrial electronics fabrication")
		var industrial_electronics_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		_check(_events_have_recipe(industrial_electronics_events, "grid_fabricate_electronics") and int(industrial_electronics_depot.get("inventory", {}).get("electronics", 0)) >= 1, "Factory physically replenishes an electronic component into storage for Advanced Propulsion industrial release; depot=%s events=%s" % [JSON.stringify(industrial_electronics_depot.get("inventory", {})), JSON.stringify(industrial_electronics_events)])
		if not failures.is_empty():
			return
		_export_to_location("electronics", 1, "Advanced Propulsion industrial-release input")
		if not failures.is_empty():
			return
		var field_test_resume_accepted := bool(game.start_research_project("research_advanced_propulsion", "HIGH_THRUST"))
		var industrial_resume_runtime: Dictionary = game.research_runtime_snapshot()
		_check(str(industrial_resume_runtime.get("project_id", "")) == "research_advanced_propulsion" and str(industrial_resume_runtime.get("status", "")) == "RUNNING" and str(industrial_resume_runtime.get("stage_id", "")) == "industrialization" and str(industrial_resume_runtime.get("route_id", "")) == "HIGH_THRUST", "completed proving flight restores the exact Advanced Propulsion industrial-release runtime; start_accepted=%s runtime=%s" % [str(field_test_resume_accepted), JSON.stringify(industrial_resume_runtime)])
		var industrial_release_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var industrial_release_blockers: Array = game.active_blockers("research")
		var completion_events := _advance(120000.0, "Advanced Propulsion industrial release")
		_check(_events_have_type(completion_events, "ResearchCompleted"), "Advanced Propulsion completes all stages and releases its technology; pre_release_available=%s pre_release_blockers=%s proving_events=%s completion_events=%s" % [JSON.stringify(industrial_release_available), JSON.stringify(industrial_release_blockers), JSON.stringify(proving_events), JSON.stringify(completion_events)])
		_check(_ordered_types(["ResearchStarted", "ResearchStageCompleted", "FactoryRecipeCompleted", "FactoryConstructionCompleted", "ResearchCompleted"], _events_after(journey_events_start)), "J5 observes the declared research, Factory, and completion event contract")
		if failures.is_empty():
			_journey_pass("J5", "RESEARCH_PROGRAM")


func _complete_ship_industry() -> void:
	var journey_events_start := observed_events.size()
	var earth_snapshot := _snapshot(EARTH_WORLD_ID)
	var capital_power := _entity_with_definition(earth_snapshot, "grid_power_substation_ii")
	var foundry := _entity_with_definition(earth_snapshot, "grid_arc_smelter")
	_check(not capital_power.is_empty() and not foundry.is_empty(), "the powered Earth Factory retains the orbital foundry required to manufacture non-random Pathfinder reactor parts")
	if capital_power.is_empty() or foundry.is_empty():
		return
	var foundry_id := str(foundry.get("id", ""))
	var reactor_recipe := _factory_command("SET_RECIPE", {"entity_id":foundry_id, "recipe_id":"grid_fabricate_reactor_part"})
	_check(bool(reactor_recipe.get("accepted", false)), "Factory protocol selects deterministic reactor-part fabrication for Shipyard inputs")
	if not bool(reactor_recipe.get("accepted", false)):
		return
	_ensure_connection("POWER", str(capital_power.get("id", "")), foundry_id, "")
	for item_id in ["iron_ingot", "copper_ingot", "electronics"]:
		_clear_competing_cargo_inputs(foundry_id, item_id, STARTER_DEPOT_ID)
		_ensure_connection("CARGO", STARTER_DEPOT_ID, foundry_id, item_id)
	_ensure_connection("CARGO", foundry_id, STARTER_DEPOT_ID, "reactor_part")
	var reactor_events := _advance(60000.0, "Pathfinder reactor-part fabrication")
	_check(_events_have_recipe(reactor_events, "grid_fabricate_reactor_part"), "Factory manufactures the Pathfinder reactor parts without patrol-loot dependency")
	var reactor_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(int(reactor_depot.get("inventory", {}).get("reactor_part", 0)) >= 2, "Factory storage holds both physical Pathfinder reactor parts before Shipyard staging")
	if not failures.is_empty():
		return
	# The saved Pathfinder design carries a real hull-plus-module manufacturing
	# BOM. Reconfigure existing powered lines to replenish the missing precision
	# electronics and scanner data cores before exporting that manifest.
	var shipyard_supply_snapshot := _snapshot(EARTH_WORLD_ID)
	var renewable_electronics := _entity_with_recipe(shipyard_supply_snapshot, "grid_fabricate_electronics")
	var iron_refinery := _entity_with_recipe(shipyard_supply_snapshot, "grid_refine_iron")
	var copper_refinery := _entity_with_recipe(shipyard_supply_snapshot, "grid_refine_copper")
	var iron_mine := _entity_with_resource(shipyard_supply_snapshot, "iron_ore")
	var copper_mine := _entity_with_resource(shipyard_supply_snapshot, "copper_ore")
	var electronics_works := _entity_with_definition(shipyard_supply_snapshot, "grid_electronics_works")
	_check(not renewable_electronics.is_empty() and not iron_refinery.is_empty() and not copper_refinery.is_empty() and not iron_mine.is_empty() and not copper_mine.is_empty() and not electronics_works.is_empty(), "Earth Factory exposes the physical iron, copper, electronics, and data-core providers required by the saved Pathfinder BOM")
	if not failures.is_empty():
		return
	var renewable_electronics_id := str(renewable_electronics.get("id", ""))
	var iron_refinery_id := str(iron_refinery.get("id", ""))
	var copper_refinery_id := str(copper_refinery.get("id", ""))
	var electronics_works_id := str(electronics_works.get("id", ""))
	var data_core_recipe := _factory_command("SET_RECIPE", {"entity_id":electronics_works_id, "recipe_id":"grid_fabricate_data_core"})
	_check(bool(data_core_recipe.get("accepted", false)), "Factory protocol assigns data-core fabrication for the Pathfinder scanner BOM")
	_ensure_connection("POWER", str(capital_power.get("id", "")), renewable_electronics_id, "")
	_ensure_connection("POWER", str(capital_power.get("id", "")), str(iron_mine.get("id", "")), "")
	_ensure_connection("POWER", str(capital_power.get("id", "")), str(copper_mine.get("id", "")), "")
	_ensure_connection("POWER", str(capital_power.get("id", "")), iron_refinery_id, "")
	_ensure_connection("POWER", str(capital_power.get("id", "")), copper_refinery_id, "")
	_ensure_connection("POWER", str(capital_power.get("id", "")), electronics_works_id, "")
	_clear_competing_cargo_inputs(renewable_electronics_id, "iron_ingot", iron_refinery_id)
	_clear_competing_cargo_inputs(renewable_electronics_id, "copper_ingot", copper_refinery_id)
	# Stage the full electronics reserve before letting the data-core line consume
	# it.  Both phases use physical Factory links, so the saved-design BOM remains
	# custody-backed rather than being inferred from an eventual recipe output.
	_clear_competing_cargo_inputs(electronics_works_id, "electronics", "")
	_clear_competing_cargo_inputs(electronics_works_id, "copper_ingot", copper_refinery_id)
	_ensure_connection("CARGO", iron_refinery_id, renewable_electronics_id, "iron_ingot")
	_ensure_connection("CARGO", copper_refinery_id, renewable_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", renewable_electronics_id, STARTER_DEPOT_ID, "electronics")
	var electronics_staging_events := _advance(120000.0, "Pathfinder electronics reserve fabrication")
	var electronics_staging_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var electronics_staging_machine := _entity(_snapshot(EARTH_WORLD_ID), renewable_electronics_id)
	var iron_staging_machine := _entity(_snapshot(EARTH_WORLD_ID), iron_refinery_id)
	var copper_staging_machine := _entity(_snapshot(EARTH_WORLD_ID), copper_refinery_id)
	_check(_events_have_recipe(electronics_staging_events, "grid_fabricate_electronics") and int(electronics_staging_depot.get("inventory", {}).get("electronics", 0)) >= 16, "Factory physically stages the electronics reserve before scanner-data consumption; depot=%s electronics_machine=%s iron_machine=%s copper_machine=%s events=%s" % [JSON.stringify(electronics_staging_depot.get("inventory", {})), JSON.stringify(electronics_staging_machine), JSON.stringify(iron_staging_machine), JSON.stringify(copper_staging_machine), JSON.stringify(electronics_staging_events)])
	if not failures.is_empty():
		return
	# Export the component reserve before the data-core link is enabled. CARGO
	# transfers are intentionally unthrottled, so leaving the reserve in the
	# source depot would correctly make all of it available to the data-core
	# machine. The Location is the public Shipyard/research custody boundary.
	_export_to_location("electronics", 12, "Pathfinder development and full saved-design Shipyard BOM")
	if not failures.is_empty():
		return
	# Copper refinement is physically gated by its industrial-waste output. Reuse
	# the now-surplus electronics line to consume that real buffer before asking
	# the refinery for the scanner-data copper batch.
	var waste_recovery_recipe := _factory_command("SET_RECIPE", {"entity_id":renewable_electronics_id, "recipe_id":"grid_reprocess_industrial_waste"})
	_check(bool(waste_recovery_recipe.get("accepted", false)), "Factory protocol assigns physical industrial-waste recovery before Pathfinder scanner-data copper refinement")
	if not bool(waste_recovery_recipe.get("accepted", false)):
		return
	_clear_competing_cargo_outputs(copper_refinery_id, "industrial_waste", renewable_electronics_id)
	_ensure_connection("CARGO", copper_refinery_id, renewable_electronics_id, "industrial_waste")
	var waste_recovery_events := _advance(60000.0, "Pathfinder copper-refinery waste recovery")
	var recovered_copper_refinery := _entity(_snapshot(EARTH_WORLD_ID), copper_refinery_id)
	_check(_events_have_recipe(waste_recovery_events, "grid_reprocess_industrial_waste") and int(recovered_copper_refinery.get("outputs", {}).get("industrial_waste", 0)) < 64, "Factory physically consumes the copper refinery waste buffer before scanner-data copper fabrication; refinery=%s" % JSON.stringify(recovered_copper_refinery))
	if not failures.is_empty():
		return
	_ensure_connection("CARGO", STARTER_DEPOT_ID, electronics_works_id, "electronics")
	_ensure_connection("CARGO", copper_refinery_id, electronics_works_id, "copper_ingot")
	# The original renewable-electronics reserve is now in Location custody, so
	# redirect the scarce physical copper source from its old output consumers to
	# the data-core machine for this bounded scanner-material batch.
	_clear_competing_cargo_outputs(copper_refinery_id, "copper_ingot", electronics_works_id)
	_ensure_connection("CARGO", electronics_works_id, STARTER_DEPOT_ID, "data_core")
	var shipyard_supply_events := _advance(60000.0, "Pathfinder scanner-data fabrication")
	# Recipe completion writes its output to the machine buffer; the next public
	# simulation tick is the CARGO handoff into the finite Factory depot.
	_advance(2.0, "Pathfinder scanner-data physical depot transfer")
	var shipyard_supply_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var scanner_data_machine := _entity(_snapshot(EARTH_WORLD_ID), electronics_works_id)
	_check(_events_have_recipe(shipyard_supply_events, "grid_fabricate_data_core") and int(shipyard_supply_depot.get("inventory", {}).get("data_core", 0)) >= 3, "Factory physically stages the scanner-data portion of the full saved Pathfinder Shipyard BOM after its electronic reserve has crossed the public custody boundary; depot=%s scanner_machine=%s events=%s" % [JSON.stringify(shipyard_supply_depot.get("inventory", {})), JSON.stringify(scanner_data_machine), JSON.stringify(shipyard_supply_events)])
	if not failures.is_empty():
		return
	_export_to_location("reactor_part", 2, "Pathfinder Shipyard reactor BOM")
	_export_to_location("data_core", 3, "Pathfinder development and sensor-array Shipyard BOM")
	_export_to_location("iron_ingot", 5, "Pathfinder hull and module Shipyard BOM")
	_export_to_location("copper_ingot", 3, "Pathfinder hull and module Shipyard BOM")
	var pathfinder_location_inventory: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(pathfinder_location_inventory.get("titanium_alloy", 0)) >= 5 and int(pathfinder_location_inventory.get("electronics", 0)) >= 12 and int(pathfinder_location_inventory.get("data_core", 0)) >= 3 and int(pathfinder_location_inventory.get("iron_ingot", 0)) >= 7 and int(pathfinder_location_inventory.get("copper_ingot", 0)) >= 3 and int(pathfinder_location_inventory.get("reactor_part", 0)) >= 2, "Factory exports the full pre-development Pathfinder research and saved-design Shipyard BOM to Earth custody; available=%s" % JSON.stringify(pathfinder_location_inventory))
	if not failures.is_empty():
		return
	_check(bool(game.start_research_project("develop_lunar_pathfinder")), "public Research command develops the canonical Lunar Pathfinder plan")
	var development_events := _advance(120000.0, "Lunar Pathfinder development")
	_check(_events_have_type(development_events, "ResearchCompleted"), "Pathfinder development completes through public research time")
	var post_development_inventory: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(post_development_inventory.get("titanium_alloy", 0)) >= 5 and int(post_development_inventory.get("electronics", 0)) >= 10 and int(post_development_inventory.get("data_core", 0)) >= 2 and int(post_development_inventory.get("iron_ingot", 0)) >= 7 and int(post_development_inventory.get("copper_ingot", 0)) >= 3 and int(post_development_inventory.get("reactor_part", 0)) >= 2, "research consumption leaves the complete one-hundred-cycle saved Pathfinder Shipyard BOM in Earth custody; available=%s" % JSON.stringify(post_development_inventory))
	if not failures.is_empty():
		return
	var design_nodes := [
		{"node_id":"hull", "kind":"hull", "definition_id":"lunar_pathfinder", "position":{"x":0.0, "y":0.0}},
		{"node_id":"weapon", "kind":"module", "definition_id":"light_autocannon", "position":{"x":100.0, "y":0.0}},
		{"node_id":"shield", "kind":"module", "definition_id":"civilian_shield", "position":{"x":100.0, "y":40.0}},
		{"node_id":"drive", "kind":"module", "definition_id":"advanced_drive", "position":{"x":100.0, "y":80.0}},
		{"node_id":"sensor", "kind":"module", "definition_id":"sensor_array", "position":{"x":100.0, "y":120.0}},
		{"node_id":"core", "kind":"module", "definition_id":"civilian_reactor_core", "position":{"x":100.0, "y":160.0}}
	]
	var design_connections := [
		{"module_node_id":"weapon", "socket_id":"socket_weapon_0"},
		{"module_node_id":"shield", "socket_id":"socket_shield_0"},
		{"module_node_id":"drive", "socket_id":"socket_drive_0"},
		{"module_node_id":"sensor", "socket_id":"socket_utility_0"},
		{"module_node_id":"core", "socket_id":"socket_core_0"}
	]
	var design_validation: Dictionary = game.ship_design_validation("construct_lunar_pathfinder", design_nodes, design_connections)
	_check(bool(design_validation.get("allowed", false)), "public ship-design validation accepts the complete canonical Pathfinder hull and module graph")
	var saved_design_events_start := observed_events.size()
	_check(bool(game.save_ship_design("", "Runtime Pathfinder", "construct_lunar_pathfinder", design_nodes, design_connections)), "public Ship Design command saves the validated Pathfinder graph with an API-assigned identity")
	var saved_design_event := _first_event(_events_after(saved_design_events_start), "ShipDesignSaved")
	var design_id := str(saved_design_event.get("design_id", ""))
	_check(not design_id.is_empty(), "Ship Design save publishes the assigned Pathfinder design identity")
	var engineering_summary: Dictionary = game.ship_design_engineering_summary("construct_lunar_pathfinder", design_nodes, design_connections)
	var expected_shipyard_costs: Dictionary = engineering_summary.get("construction_costs", {}).duplicate(true)
	var expected_modules: Array = design_validation.get("modules", []).duplicate()
	var queue_events_start := observed_events.size()
	_check(not design_id.is_empty() and bool(game.enqueue_saved_ship_design(design_id)), "public Shipyard command queues the saved Pathfinder design rather than a disconnected generic plan")
	var design_queued_event := _first_event(_events_after(queue_events_start), "ShipDesignQueued")
	_check(str(design_queued_event.get("design_id", "")) == design_id and str(design_queued_event.get("plan_id", "")) == "construct_lunar_pathfinder" and int(design_queued_event.get("quantity", 0)) == 1, "ShipDesignQueued identifies the exact saved Pathfinder design, plan, and quantity")
	var shipyard_events := _advance(120000.0, "Lunar Pathfinder Shipyard construction")
	var construction_event := _first_event(shipyard_events, "ShipConstructionCompleted")
	var shipbuilding_cycles: Array = shipyard_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "ShipbuildingCycleCompleted" and str(event.get("plan_id", "")) == "construct_lunar_pathfinder"
	)
	var exact_cycle_sequence := shipbuilding_cycles.size() == 100
	for cycle_index in shipbuilding_cycles.size():
		if int((shipbuilding_cycles[cycle_index] as Dictionary).get("segments", 0)) != cycle_index + 1:
			exact_cycle_sequence = false
			break
	_check(exact_cycle_sequence and not construction_event.is_empty() and str(construction_event.get("plan_id", "")) == "construct_lunar_pathfinder" and int(construction_event.get("segments", 0)) == 100, "Shipyard completes the physically funded Pathfinder plan through the exact one-hundred-cycle sequence")
	_check(str(construction_event.get("design_id", "")) == design_id and (construction_event.get("module_ids", []) as Array) == expected_modules and (construction_event.get("consumed", {}) as Dictionary) == expected_shipyard_costs and bool(construction_event.get("created", false)), "Ship construction publishes the exact saved design, resolved loadout, and fully debited BOM; event=%s expected=%s" % [JSON.stringify(construction_event), JSON.stringify(expected_shipyard_costs)])
	var pathfinder_candidates: Array = game.ship_design_refit_candidates(design_id)
	_check(pathfinder_candidates.size() == 1, "public design-refit candidate query exposes exactly one constructed Pathfinder instance")
	if pathfinder_candidates.size() != 1 or not failures.is_empty():
		return
	pathfinder_ship_id = str(pathfinder_candidates[0])
	var formation_events_start := observed_events.size()
	_check(bool(game.create_fleet_formation("Pathfinder Survey Group")), "public Fleet command creates a dedicated Pathfinder formation")
	var formation_event := _first_event(_events_after(formation_events_start), "FleetFormationCreated")
	var formation_id := str(formation_event.get("formation_id", ""))
	_check(not formation_id.is_empty() and bool(game.set_ship_formation_assignment(pathfinder_ship_id, formation_id)), "public Fleet command assigns the constructed Pathfinder instance to its new formation")
	pathfinder_formation_id = formation_id
	var resupply_events_start := observed_events.size()
	_check(bool(game.set_fleet_supply_plan("kinetic_munitions", 1, formation_id)) and bool(game.auto_resupply_fleet(formation_id, [pathfinder_ship_id])), "public Fleet logistics command resupplies the newly assigned Pathfinder")
	var resupply_event := _first_event(_events_after(resupply_events_start), "FleetResupplied")
	_check(int(resupply_event.get("moved", {}).get("kinetic_munitions", 0)) == 1, "FleetResupplied proves one physical munitions unit moved into the Pathfinder formation")
	var j6_events := _events_after(journey_events_start)
	var j6_event_types: Array[String] = []
	for event_value in j6_events:
		j6_event_types.append(str((event_value as Dictionary).get("type", "")))
	_check(_ordered_types(["ShipDesignSaved", "ShipDesignQueued", "ShipbuildingCycleCompleted", "ShipConstructionCompleted", "FleetFormationCreated", "ShipFormationAssignmentChanged", "FleetResupplied"], j6_events), "J6 preserves the saved-design, physical Shipyard, formation, and resupply causal sequence; observed=%s" % JSON.stringify(j6_event_types))
	if failures.is_empty():
		_journey_pass("J6", "SHIP_INDUSTRY")


func _complete_asteroid_survey() -> void:
	var journey_events_start := observed_events.size()
	_check(not pathfinder_ship_id.is_empty() and not pathfinder_formation_id.is_empty(), "J7 receives the public Pathfinder instance and formation identities created by J6")
	if not failures.is_empty():
		return
	_prepare_asteroid_survey_supplies()
	if not failures.is_empty():
		return
	# J5's finite Lunar scrap demand is fulfilled before the Pathfinder launches.
	# Retire it now so the route-return advance cannot dispatch two of the new
	# debris-corridor reward units away before their explicit J7 custody proof.
	# J8 keeps a deliberately idempotent cleanup before publishing its own manifest.
	game.clear_location_logistics_policy("lunar_space", "scrap_metal")
	var asteroid_route_reward_before := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("scrap_metal", 0))
	_check(bool(game.start_expedition_route("asteroid_route", [pathfinder_ship_id], pathfinder_formation_id)), "public Expedition command launches the constructed Pathfinder through the Asteroid route")
	var route_events := _advance(60000.0, "Asteroid Belt route")
	var asteroid_route_completions: Array = route_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "ExpeditionRouteCompleted" and str(event.get("route_id", "")) == "asteroid_route"
	)
	_check(asteroid_route_completions.size() == 1, "Pathfinder completes exactly the canonical Asteroid route through normal game time; completions=%s" % JSON.stringify(asteroid_route_completions))
	_check(not _events_have_type(route_events, "FleetCargoFull"), "the Pathfinder's 100-unit cargo hold accepts the complete Asteroid debris-corridor reward without leaving cargo stranded in the formation")
	if not failures.is_empty():
		return
	# The debris corridor now yields four finite scrap units.  Unload is to the
	# route's home Location, so immediately establish the public Location ->
	# Factory custody transfer before J8 publishes its own ten-unit Asteroid
	# construction manifest.  Leaving the reward in the twenty-unit Earth staging
	# pool would legitimately crowd out the later J9 operating-cost manifests.
	var asteroid_reward_location := _snapshot(EARTH_WORLD_ID)
	var asteroid_reward_available: Dictionary = asteroid_reward_location.get("location_available_inventory", {})
	_check(int(asteroid_reward_available.get("scrap_metal", 0)) == asteroid_route_reward_before + 4, "the completed Asteroid debris corridor unloads exactly its scrap_metal x4 reward into earth_orbit Location custody before the public Factory import; before=%d available=%s" % [asteroid_route_reward_before, JSON.stringify(asteroid_reward_available)])
	if not failures.is_empty():
		return
	var asteroid_reward_depot_before := _entity(asteroid_reward_location, STARTER_DEPOT_ID)
	var asteroid_reward_scrap_before := int(asteroid_reward_depot_before.get("inventory", {}).get("scrap_metal", 0))
	_import_from_location("scrap_metal", 4, STARTER_DEPOT_ID, "J7 Asteroid-route reward custody transfer")
	var asteroid_reward_after := _snapshot(EARTH_WORLD_ID)
	var asteroid_reward_scrap_after := int(_entity(asteroid_reward_after, STARTER_DEPOT_ID).get("inventory", {}).get("scrap_metal", 0))
	_check(asteroid_reward_scrap_after == asteroid_reward_scrap_before + 4 and _events_after(journey_events_start).any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryCargoImported" and str(event.get("world_id", "")) == EARTH_WORLD_ID and str(event.get("storage_id", "")) == STARTER_DEPOT_ID and str(event.get("item_id", "")) == "scrap_metal" and int(event.get("quantity", 0)) == 4
	), "J7 publicly imports exactly the Asteroid-route scrap reward into Earth Factory custody before later logistics")
	if not failures.is_empty():
		return
	# The route itself needs only the completed Pathfinder.  Release the survey
	# deployment components to Earth Location after the return-cargo handoff so
	# they do not consume the finite staging slots that the new route reward must
	# use.  Survey then sees the identical public custody manifest as before.
	_export_to_location("electronics", 2, "Asteroid industrial-survey deployment package after route-reward recovery")
	_export_to_location("structural_frame", 2, "Asteroid industrial-survey deployment package after route-reward recovery")
	_export_to_location("industrial_machine_tools", 1, "Asteroid industrial-survey deployment package after route-reward recovery")
	var availability: Dictionary = game.survey_mission_availability("asteroid_belt", "SURVEYED", [pathfinder_ship_id], EARTH_LOCATION_ID)
	_check(bool(availability.get("allowed", false)), "public survey availability accepts the route-unlocked Asteroid target as DETECTED -> SURVEYED; blockers=%s" % JSON.stringify(availability.get("blockers", [])))
	if not bool(availability.get("allowed", false)):
		return
	_check(bool(game.start_survey_mission("asteroid_belt", "SURVEYED", [pathfinder_ship_id], EARTH_LOCATION_ID)), "public Survey command starts the Asteroid DETECTED -> SURVEYED mission")
	var survey_events := _advance(60000.0, "Asteroid Belt industrial survey")
	var completion := _first_event(survey_events, "SurveyMissionCompleted")
	_check(str(completion.get("target", "")) == "asteroid_belt" and str(completion.get("survey_state", "")) == "SURVEYED", "J7 publishes the canonical Asteroid survey identity and terminal SURVEYED state")
	_check(bool(game.initialize_surveyed_factory_world("asteroid_belt")), "public Survey result creates the sparse Asteroid Factory workspace")
	var asteroid_world_ids: Array[String] = game.factory_world_ids_for_location("asteroid_belt")
	_check(asteroid_world_ids.size() == 1 and bool(_snapshot(str(asteroid_world_ids[0] if not asteroid_world_ids.is_empty() else "")).get("valid", false)), "the public Factory-world query exposes one versioned Asteroid workspace after the survey")
	_check(_ordered_types(["SurveyMissionStarted", "SurveyMissionCompleted", "FactoryWorldInitialized"], _events_after(journey_events_start)), "J7 preserves the survey start, completion, and Factory-world initialization causal order")
	if failures.is_empty():
		_journey_pass("J7", "SURVEY")


func _prepare_asteroid_survey_supplies() -> void:
	var snapshot := _snapshot(EARTH_WORLD_ID)
	var capital_power := _entity_with_definition(snapshot, "grid_power_substation_ii")
	var iron_refinery := _entity_with_recipe(snapshot, "grid_refine_iron")
	var copper_refinery := _entity_with_recipe(snapshot, "grid_refine_copper")
	var reusable_works: Array = _entities_with_definition(snapshot, "grid_engineering_works").filter(func(entity_value):
		var entity := entity_value as Dictionary
		var entity_id := str(entity.get("id", ""))
		return entity_id != str(iron_refinery.get("id", "")) and entity_id != str(copper_refinery.get("id", ""))
	)
	var renewable_electronics: Dictionary = reusable_works[0] as Dictionary if reusable_works.size() >= 1 else {}
	var maintenance_works: Dictionary = reusable_works[1] as Dictionary if reusable_works.size() >= 2 else {}
	_check(not capital_power.is_empty() and not iron_refinery.is_empty() and not copper_refinery.is_empty() and reusable_works.size() >= 2, "Earth Factory retains two public, reconfigurable physical providers for Asteroid survey fuel, maintenance, and deployment components")
	if not failures.is_empty():
		return
	var power_id := str(capital_power.get("id", ""))
	# Both reusable works legitimately retain buffers from the preceding Pathfinder
	# electronics/data-core sequence. Drain their public output ports before changing
	# recipes so an old iron output cannot block a newly manufactured mission item.
	for works_value in [renewable_electronics, maintenance_works]:
		var works := works_value as Dictionary
		var works_id := str(works.get("id", ""))
		_ensure_connection("POWER", power_id, works_id, "")
		for item_id_value in (works.get("outputs", {}) as Dictionary).keys():
			var item_id := str(item_id_value)
			if int((works.get("outputs", {}) as Dictionary).get(item_id, 0)) <= 0:
				continue
			_clear_competing_cargo_inputs(STARTER_DEPOT_ID, item_id, works_id)
			_clear_competing_cargo_outputs(works_id, item_id, STARTER_DEPOT_ID)
			_ensure_connection("CARGO", works_id, STARTER_DEPOT_ID, item_id)
	_advance(30000.0, "pre-survey reusable-workshop output clearance")
	# The former electronics line is intentionally saturated with physically retained
	# iron after J6. Convert four units into ordinary ammunition to open copper slots;
	# no inventory is deleted and the subsequent recipe can then balance its inputs.
	var renewable_electronics_id := str(renewable_electronics.get("id", ""))
	var buffer_recovery_recipe := _factory_command("SET_RECIPE", {"entity_id":renewable_electronics_id, "recipe_id":"grid_manufacture_kinetic_munitions"})
	_check(bool(buffer_recovery_recipe.get("accepted", false)), "Factory protocol selects a physical iron-only recovery recipe for the saturated Pathfinder workshop")
	_clear_competing_cargo_inputs(STARTER_DEPOT_ID, "kinetic_munitions", renewable_electronics_id)
	_clear_competing_cargo_outputs(renewable_electronics_id, "kinetic_munitions", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", renewable_electronics_id, STARTER_DEPOT_ID, "kinetic_munitions")
	var recovery_events := _advance(30000.0, "pre-survey retained-iron recovery")
	_check(_events_have_recipe(recovery_events, "grid_manufacture_kinetic_munitions"), "Factory consumes retained iron into a conserved useful output before electronics reconfiguration")
	var electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":renewable_electronics_id, "recipe_id":"grid_fabricate_electronics"})
	_check(bool(electronics_recipe.get("accepted", false)), "Factory protocol restores a renewable electronics line after Pathfinder scanner-data fabrication")
	for mine_value in _entities_with_definition(snapshot, "grid_surface_mine"):
		_ensure_connection("POWER", power_id, str((mine_value as Dictionary).get("id", "")), "")
	_ensure_connection("POWER", power_id, str(iron_refinery.get("id", "")), "")
	_ensure_connection("POWER", power_id, str(copper_refinery.get("id", "")), "")
	_ensure_connection("POWER", power_id, renewable_electronics_id, "")
	_clear_competing_cargo_inputs(renewable_electronics_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(renewable_electronics_id, "copper_ingot", str(copper_refinery.get("id", "")))
	_ensure_connection("CARGO", str(copper_refinery.get("id", "")), renewable_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", renewable_electronics_id, STARTER_DEPOT_ID, "electronics")
	var maintenance_id := str(maintenance_works.get("id", ""))
	var propellant_recipe := _factory_command("SET_RECIPE", {"entity_id":maintenance_id, "recipe_id":"grid_manufacture_emergency_propellant"})
	_check(bool(propellant_recipe.get("accepted", false)), "Factory protocol restores the renewable emergency-propellant line for the Asteroid survey manifest")
	if not bool(propellant_recipe.get("accepted", false)):
		return
	_ensure_connection("POWER", power_id, maintenance_id, "")
	_clear_competing_cargo_inputs(maintenance_id, "iron_ingot", str(iron_refinery.get("id", "")))
	# J6 leaves seven real electronics inside this workshop. Consume that retained
	# stock for the finite survey-fuel batch, while keeping newly made deployment
	# electronics in the depot instead of feeding them straight back into fuel.
	_clear_competing_cargo_inputs(maintenance_id, "electronics", "")
	_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "electronics", "")
	_ensure_connection("CARGO", str(iron_refinery.get("id", "")), maintenance_id, "iron_ingot")
	_ensure_connection("CARGO", maintenance_id, STARTER_DEPOT_ID, "chemical_propellant")
	var production_events := _advance(120000.0, "Asteroid survey physical supply production")
	var electronics_runtime := _entity(_snapshot(EARTH_WORLD_ID), str(renewable_electronics.get("id", "")))
	var propellant_runtime := _entity(_snapshot(EARTH_WORLD_ID), maintenance_id)
	_check(_events_have_recipe(production_events, "grid_fabricate_electronics") and _events_have_recipe(production_events, "grid_manufacture_emergency_propellant"), "Earth Factory physically replenishes electronic deployment components and survey propellant; electronics=%s propellant=%s" % [JSON.stringify(electronics_runtime), JSON.stringify(propellant_runtime)])
	var depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var inventory: Dictionary = depot.get("inventory", {})
	_check(int(inventory.get("chemical_propellant", 0)) >= 4 and int(inventory.get("electronics", 0)) >= 2 and int(inventory.get("structural_frame", 0)) >= 2 and int(inventory.get("industrial_machine_tools", 0)) >= 1, "Factory storage holds the real Asteroid survey mission and deployment BOM before public transfer; inventory=%s" % JSON.stringify(inventory))
	if not failures.is_empty():
		return
	# Do not export the survey deployment package yet.  The Asteroid route returns
	# a finite four-unit scrap reward through the Pathfinder, and Earth Location's
	# staging limit must remain free until that cargo has been publicly recovered
	# into Factory custody by _complete_asteroid_survey().  Propellant is distinct
	# operating cargo rather than deployment staging and remains available for the
	# subsequent public survey mission.
	_export_to_location("chemical_propellant", 4, "Asteroid survey mission and onward logistics reserve")


func _complete_remote_asteroid_industry() -> void:
	var journey_events_start := observed_events.size()
	var asteroid_world_ids: Array[String] = game.factory_world_ids_for_location("asteroid_belt")
	_check(asteroid_world_ids.size() == 1, "J8 receives the Asteroid Factory workspace initialized by the completed J7 survey")
	if asteroid_world_ids.is_empty() or not failures.is_empty():
		return
	var asteroid_world_id := str(asteroid_world_ids[0])
	var earth_snapshot := _snapshot(EARTH_WORLD_ID)
	var earth_depot := _entity(earth_snapshot, STARTER_DEPOT_ID)
	var earth_inventory: Dictionary = earth_depot.get("inventory", {})
	var earth_location_inventory: Dictionary = earth_snapshot.get("location_available_inventory", {})
	_check(int(earth_inventory.get("iron_ingot", 0)) >= 20 and int(earth_inventory.get("chemical_propellant", 0)) >= 11 and int(earth_inventory.get("repair_material", 0)) >= 8 and int(earth_inventory.get("scrap_metal", 0)) >= 10 and int(earth_inventory.get("electronics", 0)) >= 2, "Earth Factory custody holds the real outputs, operating costs, and scrap needed for a capacity-safe Asteroid Factory bootstrap; factory=%s location=%s" % [JSON.stringify(earth_inventory), JSON.stringify(earth_location_inventory)])
	if not failures.is_empty():
		return
	_export_to_location("iron_ingot", 20, "Asteroid bulk-depot construction and post-build Factory staging")
	_export_to_location("chemical_propellant", 11, "four multi-hop Asteroid freight operating-cost reserve")
	_export_to_location("repair_material", 8, "four multi-hop Asteroid freight maintenance reserve")
	_export_to_location("scrap_metal", 10, "Asteroid solar-and-dual-extractor construction manifest")
	_export_to_location("electronics", 2, "Asteroid dual-extractor construction manifest after survey consumption")
	var staged_location_inventory: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(staged_location_inventory.get("scrap_metal", 0)) >= 10, "Factory export makes the complete Asteroid bootstrap scrap manifest available to public Logistics; location=%s" % JSON.stringify(staged_location_inventory))
	if not failures.is_empty():
		return
	# J7 already retires the completed Lunar bootstrap policy before Pathfinder
	# cargo returns.  Repeat removal is intentionally idempotent: its observable
	# contract here is that no stale Lunar demand can compete with J8's finite
	# Asteroid construction manifest, not that a policy still exists.
	game.clear_location_logistics_policy("lunar_space", "scrap_metal")
	_check(bool(game.configure_logistics_service("lunar_belt_freight", "general_cargo")), "public Logistics command configures the Lunar-Belt freight corridor")
	_check(bool(game.set_location_logistics_policy("asteroid_belt", "iron_ingot", "DEMAND", 0, 10, 100, 1)), "Asteroid staging requests the exact bulk-depot iron construction manifest")
	var depot_manifest_events := _advance(360000.0, "Earth-to-Asteroid bulk-depot freight")
	_check(_events_have_type(depot_manifest_events, "ShipmentDispatched") and _events_have_type(depot_manifest_events, "ShipmentArrived"), "public multi-route logistics dispatches and settles the capacity-opening depot manifest")
	var asteroid_snapshot := _snapshot(asteroid_world_id)
	var asteroid_available: Dictionary = asteroid_snapshot.get("location_available_inventory", {})
	_check(int(asteroid_available.get("iron_ingot", 0)) >= 10, "Asteroid initial staging receives the exact depot manifest without pretending it has post-depot capacity; available=%s" % JSON.stringify(asteroid_available))
	if not failures.is_empty():
		return
	var asteroid_depot := _queue_and_fund("grid_bulk_depot", "", {"x":0, "y":0}, "Asteroid bulk depot", true, asteroid_world_id, "")
	if asteroid_depot.is_empty() or not failures.is_empty():
		return
	var depot_events := _advance(120000.0, "Asteroid bulk-depot construction")
	_check(_events_have_type(depot_events, "FactoryConstructionCompleted"), "remote Factory completes its physical bulk depot from the delivered manifest")
	var asteroid_depot_id := str(asteroid_depot.get("entity_id", ""))
	var post_depot_available: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	_check(int(post_depot_available.get("iron_ingot", 0)) >= 10, "the second staged iron batch arrives after depot funding releases initial capacity; available=%s" % JSON.stringify(post_depot_available))
	_import_from_location("iron_ingot", 10, asteroid_depot_id, "Asteroid depot staging", asteroid_world_id)
	_check(bool(game.set_location_logistics_policy("asteroid_belt", "scrap_metal", "DEMAND", 0, 10, 100, 1)), "expanded Asteroid staging requests the exact solar-and-two-mine scrap construction manifest")
	_check(bool(game.set_location_logistics_policy("asteroid_belt", "electronics", "DEMAND", 0, 2, 100, 1)), "expanded Asteroid staging requests both remote-extractor electronic construction components")
	var manifest_events := _advance(360000.0, "Earth-to-Asteroid remote extractor freight")
	_check(_events_have_type(manifest_events, "ShipmentDispatched") and _events_have_type(manifest_events, "ShipmentArrived"), "public multi-route logistics dispatches and settles the post-depot remote Factory manifest")
	asteroid_snapshot = _snapshot(asteroid_world_id)
	asteroid_available = asteroid_snapshot.get("location_available_inventory", {})
	_check(int(asteroid_available.get("scrap_metal", 0)) >= 10 and int(asteroid_available.get("electronics", 0)) >= 2, "expanded Asteroid staging receives the real extractor manifest before remote Factory construction; available=%s blockers=%s earth=%s events=%s" % [JSON.stringify(asteroid_available), JSON.stringify(game.active_blockers("asteroid_belt")), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})), JSON.stringify(manifest_events)])
	if not failures.is_empty():
		return
	var mining_snapshot := _snapshot(asteroid_world_id)
	var cobalt_field := _resource_field(mining_snapshot, "cobalt_ore")
	var silicate_field := _resource_field(mining_snapshot, "silicate_ore")
	_check(not cobalt_field.is_empty() and not silicate_field.is_empty(), "surveyed Asteroid Factory workspace exposes both canonical cobalt and silicate fields")
	if cobalt_field.is_empty() or silicate_field.is_empty() or not failures.is_empty():
		return
	var asteroid_power := _queue_and_fund("grid_solar_array", "", {"x":0, "y":40}, "Asteroid solar array", true, asteroid_world_id, "")
	var cobalt_mine := _queue_and_fund("grid_surface_mine", "", cobalt_field.get("footprint", {}).get("origin", {}), "Asteroid cobalt mine", true, asteroid_world_id, "")
	var silicate_mine := _queue_and_fund("grid_surface_mine", "", silicate_field.get("footprint", {}).get("origin", {}), "Asteroid silicate mine", true, asteroid_world_id, "")
	if asteroid_power.is_empty() or cobalt_mine.is_empty() or silicate_mine.is_empty() or not failures.is_empty():
		return
	var remote_construction_events := _advance(180000.0, "Asteroid solar and extractor construction")
	_check(_events_have_type(remote_construction_events, "FactoryConstructionCompleted"), "remote Factory completes its power and dual-resource extraction infrastructure")
	_connect("POWER", str(asteroid_power.get("entity_id", "")), str(cobalt_mine.get("entity_id", "")), "", asteroid_world_id)
	_connect("POWER", str(asteroid_power.get("entity_id", "")), str(silicate_mine.get("entity_id", "")), "", asteroid_world_id)
	_connect("CARGO", str(cobalt_mine.get("entity_id", "")), asteroid_depot_id, "cobalt_ore", asteroid_world_id)
	_connect("CARGO", str(silicate_mine.get("entity_id", "")), asteroid_depot_id, "silicate_ore", asteroid_world_id)
	var extraction_events := _advance(60000.0, "Asteroid dual-resource extraction")
	_check(_events_have_type(extraction_events, "FactoryResourceExtracted"), "remote Asteroid Factory extracts surveyed physical resources through its powered dual-mine topology")
	var remote_depot_runtime := _entity(_snapshot(asteroid_world_id), asteroid_depot_id)
	_check(int(remote_depot_runtime.get("inventory", {}).get("cobalt_ore", 0)) > 0 and int(remote_depot_runtime.get("inventory", {}).get("silicate_ore", 0)) > 0, "remote Asteroid depot receives both powered mine outputs through Factory CARGO links; inventory=%s" % JSON.stringify(remote_depot_runtime.get("inventory", {})))
	_check(_events_have_type(_events_after(journey_events_start), "FactoryCargoImported"), "J8 retains the public Factory cargo-import event after the preceding J7 survey initialized its remote workspace")
	_check(_ordered_types(["LogisticsServiceConfigured", "ShipmentDispatched", "ShipmentArrived", "FactoryConstructionQueued", "FactoryConstructionFunded", "FactoryConstructionCompleted", "FactoryCargoImported", "FactoryEntitiesConnected"], _events_after(journey_events_start)), "J8 preserves logistics, physical remote construction, import, and connection causality")
	if failures.is_empty():
		_journey_pass("J8", "REMOTE_INDUSTRY")


func _complete_advanced_industry() -> void:
	var journey_events_start := observed_events.size()
	# J5 left a finite Lunar titanium reserve.  Extend it only with the live
	# Lunar Factory and Earth-Lunar logistics: the Heavy Industry program needs
	# twelve physical alloy units for its high-field materials, two further units
	# for industrial release, and six units for the assembly array.
	var lunar_world_ids: Array[String] = game.factory_world_ids_for_location("lunar_space")
	_check(lunar_world_ids.size() == 1, "J9 retains the canonical Lunar Factory workspace for physical titanium replenishment")
	if lunar_world_ids.is_empty() or not failures.is_empty():
		return
	var lunar_world_id := str(lunar_world_ids[0])
	var lunar_snapshot := _snapshot(lunar_world_id)
	var lunar_depot := _entity_with_definition(lunar_snapshot, "grid_bulk_depot")
	var lunar_foundry := _entity_with_recipe(lunar_snapshot, "grid_refine_titanium")
	var lunar_mine := _entity_with_resource(lunar_snapshot, "titanium_ore")
	var lunar_solar_arrays := _entities_with_definition(lunar_snapshot, "grid_solar_array")
	_check(not lunar_depot.is_empty() and not lunar_foundry.is_empty() and not lunar_mine.is_empty() and not lunar_solar_arrays.is_empty(), "J9 can address the completed Lunar titanium depot, refinery, mine, and power providers")
	if not failures.is_empty():
		return
	var lunar_depot_id := str(lunar_depot.get("id", ""))
	# Produce the later assembly-array reserve in this same bounded batch. The
	# refinery legitimately retains a full ore buffer once the live mine has run;
	# reserving all 29 units now avoids inventing a destructive buffer-clear path.
	var required_lunar_titanium := 29
	var lunar_titanium := int(lunar_depot.get("inventory", {}).get("titanium_alloy", 0))
	if lunar_titanium < required_lunar_titanium:
		# Produce a complete fresh manifest. Existing Lunar alloy remains subject to
		# the already-configured public SUPPLY policy during the long construction
		# window, so treating that moving stock as part of this batch underfunds it.
		var titanium_batch := required_lunar_titanium
		# J8 deliberately consumes the preceding multi-hop operating reserve.  Keep
		# the next single-hop Earth-Lunar dispatch physically funded as well: this
		# is cargo moved across the public Factory/Location boundary, not an implicit
		# logistics subsidy.  J8 leaves one repair material at Earth Location for
		# the matching general-cargo maintenance cost.
		var earth_before_lunar_freight := _snapshot(EARTH_WORLD_ID)
		var earth_before_lunar_depot := _entity(earth_before_lunar_freight, STARTER_DEPOT_ID)
		_check(int(earth_before_lunar_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 1, "J8 leaves one physical Factory propellant unit for the next Earth-Lunar freight dispatch; inventory=%s" % JSON.stringify(earth_before_lunar_depot.get("inventory", {})))
		if not failures.is_empty():
			return
		_export_to_location("chemical_propellant", 1, "J9 Earth-Lunar titanium freight operating cost")
		_export_to_location("repair_material", 1, "J9 second Earth-Lunar titanium freight maintenance cost")
		var earth_operating_inventory: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(int(earth_operating_inventory.get("chemical_propellant", 0)) >= 2 and int(earth_operating_inventory.get("repair_material", 0)) >= 2, "Earth Location holds the physical propellant and maintenance costs for both capacity-safe J9 titanium freight dispatches; available=%s" % JSON.stringify(earth_operating_inventory))
		if not failures.is_empty():
			return
		_export_to_location("iron_ingot", titanium_batch, "J9 Lunar titanium furnace feed")
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot", "SUPPLY", 0, 0, 100, 1)), "Earth publishes the bounded J9 Lunar titanium furnace-feed supply")
		_check(bool(game.set_location_logistics_policy("lunar_space", "iron_ingot", "DEMAND", 0, titanium_batch, 100, 1)), "Lunar Space requests only the J9 titanium furnace-feed batch")
		var lunar_iron_events := _advance(240000.0, "J9 Earth-Lunar titanium furnace-feed logistics")
		_check(_events_have_type(lunar_iron_events, "ShipmentArrived"), "public logistics delivers the J9 Lunar titanium furnace feed")
		var first_lunar_iron_batch := mini(titanium_batch, int(_snapshot(lunar_world_id).get("location_available_inventory", {}).get("iron_ingot", 0)))
		_check(first_lunar_iron_batch > 0, "the first capacity-safe Lunar furnace-feed stream reaches Location custody")
		_import_from_location("iron_ingot", first_lunar_iron_batch, lunar_depot_id, "J9 first Lunar titanium foundry-feed stream", lunar_world_id)
		var remaining_lunar_iron := titanium_batch - first_lunar_iron_batch
		if remaining_lunar_iron > 0 and failures.is_empty():
			var second_lunar_iron_events := _advance(120000.0, "J9 second capacity-safe Lunar titanium furnace-feed stream")
			_check(_events_have_type(second_lunar_iron_events, "ShipmentArrived"), "public logistics uses the released Lunar staging capacity for the remaining furnace feed")
			_import_from_location("iron_ingot", remaining_lunar_iron, lunar_depot_id, "J9 second Lunar titanium foundry-feed stream", lunar_world_id)
		# J5 leaves its first smelter with a finite, physically accumulated titanium
		# ore buffer.  That buffer cannot be teleported away or overwritten by a
		# recipe change, and it correctly leaves no input headroom for fresh iron.
		# Commission a second powered smelter from an independently delivered public
		# construction manifest, then divert the live mine output to that new line.
		# This preserves both the saturated machine's cargo and Factory topology.
		if int(lunar_foundry.get("inputs", {}).get("titanium_ore", 0)) >= 46:
			var earth_recovery_snapshot := _snapshot(EARTH_WORLD_ID)
			var propellant_works := _entity_with_recipe(earth_recovery_snapshot, "grid_manufacture_emergency_propellant")
			var earth_power := _entity_with_definition(earth_recovery_snapshot, "grid_power_substation_ii")
			_check(not propellant_works.is_empty() and not earth_power.is_empty(), "Earth retains the public emergency-propellant works and power source needed for the second Lunar smelter manifest")
			if failures.size() > 0:
				return
			var propellant_works_id := str(propellant_works.get("id", ""))
			_ensure_connection("POWER", str(earth_power.get("id", "")), propellant_works_id, "")
			# The J7/J8 emergency line has faithfully retained an old industrial-waste
			# buffer.  Consume it with a compatible public recipe before asking that
			# finite input buffer to accept the two fresh electronic components.
			var propellant_recovery_recipe := _factory_command("SET_RECIPE", {"entity_id":propellant_works_id, "recipe_id":"grid_reprocess_industrial_waste"})
			_check(bool(propellant_recovery_recipe.get("accepted", false)), "Factory protocol selects waste recovery to clear the retained emergency-line input buffer")
			_clear_competing_cargo_outputs(propellant_works_id, "iron_ingot", STARTER_DEPOT_ID)
			_ensure_connection("CARGO", propellant_works_id, STARTER_DEPOT_ID, "iron_ingot")
			var propellant_buffer_events := _advance(30000.0, "J9 emergency-line industrial-waste recovery")
			var cleared_propellant_works := _entity(_snapshot(EARTH_WORLD_ID), propellant_works_id)
			_check(_events_have_recipe(propellant_buffer_events, "grid_reprocess_industrial_waste") and int(cleared_propellant_works.get("inputs", {}).get("industrial_waste", 0)) <= 1, "Factory physically drains the retained emergency-line waste buffer before freight-propellant replenishment; works=%s" % JSON.stringify(cleared_propellant_works))
			if failures.size() > 0:
				return
			var restore_propellant_recipe := _factory_command("SET_RECIPE", {"entity_id":propellant_works_id, "recipe_id":"grid_manufacture_emergency_propellant"})
			_check(bool(restore_propellant_recipe.get("accepted", false)), "Factory protocol restores the physical emergency-propellant recipe after clearing its retained buffer")
			if failures.size() > 0:
				return
			_clear_competing_cargo_inputs(propellant_works_id, "electronics", STARTER_DEPOT_ID)
			_clear_competing_cargo_outputs(propellant_works_id, "chemical_propellant", STARTER_DEPOT_ID)
			_ensure_connection("CARGO", STARTER_DEPOT_ID, propellant_works_id, "electronics")
			_ensure_connection("CARGO", propellant_works_id, STARTER_DEPOT_ID, "chemical_propellant")
			var recovery_propellant_events := _advance(40000.0, "J9 second Lunar smelter freight-propellant fabrication")
			var recovery_snapshot := _snapshot(EARTH_WORLD_ID)
			var recovery_depot := _entity(recovery_snapshot, STARTER_DEPOT_ID)
			var recovery_propellant_runtime := _entity(recovery_snapshot, propellant_works_id)
			_check(_events_have_recipe(recovery_propellant_events, "grid_manufacture_emergency_propellant") and int(recovery_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 3, "Earth Factory physically replenishes the three freight-propellant units for the second Lunar smelter manifest; inventory=%s works=%s events=%s" % [JSON.stringify(recovery_depot.get("inventory", {})), JSON.stringify(recovery_propellant_runtime), JSON.stringify(recovery_propellant_events)])
			if failures.size() > 0:
				return
			# Stop feeding the fuel line before restoring construction components: it
			# legitimately consumed the starter depot's last electronics into freight
			# propellant. A distinct existing works now makes a bounded new batch, with
			# the copper refinery's waste physically routed to the J4 bulk depot.
			_clear_competing_cargo_inputs(propellant_works_id, "electronics", "")
			var iron_source := _entity_with_recipe(recovery_snapshot, "grid_refine_iron")
			var copper_source := _entity_with_recipe(recovery_snapshot, "grid_refine_copper")
			var component_works: Dictionary = {}
			for works_value in _entities_with_definition(recovery_snapshot, "grid_engineering_works"):
				var works := works_value as Dictionary
				var works_id := str(works.get("id", ""))
				if works_id != propellant_works_id and works_id != str(iron_source.get("id", "")) and works_id != str(copper_source.get("id", "")):
					component_works = works
					break
			_check(not iron_source.is_empty() and not copper_source.is_empty() and not component_works.is_empty() and not earth_bulk_depot_id.is_empty(), "Earth retains a separate physical electronics works, both metal sources, and the bulk waste sink for the second Lunar smelter components")
			if failures.size() > 0:
				return
			var component_works_id := str(component_works.get("id", ""))
			# J4's bulk sink is a real finite store, not a hidden disposal path. Move
			# its retained waste out through the public Factory/Location boundary and
			# remove the prior continuous iron feed before using its remaining capacity
			# for the copper line's live waste egress.
			var bulk_before_relief := _entity(_snapshot(EARTH_WORLD_ID), earth_bulk_depot_id)
			var retained_waste := int(bulk_before_relief.get("inventory", {}).get("industrial_waste", 0))
			_check(retained_waste >= 63, "J9 diagnoses the finite bulk-sink waste occupancy before physical custody relief; inventory=%s" % JSON.stringify(bulk_before_relief.get("inventory", {})))
			if failures.size() > 0:
				return
			_export_to_location("industrial_waste", retained_waste, "J9 copper-refinery waste-sink capacity relief", EARTH_WORLD_ID, earth_bulk_depot_id)
			_clear_competing_cargo_inputs(earth_bulk_depot_id, "iron_ingot", "")
			var bulk_after_relief := _entity(_snapshot(EARTH_WORLD_ID), earth_bulk_depot_id)
			_check(int(bulk_after_relief.get("inventory", {}).get("industrial_waste", 0)) == 0 and int(bulk_after_relief.get("inventory", {}).get("iron_ingot", 0)) < int(bulk_after_relief.get("inventory_capacity", 0)), "J9 physically frees the bulk-sink waste capacity and removes its obsolete iron feed before copper resumes; inventory=%s links=%s" % [JSON.stringify(bulk_after_relief.get("inventory", {})), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("links", []))])
			if failures.size() > 0:
				return
			# The separate electronics works also retains a full pre-J9 iron buffer.
			# Consume a bounded portion into a useful, exported stockpile before asking
			# it to accept live copper: no input buffer is cleared or overwritten.
			_clear_competing_cargo_inputs(component_works_id, "iron_ingot", "")
			var component_drain_recipe := _factory_command("SET_RECIPE", {"entity_id":component_works_id, "recipe_id":"grid_manufacture_kinetic_munitions"})
			_check(bool(component_drain_recipe.get("accepted", false)), "Factory protocol selects a physical iron-consuming recipe to make input headroom for J9 replacement electronics")
			_clear_competing_cargo_outputs(component_works_id, "kinetic_munitions", STARTER_DEPOT_ID)
			_ensure_connection("CARGO", component_works_id, STARTER_DEPOT_ID, "kinetic_munitions")
			var component_drain_events := _advance(14000.0, "J9 retained-iron consumption before replacement electronics")
			var component_after_drain := _entity(_snapshot(EARTH_WORLD_ID), component_works_id)
			_check(_events_have_recipe(component_drain_events, "grid_manufacture_kinetic_munitions") and int(component_after_drain.get("inputs", {}).get("iron_ingot", 0)) < int(component_works.get("inputs", {}).get("iron_ingot", 0)), "Factory physically consumes retained electronics-works iron before reconnecting copper; works=%s" % JSON.stringify(component_after_drain))
			if failures.size() > 0:
				return
			var component_recipe := _factory_command("SET_RECIPE", {"entity_id":component_works_id, "recipe_id":"grid_fabricate_electronics"})
			_check(bool(component_recipe.get("accepted", false)), "Factory protocol assigns the independent electronics line for second Lunar smelter construction")
			_ensure_connection("POWER", str(earth_power.get("id", "")), component_works_id, "")
			# The bounded electronics batch uses the retained iron that just created
			# copper headroom. Do not immediately refill that finite buffer from the
			# prior refinery link before the live copper can arrive.
			_clear_competing_cargo_inputs(component_works_id, "iron_ingot", "")
			_clear_competing_cargo_inputs(component_works_id, "copper_ingot", str(copper_source.get("id", "")))
			_clear_competing_cargo_outputs(str(copper_source.get("id", "")), "copper_ingot", component_works_id)
			_clear_competing_cargo_outputs(str(copper_source.get("id", "")), "industrial_waste", earth_bulk_depot_id)
			_clear_competing_cargo_outputs(component_works_id, "electronics", STARTER_DEPOT_ID)
			_ensure_connection("CARGO", str(copper_source.get("id", "")), component_works_id, "copper_ingot")
			_ensure_connection("CARGO", str(copper_source.get("id", "")), earth_bulk_depot_id, "industrial_waste")
			_ensure_connection("CARGO", component_works_id, STARTER_DEPOT_ID, "electronics")
			var copper_waste_before := int(copper_source.get("outputs", {}).get("industrial_waste", 0))
			var copper_egress_events := _advance(20000.0, "J9 copper-refinery waste egress for second Lunar smelter electronics")
			var copper_egress_snapshot := _snapshot(EARTH_WORLD_ID)
			var copper_egress_runtime := _entity(copper_egress_snapshot, str(copper_source.get("id", "")))
			var component_egress_runtime := _entity(copper_egress_snapshot, component_works_id)
			var egress_waste_sink := _entity(copper_egress_snapshot, earth_bulk_depot_id)
			var copper_waste_after := int(copper_egress_runtime.get("outputs", {}).get("industrial_waste", 0))
			_check(_events_have_recipe(copper_egress_events, "grid_refine_copper") or copper_waste_after < copper_waste_before, "Earth copper refinery has a live physical industrial-waste egress before replacement-electronics fabrication; waste_before=%d waste_after=%d copper=%s electronics_works=%s waste_sink=%s links=%s events=%s" % [copper_waste_before, copper_waste_after, JSON.stringify(copper_egress_runtime), JSON.stringify(component_egress_runtime), JSON.stringify(egress_waste_sink), JSON.stringify(copper_egress_snapshot.get("links", [])), JSON.stringify(copper_egress_events)])
			if failures.size() > 0:
				return
			var replacement_electronics_events := _advance(60000.0, "J9 second Lunar smelter component-electronics fabrication")
			recovery_snapshot = _snapshot(EARTH_WORLD_ID)
			recovery_depot = _entity(recovery_snapshot, STARTER_DEPOT_ID)
			var replacement_electronics_runtime := _entity(recovery_snapshot, component_works_id)
			var replacement_copper_runtime := _entity(recovery_snapshot, str(copper_source.get("id", "")))
			var replacement_waste_sink := _entity(recovery_snapshot, earth_bulk_depot_id)
			_check(_events_have_recipe(replacement_electronics_events, "grid_fabricate_electronics") and int(recovery_depot.get("inventory", {}).get("electronics", 0)) >= 2, "Earth Factory physically replaces the two electronic construction components consumed by freight fuel; inventory=%s electronics_works=%s copper=%s waste_sink=%s events=%s" % [JSON.stringify(recovery_depot.get("inventory", {})), JSON.stringify(replacement_electronics_runtime), JSON.stringify(replacement_copper_runtime), JSON.stringify(replacement_waste_sink), JSON.stringify(replacement_electronics_events)])
			if failures.size() > 0:
				return
			_export_to_location("chemical_propellant", 3, "J9 second Lunar smelter freight operating costs")
			_export_to_location("repair_material", 3, "J9 second Lunar smelter freight maintenance costs")
			_export_to_location("iron_ingot", 4, "J9 second Lunar smelter construction")
			_export_to_location("electronics", 2, "J9 second Lunar smelter construction")
			_export_to_location("structural_frame", 1, "J9 second Lunar smelter construction")
			# J8's completed remote deployment leaves bounded DEMAND policies behind.
			# Retire them explicitly so the physical J9 manifest cannot be dispatched
			# into an already-built Asteroid workspace instead of Lunar custody.
			_check(bool(game.clear_location_logistics_policy("asteroid_belt", "iron_ingot")) and bool(game.clear_location_logistics_policy("asteroid_belt", "scrap_metal")) and bool(game.clear_location_logistics_policy("asteroid_belt", "electronics")), "public Logistics commands retire J8's fulfilled Asteroid construction demands before dispatching the J9 Lunar manifest")
			if failures.size() > 0:
				return
			# A prior J8/J9 manifest may already hold an identical public SUPPLY policy.
			# The Game API correctly returns false for an unchanged policy, so apply each
			# independently and prove the actual full cargo arrival below rather than
			# treating idempotent policy retention as a rejected logistics path.
			game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)
			game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)
			game.set_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot", "SUPPLY", 0, 0, 100, 1)
			game.set_location_logistics_policy(EARTH_LOCATION_ID, "electronics", "SUPPLY", 0, 0, 100, 1)
			game.set_location_logistics_policy(EARTH_LOCATION_ID, "structural_frame", "SUPPLY", 0, 0, 100, 1)
			_check(bool(game.set_location_logistics_policy("lunar_space", "iron_ingot", "DEMAND", 0, 4, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "electronics", "DEMAND", 0, 2, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "structural_frame", "DEMAND", 0, 1, 100, 1)), "Lunar Space requests exactly the second-smelter construction manifest")
			var recovery_manifest_events := _advance(240000.0, "J9 second Lunar smelter logistics")
			_check(_events_have_type(recovery_manifest_events, "ShipmentArrived"), "public logistics delivers the physical second Lunar smelter manifest")
			var lunar_manifest_inventory: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
			_check(int(lunar_manifest_inventory.get("iron_ingot", 0)) >= 4 and int(lunar_manifest_inventory.get("electronics", 0)) >= 2 and int(lunar_manifest_inventory.get("structural_frame", 0)) >= 1, "J9 observes the complete physical second-smelter construction cargo at Lunar Location custody before Factory funding; available=%s events=%s" % [JSON.stringify(lunar_manifest_inventory), JSON.stringify(recovery_manifest_events)])
			if failures.size() > 0:
				return
			var recovery_foundry_order := _queue_and_fund("grid_arc_smelter", "grid_refine_titanium", {"x":130, "y":100}, "J9 saturated-buffer recovery Lunar smelter", true, lunar_world_id, "")
			if recovery_foundry_order.is_empty() or failures.size() > 0:
				return
			var recovery_foundry_events := _advance(240000.0, "J9 second Lunar smelter construction")
			_check(_events_have_type(recovery_foundry_events, "FactoryConstructionCompleted"), "Factory physically constructs a second Lunar smelter without discarding the first smelter's saturated buffer")
			lunar_foundry = _entity(_snapshot(lunar_world_id), str(recovery_foundry_order.get("entity_id", "")))
			_check(not lunar_foundry.is_empty(), "J9 receives the completed second Lunar smelter identity through the Factory snapshot")
			if failures.size() > 0:
				return
		for solar_value in lunar_solar_arrays:
			var solar := solar_value as Dictionary
			_ensure_connection("POWER", str(solar.get("id", "")), str(lunar_mine.get("id", "")), "", lunar_world_id)
			_ensure_connection("POWER", str(solar.get("id", "")), str(lunar_foundry.get("id", "")), "", lunar_world_id)
		# J5's long-running refinery can retain links from previous material
		# configurations.  The versioned command API makes those topology changes
		# explicit; preserve only the exact mine/depot/refinery chain required here.
		_clear_competing_cargo_outputs(str(lunar_mine.get("id", "")), "titanium_ore", str(lunar_foundry.get("id", "")), lunar_world_id)
		_clear_competing_cargo_inputs(str(lunar_foundry.get("id", "")), "titanium_ore", str(lunar_mine.get("id", "")), lunar_world_id)
		_clear_competing_cargo_inputs(str(lunar_foundry.get("id", "")), "iron_ingot", lunar_depot_id, lunar_world_id)
		_clear_competing_cargo_outputs(str(lunar_foundry.get("id", "")), "titanium_alloy", lunar_depot_id, lunar_world_id)
		_clear_competing_cargo_inputs(lunar_depot_id, "titanium_alloy", str(lunar_foundry.get("id", "")), lunar_world_id)
		_ensure_connection("CARGO", str(lunar_mine.get("id", "")), str(lunar_foundry.get("id", "")), "titanium_ore", lunar_world_id)
		_ensure_connection("CARGO", lunar_depot_id, str(lunar_foundry.get("id", "")), "iron_ingot", lunar_world_id)
		_ensure_connection("CARGO", str(lunar_foundry.get("id", "")), lunar_depot_id, "titanium_alloy", lunar_world_id)
		var titanium_events := _advance(480000.0, "J9 Lunar titanium refinement")
		var lunar_runtime_snapshot := _snapshot(lunar_world_id)
		var lunar_foundry_runtime := _entity(lunar_runtime_snapshot, str(lunar_foundry.get("id", "")))
		var lunar_mine_runtime := _entity(lunar_runtime_snapshot, str(lunar_mine.get("id", "")))
		_check(_events_have_recipe(titanium_events, "grid_refine_titanium"), "Lunar Factory physically refines the missing J9 titanium; foundry=%s mine=%s links=%s events=%s" % [JSON.stringify(lunar_foundry_runtime), JSON.stringify(lunar_mine_runtime), JSON.stringify(lunar_runtime_snapshot.get("links", [])), JSON.stringify(titanium_events)])
		lunar_depot = _entity(lunar_runtime_snapshot, lunar_depot_id)
		lunar_titanium = int(lunar_depot.get("inventory", {}).get("titanium_alloy", 0))
		# Stop the extractor once the bounded manifest is ready. Otherwise the long
		# J9 research windows legitimately fill the smelter with ore and leave no
		# input slot for a later, explicitly funded titanium top-up.
		_clear_competing_cargo_outputs(str(lunar_mine.get("id", "")), "titanium_ore", "", lunar_world_id)
	_check(lunar_titanium >= required_lunar_titanium, "Lunar Factory holds the complete finite titanium manifest for Heavy Industry and its assembly array; inventory=%s" % JSON.stringify(lunar_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	# The surveyed sites' Location staging is intentionally finite. Stream three
	# capacity-safe shipments and move the first sixteen units into Earth Factory
	# custody before the final six arrive.
	var titanium_chunks := [10, 10, 9]
	for titanium_chunk_index in range(titanium_chunks.size()):
		var titanium_chunk := int(titanium_chunks[titanium_chunk_index])
		_export_to_location("titanium_alloy", titanium_chunk, "J9 Heavy Industry alloy stream %d" % (titanium_chunk_index + 1), lunar_world_id, lunar_depot_id)
		# These policies can already be active from J5. An unchanged-policy return is
		# intentionally not treated as a rejection; the matched arrival below is the
		# observable, custody-preserving proof for this exact stream.
		game.set_location_logistics_policy("lunar_space", "titanium_alloy", "SUPPLY", 0, 0, 100, 1)
		var earth_titanium_before_stream := int(_snapshot(EARTH_WORLD_ID).get("location_inventory", {}).get("titanium_alloy", 0))
		game.set_location_logistics_policy(EARTH_LOCATION_ID, "titanium_alloy", "DEMAND", 0, earth_titanium_before_stream + titanium_chunk, 100, 1)
		var titanium_return_events := _advance(240000.0, "J9 Lunar-Earth titanium logistics stream %d" % (titanium_chunk_index + 1))
		_check(_events_have_type(titanium_return_events, "ShipmentArrived"), "public logistics returns J9 titanium stream %d to Earth custody" % (titanium_chunk_index + 1))
		var stream_earth_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(int(stream_earth_available.get("titanium_alloy", 0)) >= titanium_chunk, "Earth Location receives the complete physical J9 titanium stream %d; available=%s events=%s" % [titanium_chunk_index + 1, JSON.stringify(stream_earth_available), JSON.stringify(titanium_return_events)])
		if not failures.is_empty():
			return
		if titanium_chunk_index == 0:
			_import_from_location("titanium_alloy", titanium_chunk, STARTER_DEPOT_ID, "J9 first streamed high-field alloy batch")
			if not failures.is_empty():
				return
		elif titanium_chunk_index == 1:
			_import_from_location("titanium_alloy", 6, STARTER_DEPOT_ID, "J9 second streamed assembly reserve")
			if not failures.is_empty():
				return
	var earth_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var earth_titanium_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var earth_streamed_titanium := int(earth_available.get("titanium_alloy", 0)) + int(earth_titanium_depot.get("inventory", {}).get("titanium_alloy", 0))
	_check(earth_streamed_titanium >= required_lunar_titanium, "Earth retains all finite Heavy Industry, research, and assembly titanium across public Location and Factory custody; location=%s depot=%s" % [JSON.stringify(earth_available), JSON.stringify(earth_titanium_depot.get("inventory", {}))])
	if not failures.is_empty():
		return
	_import_from_location("titanium_alloy", 2, STARTER_DEPOT_ID, "J9 final high-field alloy stream")
	var post_stream_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(int(post_stream_depot.get("inventory", {}).get("titanium_alloy", 0)) >= 12 and int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("titanium_alloy", 0)) >= 6, "J9 stages twelve titanium alloy in Factory for high-field fabrication while preserving six at Earth Location for the assembly array; depot=%s location=%s" % [JSON.stringify(post_stream_depot.get("inventory", {})), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}))])
	if not failures.is_empty():
		return
	var earth_snapshot := _snapshot(EARTH_WORLD_ID)
	var capital_power := _entity_with_definition(earth_snapshot, "grid_power_substation_ii")
	var foundry := _entity_with_definition(earth_snapshot, "grid_arc_smelter")
	var high_energy_works := _entity_with_definition(earth_snapshot, "grid_electronics_works")
	var iron_refinery := _entity_with_recipe(earth_snapshot, "grid_refine_iron")
	var copper_refinery := _entity_with_recipe(earth_snapshot, "grid_refine_copper")
	var ordinary_works: Array = _entities_with_definition(earth_snapshot, "grid_engineering_works").filter(func(entity_value):
		var entity := entity_value as Dictionary
		var entity_id := str(entity.get("id", ""))
		return entity_id != str(iron_refinery.get("id", "")) and entity_id != str(copper_refinery.get("id", ""))
	)
	_check(not capital_power.is_empty() and not foundry.is_empty() and not high_energy_works.is_empty() and not iron_refinery.is_empty() and not copper_refinery.is_empty() and ordinary_works.size() >= 2, "Earth Factory retains the powered high-field and ordinary works needed for J9 physical materials")
	if not failures.is_empty():
		return
	var waste_works := ordinary_works[0] as Dictionary
	var electronics_works := ordinary_works[1] as Dictionary
	var power_id := str(capital_power.get("id", ""))
	var copper_refinery_id := str(copper_refinery.get("id", ""))
	var high_energy_id := str(high_energy_works.get("id", ""))
	var waste_works_id := str(waste_works.get("id", ""))
	var electronics_works_id := str(electronics_works.get("id", ""))
	for target_id in [str(iron_refinery.get("id", "")), copper_refinery_id, high_energy_id, waste_works_id, electronics_works_id, str(foundry.get("id", ""))]:
		_ensure_connection("POWER", power_id, target_id, "")
	# Keep the copper refinery's waste outlet physically live throughout the long
	# high-field batch instead of allowing a full waste buffer to create hidden
	# copper.  A distinct ordinary works makes the fresh basic electronics needed
	# for theory and the later assembly construction.
	var waste_recipe := _factory_command("SET_RECIPE", {"entity_id":waste_works_id, "recipe_id":"grid_reprocess_industrial_waste"})
	var electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":electronics_works_id, "recipe_id":"grid_fabricate_electronics"})
	_check(bool(waste_recipe.get("accepted", false)) and bool(electronics_recipe.get("accepted", false)), "Factory protocol assigns distinct waste-recovery and renewable-electronics J9 lines")
	_clear_competing_cargo_outputs(copper_refinery_id, "industrial_waste", waste_works_id)
	_ensure_connection("CARGO", copper_refinery_id, waste_works_id, "industrial_waste")
	_clear_competing_cargo_inputs(electronics_works_id, "iron_ingot", str(iron_refinery.get("id", "")))
	_clear_competing_cargo_inputs(electronics_works_id, "copper_ingot", copper_refinery_id)
	_clear_competing_cargo_outputs(electronics_works_id, "electronics", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", str(iron_refinery.get("id", "")), electronics_works_id, "iron_ingot")
	_ensure_connection("CARGO", copper_refinery_id, electronics_works_id, "copper_ingot")
	_ensure_connection("CARGO", electronics_works_id, STARTER_DEPOT_ID, "electronics")
	var electronics_events := _advance(60000.0, "J9 renewable theory and assembly electronics")
	var electronics_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(electronics_events, "grid_fabricate_electronics") and int(electronics_depot.get("inventory", {}).get("electronics", 0)) >= 7, "Earth Factory physically stages J9 research and assembly electronics; inventory=%s" % JSON.stringify(electronics_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	var composite_recipe := _factory_command("SET_RECIPE", {"entity_id":high_energy_id, "recipe_id":"grid_fabricate_superconducting_composite"})
	_check(bool(composite_recipe.get("accepted", false)), "Factory protocol assigns superconducting-composite fabrication for Heavy Industry")
	_clear_competing_cargo_outputs(copper_refinery_id, "copper_ingot", high_energy_id)
	_clear_competing_cargo_inputs(high_energy_id, "copper_ingot", copper_refinery_id)
	_clear_competing_cargo_inputs(high_energy_id, "titanium_alloy", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(high_energy_id, "superconducting_composite", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", copper_refinery_id, high_energy_id, "copper_ingot")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, high_energy_id, "titanium_alloy")
	_ensure_connection("CARGO", high_energy_id, STARTER_DEPOT_ID, "superconducting_composite")
	var composite_events := _advance(144000.0, "J9 superconducting-composite fabrication")
	var component_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(composite_events, "grid_fabricate_superconducting_composite") and int(component_depot.get("inventory", {}).get("superconducting_composite", 0)) >= 8, "Earth Factory physically stages eight superconducting composites for four Heavy Industry coils; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	var coil_recipe := _factory_command("SET_RECIPE", {"entity_id":high_energy_id, "recipe_id":"grid_wind_superconducting_coil"})
	_check(bool(coil_recipe.get("accepted", false)), "Factory protocol assigns superconducting-coil fabrication for Heavy Industry")
	_clear_competing_cargo_inputs(high_energy_id, "superconducting_composite", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(high_energy_id, "electronics", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(high_energy_id, "superconducting_coil", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, high_energy_id, "superconducting_composite")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, high_energy_id, "electronics")
	_ensure_connection("CARGO", high_energy_id, STARTER_DEPOT_ID, "superconducting_coil")
	var coil_events := _advance(96000.0, "J9 superconducting-coil fabrication")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var coil_runtime_snapshot := _snapshot(EARTH_WORLD_ID)
	var coil_runtime := _entity(coil_runtime_snapshot, high_energy_id)
	_check(_events_have_recipe(coil_events, "grid_wind_superconducting_coil") and int(component_depot.get("inventory", {}).get("superconducting_coil", 0)) >= 4, "Earth Factory physically stages all experiment, engineering, and prototype coils; inventory=%s works=%s links=%s events=%s" % [JSON.stringify(component_depot.get("inventory", {})), JSON.stringify(coil_runtime), JSON.stringify(coil_runtime_snapshot.get("links", [])), JSON.stringify(coil_events)])
	if not failures.is_empty():
		return
	var radiation_recipe := _factory_command("SET_RECIPE", {"entity_id":high_energy_id, "recipe_id":"grid_fabricate_radiation_hardened_electronics"})
	_check(bool(radiation_recipe.get("accepted", false)), "Factory protocol assigns radiation-hardened electronics for Heavy Industry")
	_clear_competing_cargo_outputs(high_energy_id, "radiation_hardened_electronics", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", high_energy_id, STARTER_DEPOT_ID, "radiation_hardened_electronics")
	var radiation_events := _advance(88000.0, "J9 radiation-hardened electronics fabrication")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(radiation_events, "grid_fabricate_radiation_hardened_electronics") and int(component_depot.get("inventory", {}).get("radiation_hardened_electronics", 0)) >= 4, "Earth Factory physically stages all experiment, engineering, and prototype radiation electronics; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	var data_core_recipe := _factory_command("SET_RECIPE", {"entity_id":high_energy_id, "recipe_id":"grid_fabricate_data_core"})
	_check(bool(data_core_recipe.get("accepted", false)), "Factory protocol assigns the Heavy Industry industrial-release data-core batch")
	_clear_competing_cargo_outputs(high_energy_id, "data_core", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", high_energy_id, STARTER_DEPOT_ID, "data_core")
	var data_events := _advance(18000.0, "J9 industrial-release data-core fabrication")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(data_events, "grid_fabricate_data_core") and int(component_depot.get("inventory", {}).get("data_core", 0)) >= 1, "Earth Factory physically stages the Heavy Industry industrial-release data core; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	_export_to_location("electronics", 1, "J9 Heavy Industry theory")
	_export_to_location("superconducting_coil", 3, "J9 Heavy Industry experiment and engineering")
	_export_to_location("radiation_hardened_electronics", 3, "J9 Heavy Industry experiment and engineering")
	_export_to_location("data_core", 1, "J9 Heavy Industry industrial release")
	_check(bool(game.start_research_project("research_heavy_industry")), "public Research command starts the multi-stage Heavy Industry program from Factory-backed custody")
	var research_prefix_events := _advance(60000.0, "J9 Heavy Industry theory, experiment, and engineering")
	_check(_events_have_type(research_prefix_events, "ResearchStageCompleted"), "Heavy Industry progresses through its physical high-field research stages")
	if not failures.is_empty():
		return
	# The starter Arc Smelter has faithfully retained the copper and electronics
	# from earlier lines.  Its input buffer is full, so do not erase or overwrite
	# that physical history just to make room for the prototype.  Build a separate
	# publicly funded, powered foundry for the remaining one coil and one radiation
	# electronics unit instead.
	var retained_foundry_runtime := _entity(_snapshot(EARTH_WORLD_ID), str(foundry.get("id", "")))
	var retained_input_total := 0
	for retained_quantity in retained_foundry_runtime.get("inputs", {}).values():
		retained_input_total += int(retained_quantity)
	_check(retained_input_total >= int(retained_foundry_runtime.get("input_capacity", 0)), "J9 observes the legacy Arc Smelter's full retained input buffer before commissioning an isolated material-test line; foundry=%s" % JSON.stringify(retained_foundry_runtime))
	if not failures.is_empty():
		return
	# MACHINE placement requires a compatible initial recipe.  Use the already
	# unlocked iron-refining recipe for construction, then explicitly reconfigure
	# this isolated entity to the now-unlocked material-test recipe below.
	var material_foundry_order := _queue_and_fund("grid_arc_smelter", "grid_refine_iron", {"x":200, "y":140}, "J9 isolated Heavy Industry material-test foundry", false)
	if material_foundry_order.is_empty() or not failures.is_empty():
		return
	var material_foundry_construction_events := _advance(240000.0, "J9 isolated material-test foundry construction")
	_check(_events_have_type(material_foundry_construction_events, "FactoryConstructionCompleted"), "Factory physically constructs an isolated Arc Smelter without discarding the legacy foundry buffer")
	if not failures.is_empty():
		return
	foundry = _entity(_snapshot(EARTH_WORLD_ID), str(material_foundry_order.get("entity_id", "")))
	_check(not foundry.is_empty(), "the completed isolated material-test foundry is addressable through the versioned Factory snapshot")
	if foundry.is_empty():
		return
	_ensure_connection("POWER", str(capital_power.get("id", "")), str(foundry.get("id", "")), "")
	var article_recipe := _factory_command("SET_RECIPE", {"entity_id":str(foundry.get("id", "")), "recipe_id":"grid_fabricate_material_test_article"})
	_check(bool(article_recipe.get("accepted", false)), "Factory protocol assigns the Heavy Industry material-test-article recipe after experimental spillover")
	_clear_competing_cargo_inputs(str(foundry.get("id", "")), "superconducting_coil", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(str(foundry.get("id", "")), "radiation_hardened_electronics", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(str(foundry.get("id", "")), "material_test_article", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, str(foundry.get("id", "")), "superconducting_coil")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, str(foundry.get("id", "")), "radiation_hardened_electronics")
	_ensure_connection("CARGO", str(foundry.get("id", "")), STARTER_DEPOT_ID, "material_test_article")
	var article_events := _advance(60000.0, "J9 material-test-article fabrication")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var article_runtime_snapshot := _snapshot(EARTH_WORLD_ID)
	var article_foundry_runtime := _entity(article_runtime_snapshot, str(foundry.get("id", "")))
	_check(_events_have_recipe(article_events, "grid_fabricate_material_test_article") and int(component_depot.get("inventory", {}).get("material_test_article", 0)) >= 1, "Factory physically fabricates the Heavy Industry prototype material article after experimental spillover; inventory=%s foundry=%s links=%s events=%s" % [JSON.stringify(component_depot.get("inventory", {})), JSON.stringify(article_foundry_runtime), JSON.stringify(article_runtime_snapshot.get("links", [])), JSON.stringify(article_events)])
	if not failures.is_empty():
		return
	_export_to_location("material_test_article", 1, "J9 Heavy Industry prototype")
	var heavy_completion_events := _advance(120000.0, "J9 Heavy Industry prototype and industrial release")
	_check(_events_have_type(heavy_completion_events, "ResearchCompleted") and _events_have_type(heavy_completion_events, "TechnologyDomainLeveledUp"), "Heavy Industry completes and levels its technology domains through public time advancement")
	if not failures.is_empty():
		return
	# Pull the physical Asteroid ore harvested by J8 back through public
	# logistics, then turn it into the exact eight steel units that fund the new
	# Heavy Industry assembly array.
	var asteroid_world_ids: Array[String] = game.factory_world_ids_for_location("asteroid_belt")
	_check(asteroid_world_ids.size() == 1, "J9 retains the canonical Asteroid Factory workspace harvested by J8")
	if asteroid_world_ids.is_empty():
		return
	var asteroid_world_id := str(asteroid_world_ids[0])
	var asteroid_depot := _entity_with_definition(_snapshot(asteroid_world_id), "grid_bulk_depot")
	_check(not asteroid_depot.is_empty(), "J9 can address the J8 Asteroid bulk depot for physical ore export")
	if asteroid_depot.is_empty():
		return
	var asteroid_depot_id := str(asteroid_depot.get("id", ""))
	# Five bounded Asteroid-origin shipments need physical operating reserves at
	# their origin. Reuse the proven emergency-propellant line, but feed it through
	# the public topology rather than granting the remote route free fuel.
	var ore_reserve_snapshot := _snapshot(EARTH_WORLD_ID)
	var ore_reserve_depot := _entity(ore_reserve_snapshot, STARTER_DEPOT_ID)
	var ore_propellant_works: Dictionary = {}
	var ore_propellant_score := -1
	for works_value in _entities_with_definition(ore_reserve_snapshot, "grid_engineering_works"):
		var works := works_value as Dictionary
		var works_inputs: Dictionary = works.get("inputs", {})
		var works_score := mini(4, int(works_inputs.get("iron_ingot", 0))) + mini(1, int(works_inputs.get("electronics", 0))) * 8
		if works_score > ore_propellant_score:
			ore_propellant_score = works_score
			ore_propellant_works = works
	var ore_power := _entity_with_definition(ore_reserve_snapshot, "grid_power_substation_ii")
	_check(not ore_propellant_works.is_empty() and not ore_power.is_empty(), "J9 retains a physical engineering works and power provider needed to fund five Asteroid return shipments")
	var ore_propellant_id := str(ore_propellant_works.get("id", ""))
	if failures.is_empty() and int(ore_reserve_depot.get("inventory", {}).get("chemical_propellant", 0)) < 26:
		_ensure_connection("POWER", str(ore_power.get("id", "")), ore_propellant_id, "")
		# Long-running earlier recipes leave this works with a legitimate full iron
		# buffer. Consume a bounded part of it into useful fleet munitions before the
		# emergency-propellant recipe asks for an electronics slot.
		var ore_buffer_recipe := _factory_command("SET_RECIPE", {"entity_id":ore_propellant_id, "recipe_id":"grid_manufacture_kinetic_munitions"})
		_check(bool(ore_buffer_recipe.get("accepted", false)), "Factory protocol selects a physical iron-consuming recipe before return-route propellant fabrication")
		_clear_competing_cargo_inputs(ore_propellant_id, "iron_ingot", "")
		# Stop the completed data-core batch from pulling the remaining depot
		# electronics while the propellant works makes physical input headroom.
		_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "electronics", "")
		_clear_competing_cargo_outputs(ore_propellant_id, "kinetic_munitions", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", ore_propellant_id, STARTER_DEPOT_ID, "kinetic_munitions")
		var ore_buffer_events := _advance(28000.0, "J9 retained-iron consumption before return-route propellant")
		var ore_buffer_runtime := _entity(_snapshot(EARTH_WORLD_ID), ore_propellant_id)
		_check(_events_have_recipe(ore_buffer_events, "grid_manufacture_kinetic_munitions") and int(ore_buffer_runtime.get("inputs", {}).get("iron_ingot", 0)) < int(ore_propellant_works.get("inputs", {}).get("iron_ingot", 0)), "Factory physically consumes retained iron to create electronics headroom for return-route propellant; works=%s" % JSON.stringify(ore_buffer_runtime))
		if not failures.is_empty():
			return
		var ore_propellant_recipe := _factory_command("SET_RECIPE", {"entity_id":ore_propellant_id, "recipe_id":"grid_manufacture_emergency_propellant"})
		_check(bool(ore_propellant_recipe.get("accepted", false)), "Factory protocol assigns emergency propellant to the selected physical return-route works")
		_clear_competing_cargo_inputs(ore_propellant_id, "electronics", STARTER_DEPOT_ID)
		_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "electronics", ore_propellant_id)
		_clear_competing_cargo_outputs(ore_propellant_id, "chemical_propellant", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", STARTER_DEPOT_ID, ore_propellant_id, "electronics")
		_ensure_connection("CARGO", ore_propellant_id, STARTER_DEPOT_ID, "chemical_propellant")
		var ore_propellant_events := _advance(100000.0, "J9 Asteroid return-route propellant fabrication")
		ore_reserve_snapshot = _snapshot(EARTH_WORLD_ID)
		ore_reserve_depot = _entity(ore_reserve_snapshot, STARTER_DEPOT_ID)
		ore_propellant_works = _entity(ore_reserve_snapshot, ore_propellant_id)
		_check(_events_have_recipe(ore_propellant_events, "grid_manufacture_emergency_propellant") and int(ore_reserve_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 26, "Earth Factory physically stages the outbound and five-return-shipment propellant reserve; inventory=%s works=%s events=%s" % [JSON.stringify(ore_reserve_depot.get("inventory", {})), JSON.stringify(ore_propellant_works), JSON.stringify(ore_propellant_events)])
		_clear_competing_cargo_inputs(ore_propellant_id, "electronics", "")
	if failures.is_empty() and int(ore_reserve_depot.get("inventory", {}).get("repair_material", 0)) < 26:
		var ore_repair_recipe := _factory_command("SET_RECIPE", {"entity_id":ore_propellant_id, "recipe_id":"grid_fabricate_repair_material"})
		_check(bool(ore_repair_recipe.get("accepted", false)), "Factory protocol selects physical repair-material fabrication for the final Asteroid dispatch reserve")
		_clear_competing_cargo_inputs(ore_propellant_id, "copper_ingot", STARTER_DEPOT_ID)
		_clear_competing_cargo_outputs(ore_propellant_id, "repair_material", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", STARTER_DEPOT_ID, ore_propellant_id, "copper_ingot")
		_ensure_connection("CARGO", ore_propellant_id, STARTER_DEPOT_ID, "repair_material")
		var ore_repair_events := _advance(18000.0, "J9 final Asteroid dispatch repair-material fabrication")
		ore_reserve_snapshot = _snapshot(EARTH_WORLD_ID)
		ore_reserve_depot = _entity(ore_reserve_snapshot, STARTER_DEPOT_ID)
		_check(_events_have_recipe(ore_repair_events, "grid_fabricate_repair_material") and int(ore_reserve_depot.get("inventory", {}).get("repair_material", 0)) >= 26, "Earth Factory physically replaces the repair material committed to the second capacity-safe Lunar feed shipment; inventory=%s" % JSON.stringify(ore_reserve_depot.get("inventory", {})))
	_check(int(ore_reserve_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 26 and int(ore_reserve_depot.get("inventory", {}).get("repair_material", 0)) >= 26, "Earth Factory holds physical cargo plus dispatch headroom for staging fifteen propellant and ten maintenance units at Asteroid; inventory=%s" % JSON.stringify(ore_reserve_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	# J4's Lunar bootstrap demands have already served their purpose. Retire them
	# before publishing this reserve so they cannot compete with the later,
	# higher-distance Asteroid dispatch for fleet-reserved operating materials.
	_check(bool(game.clear_location_logistics_policy("lunar_space", "chemical_propellant")) and bool(game.clear_location_logistics_policy("lunar_space", "repair_material")) and bool(game.clear_location_logistics_policy("lunar_space", "iron_ingot")) and bool(game.clear_location_logistics_policy("lunar_space", "electronics")) and bool(game.clear_location_logistics_policy("lunar_space", "structural_frame")), "public Logistics retires the fulfilled Lunar construction and operating-reserve demands before Asteroid staging")
	_export_to_location("chemical_propellant", 26, "J9 Asteroid return-route cargo, dispatch, and fleet-reserve headroom")
	_export_to_location("repair_material", 26, "J9 Asteroid return-route maintenance cargo and dispatch headroom")
	game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)
	game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)
	# The hazardous propellant cargo consumes 1.5 units of the twenty-unit
	# Asteroid hub budget per item. Stage maintenance first so both manifests pay
	# their own dispatch costs instead of competing inside one dispatch interval.
	_check(bool(game.set_location_logistics_policy("asteroid_belt", "repair_material", "DEMAND", 0, 10, 100, 1)), "Asteroid requests the exact physical maintenance reserve for five return shipments")
	var ore_operating_events := _advance(180000.0, "J9 Earth-Asteroid return-route maintenance reserve logistics")
	var asteroid_operating_inventory: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	_check(_events_have_type(ore_operating_events, "ShipmentArrived") and int(asteroid_operating_inventory.get("repair_material", 0)) >= 10, "public logistics stages five reverse-shipment maintenance costs before hazardous propellant consumes hub throughput; available=%s events=%s" % [JSON.stringify(asteroid_operating_inventory), JSON.stringify(ore_operating_events)])
	if not failures.is_empty():
		return
	_check(bool(game.set_location_logistics_policy("asteroid_belt", "chemical_propellant", "DEMAND", 0, 15, 100, 1)), "Asteroid requests the exact physical propellant reserve for five return shipments")
	var ore_propellant_staging_events := _advance(360000.0, "J9 Earth-Asteroid return-route propellant reserve logistics")
	ore_operating_events.append_array(ore_propellant_staging_events)
	asteroid_operating_inventory = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	var ore_propellant_cargo_arrivals: Array = ore_propellant_staging_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "ShipmentArrived" and int((event.get("cargo", {}) as Dictionary).get("chemical_propellant", 0)) == 15
	)
	var ore_propellant_arrival := ore_propellant_cargo_arrivals[0] as Dictionary if ore_propellant_cargo_arrivals.size() == 1 else {}
	_check(ore_propellant_cargo_arrivals.size() == 1 and str(ore_propellant_arrival.get("origin", "")) == EARTH_LOCATION_ID and str(ore_propellant_arrival.get("destination", "")) == "asteroid_belt" and int(asteroid_operating_inventory.get("chemical_propellant", 0)) >= 15 and int(asteroid_operating_inventory.get("repair_material", 0)) >= 10, "public logistics physically stages the exact fifteen-unit Earth-to-Asteroid propellant reserve for five reverse shipments; cargo_arrivals=%s available=%s raw_events=%s" % [JSON.stringify(ore_propellant_cargo_arrivals), JSON.stringify(asteroid_operating_inventory), JSON.stringify(ore_propellant_staging_events)])
	if not failures.is_empty():
		return
	_check(bool(game.clear_location_logistics_policy("asteroid_belt", "chemical_propellant")) and bool(game.clear_location_logistics_policy("asteroid_belt", "repair_material")), "public Logistics retires the fulfilled Asteroid operating-reserve demands before ore return")
	# Survey staging provides only twenty BULK storage units and each raw ore uses
	# 2.5 units, so stream at most eight physical items through Location custody.
	# Eight steel composites consume sixteen cobalt and sixteen silicate; Heavy
	# Extraction consumes six additional silicate before Factory import.
	_check(bool(game.set_location_logistics_policy("asteroid_belt", "cobalt_ore", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "silicate_ore", "SUPPLY", 0, 0, 100, 1)), "Asteroid publishes the finite J9 steel feedstocks")
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore", "DEMAND", 0, 16, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "silicate_ore", "DEMAND", 0, 22, 100, 1)), "Earth requests the exact J9 refined-steel and Heavy Extraction feedstocks")
	var ore_return_events: Array = []
	for cobalt_chunk in [8, 8]:
		_export_to_location("cobalt_ore", cobalt_chunk, "J9 bounded Heavy Industry cobalt feed", asteroid_world_id, asteroid_depot_id)
		var cobalt_chunk_events := _advance(360000.0, "J9 bounded Asteroid-Earth cobalt logistics")
		ore_return_events.append_array(cobalt_chunk_events)
		_check(_events_have_type(cobalt_chunk_events, "ShipmentArrived"), "public logistics returns one capacity-safe cobalt batch to Earth")
		if not failures.is_empty():
			return
	for silicate_chunk in [8, 8, 6]:
		_export_to_location("silicate_ore", silicate_chunk, "J9 bounded Heavy Industry silicate feed", asteroid_world_id, asteroid_depot_id)
		var silicate_chunk_events := _advance(360000.0, "J9 bounded Asteroid-Earth silicate logistics")
		ore_return_events.append_array(silicate_chunk_events)
		_check(_events_have_type(silicate_chunk_events, "ShipmentArrived"), "public logistics returns one capacity-safe silicate batch to Earth")
		if not failures.is_empty():
			return
	_check(_events_have_type(ore_return_events, "ShipmentArrived"), "public logistics returns J8 Asteroid cobalt and silicate to Earth")
	earth_available = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(earth_available.get("cobalt_ore", 0)) >= 16 and int(earth_available.get("silicate_ore", 0)) >= 22, "Earth Location receives the full physical J9 steel and Heavy Extraction feedstock manifest; available=%s" % JSON.stringify(earth_available))
	if not failures.is_empty():
		return
	_check(bool(game.start_research_project("research_heavy_extraction")), "public Research command starts Heavy Extraction using the returned Asteroid silicate feedstock")
	var extraction_research_events := _advance(60000.0, "J9 Heavy Extraction research")
	_check(_events_have_type(extraction_research_events, "ResearchCompleted"), "Heavy Extraction completes through public research time advancement before cobalt refinement")
	if not failures.is_empty():
		return
	# Heavy Extraction consumes six silicate units at Location custody; move the
	# remaining sixteen plus all sixteen cobalt ore units into the Factory, then
	# produce the two intermediate inputs that the steel recipe actually requires.
	_import_from_location("cobalt_ore", 16, STARTER_DEPOT_ID, "J9 steel cobalt Factory feed")
	_import_from_location("silicate_ore", 16, STARTER_DEPOT_ID, "J9 steel silicate Factory feed")
	var cobalt_recipe := _factory_command("SET_RECIPE", {"entity_id":str(foundry.get("id", "")), "recipe_id":"grid_refine_cobalt"})
	_check(bool(cobalt_recipe.get("accepted", false)), "Factory protocol assigns Heavy Extraction cobalt refinement before steelmaking")
	_clear_competing_cargo_inputs(str(foundry.get("id", "")), "cobalt_ore", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(str(foundry.get("id", "")), "cobalt_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(str(foundry.get("id", "")), "industrial_waste", waste_works_id)
	_clear_competing_cargo_inputs(waste_works_id, "industrial_waste", str(foundry.get("id", "")))
	_ensure_connection("CARGO", STARTER_DEPOT_ID, str(foundry.get("id", "")), "cobalt_ore")
	_ensure_connection("CARGO", str(foundry.get("id", "")), STARTER_DEPOT_ID, "cobalt_ingot")
	_ensure_connection("CARGO", str(foundry.get("id", "")), waste_works_id, "industrial_waste")
	var cobalt_events := _advance(120000.0, "J9 cobalt-ingot refinement")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(cobalt_events, "grid_refine_cobalt") and int(component_depot.get("inventory", {}).get("cobalt_ingot", 0)) >= 8, "Earth Factory physically refines the eight cobalt ingots required for J9 steel; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	var ceramic_recipe := _factory_command("SET_RECIPE", {"entity_id":str(foundry.get("id", "")), "recipe_id":"grid_process_silicate_ceramic"})
	_check(bool(ceramic_recipe.get("accepted", false)), "Factory protocol assigns silicate-ceramic processing before steelmaking")
	_clear_competing_cargo_inputs(str(foundry.get("id", "")), "silicate_ore", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(str(foundry.get("id", "")), "silicate_ceramic", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, str(foundry.get("id", "")), "silicate_ore")
	_ensure_connection("CARGO", str(foundry.get("id", "")), STARTER_DEPOT_ID, "silicate_ceramic")
	var ceramic_events := _advance(96000.0, "J9 silicate-ceramic processing")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(ceramic_events, "grid_process_silicate_ceramic") and int(component_depot.get("inventory", {}).get("silicate_ceramic", 0)) >= 8, "Earth Factory physically processes the eight silicate ceramics required for J9 steel; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	var steel_recipe := _factory_command("SET_RECIPE", {"entity_id":str(foundry.get("id", "")), "recipe_id":"grid_refine_steel"})
	_check(bool(steel_recipe.get("accepted", false)), "Factory protocol assigns Heavy Industry steel refinement for the assembly array")
	_clear_competing_cargo_inputs(str(foundry.get("id", "")), "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(str(foundry.get("id", "")), "cobalt_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(str(foundry.get("id", "")), "silicate_ceramic", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(str(foundry.get("id", "")), "steel_composite", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, str(foundry.get("id", "")), "iron_ingot")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, str(foundry.get("id", "")), "cobalt_ingot")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, str(foundry.get("id", "")), "silicate_ceramic")
	_ensure_connection("CARGO", str(foundry.get("id", "")), STARTER_DEPOT_ID, "steel_composite")
	var steel_events := _advance(128000.0, "J9 Heavy Industry steel refinement")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(steel_events, "grid_refine_steel") and int(component_depot.get("inventory", {}).get("steel_composite", 0)) >= 8, "Earth Factory physically stages eight Heavy Industry steel composites for the assembly array; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	# Long research windows legitimately consumed the earlier electronics batch.
	# Reconfigure the proven engineering works once more and physically replace the
	# six components needed by the assembly-array construction order.
	var assembly_electronics_id := str(ore_propellant_works.get("id", ""))
	var assembly_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":assembly_electronics_id, "recipe_id":"grid_fabricate_electronics"})
	_check(bool(assembly_electronics_recipe.get("accepted", false)), "Factory protocol restores renewable electronics for the Heavy Industry assembly construction")
	_clear_competing_cargo_inputs(assembly_electronics_id, "copper_ingot", copper_refinery_id)
	_clear_competing_cargo_outputs(copper_refinery_id, "copper_ingot", assembly_electronics_id)
	_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "electronics", "")
	_clear_competing_cargo_outputs(assembly_electronics_id, "electronics", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", copper_refinery_id, assembly_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", assembly_electronics_id, STARTER_DEPOT_ID, "electronics")
	var assembly_electronics_events := _advance(48000.0, "J9 assembly-array construction electronics")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(assembly_electronics_events, "grid_fabricate_electronics") and int(component_depot.get("inventory", {}).get("electronics", 0)) >= 6, "Earth Factory physically replaces the six assembly-array construction electronics; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	var pre_assembly_titanium_snapshot := _snapshot(EARTH_WORLD_ID)
	var pre_assembly_titanium_depot := _entity(pre_assembly_titanium_snapshot, STARTER_DEPOT_ID)
	var pre_assembly_titanium_total := int(pre_assembly_titanium_snapshot.get("location_available_inventory", {}).get("titanium_alloy", 0)) + int(pre_assembly_titanium_depot.get("inventory", {}).get("titanium_alloy", 0))
	_check(pre_assembly_titanium_total >= 6, "the capacity-safe Lunar stream preserves the complete six-unit assembly-array titanium reserve across Earth custody; location=%s depot=%s" % [JSON.stringify(pre_assembly_titanium_snapshot.get("location_available_inventory", {})), JSON.stringify(pre_assembly_titanium_depot.get("inventory", {}))])
	if not failures.is_empty():
		return
	# Factory machines enter construction with one compatible recipe. Logistics
	# handling is unlocked by Heavy Industry and will be reused by J10.
	var assembly_array := _queue_and_fund("grid_assembly_array", "grid_fabricate_logistics_handling_equipment", {"x":200, "y":100}, "J9 Heavy Industry assembly array", true)
	if assembly_array.is_empty() or not failures.is_empty():
		return
	var assembly_events := _advance(240000.0, "J9 assembly-array construction")
	var assembly_order_id := str(assembly_array.get("order_id", ""))
	var assembly_entity_id := str(assembly_array.get("entity_id", ""))
	var assembly_completed := assembly_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("order_id", "")) == assembly_order_id and str(event.get("entity_id", "")) == assembly_entity_id
	)
	var assembly_snapshot := _snapshot(EARTH_WORLD_ID)
	var completed_assembly_entity := _entity(assembly_snapshot, assembly_entity_id)
	var assembly_order_retired := not (assembly_snapshot.get("construction_orders", []) as Array).any(func(order_value): return str((order_value as Dictionary).get("id", "")) == assembly_order_id)
	_check(assembly_completed and assembly_order_retired and str(completed_assembly_entity.get("definition_id", "")) == "grid_assembly_array", "Factory physically constructs and retires the exact Heavy Industry assembly-array order")
	var j9_events := _events_after(journey_events_start)
	_check(_ordered_types(["FactoryRecipeCompleted", "ResearchCompleted", "FactoryConstructionCompleted"], j9_events), "J9 preserves physical material fabrication, Heavy Industry research, and assembly-array construction causality")
	if failures.is_empty():
		_journey_pass("J9", "ADVANCED_INDUSTRY")


func _complete_megastructure_journey() -> void:
	var journey_events_start := observed_events.size()
	# J7's canonical Asteroid route returns a finite four-unit scrap reward through
	# the Pathfinder's cargo hold.  J7 already observed its earth_orbit unload and
	# moved it through protocol-v1 into the Earth starter depot, freeing finite
	# Location staging before J8/J9 logistics.  J10 keeps the causal evidence and
	# uses the remaining custody for the Lunar rare-earth mine.
	var asteroid_route_events: Array = observed_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "ExpeditionRouteCompleted" and str(event.get("route_id", "")) == "asteroid_route"
	)
	_check(asteroid_route_events.size() == 1, "J10 retains exactly one completed canonical Asteroid route as the source of its finite Lunar rare-earth bootstrap scrap")
	var asteroid_route_imports: Array = observed_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryCargoImported" and str(event.get("world_id", "")) == EARTH_WORLD_ID and str(event.get("storage_id", "")) == STARTER_DEPOT_ID and str(event.get("item_id", "")) == "scrap_metal" and int(event.get("quantity", 0)) == 4
	)
	var earth_after_j9 := _snapshot(EARTH_WORLD_ID)
	var earth_after_j9_depot := _entity(earth_after_j9, STARTER_DEPOT_ID)
	_check(asteroid_route_imports.size() == 1 and int(earth_after_j9_depot.get("inventory", {}).get("scrap_metal", 0)) >= 4, "J10 retains the one J7 public scrap import and at least four physical route-reward scrap units in Earth Factory custody for Lunar rare-earth construction; inventory=%s" % JSON.stringify(earth_after_j9_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	var lunar_world_ids: Array[String] = game.factory_world_ids_for_location("lunar_space")
	_check(lunar_world_ids.size() == 1, "J10 reuses the surveyed Lunar Factory workspace for the physical rare-earth mine bootstrap")
	if lunar_world_ids.is_empty() or not failures.is_empty():
		return
	var lunar_world_id := str(lunar_world_ids[0])
	var lunar_snapshot := _snapshot(lunar_world_id)
	var lunar_depot := _entity_with_definition(lunar_snapshot, "grid_bulk_depot")
	var rare_earth_field := _resource_field(lunar_snapshot, "rare_earth_concentrate")
	_check(not lunar_depot.is_empty() and not rare_earth_field.is_empty(), "Lunar Factory exposes its completed bulk storage and surveyed rare-earth field for the J10 physical bootstrap")
	if failures.size() > 0:
		return
	# Every movement remains a public Location-to-Location shipment.  The current
	# Earth Factory must itself fund both freight operating inputs; this preflight
	# is intentionally fail-fast instead of relying on prior route cargo.
	var earth_freight_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var earth_freight_inventory: Dictionary = earth_freight_depot.get("inventory", {})
	if int(earth_freight_inventory.get("chemical_propellant", 0)) < 2:
		var propellant_works := _entity_with_recipe(_snapshot(EARTH_WORLD_ID), "grid_fabricate_electronics")
		var propellant_power := _entity_with_definition(_snapshot(EARTH_WORLD_ID), "grid_power_substation_ii")
		_check(not propellant_works.is_empty() and not propellant_power.is_empty(), "J10 can reconfigure an existing powered Earth engineering works for the finite Lunar rare-earth freight propellant batch")
		if failures.size() > 0:
			return
		var propellant_works_id := str(propellant_works.get("id", ""))
		var propellant_recipe := _factory_command("SET_RECIPE", {"entity_id":propellant_works_id, "recipe_id":"grid_manufacture_emergency_propellant"})
		_check(bool(propellant_recipe.get("accepted", false)), "Factory protocol assigns emergency propellant for the J10 Lunar rare-earth freight reserve")
		_ensure_connection("POWER", str(propellant_power.get("id", "")), propellant_works_id, "")
		_clear_competing_cargo_inputs(propellant_works_id, "iron_ingot", STARTER_DEPOT_ID)
		_clear_competing_cargo_inputs(propellant_works_id, "electronics", STARTER_DEPOT_ID)
		_clear_competing_cargo_outputs(propellant_works_id, "chemical_propellant", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", STARTER_DEPOT_ID, propellant_works_id, "iron_ingot")
		_ensure_connection("CARGO", STARTER_DEPOT_ID, propellant_works_id, "electronics")
		_ensure_connection("CARGO", propellant_works_id, STARTER_DEPOT_ID, "chemical_propellant")
		var propellant_events := _advance(20000.0, "J10 Lunar rare-earth freight propellant fabrication")
		earth_freight_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		earth_freight_inventory = earth_freight_depot.get("inventory", {})
		_check(_events_have_recipe(propellant_events, "grid_manufacture_emergency_propellant") and int(earth_freight_inventory.get("chemical_propellant", 0)) >= 2, "Earth Factory physically replenishes the bounded J10 Earth-Lunar freight propellant reserve; inventory=%s" % JSON.stringify(earth_freight_inventory))
		# This finite reserve is complete.  Disconnect its inputs before later long
		# research/transport windows so it cannot silently consume electronics that
		# belong to the explicit J10 advanced-material manifests.
		_clear_competing_cargo_inputs(propellant_works_id, "iron_ingot", "")
		_clear_competing_cargo_inputs(propellant_works_id, "electronics", "")
		if failures.size() > 0:
			return
	_check(int(earth_freight_inventory.get("chemical_propellant", 0)) >= 2 and int(earth_freight_inventory.get("repair_material", 0)) >= 2, "Earth Factory retains physical propellant and repair cargo for the bounded J10 Earth-Lunar rare-earth mine shipment; inventory=%s" % JSON.stringify(earth_freight_inventory))
	if failures.size() > 0:
		return
	_export_to_location("scrap_metal", 4, "J10 Lunar rare-earth mine construction manifest")
	_export_to_location("chemical_propellant", 2, "J10 Earth-Lunar rare-earth manifest operating reserve")
	_export_to_location("repair_material", 2, "J10 Earth-Lunar rare-earth manifest maintenance reserve")
	# J8 retained its Earth-side scrap supply policy after completing the Asteroid
	# bootstrap.  Retire that public policy before publishing J10's bounded four-
	# unit manifest; a policy replacement is intentionally not treated as an
	# idempotent success because the target/priority must be observable here.
	_check(bool(game.clear_location_logistics_policy(EARTH_LOCATION_ID, "scrap_metal")), "J10 retires the completed J8 Earth scrap policy before publishing its bounded Lunar construction manifest")
	if failures.size() > 0:
		return
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "scrap_metal", "SUPPLY", 0, 0, 100, 1)), "Earth publishes the imported Asteroid-route scrap as the bounded J10 Lunar construction supply")
	_check(bool(game.set_location_logistics_policy("lunar_space", "scrap_metal", "DEMAND", 0, 4, 100, 1)), "Lunar Space requests exactly four Asteroid-route scrap units for its rare-earth mine")
	var lunar_scrap_freight_events := _advance(180000.0, "J10 Earth-Lunar rare-earth mine logistics")
	var lunar_available: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(_events_have_type(lunar_scrap_freight_events, "ShipmentArrived") and int(lunar_available.get("scrap_metal", 0)) >= 4, "public Logistics delivers the exact Asteroid-route scrap construction manifest to Lunar Location custody; available=%s" % JSON.stringify(lunar_available))
	if failures.size() > 0:
		return
	var lunar_depot_id := str(lunar_depot.get("id", ""))
	_import_from_location("scrap_metal", 4, lunar_depot_id, "J10 Lunar rare-earth mine Factory staging", lunar_world_id)
	# The surface mine's final component is deliberately transported through the
	# same public route, even though prior journeys may have left unrelated Lunar
	# electronics behind.  This proves the construction consumes a new, bounded
	# Earth-to-Lunar manifest rather than treating that earlier custody as a grant.
	_export_to_location("electronics", 1, "J10 Lunar rare-earth mine electronic construction manifest")
	_export_to_location("chemical_propellant", 1, "J10 Lunar rare-earth electronic manifest operating reserve")
	_export_to_location("repair_material", 1, "J10 Lunar rare-earth electronic manifest maintenance reserve")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "electronics")
	game.clear_location_logistics_policy("lunar_space", "electronics")
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "electronics", "SUPPLY", 0, 0, 100, 1)), "Earth publishes the bounded electronic supply for the Lunar rare-earth mine")
	_check(bool(game.set_location_logistics_policy("lunar_space", "electronics", "DEMAND", 0, 3, 100, 1)), "Lunar Space requests exactly one additional electronic component after its inherited finite inventory")
	var lunar_electronics_freight_events := _advance(180000.0, "J10 Earth-Lunar rare-earth mine electronics logistics")
	lunar_available = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(_events_have_type(lunar_electronics_freight_events, "ShipmentArrived") and int(lunar_available.get("electronics", 0)) >= 3, "public Logistics delivers the bounded final electronic mine component to Lunar Location custody; available=%s events=%s" % [JSON.stringify(lunar_available), JSON.stringify(lunar_electronics_freight_events)])
	if failures.size() > 0:
		return
	# Fund this order from mixed physical custody: route reward scrap in the
	# Factory bulk depot and the newly shipped electronics at the same Location.
	var rare_earth_mine := _queue_and_fund("grid_surface_mine", "", rare_earth_field.get("footprint", {}).get("origin", {}), "J10 Lunar rare-earth mine", true, lunar_world_id, lunar_depot_id)
	if rare_earth_mine.is_empty() or failures.size() > 0:
		return
	var rare_earth_construction_events := _advance(180000.0, "J10 Lunar rare-earth mine construction")
	var rare_earth_mine_id := str(rare_earth_mine.get("entity_id", ""))
	_check(_events_have_type(rare_earth_construction_events, "FactoryConstructionCompleted") and not _entity(_snapshot(lunar_world_id), rare_earth_mine_id).is_empty(), "Factory physically constructs the route-reward-funded Lunar rare-earth mine")
	if failures.size() > 0:
		return
	var lunar_power := _entity_with_definition(_snapshot(lunar_world_id), "grid_solar_array")
	_check(not lunar_power.is_empty(), "J10 retains a completed Lunar solar provider for the rare-earth mine")
	if lunar_power.is_empty():
		return
	_ensure_connection("POWER", str(lunar_power.get("id", "")), rare_earth_mine_id, "", lunar_world_id)
	_clear_competing_cargo_outputs(rare_earth_mine_id, "rare_earth_concentrate", lunar_depot_id, lunar_world_id)
	_ensure_connection("CARGO", rare_earth_mine_id, lunar_depot_id, "rare_earth_concentrate", lunar_world_id)
	var rare_earth_extraction_events := _advance(60000.0, "J10 Lunar rare-earth extraction")
	var rare_earth_depot := _entity(_snapshot(lunar_world_id), lunar_depot_id)
	_check(_events_have_type(rare_earth_extraction_events, "FactoryResourceExtracted") and int(rare_earth_depot.get("inventory", {}).get("rare_earth_concentrate", 0)) >= 2, "the powered Lunar rare-earth mine physically extracts and stages the first capacity-safe quantum-material feed; depot=%s events=%s" % [JSON.stringify(rare_earth_depot), JSON.stringify(rare_earth_extraction_events)])
	if failures.size() > 0:
		return
	# Rare-earth concentrate is a SPECIAL resource (two storage units per item),
	# while the surveyed Lunar package has only five SPECIAL units.  Return the
	# exact capacity-safe two-unit batch instead of bypassing its storage class;
	# those two units are precisely the first Belt research/construction quantum
	# feed. The Location still holds the one propellant and one maintenance unit
	# that arrived with the first route-reward manifest for this one shipment.
	_export_to_location("rare_earth_concentrate", 2, "J10 Lunar rare-earth quantum-material return", lunar_world_id, lunar_depot_id)
	_check(bool(game.set_location_logistics_policy("lunar_space", "rare_earth_concentrate", "SUPPLY", 0, 0, 100, 1)), "Lunar Space publishes the physical rare-earth concentrate return supply")
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate", "DEMAND", 0, 2, 100, 1)), "Earth requests the exact first capacity-safe Lunar rare-earth concentrate batch")
	var rare_earth_return_events := _advance(180000.0, "J10 Lunar-to-Earth rare-earth return logistics")
	var earth_rare_earth_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(_events_have_type(rare_earth_return_events, "ShipmentArrived") and int(earth_rare_earth_available.get("rare_earth_concentrate", 0)) >= 2, "public Logistics returns the exact capacity-safe Lunar rare-earth batch to Earth Location custody; available=%s" % JSON.stringify(earth_rare_earth_available))
	if failures.size() > 0:
		return
	_import_from_location("rare_earth_concentrate", 2, STARTER_DEPOT_ID, "J10 Earth quantum-material Factory staging")
	var earth_rare_earth_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(int(earth_rare_earth_depot.get("inventory", {}).get("rare_earth_concentrate", 0)) >= 2, "Earth Factory imports the exact public Lunar rare-earth return for J10 quantum fabrication; inventory=%s" % JSON.stringify(earth_rare_earth_depot.get("inventory", {})))
	if failures.size() > 0:
		return
	# The J9 Assembly Array is the unlocked, physical microstructure facility.
	# Reconfigure it instead of creating a second authority, and route all three
	# recipe inputs through explicitly owned Cargo ports.
	var quantum_snapshot := _snapshot(EARTH_WORLD_ID)
	var quantum_assembly := _entity_with_definition(quantum_snapshot, "grid_assembly_array")
	var quantum_power := _entity_with_definition(quantum_snapshot, "grid_power_substation_ii")
	var quantum_copper := _entity_with_recipe(quantum_snapshot, "grid_refine_copper")
	_check(not quantum_assembly.is_empty() and not quantum_power.is_empty() and not quantum_copper.is_empty(), "J10 retains the completed Assembly Array, powered grid, and physical copper provider for first quantum components")
	if failures.size() > 0:
		return
	var quantum_assembly_id := str(quantum_assembly.get("id", ""))
	var quantum_copper_id := str(quantum_copper.get("id", ""))
	var quantum_recipe := _factory_command("SET_RECIPE", {"entity_id":quantum_assembly_id, "recipe_id":"grid_fabricate_quantum_component"})
	_check(bool(quantum_recipe.get("accepted", false)), "Factory protocol assigns first quantum-component fabrication to the completed Assembly Array")
	# CARGO input transfers are intentionally unconstrained by a per-link reserve.
	# Preserve the five electronics that belong to the two subsequent public
	# development/Shipyard costs before attaching the Array's hungry input port.
	_export_to_location("electronics", 5, "J10 Belt Cruiser development and Shipyard electronics reserve before quantum fabrication")
	var pre_quantum_electronics_location: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(pre_quantum_electronics_location.get("electronics", 0)) >= 5, "Earth custody reserves the exact Belt Cruiser development and Shipyard electronics before the Assembly Array may consume Factory stock; available=%s" % JSON.stringify(pre_quantum_electronics_location))
	if failures.size() > 0:
		return
	_ensure_connection("POWER", str(quantum_power.get("id", "")), quantum_assembly_id, "")
	_clear_competing_cargo_inputs(quantum_assembly_id, "copper_ingot", quantum_copper_id)
	_clear_competing_cargo_inputs(quantum_assembly_id, "electronics", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(quantum_assembly_id, "rare_earth_concentrate", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(quantum_copper_id, "copper_ingot", quantum_assembly_id)
	_clear_competing_cargo_outputs(quantum_assembly_id, "quantum_component", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", quantum_copper_id, quantum_assembly_id, "copper_ingot")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, quantum_assembly_id, "electronics")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, quantum_assembly_id, "rare_earth_concentrate")
	_ensure_connection("CARGO", quantum_assembly_id, STARTER_DEPOT_ID, "quantum_component")
	var quantum_events := _advance(120000.0, "J10 first Lunar rare-earth quantum-component fabrication")
	var quantum_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var quantum_runtime := _entity(_snapshot(EARTH_WORLD_ID), quantum_assembly_id)
	_check(_events_have_recipe(quantum_events, "grid_fabricate_quantum_component") and int(quantum_depot.get("inventory", {}).get("quantum_component", 0)) >= 2, "the public Factory topology physically turns the exact Lunar rare-earth batch into two quantum components; depot=%s assembly=%s" % [JSON.stringify(quantum_depot.get("inventory", {})), JSON.stringify(quantum_runtime)])
	if failures.size() > 0:
		return
	# Development and the Shipyard each need one quantum component. The exact five
	# electronics were deliberately moved to Location before quantum fabrication.
	_export_to_location("quantum_component", 2, "J10 Belt Cruiser development and Shipyard quantum BOM")
	var belt_development_inventory: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(belt_development_inventory.get("quantum_component", 0)) >= 2 and int(belt_development_inventory.get("electronics", 0)) >= 5, "Factory exports the exact first Belt Cruiser development and construction quantum/electronics manifest to Earth custody; available=%s" % JSON.stringify(belt_development_inventory))
	if failures.size() > 0:
		return
	_check(bool(game.start_research_project("develop_belt_cruiser")), "public Research command begins development of the canonical Belt Cruiser plan")
	var belt_development_events := _advance(60000.0, "J10 Belt Cruiser development")
	_check(_events_have_type(belt_development_events, "ResearchCompleted"), "Belt Cruiser development consumes its public quantum/electronics research manifest and releases the construction plan")
	var belt_post_development_inventory: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(belt_post_development_inventory.get("quantum_component", 0)) >= 1 and int(belt_post_development_inventory.get("electronics", 0)) >= 2, "Belt Cruiser development leaves the exact fixed Shipyard quantum/electronics reserve in Location custody; available=%s" % JSON.stringify(belt_post_development_inventory))
	if failures.size() > 0:
		return
	# The complete Belt Cruiser Shipyard BOM (hull plus canonical starting modules)
	# needs seven titanium alloy. Reuse the running Lunar
	# titanium Factory and stage the single return dispatch's operating inputs at
	# its own Location; the depot itself remains the source of the alloy cargo.
	var lunar_titanium_depot := _entity(_snapshot(lunar_world_id), lunar_depot_id)
	var lunar_titanium_reserve := int(lunar_titanium_depot.get("inventory", {}).get("titanium_alloy", 0))
	_check(lunar_titanium_reserve >= 7, "J10 retains all seven physically refined Lunar titanium alloy units required by the complete Belt Cruiser Shipyard BOM; depot=%s" % JSON.stringify(lunar_titanium_depot.get("inventory", {})))
	if failures.size() > 0:
		return
	# Retire the fulfilled titanium policy before staging the return's operating
	# inputs.  Otherwise a historical zero-minimum policy can immediately spend
	# the newly delivered maintenance cargo on an unrelated dispatch.
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "titanium_alloy")
	game.clear_location_logistics_policy("lunar_space", "titanium_alloy")
	# The J8/J9 bounded raw-material and rare-earth policies have completed their
	# exact manifests. Retire them before the Cruiser return so their now-empty
	# sources cannot keep the public Logistics tick in MAINTENANCE_SHORTAGE.
	for retired_item in ["cobalt_ore", "silicate_ore", "rare_earth_concentrate", "scrap_metal"]:
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, retired_item)
		game.clear_location_logistics_policy("lunar_space", retired_item)
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
	game.clear_location_logistics_policy("lunar_space", "chemical_propellant")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "repair_material")
	game.clear_location_logistics_policy("lunar_space", "repair_material")
	var earth_belt_freight_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(earth_belt_freight_available.get("chemical_propellant", 0)) >= 1 and int(earth_belt_freight_available.get("repair_material", 0)) >= 1, "Earth Location retains the physical propellant and transport-maintenance costs for the one bounded Belt Cruiser titanium source-resupply shipment; available=%s" % JSON.stringify(earth_belt_freight_available))
	if failures.size() > 0:
		return
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)), "Earth publishes the physical propellant cost for the Lunar titanium return")
	_check(bool(game.set_location_logistics_policy("lunar_space", "chemical_propellant", "DEMAND", 0, 1, 100, 1)), "Lunar Space requests the exact propellant cost for its Belt Cruiser titanium return")
	var lunar_titanium_operating_events := _advance(180000.0, "J10 Lunar titanium return operating-reserve logistics")
	var lunar_titanium_available: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(_events_have_type(lunar_titanium_operating_events, "ShipmentArrived") and int(lunar_titanium_available.get("chemical_propellant", 0)) >= 1, "public Logistics stages the exact physical propellant cost at the Lunar titanium source before dispatch; available=%s" % JSON.stringify(lunar_titanium_available))
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy("lunar_space", "chemical_propellant")
	_export_to_location("titanium_alloy", 7, "J10 complete Belt Cruiser titanium Shipyard BOM return", lunar_world_id, lunar_depot_id)
	game.clear_location_logistics_policy("lunar_space", "titanium_alloy")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "titanium_alloy")
	_check(bool(game.set_location_logistics_policy("lunar_space", "titanium_alloy", "SUPPLY", 0, 0, 100, 1)), "Lunar Space publishes the exact Belt Cruiser titanium hull supply")
	var earth_titanium_target := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("titanium_alloy", 0)) + 7
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "titanium_alloy", "DEMAND", 0, earth_titanium_target, 100, 1)), "Earth requests the exact seven-unit complete Belt Cruiser titanium Shipyard manifest")
	# A general-cargo path adds one repair-material maintenance cost on top of the
	# route's declared propellant cost. Keep titanium policy live, then deliver the
	# repair unit: the public settle/dispatch boundary must consume that arrival to
	# launch the already-published Titanium return in the same deterministic tick.
	var earth_repair_dispatch_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(int(earth_repair_dispatch_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 1, "Earth Factory retains one physical propellant unit for the separate general-cargo repair delivery; inventory=%s" % JSON.stringify(earth_repair_dispatch_depot.get("inventory", {})))
	if failures.size() > 0:
		return
	_export_to_location("chemical_propellant", 1, "J10 Lunar titanium repair-delivery dispatch cost")
	var earth_repair_dispatch_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(earth_repair_dispatch_available.get("chemical_propellant", 0)) >= 1, "Earth Location stages the physical propellant source cost for the separate repair delivery; available=%s" % JSON.stringify(earth_repair_dispatch_available))
	if failures.size() > 0:
		return
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)), "Earth publishes the exact general-cargo maintenance unit after the Titanium return policy is live")
	_check(bool(game.set_location_logistics_policy("lunar_space", "repair_material", "DEMAND", 0, 1, 100, 1)), "Lunar Space requests the exact general-cargo maintenance unit needed to dispatch the published Titanium return")
	var titanium_repair_dispatch_events := _advance(45000.0, "J10 Lunar titanium maintenance arrival and same-boundary dispatch")
	var repair_arrived := false
	var titanium_dispatched := false
	for titanium_event_value in titanium_repair_dispatch_events:
		var titanium_event := titanium_event_value as Dictionary
		var titanium_cargo := titanium_event.get("cargo", {}) as Dictionary
		if str(titanium_event.get("type", "")) == "ShipmentArrived" and int(titanium_cargo.get("repair_material", 0)) == 1:
			repair_arrived = true
		if str(titanium_event.get("type", "")) == "ShipmentDispatched" and int(titanium_cargo.get("titanium_alloy", 0)) == 7:
			titanium_dispatched = true
	_check(repair_arrived and titanium_dispatched, "public Logistics settles the repair cargo and dispatches the already-published Titanium hull manifest at the same deterministic boundary; earth_available=%s lunar_available=%s earth_blockers=%s lunar_blockers=%s events=%s" % [JSON.stringify(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})), JSON.stringify(_snapshot(lunar_world_id).get("location_available_inventory", {})), JSON.stringify(game.active_blockers(EARTH_LOCATION_ID)), JSON.stringify(game.active_blockers("lunar_space")), JSON.stringify(titanium_repair_dispatch_events)])
	if failures.size() > 0:
		return
	var titanium_hull_return_events := _advance(60000.0, "J10 Lunar-to-Earth Belt Cruiser titanium arrival")
	var earth_titanium_hull_inventory: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(_events_have_type(titanium_hull_return_events, "ShipmentArrived") and int(earth_titanium_hull_inventory.get("titanium_alloy", 0)) >= 7, "public Logistics returns the exact seven-unit Lunar titanium Shipyard manifest to Earth custody without exceeding its finite storage class; available=%s lunar_available=%s earth_blockers=%s lunar_blockers=%s events=%s" % [JSON.stringify(earth_titanium_hull_inventory), JSON.stringify(_snapshot(lunar_world_id).get("location_available_inventory", {})), JSON.stringify(game.active_blockers(EARTH_LOCATION_ID)), JSON.stringify(game.active_blockers("lunar_space")), JSON.stringify(titanium_hull_return_events)])
	if failures.size() > 0:
		return
	# The completed development already leaves two electronics at Earth. Reuse the
	# same public copper/electronics topology for the remaining nine raw electronic
	# components, then export the exact raw iron, copper, and reactor-part portions
	# of the canonical Cruiser starting-module BOM. No modules are granted here:
	# the saved-design Shipyard resolves and debits their full raw-material costs.
	var cruiser_supply_snapshot := _snapshot(EARTH_WORLD_ID)
	var cruiser_electronics_works := _entity_with_recipe(cruiser_supply_snapshot, "grid_manufacture_emergency_propellant")
	var cruiser_copper_refinery := _entity_with_recipe(cruiser_supply_snapshot, "grid_refine_copper")
	var cruiser_power := _entity_with_definition(cruiser_supply_snapshot, "grid_power_substation_ii")
	_check(not cruiser_electronics_works.is_empty() and not cruiser_copper_refinery.is_empty() and not cruiser_power.is_empty(), "J10 retains the public Earth machines needed to physically replenish the Belt Cruiser starting-module electronics BOM")
	if failures.size() > 0:
		return
	var cruiser_electronics_id := str(cruiser_electronics_works.get("id", ""))
	var cruiser_copper_id := str(cruiser_copper_refinery.get("id", ""))
	var cruiser_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_electronics"})
	_check(bool(cruiser_electronics_recipe.get("accepted", false)), "Factory protocol restores renewable electronics for the remaining Belt Cruiser Shipyard manifest")
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_electronics_id, "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", cruiser_copper_id)
	_clear_competing_cargo_outputs(cruiser_copper_id, "copper_ingot", cruiser_electronics_id)
	# The completed Array is intentionally INPUT_SHORTAGE on rare earth, but its
	# live electronics CARGO port would still absorb this exact Cruiser reserve.
	# Remove that public link before producing, rather than counting output that
	# silently remains in another machine's input buffer.
	_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "electronics", "")
	_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_copper_id, cruiser_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_electronics_id, STARTER_DEPOT_ID, "electronics")
	var cruiser_electronics_events := _advance(60000.0, "J10 Belt Cruiser starting-module electronics fabrication")
	var cruiser_supply_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(cruiser_electronics_events, "grid_fabricate_electronics") and int(cruiser_supply_depot.get("inventory", {}).get("electronics", 0)) >= 10, "after removing the Array electronics link, five public Factory electronics cycles retain their full ten-unit output in depot custody for the nine-unit Belt Cruiser reserve; inventory=%s works=%s copper=%s links=%s events=%s" % [JSON.stringify(cruiser_supply_depot.get("inventory", {})), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_copper_id)), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("links", [])), JSON.stringify(cruiser_electronics_events)])
	if failures.size() > 0:
		return
	# A cruiser is an engineering-level-two Shipyard project.  Upgrade the
	# Starport through the same physical Factory construction/funding path before
	# exporting its final electronics reserve, so the scale upgrade cannot consume
	# shipyard-custody materials after they have crossed the Location boundary.
	var starport_expansion := _queue_and_fund("grid_starport_expansion_ii", "", {"x":270, "y":0}, "J10 Starport II required for Belt Cruiser engineering", false)
	if starport_expansion.is_empty() or failures.size() > 0:
		return
	var starport_expansion_events := _advance(120000.0, "J10 Starport II physical construction")
	_check(_events_have_type(starport_expansion_events, "FactoryConstructionCompleted"), "Factory physically completes Starport Expansion II after its versioned queue and Factory-funded order")
	var starport_expansion_entity := _entity(_snapshot(EARTH_WORLD_ID), str(starport_expansion.get("entity_id", "")))
	_check(str(starport_expansion_entity.get("definition_id", "")) == "grid_starport_expansion_ii", "Factory snapshot exposes the completed canonical Starport II provider before Cruiser queueing; entity=%s" % JSON.stringify(starport_expansion_entity))
	if failures.size() > 0:
		return
	_export_to_location("electronics", 9, "J10 remaining Belt Cruiser starting-module electronics BOM")
	# The copper refinery is physically OUTPUT_FULL on its industrial-waste
	# co-product.  Drain that output through its public CARGO port into the existing
	# compatible starter depot; this preserves all material and frees the distinct
	# copper output instead of deleting either buffer.
	_clear_competing_cargo_outputs(cruiser_copper_id, "industrial_waste", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", cruiser_copper_id, STARTER_DEPOT_ID, "industrial_waste")
	# The electronic line no longer needs its copper port after the bounded batch.
	# Return the real provider to depot custody for the three raw copper units in
	# the light weapon, shield, and civilian reactor modules.
	_clear_competing_cargo_outputs(cruiser_copper_id, "copper_ingot", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", cruiser_copper_id, STARTER_DEPOT_ID, "copper_ingot")
	var cruiser_copper_staging_events := _advance(30000.0, "J10 Belt Cruiser module copper staging")
	cruiser_supply_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(cruiser_copper_staging_events, "grid_refine_copper") and int(cruiser_supply_depot.get("inventory", {}).get("industrial_waste", 0)) >= 63 and int(cruiser_supply_depot.get("inventory", {}).get("copper_ingot", 0)) >= 3, "Earth Factory physically drains the copper-refinery industrial-waste buffer and stages the three copper ingots required by Belt Cruiser starting modules; inventory=%s refinery=%s events=%s" % [JSON.stringify(cruiser_supply_depot.get("inventory", {})), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_copper_id)), JSON.stringify(cruiser_copper_staging_events)])
	if failures.size() > 0:
		return
	_export_to_location("copper_ingot", 3, "J10 Belt Cruiser weapon shield and reactor copper BOM")
	_export_to_location("iron_ingot", 7, "J10 Belt Cruiser weapon shield and reactor iron BOM")
	_export_to_location("reactor_part", 1, "J10 Belt Cruiser targeting-computer reactor-part BOM")
	var cruiser_location_manifest: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(cruiser_location_manifest.get("quantum_component", 0)) >= 1 and int(cruiser_location_manifest.get("titanium_alloy", 0)) >= 7 and int(cruiser_location_manifest.get("electronics", 0)) >= 11 and int(cruiser_location_manifest.get("iron_ingot", 0)) >= 7 and int(cruiser_location_manifest.get("copper_ingot", 0)) >= 3 and int(cruiser_location_manifest.get("reactor_part", 0)) >= 1, "Earth custody holds every non-steel raw input of the complete canonical Belt Cruiser Shipyard BOM; available=%s" % JSON.stringify(cruiser_location_manifest))
	if failures.size() > 0:
		return
	# The bounded raw-cobalt return reuses the J8 Asteroid depot and the already
	# configured freight service.  Survey Location BULK capacity is only twenty
	# units (raw ore uses 2.5), so two public 8+4 shipments are required; import
	# each before requesting the next batch instead of enlarging any capacity.
	var asteroid_world_ids: Array[String] = game.factory_world_ids_for_location("asteroid_belt")
	_check(asteroid_world_ids.size() == 1, "J10 retains the one surveyed Asteroid Factory needed for the bounded cobalt stream")
	if asteroid_world_ids.is_empty() or failures.size() > 0:
		return
	var asteroid_world_id := str(asteroid_world_ids[0])
	var asteroid_steel_snapshot := _snapshot(asteroid_world_id)
	var asteroid_steel_depot := _entity_with_definition(asteroid_steel_snapshot, "grid_bulk_depot")
	_check(not asteroid_steel_depot.is_empty(), "J10 can address the completed Asteroid bulk depot through its versioned snapshot")
	if failures.size() > 0:
		return
	var asteroid_steel_depot_id := str(asteroid_steel_depot.get("id", ""))
	var asteroid_operating_before: Dictionary = asteroid_steel_snapshot.get("location_available_inventory", {})
	# J9 correctly consumes its original five-return reserve.  Restage exactly the
	# two later cobalt-return costs (cargo CP6/repair4), plus the two Earth-to-
	# Asteroid dispatch costs that carry them (CP6/repair4).  Both policies share
	# one fixed window, then are retired before the cobalt manifests publish.
	var asteroid_return_propellant_target := int(asteroid_operating_before.get("chemical_propellant", 0)) + 6
	var asteroid_return_repair_target := int(asteroid_operating_before.get("repair_material", 0)) + 4
	var earth_operating_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var earth_propellant_top_up := maxi(0, 12 - int(earth_operating_before.get("chemical_propellant", 0)))
	var earth_repair_top_up := maxi(0, 8 - int(earth_operating_before.get("repair_material", 0)))
	if earth_propellant_top_up > 0:
		_export_to_location("chemical_propellant", earth_propellant_top_up, "J10 exact two-dispatch Asteroid operating-propellant budget")
	if earth_repair_top_up > 0:
		_export_to_location("repair_material", earth_repair_top_up, "J10 exact two-dispatch Asteroid operating-maintenance budget")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
	game.clear_location_logistics_policy("asteroid_belt", "chemical_propellant")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "repair_material")
	game.clear_location_logistics_policy("asteroid_belt", "repair_material")
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "chemical_propellant", "DEMAND", 0, asteroid_return_propellant_target, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "repair_material", "DEMAND", 0, asteroid_return_repair_target, 100, 1)), "public Logistics publishes the exact J10 two-layer Asteroid operating manifest")
	if failures.size() > 0:
		return
	var asteroid_operating_events := _advance(360000.0, "J10 Earth-Asteroid cobalt-return operating staging")
	var asteroid_operating_after: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	var asteroid_propellant_staging_arrived := false
	var asteroid_repair_staging_arrived := false
	for operating_event_value in asteroid_operating_events:
		var operating_event := operating_event_value as Dictionary
		var operating_cargo := operating_event.get("cargo", {}) as Dictionary
		if str(operating_event.get("type", "")) != "ShipmentArrived" or str(operating_event.get("destination", "")) != "asteroid_belt":
			continue
		asteroid_propellant_staging_arrived = asteroid_propellant_staging_arrived or int(operating_cargo.get("chemical_propellant", 0)) == 6
		asteroid_repair_staging_arrived = asteroid_repair_staging_arrived or int(operating_cargo.get("repair_material", 0)) == 4
	_check(asteroid_propellant_staging_arrived and asteroid_repair_staging_arrived and int(asteroid_operating_after.get("chemical_propellant", 0)) >= asteroid_return_propellant_target and int(asteroid_operating_after.get("repair_material", 0)) >= asteroid_return_repair_target, "public Logistics settles the exact two cargo manifests and leaves the complete physical Asteroid reserve for two cobalt returns; available=%s events=%s" % [JSON.stringify(asteroid_operating_after), JSON.stringify(asteroid_operating_events)])
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
	game.clear_location_logistics_policy("asteroid_belt", "chemical_propellant")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "repair_material")
	game.clear_location_logistics_policy("asteroid_belt", "repair_material")
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy("asteroid_belt", "cobalt_ore")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore")
	var cobalt_return_events: Array = []
	for cobalt_chunk in [8, 4]:
		var earth_cobalt_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("cobalt_ore", 0))
		_export_to_location("cobalt_ore", cobalt_chunk, "J10 bounded Belt Cruiser electric-steel cobalt feed", asteroid_world_id, asteroid_steel_depot_id)
		_check(bool(game.set_location_logistics_policy("asteroid_belt", "cobalt_ore", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore", "DEMAND", 0, earth_cobalt_before + cobalt_chunk, 100, 1)), "public Logistics publishes one capacity-safe J10 cobalt stream")
		var cobalt_chunk_events := _advance(360000.0, "J10 bounded Asteroid-Earth cobalt logistics")
		cobalt_return_events.append_array(cobalt_chunk_events)
		var earth_cobalt_arrived := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("cobalt_ore", 0))
		_check(_events_have_type(cobalt_chunk_events, "ShipmentArrived") and earth_cobalt_arrived >= earth_cobalt_before + cobalt_chunk, "public Logistics returns one capacity-safe J10 cobalt batch to Earth custody; available=%s events=%s" % [JSON.stringify(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})), JSON.stringify(cobalt_chunk_events)])
		if failures.size() > 0:
			return
		_import_from_location("cobalt_ore", cobalt_chunk, STARTER_DEPOT_ID, "J10 capacity-safe cobalt Factory import")
		game.clear_location_logistics_policy("asteroid_belt", "cobalt_ore")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore")
	_check(_events_have_type(cobalt_return_events, "ShipmentArrived") and int(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}).get("cobalt_ore", 0)) >= 12, "Earth Factory holds exactly the public twelve-unit cobalt-ore feed required for six electric-steel cycles; inventory=%s" % JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})))
	if failures.size() > 0:
		return
	# The isolated J9 smelter was intentionally preserved rather than cleared; its
	# snapshot now proves an iron buffer fills all 48 input slots.  Construct one
	# clean public Arc Smelter from the actual Factory depot instead of discarding
	# that historical material or forcing cobalt into an occupied port.
	var retained_foundry := _entity(_snapshot(EARTH_WORLD_ID), "ENTITY-000013")
	_check(str(retained_foundry.get("definition_id", "")) == "grid_arc_smelter" and int(retained_foundry.get("inputs", {}).get("iron_ingot", 0)) >= 48, "J10 observes the retained full J9 Arc-Smelter iron buffer before choosing the physical clean-line recovery; foundry=%s" % JSON.stringify(retained_foundry))
	if failures.size() > 0:
		return
	var clean_foundry_order := _queue_and_fund("grid_arc_smelter", "grid_refine_cobalt", {"x":230, "y":140}, "J10 clean Belt Cruiser cobalt-and-steel Arc Smelter", false)
	if clean_foundry_order.is_empty() or failures.size() > 0:
		return
	var clean_foundry_construction_events := _advance(240000.0, "J10 clean Arc-Smelter construction")
	_check(_events_have_type(clean_foundry_construction_events, "FactoryConstructionCompleted"), "Factory physically completes the clean Arc Smelter without mutating the retained J9 buffer")
	if failures.size() > 0:
		return
	var cruiser_foundry_id := str(clean_foundry_order.get("entity_id", ""))
	var cruiser_foundry := _entity(_snapshot(EARTH_WORLD_ID), cruiser_foundry_id)
	_check(str(cruiser_foundry.get("definition_id", "")) == "grid_arc_smelter" and cruiser_foundry.get("inputs", {}).is_empty(), "J10 addresses the newly completed empty Arc Smelter through the versioned Factory snapshot; foundry=%s" % JSON.stringify(cruiser_foundry))
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_foundry_id, "")
	if failures.size() > 0:
		return
	# The starter component depot is deliberately at its physical limit after the
	# prior research and shipyard staging.  Expand BULK custody through a normal
	# construction order rather than discarding the clean smelter's cobalt/waste
	# output or treating a full target as a successful transfer.
	var cruiser_bulk_order := _queue_and_fund("grid_bulk_depot", "", {"x":230, "y":210}, "J10 Belt Cruiser cobalt-and-waste receiving Bulk Depot", false)
	if cruiser_bulk_order.is_empty() or failures.size() > 0:
		return
	var cruiser_bulk_construction_events := _advance(80000.0, "J10 Belt Cruiser Bulk Depot construction")
	_check(_events_have_type(cruiser_bulk_construction_events, "FactoryConstructionCompleted"), "Factory physically completes the new Bulk Depot that relieves the full starter target")
	if failures.size() > 0:
		return
	var cruiser_bulk_depot_id := str(cruiser_bulk_order.get("entity_id", ""))
	var cruiser_bulk_depot := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(str(cruiser_bulk_depot.get("definition_id", "")) == "grid_bulk_depot" and cruiser_bulk_depot.get("inventory", {}).is_empty(), "J10 addresses the newly completed empty canonical Bulk Depot through the Factory snapshot; depot=%s" % JSON.stringify(cruiser_bulk_depot))
	if failures.size() > 0:
		return
	var cruiser_cobalt_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_cobalt"})
	_check(bool(cruiser_cobalt_recipe.get("accepted", false)), "Factory protocol assigns the six-cycle J10 cobalt-refinement recipe")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "industrial_waste", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "cobalt_ingot", cruiser_foundry_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "industrial_waste", cruiser_foundry_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_foundry_id, "cobalt_ore")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "cobalt_ingot")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "industrial_waste")
	var cobalt_prestage_events := _advance(3000.0, "J10 exact cobalt-refinery input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", "")
	var cruiser_cobalt_events := _advance(90000.0, "J10 six-cycle cobalt-ingot refinement")
	var cruiser_cobalt_depot := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(cruiser_cobalt_events, "grid_refine_cobalt") and int(cruiser_cobalt_depot.get("inventory", {}).get("cobalt_ingot", 0)) >= 6 and int(cruiser_cobalt_depot.get("inventory", {}).get("industrial_waste", 0)) >= 6, "Earth Factory physically refines the twelve public cobalt ore into six ingots and preserves six waste units in new Bulk custody for the exact Cruiser steel batch; depot=%s stage_events=%d completed_cycles=%d" % [JSON.stringify(cruiser_cobalt_depot.get("inventory", {})), cobalt_prestage_events.size(), cruiser_cobalt_events.filter(func(event_value): return str((event_value as Dictionary).get("recipe_id", "")) == "grid_refine_cobalt").size()])
	if failures.size() > 0:
		return
	var cruiser_steel_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_steel_electric"})
	_check(bool(cruiser_steel_recipe.get("accepted", false)), "Factory protocol assigns the J10 six-cycle electric-steel recipe after Asteroid discovery")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "steel_composite", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_foundry_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ingot")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "steel_composite")
	var steel_prestage_events := _advance(3000.0, "J10 exact electric-steel input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", "")
	var cruiser_steel_events := _advance(60000.0, "J10 six-cycle electric steelmaking")
	var cruiser_steel_depot := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(cruiser_steel_events, "grid_refine_steel_electric") and int(cruiser_steel_depot.get("inventory", {}).get("steel_composite", 0)) >= 6, "Earth Factory completes the exact six public electric-steel cycles for the Belt Cruiser Shipyard BOM; depot=%s stage_events=%s" % [JSON.stringify(cruiser_steel_depot.get("inventory", {})), JSON.stringify(steel_prestage_events)])
	if failures.size() > 0:
		return
	_export_to_location("steel_composite", 6, "J10 complete Belt Cruiser steel-composite Shipyard BOM", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	var cruiser_design_nodes := [
		{"node_id":"hull", "kind":"hull", "definition_id":"belt_cruiser", "position":{"x":0.0, "y":0.0}},
		{"node_id":"weapon", "kind":"module", "definition_id":"light_autocannon", "position":{"x":100.0, "y":0.0}},
		{"node_id":"shield", "kind":"module", "definition_id":"civilian_shield", "position":{"x":100.0, "y":40.0}},
		{"node_id":"drive", "kind":"module", "definition_id":"advanced_drive", "position":{"x":100.0, "y":80.0}},
		{"node_id":"targeting", "kind":"module", "definition_id":"targeting_computer", "position":{"x":100.0, "y":120.0}},
		{"node_id":"core", "kind":"module", "definition_id":"civilian_reactor_core", "position":{"x":100.0, "y":160.0}}
	]
	var cruiser_design_connections := [
		{"module_node_id":"weapon", "socket_id":"socket_weapon_0"},
		{"module_node_id":"shield", "socket_id":"socket_shield_0"},
		{"module_node_id":"drive", "socket_id":"socket_drive_0"},
		{"module_node_id":"targeting", "socket_id":"socket_utility_0"},
		{"module_node_id":"core", "socket_id":"socket_core_0"}
	]
	var cruiser_design_validation: Dictionary = game.ship_design_validation("construct_belt_cruiser", cruiser_design_nodes, cruiser_design_connections)
	_check(bool(cruiser_design_validation.get("allowed", false)), "public ship-design validation accepts the complete canonical Belt Cruiser hull and starting-module graph; validation=%s" % JSON.stringify(cruiser_design_validation))
	if failures.size() > 0:
		return
	var cruiser_design_events_start := observed_events.size()
	_check(bool(game.save_ship_design("", "Runtime Belt Cruiser", "construct_belt_cruiser", cruiser_design_nodes, cruiser_design_connections)), "public Ship Design command saves the validated Belt Cruiser graph with an API-assigned identity")
	var cruiser_saved_design_event := _first_event(_events_after(cruiser_design_events_start), "ShipDesignSaved")
	var cruiser_design_id := str(cruiser_saved_design_event.get("design_id", ""))
	_check(not cruiser_design_id.is_empty() and str(cruiser_saved_design_event.get("plan_id", "")) == "construct_belt_cruiser", "Ship Design save publishes the exact Belt Cruiser design and plan identities; event=%s" % JSON.stringify(cruiser_saved_design_event))
	if failures.size() > 0:
		return
	var cruiser_engineering_summary: Dictionary = game.ship_design_engineering_summary("construct_belt_cruiser", cruiser_design_nodes, cruiser_design_connections)
	var cruiser_expected_costs: Dictionary = cruiser_engineering_summary.get("construction_costs", {}).duplicate(true)
	var cruiser_expected_modules: Array = cruiser_design_validation.get("modules", []).duplicate()
	var cruiser_queue_events_start := observed_events.size()
	_check(bool(game.enqueue_saved_ship_design(cruiser_design_id)), "public Shipyard command queues the saved Belt Cruiser design against its physical Earth Location manifest")
	var cruiser_queued_event := _first_event(_events_after(cruiser_queue_events_start), "ShipDesignQueued")
	_check(str(cruiser_queued_event.get("design_id", "")) == cruiser_design_id and str(cruiser_queued_event.get("plan_id", "")) == "construct_belt_cruiser" and int(cruiser_queued_event.get("quantity", 0)) == 1, "ShipDesignQueued identifies the exact saved Belt Cruiser design, plan, and one physical unit")
	var cruiser_queue_blockers: Array = game.active_blockers()
	var cruiser_scale_blocked := cruiser_queue_blockers.any(func(blocker_value):
		var blocker := blocker_value as Dictionary
		return str(blocker.get("domain", "")) == "shipyard" and str(blocker.get("code", "")) == "MISSING_SCALE_STAGE" and str(blocker.get("source_entity", {}).get("id", "")) == "construct_belt_cruiser"
	)
	_check(not cruiser_scale_blocked, "public blocker façade reports no missing Shipyard engineering scale after Factory-backed Starport II completion; blockers=%s" % JSON.stringify(cruiser_queue_blockers))
	if failures.size() > 0:
		return
	var cruiser_shipyard_events := _advance(60000.0, "J10 Belt Cruiser exact one-hundred-segment Shipyard construction")
	var cruiser_construction_event := _first_event(cruiser_shipyard_events, "ShipConstructionCompleted")
	var cruiser_build_cycles: Array = cruiser_shipyard_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "ShipbuildingCycleCompleted" and str(event.get("plan_id", "")) == "construct_belt_cruiser"
	)
	var cruiser_exact_cycle_sequence := cruiser_build_cycles.size() == 100
	for cycle_index in cruiser_build_cycles.size():
		if int((cruiser_build_cycles[cycle_index] as Dictionary).get("segments", 0)) != cycle_index + 1:
			cruiser_exact_cycle_sequence = false
			break
	_check(cruiser_exact_cycle_sequence and not cruiser_construction_event.is_empty() and str(cruiser_construction_event.get("plan_id", "")) == "construct_belt_cruiser" and int(cruiser_construction_event.get("segments", 0)) == 100, "Shipyard completes the physically funded Belt Cruiser through the exact one-hundred-cycle sequence")
	_check(str(cruiser_construction_event.get("design_id", "")) == cruiser_design_id and (cruiser_construction_event.get("module_ids", []) as Array) == cruiser_expected_modules and (cruiser_construction_event.get("consumed", {}) as Dictionary) == cruiser_expected_costs and bool(cruiser_construction_event.get("created", false)), "Ship construction publishes the exact Belt Cruiser saved design, resolved loadout, and fully debited raw BOM; event=%s expected=%s" % [JSON.stringify(cruiser_construction_event), JSON.stringify(cruiser_expected_costs)])
	var cruiser_candidates: Array = game.ship_design_refit_candidates(cruiser_design_id)
	_check(cruiser_candidates.size() == 1, "public design-refit candidate query exposes exactly one constructed Belt Cruiser instance")
	if cruiser_candidates.size() != 1 or failures.size() > 0:
		return
	belt_cruiser_ship_id = str(cruiser_candidates[0])
	_check(not pathfinder_formation_id.is_empty() and bool(game.set_ship_formation_assignment(belt_cruiser_ship_id, pathfinder_formation_id)), "public Fleet command assigns the constructed Belt Cruiser to the existing Pathfinder formation for the canonical armed-and-shielded route capability")
	if failures.size() > 0:
		return
	# The flagship gate requires a real Repair Dock at the Asteroid Factory, not a
	# global proxy at Earth.  Return one bounded raw-cobalt manifest to make the
	# exact four local-dock steel units, preserving the two-hop operating costs.
	for repair_dock_policy_item in ["chemical_propellant", "repair_material", "cobalt_ore", "steel_composite", "electronics"]:
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, repair_dock_policy_item)
		game.clear_location_logistics_policy("asteroid_belt", repair_dock_policy_item)
	# The Cruiser and its preceding Lunar manifests legitimately consumed the
	# early propellant buffer.  Reconfigure the existing powered Engineering
	# Works and manufacture the finite nine-unit Asteroid reserve instead of
	# assuming a historic Factory balance remains available.
	# This works retains a completely full historical iron buffer from the prior
	# Earth lines.  It cannot admit the emergency recipe's five electronics until
	# a real recipe consumes enough of that buffer.  Make the minimum six-cycle,
	# iron-only munitions batch into the new Bulk depot; do not clear a machine
	# buffer or fabricate a replacement inventory.
	var repair_dock_iron_recovery_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_manufacture_kinetic_munitions"})
	_check(bool(repair_dock_iron_recovery_recipe.get("accepted", false)), "Factory protocol assigns the physical iron-only recovery recipe before the Asteroid Repair Dock propellant run")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
	_clear_competing_cargo_outputs(cruiser_electronics_id, "kinetic_munitions", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "kinetic_munitions")
	var repair_dock_iron_recovery_events := _advance(50000.0, "J10 bounded historical Engineering Works iron-buffer recovery")
	var repair_dock_iron_recovery_snapshot := _snapshot(EARTH_WORLD_ID)
	var repair_dock_iron_recovery_works := _entity(repair_dock_iron_recovery_snapshot, cruiser_electronics_id)
	var repair_dock_iron_recovery_bulk := _entity(repair_dock_iron_recovery_snapshot, cruiser_bulk_depot_id)
	_check(_events_have_recipe(repair_dock_iron_recovery_events, "grid_manufacture_kinetic_munitions") and int(repair_dock_iron_recovery_works.get("inputs", {}).get("iron_ingot", 0)) <= 90 and int(repair_dock_iron_recovery_bulk.get("inventory", {}).get("kinetic_munitions", 0)) >= 120, "Engineering Works physically consumes six retained iron units into public Bulk custody before admitting five propellant electronics; works=%s bulk=%s" % [JSON.stringify(repair_dock_iron_recovery_works), JSON.stringify(repair_dock_iron_recovery_bulk.get("inventory", {}))])
	if failures.size() > 0:
		return
	_clear_competing_cargo_outputs(cruiser_electronics_id, "kinetic_munitions", "")
	var repair_dock_propellant_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_manufacture_emergency_propellant"})
	_check(bool(repair_dock_propellant_recipe.get("accepted", false)), "Factory protocol reconfigures the proven Engineering Works for the bounded Asteroid Repair Dock propellant reserve")
	# Keep the recovered buffer slots free for electronics: the retained ninety
	# iron already covers the five propellant cycles, so do not refill it first.
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "electronics", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(cruiser_electronics_id, "chemical_propellant", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "electronics")
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "chemical_propellant")
	# This shared Earth subgrid is intentionally power-limited by the already
	# operating production lines.  Give the physical recipe a fixed, bounded
	# window for exactly its five required cycles; do not synthesize or poll.
	var repair_dock_propellant_events := _advance(100000.0, "J10 bounded Asteroid Repair Dock propellant fabrication")
	var repair_dock_propellant_snapshot := _snapshot(EARTH_WORLD_ID)
	var repair_dock_propellant_depot := _entity(repair_dock_propellant_snapshot, cruiser_bulk_depot_id)
	var repair_dock_propellant_works := _entity(repair_dock_propellant_snapshot, cruiser_electronics_id)
	_check(_events_have_recipe(repair_dock_propellant_events, "grid_manufacture_emergency_propellant") and int(repair_dock_propellant_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 10, "Factory physically replenishes the exact Asteroid Repair Dock operating propellant reserve into its actual public Bulk custody; inventory=%s works=%s recipe_events=%s" % [JSON.stringify(repair_dock_propellant_depot.get("inventory", {})), JSON.stringify(repair_dock_propellant_works), JSON.stringify(repair_dock_propellant_events.filter(func(event: Dictionary) -> bool: return str(event.get("recipe_id", "")) == "grid_manufacture_emergency_propellant"))])
	if failures.size() > 0:
		return
	var repair_dock_asteroid_before: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	var repair_dock_cp_shortfall := maxi(0, 3 - int(repair_dock_asteroid_before.get("chemical_propellant", 0)))
	var repair_dock_maintenance_shortfall := maxi(0, 2 - int(repair_dock_asteroid_before.get("repair_material", 0)))
	var repair_dock_operating_shipments := (1 if repair_dock_cp_shortfall > 0 else 0) + (1 if repair_dock_maintenance_shortfall > 0 else 0)
	var repair_dock_earth_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var repair_dock_earth_cp_target := repair_dock_cp_shortfall + repair_dock_operating_shipments * 3
	var repair_dock_earth_maintenance_target := repair_dock_maintenance_shortfall + repair_dock_operating_shipments * 2
	var repair_dock_cp_export := maxi(0, repair_dock_earth_cp_target - int(repair_dock_earth_before.get("chemical_propellant", 0)))
	var repair_dock_maintenance_export := maxi(0, repair_dock_earth_maintenance_target - int(repair_dock_earth_before.get("repair_material", 0)))
	if repair_dock_cp_export > 0:
		_export_to_location("chemical_propellant", repair_dock_cp_export, "J10 one bounded Asteroid cobalt-return propellant reserve", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	if repair_dock_maintenance_export > 0:
		_export_to_location("repair_material", repair_dock_maintenance_export, "J10 one bounded Asteroid cobalt-return maintenance reserve")
	if repair_dock_cp_shortfall > 0:
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "chemical_propellant", "DEMAND", 0, int(repair_dock_asteroid_before.get("chemical_propellant", 0)) + repair_dock_cp_shortfall, 100, 1)), "public Logistics publishes the bounded Asteroid cobalt-return propellant reserve")
	if repair_dock_maintenance_shortfall > 0:
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "repair_material", "DEMAND", 0, int(repair_dock_asteroid_before.get("repair_material", 0)) + repair_dock_maintenance_shortfall, 100, 1)), "public Logistics publishes the bounded Asteroid cobalt-return maintenance reserve")
	var repair_dock_operating_events := _advance(360000.0, "J10 Asteroid cobalt-return operating-reserve logistics")
	var repair_dock_asteroid_operating: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	_check((repair_dock_cp_shortfall == 0 or _events_have_type(repair_dock_operating_events, "ShipmentArrived")) and int(repair_dock_asteroid_operating.get("chemical_propellant", 0)) >= 3 and int(repair_dock_asteroid_operating.get("repair_material", 0)) >= 2, "public Logistics stages the exact Asteroid source operating reserve before the one cobalt return; available=%s events=%s" % [JSON.stringify(repair_dock_asteroid_operating), JSON.stringify(repair_dock_operating_events)])
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
	game.clear_location_logistics_policy("asteroid_belt", "chemical_propellant")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "repair_material")
	game.clear_location_logistics_policy("asteroid_belt", "repair_material")
	var repair_dock_cobalt_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("cobalt_ore", 0))
	_export_to_location("cobalt_ore", 8, "J10 Asteroid Repair Dock steel cobalt feed", asteroid_world_id, asteroid_steel_depot_id)
	_check(bool(game.set_location_logistics_policy("asteroid_belt", "cobalt_ore", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore", "DEMAND", 0, repair_dock_cobalt_before + 8, 100, 1)), "public Logistics publishes the one bounded Repair Dock cobalt return")
	var repair_dock_cobalt_events := _advance(360000.0, "J10 bounded Asteroid-Earth Repair Dock cobalt logistics")
	_check(_events_have_type(repair_dock_cobalt_events, "ShipmentArrived") and int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("cobalt_ore", 0)) >= repair_dock_cobalt_before + 8, "public Logistics returns the exact eight cobalt ore needed for the Asteroid Repair Dock steel; available=%s events=%s" % [JSON.stringify(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})), JSON.stringify(repair_dock_cobalt_events)])
	if failures.size() > 0:
		return
	_import_from_location("cobalt_ore", 8, cruiser_bulk_depot_id, "J10 Repair Dock steel cobalt Factory feed")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore")
	game.clear_location_logistics_policy("asteroid_belt", "cobalt_ore")
	var repair_dock_cobalt_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_cobalt"})
	_check(bool(repair_dock_cobalt_recipe.get("accepted", false)), "Factory protocol reassigns the clean Arc Smelter to the bounded Repair Dock cobalt batch")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "industrial_waste", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ore")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "cobalt_ingot")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "industrial_waste")
	_advance(2000.0, "J10 bounded Repair Dock cobalt input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", "")
	var repair_dock_cobalt_refining_events := _advance(60000.0, "J10 four-cycle Repair Dock cobalt refinement")
	var repair_dock_bulk_after_cobalt := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(repair_dock_cobalt_refining_events, "grid_refine_cobalt") and int(repair_dock_bulk_after_cobalt.get("inventory", {}).get("cobalt_ingot", 0)) >= 4, "Factory physically refines the exact four cobalt ingots required for Repair Dock steel; depot=%s" % JSON.stringify(repair_dock_bulk_after_cobalt.get("inventory", {})))
	if failures.size() > 0:
		return
	var repair_dock_steel_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_steel_electric"})
	_check(bool(repair_dock_steel_recipe.get("accepted", false)), "Factory protocol selects the bounded Repair Dock electric-steel recipe")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "steel_composite", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_foundry_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ingot")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "steel_composite")
	_advance(2000.0, "J10 bounded Repair Dock steel input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", "")
	var repair_dock_steel_events := _advance(60000.0, "J10 four-cycle Repair Dock electric steelmaking")
	var repair_dock_bulk_after_steel := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(repair_dock_steel_events, "grid_refine_steel_electric") and int(repair_dock_bulk_after_steel.get("inventory", {}).get("steel_composite", 0)) >= 4, "Factory physically completes the exact four Repair Dock steel composites; depot=%s" % JSON.stringify(repair_dock_bulk_after_steel.get("inventory", {})))
	if failures.size() > 0:
		return
	_export_to_location("steel_composite", 4, "J10 Asteroid Repair Dock steel construction manifest", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	# Subsequent bounded logistics elapsed the active propellant recipe long
	# enough to consume its retained iron, leaving a real 39-slot Works buffer.
	# Retire that obsolete electronics input and use only physical iron/copper
	# CARGO to make four new electronics into Bulk; three feed the exact dock BOM.
	var repair_dock_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_electronics"})
	_check(bool(repair_dock_electronics_recipe.get("accepted", false)), "Factory protocol reconfigures the physically available Works for the bounded Repair Dock electronics batch")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "electronics", "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", "")
	_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", cruiser_bulk_depot_id)
	# Stage copper then iron through their single ports and immediately retire
	# each input link.  This prevents either unlimited source from occupying the
	# remaining buffer before its paired recipe input can arrive.
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "copper_ingot")
	_advance(2000.0, "J10 bounded Repair Dock electronics copper input staging")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", "")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "iron_ingot")
	_advance(2000.0, "J10 bounded Repair Dock electronics iron input staging")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "electronics")
	var repair_dock_electronics_events := _advance(30000.0, "J10 bounded Repair Dock electronics fabrication")
	var repair_dock_electronics_depot := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var repair_dock_electronics_cycles := repair_dock_electronics_events.filter(func(event: Dictionary) -> bool: return str(event.get("recipe_id", "")) == "grid_fabricate_electronics")
	_check(repair_dock_electronics_cycles.size() >= 2 and int(repair_dock_electronics_depot.get("inventory", {}).get("electronics", 0)) >= 4, "Factory physically completes two electronics cycles and retains the bounded four-electronics Repair Dock fabrication batch in public Bulk custody; inventory=%s events=%s" % [JSON.stringify(repair_dock_electronics_depot.get("inventory", {})), JSON.stringify(repair_dock_electronics_cycles)])
	if failures.size() > 0:
		return
	_export_to_location("electronics", 3, "J10 Asteroid Repair Dock electronics construction manifest", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	# The two construction shipments each pay a physical general-cargo
	# maintenance cost.  Reconfigure the same Works with its retained iron/copper
	# input to make the two missing repair units into Bulk rather than assuming
	# the historic starter balance can cover both dispatches.
	var repair_dock_maintenance_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_repair_material"})
	_check(bool(repair_dock_maintenance_recipe.get("accepted", false)), "Factory protocol reconfigures the staged Engineering Works for the two-unit Repair Dock delivery maintenance batch")
	_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", "")
	_clear_competing_cargo_outputs(cruiser_electronics_id, "repair_material", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "repair_material")
	var repair_dock_maintenance_events := _advance(30000.0, "J10 bounded Repair Dock delivery maintenance fabrication")
	var repair_dock_maintenance_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(repair_dock_maintenance_events.filter(func(event: Dictionary) -> bool: return str(event.get("recipe_id", "")) == "grid_fabricate_repair_material").size() >= 2 and int(repair_dock_maintenance_bulk.get("inventory", {}).get("repair_material", 0)) >= 2, "Factory physically completes the two-unit Bulk repair-material supplement for the two Repair Dock delivery dispatches; inventory=%s" % JSON.stringify(repair_dock_maintenance_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	var repair_dock_earth_operating_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var repair_dock_earth_cp_dispatch_export := maxi(0, 6 - int(repair_dock_earth_operating_before.get("chemical_propellant", 0)))
	var repair_dock_earth_maintenance_dispatch_export := maxi(0, 4 - int(repair_dock_earth_operating_before.get("repair_material", 0)))
	if repair_dock_earth_cp_dispatch_export > 0:
		_export_to_location("chemical_propellant", repair_dock_earth_cp_dispatch_export, "J10 two-item Repair Dock delivery propellant costs", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	if repair_dock_earth_maintenance_dispatch_export > 0:
		var repair_dock_starter_repair := int(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}).get("repair_material", 0))
		var repair_dock_bulk_repair := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("repair_material", 0))
		_check(repair_dock_starter_repair + repair_dock_bulk_repair >= repair_dock_earth_maintenance_dispatch_export, "Earth Factory retains the complete mixed-custody Repair Dock delivery maintenance manifest; starter=%d bulk=%d required=%d" % [repair_dock_starter_repair, repair_dock_bulk_repair, repair_dock_earth_maintenance_dispatch_export])
		if failures.size() > 0:
			return
		var repair_dock_repair_from_starter := mini(repair_dock_starter_repair, repair_dock_earth_maintenance_dispatch_export)
		var repair_dock_repair_from_bulk := repair_dock_earth_maintenance_dispatch_export - repair_dock_repair_from_starter
		if repair_dock_repair_from_starter > 0:
			_export_to_location("repair_material", repair_dock_repair_from_starter, "J10 starter share of two-item Repair Dock delivery maintenance costs")
		if repair_dock_repair_from_bulk > 0:
			_export_to_location("repair_material", repair_dock_repair_from_bulk, "J10 Bulk share of two-item Repair Dock delivery maintenance costs", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "steel_composite", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "steel_composite", "DEMAND", 0, 4, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "electronics", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "electronics", "DEMAND", 0, 3, 100, 1)), "public Logistics publishes the exact steel/electronics Asteroid Repair Dock construction manifest")
	var repair_dock_delivery_events := _advance(360000.0, "J10 Asteroid Repair Dock construction logistics")
	var repair_dock_asteroid_delivery: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	_check(_events_have_type(repair_dock_delivery_events, "ShipmentArrived") and int(repair_dock_asteroid_delivery.get("steel_composite", 0)) >= 4 and int(repair_dock_asteroid_delivery.get("electronics", 0)) >= 3, "public Logistics delivers the exact physical Asteroid Repair Dock construction manifest; available=%s events=%s" % [JSON.stringify(repair_dock_asteroid_delivery), JSON.stringify(repair_dock_delivery_events)])
	if failures.size() > 0:
		return
	for repair_dock_delivery_item in ["steel_composite", "electronics"]:
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, repair_dock_delivery_item)
		game.clear_location_logistics_policy("asteroid_belt", repair_dock_delivery_item)
	# This manifest is deliberately in same-location custody, not Asteroid
	# Factory storage: avoid an expected empty-storage FUND attempt and use the
	# already asserted FUND_CONSTRUCTION_FROM_LOCATION path only.
	var asteroid_repair_dock := _queue_and_fund("grid_repair_dock", "", {"x":100, "y":0}, "J10 Asteroid-local Repair Dock", true, asteroid_world_id, "")
	if asteroid_repair_dock.is_empty() or failures.size() > 0:
		return
	var asteroid_repair_dock_events := _advance(180000.0, "J10 Asteroid-local Repair Dock construction")
	_check(_events_have_type(asteroid_repair_dock_events, "FactoryConstructionCompleted"), "remote Factory physically completes the canonical Asteroid-local Repair Dock")
	var asteroid_repair_dock_id := str(asteroid_repair_dock.get("entity_id", ""))
	var asteroid_repair_dock_snapshot := _entity(_snapshot(asteroid_world_id), asteroid_repair_dock_id)
	_check(str(asteroid_repair_dock_snapshot.get("definition_id", "")) == "grid_repair_dock", "versioned Asteroid Factory snapshot identifies the completed local Repair Dock; dock=%s" % JSON.stringify(asteroid_repair_dock_snapshot))
	if failures.size() > 0:
		return
	# The original Asteroid solar field is fully allocated to the two mines.
	# Retire those explicit POWER links after their bounded cobalt deliveries,
	# then power the actual remote dock rather than relying on a global facility
	# flag or relaxing the local service requirement.
	for asteroid_power_link_value in _snapshot(asteroid_world_id).get("links", []):
		var asteroid_power_link := asteroid_power_link_value as Dictionary
		if str(asteroid_power_link.get("kind", "")) == "POWER" and str(asteroid_power_link.get("source_id", "")) == "ENTITY-000002" and str(asteroid_power_link.get("target_id", "")) != asteroid_repair_dock_id:
			var asteroid_power_release := _factory_command("REMOVE_LINK", {"link_id":str(asteroid_power_link.get("id", ""))}, asteroid_world_id)
			_check(bool(asteroid_power_release.get("accepted", false)), "Factory protocol releases a completed Asteroid mine POWER link for the local Repair Dock")
	if failures.size() > 0:
		return
	_ensure_connection("POWER", "ENTITY-000002", asteroid_repair_dock_id, "", asteroid_world_id)
	_advance(2000.0, "J10 Asteroid Repair Dock power activation")
	asteroid_repair_dock_snapshot = _entity(_snapshot(asteroid_world_id), asteroid_repair_dock_id)
	_check(float(asteroid_repair_dock_snapshot.get("power_factor", 0.0)) > 0.0, "versioned Asteroid Factory snapshot proves the remote Repair Dock is physically powered; dock=%s" % JSON.stringify(asteroid_repair_dock_snapshot))
	if failures.size() > 0:
		return
	# Do not rely on a historic fleet inventory after the Asteroid survey and
	# remote construction deliveries.  Manufacture the route's repair supplies
	# through the existing powered Engineering Works, retaining the material in
	# the explicit large Earth depot before exporting the exact fleet manifest.
	# This deliberately stages a little more than the final twenty units: the
	# public fleet command, rather than a hidden inventory write, makes the
	# exact bounded transfer into the named two-ship formation.
	var resupply_bulk_before := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var resupply_repair_before := int(resupply_bulk_before.get("inventory", {}).get("repair_material", 0))
	var repair_material_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_repair_material"})
	_check(bool(repair_material_recipe.get("accepted", false)), "Factory protocol selects the physical repair-material recipe for Belt flagship fleet support")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(cruiser_electronics_id, "repair_material", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "iron_ingot")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "repair_material")
	_advance(2000.0, "J10 Belt flagship repair-material input staging")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", "")
	var repair_material_events := _advance(60000.0, "J10 Belt flagship repair-material fabrication")
	var resupply_bulk_after_material := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(repair_material_events, "grid_fabricate_repair_material") and int(resupply_bulk_after_material.get("inventory", {}).get("repair_material", 0)) >= resupply_repair_before + 4, "bounded Engineering Works cycles physically add at least four repair-material units to the explicit fleet-support depot; before=%d after=%s" % [resupply_repair_before, JSON.stringify(resupply_bulk_after_material.get("inventory", {}))])
	if failures.size() > 0:
		return
	var repair_supply_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_manufacture_repair_supplies"})
	_check(bool(repair_supply_recipe.get("accepted", false)), "Factory protocol converts the running Engineering Works to the canonical repair-supplies recipe")
	_clear_competing_cargo_outputs(cruiser_electronics_id, "repair_material", "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "repair_material", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_electronics_id, "repair_supplies", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_electronics_id, "repair_material")
	_advance(2000.0, "J10 Belt flagship repair-supplies input staging")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "repair_material", "")
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "repair_supplies")
	var repair_supply_events := _advance(50000.0, "J10 Belt flagship repair-supplies fabrication")
	var resupply_bulk_after_supplies := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(repair_supply_events, "grid_manufacture_repair_supplies") and int(resupply_bulk_after_supplies.get("inventory", {}).get("repair_supplies", 0)) >= 20, "bounded Engineering Works cycles retain the twenty physical repair supplies required for the Belt flagship formation; depot=%s" % JSON.stringify(resupply_bulk_after_supplies.get("inventory", {})))
	_check(int(resupply_bulk_after_supplies.get("inventory", {}).get("kinetic_munitions", 0)) >= 120, "the explicit Earth bulk depot retains the earlier bounded kinetic-munitions batch for the Belt flagship formation; depot=%s" % JSON.stringify(resupply_bulk_after_supplies.get("inventory", {})))
	if failures.size() > 0:
		return
	_export_to_location("repair_supplies", 20, "J10 exact Belt flagship repair-supplies fleet manifest", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	_export_to_location("kinetic_munitions", 120, "J10 exact Belt flagship kinetic-munitions fleet manifest", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	if failures.size() > 0:
		return
	var resupply_events_start := observed_events.size()
	_check(bool(game.set_fleet_supply_plan("kinetic_munitions", 120, pathfinder_formation_id)) and bool(game.set_fleet_supply_plan("repair_supplies", 20, pathfinder_formation_id)), "public Fleet commands publish the exact Belt flagship kinetic and repair-supply targets for the Pathfinder-Cruiser formation")
	_check(bool(game.auto_resupply_fleet(pathfinder_formation_id, [pathfinder_ship_id, belt_cruiser_ship_id])), "public Fleet command transfers the published physical Belt flagship supplies into the named Pathfinder-Cruiser formation")
	var belt_resupply_event := _first_event(_events_after(resupply_events_start), "FleetResupplied")
	var belt_resupply_moved: Dictionary = belt_resupply_event.get("moved", {})
	_check(str(belt_resupply_event.get("fleet_id", "")) == pathfinder_formation_id and belt_resupply_event.get("ship_ids", []) == [pathfinder_ship_id, belt_cruiser_ship_id] and int(belt_resupply_moved.get("repair_supplies", 0)) == 20 and int(belt_resupply_moved.get("kinetic_munitions", 0)) == 119, "FleetResupplied records the exact formation, 20 repair supplies, and the 119-unit kinetic top-up after J6's one retained Pathfinder round; event=%s" % JSON.stringify(belt_resupply_event))
	if failures.size() > 0:
		return
	var belt_route_events_start := observed_events.size()
	var belt_reward_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	_check(bool(game.start_expedition_route("belt_flagship_route", [pathfinder_ship_id, belt_cruiser_ship_id], pathfinder_formation_id)), "public Expedition command starts the canonical Belt flagship route with exactly the Pathfinder and constructed Belt Cruiser")
	var belt_route_events := _advance(120000.0, "J10 Belt flagship route")
	var belt_route_completions: Array = belt_route_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "ExpeditionRouteCompleted" and str(event.get("route_id", "")) == "belt_flagship_route"
	)
	_check(belt_route_completions.size() == 1 and _events_have_type(_events_after(belt_route_events_start), "ExpeditionRouteStarted"), "the public Expedition runtime completes exactly the canonical Belt flagship route through its route identity")
	var belt_boss_completed := belt_route_events.any(func(event_value):
		var belt_event := event_value as Dictionary
		return str(belt_event.get("type", "")) == "ExpeditionNodeCompleted" and str(belt_event.get("route_id", "")) == "belt_flagship_route" and int(belt_event.get("node_index", -1)) == 3
	)
	var belt_boss_combat := belt_route_events.any(func(event_value):
		var belt_event := event_value as Dictionary
		return str(belt_event.get("type", "")) == "CombatStarted" and str(belt_event.get("route_id", "")) == "belt_flagship_route" and str(belt_event.get("enemy_id", "")) == "belt_flagship" and bool(belt_event.get("boss", false))
	)
	var belt_boss_defeated := belt_route_events.any(func(event_value):
		var belt_event := event_value as Dictionary
		return str(belt_event.get("type", "")) == "EnemyDefeated" and str(belt_event.get("enemy_id", "")) == "belt_flagship" and bool(belt_event.get("boss", false))
	)
	_check(belt_boss_completed and belt_boss_combat and belt_boss_defeated, "raw route events retain the exact Belt flagship boss combat, defeat, and node identities without observed-event de-duplication")
	var belt_rewards: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(belt_rewards.get("pirate_cipher", 0)) == int(belt_reward_before.get("pirate_cipher", 0)) + 3 and int(belt_rewards.get("blueprint_fragment", 0)) == int(belt_reward_before.get("blueprint_fragment", 0)) + 3, "Belt flagship completion deposits exactly its canonical pirate-cipher and blueprint-fragment x3 rewards in public Earth custody; before=%s available=%s" % [JSON.stringify(belt_reward_before), JSON.stringify(belt_rewards)])
	if failures.size() > 0:
		return
	# Even a no-damage victory receives the same bounded post-route recovery
	# window.  The powered local Repair Dock remains proven above; the succeeding
	# public Jovian launch is the observable deployability proof in the valid
	# no-repair-event case.
	var belt_recovery_events := _advance(120000.0, "J10 Belt flagship formation repair recovery")
	_check(not belt_recovery_events.is_empty() or float(_entity(_snapshot(asteroid_world_id), asteroid_repair_dock_id).get("power_factor", 0.0)) > 0.0, "the bounded no-damage post-Belt recovery window retains the proven powered local Repair Dock")
	if failures.size() > 0:
		return
	var jovian_route_events_start := observed_events.size()
	var jovian_helium_before := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("helium_3", 0))
	_check(bool(game.start_expedition_route("jovian_route", [pathfinder_ship_id, belt_cruiser_ship_id], pathfinder_formation_id)), "public Expedition command starts the canonical Jovian guardian route with the repaired Pathfinder-Cruiser formation")
	var jovian_route_events := _advance(120000.0, "J10 Jovian guardian route")
	var jovian_event_slice := _events_after(jovian_route_events_start)
	var jovian_combat_started := jovian_route_events.any(func(event_value):
		var jovian_event := event_value as Dictionary
		return str(jovian_event.get("type", "")) == "CombatStarted" and str(jovian_event.get("route_id", "")) == "jovian_route" and str(jovian_event.get("enemy_id", "")) == "jovian_guardian" and bool(jovian_event.get("boss", false))
	)
	var jovian_guardian_defeated := jovian_route_events.any(func(event_value):
		var jovian_event := event_value as Dictionary
		return str(jovian_event.get("type", "")) == "EnemyDefeated" and str(jovian_event.get("enemy_id", "")) == "jovian_guardian" and bool(jovian_event.get("boss", false))
	)
	# The terminal CHECKPOINT completes the route directly, so it produces the
	# terminal RouteCompleted event rather than a duplicate NodeCompleted record.
	_check(_events_have_type(jovian_event_slice, "ExpeditionRouteStarted") and _ordered_types(["ExpeditionNodeCompleted", "ExpeditionNodeCompleted", "CombatStarted", "EnemyDefeated", "ExpeditionNodeCompleted", "ExpeditionRouteCompleted"], jovian_route_events) and jovian_combat_started and jovian_guardian_defeated, "raw Jovian route events preserve travel, storm, exact guardian boss combat, terminal checkpoint, and completion causality without observed-event node de-duplication")
	var jovian_rewards: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(jovian_route_events.any(func(event_value):
		var jovian_event := event_value as Dictionary
		return str(jovian_event.get("type", "")) == "ExpeditionRouteCompleted" and str(jovian_event.get("route_id", "")) == "jovian_route"
	) and int(jovian_rewards.get("helium_3", 0)) == jovian_helium_before + 6, "Jovian guardian completion deposits exactly its canonical six-unit helium-3 reward in public Earth custody; before=%d available=%s" % [jovian_helium_before, JSON.stringify(jovian_rewards)])
	if failures.size() > 0:
		return
	# The Jovian reward is intentionally not the whole helium economy.  First
	# establish the renewable Lunar KREEP chain with an explicit FLUID storage
	# endpoint, so later Energy Array, antimatter research, and capital-ship costs
	# can consume distinct physical helium custody.
	var lunar_helium_snapshot := _snapshot(lunar_world_id)
	var lunar_helium_field := _resource_field(lunar_helium_snapshot, "helium_3")
	var lunar_helium_depot := _entity_with_definition(lunar_helium_snapshot, "grid_bulk_depot")
	_check(not lunar_helium_field.is_empty() and not lunar_helium_depot.is_empty(), "Lunar KREEP snapshot exposes the surveyed helium-3 field and physical bulk depot for renewable J10 extraction")
	if failures.size() > 0:
		return
	# Reconfigure the already-powered Earth Works through public cargo links to
	# make the seven electronics needed by the paired cryogenic extractor and
	# fluid-tank construction manifests.  Copper waste remains in the real bulk
	# store, rather than being discarded to clear this production line.
	var lunar_support_electronics := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_electronics"})
	_check(bool(lunar_support_electronics.get("accepted", false)), "Factory protocol selects renewable electronics for the Lunar cryogenic-support manifest")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_copper_id, "copper_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_copper_id, "industrial_waste", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_copper_id, cruiser_bulk_depot_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_copper_id, cruiser_bulk_depot_id, "industrial_waste")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "electronics")
	var lunar_support_electronics_events := _advance(60000.0, "J10 Lunar cryogenic-support electronics fabrication")
	var lunar_support_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(lunar_support_electronics_events, "grid_fabricate_electronics") and int(lunar_support_bulk.get("inventory", {}).get("electronics", 0)) >= 7, "Earth Factory physically stages the seven-electronics Lunar extractor-and-tank manifest in its explicit bulk depot; depot=%s" % JSON.stringify(lunar_support_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	# Manufacture the four route-maintenance units that the two Earth-Lunar
	# component shipments actually consume at the current public maintenance
	# profile.  This does not treat historical O&M inventory as a free grant.
	var lunar_support_repair_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_repair_material"})
	_check(bool(lunar_support_repair_recipe.get("accepted", false)), "Factory protocol selects physical repair-material fabrication for Lunar support freight")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_electronics_id, "repair_material", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "repair_material")
	_advance(2000.0, "J10 Lunar support repair-material input staging")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", "")
	var lunar_support_repair_events := _advance(60000.0, "J10 Lunar support repair-material fabrication")
	lunar_support_bulk = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(lunar_support_repair_events, "grid_fabricate_repair_material") and int(lunar_support_bulk.get("inventory", {}).get("repair_material", 0)) >= 4, "Earth Factory physically produces the four maintenance units for the bounded two-manifest Lunar support freight; depot=%s" % JSON.stringify(lunar_support_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	var earth_support_starter := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(int(earth_support_starter.get("inventory", {}).get("industrial_machine_tools", 0)) >= 2 and int(lunar_support_bulk.get("inventory", {}).get("chemical_propellant", 0)) >= 4, "Earth Factory retains the physical industrial tools and two general-cargo dispatches' propellant for the Lunar cryogenic support manifest; starter=%s bulk=%s" % [JSON.stringify(earth_support_starter.get("inventory", {})), JSON.stringify(lunar_support_bulk.get("inventory", {}))])
	if failures.size() > 0:
		return
	for support_location_id in [EARTH_LOCATION_ID, "lunar_space", "asteroid_belt"]:
		game.clear_location_logistics_policy(support_location_id, "chemical_propellant")
		game.clear_location_logistics_policy(support_location_id, "repair_material")
	for support_item in ["electronics", "industrial_machine_tools"]:
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, support_item)
		game.clear_location_logistics_policy("lunar_space", support_item)
	_export_to_location("electronics", 7, "J10 Lunar cryogenic extractor and FLUID tank electronics manifest", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	_export_to_location("industrial_machine_tools", 2, "J10 Lunar cryogenic extractor industrial-tools manifest")
	_export_to_location("chemical_propellant", 4, "J10 Lunar cryogenic two-manifest dispatch propellant", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	_export_to_location("repair_material", 4, "J10 Lunar cryogenic two-manifest dispatch maintenance", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	var lunar_component_before: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	var lunar_electronics_target := int(lunar_component_before.get("electronics", 0)) + 7
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "electronics", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "electronics", "DEMAND", 0, lunar_electronics_target, 100, 1)), "public Logistics publishes the first capacity-safe electronics portion of the finite extractor-and-FLUID-tank manifest")
	var lunar_cryo_electronics_freight_events := _advance(120000.0, "J10 Lunar cryogenic electronics logistics")
	var lunar_component_after: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(_events_have_type(lunar_cryo_electronics_freight_events, "ShipmentArrived") and int(lunar_component_after.get("electronics", 0)) >= lunar_electronics_target, "public Logistics delivers the bounded electronics portion before finite COMPONENT staging would reject the tools; available=%s events=%s" % [JSON.stringify(lunar_component_after), JSON.stringify(lunar_cryo_electronics_freight_events)])
	if failures.size() > 0:
		return
	var lunar_helium_depot_id := str(lunar_helium_depot.get("id", ""))
	# Fund the electronic share now.  The IMT share remains physically at Earth
	# until this exact construction reservation releases Lunar COMPONENT capacity.
	var lunar_cryo_extractor := _queue_and_fund("grid_cryogenic_extractor", "", lunar_helium_field.get("footprint", {}).get("origin", {}), "J10 Lunar KREEP cryogenic helium extractor", true, lunar_world_id, "")
	if lunar_cryo_extractor.is_empty() or failures.size() > 0:
		return
	# The extractor has now reserved three electronics, but its remaining seven
	# components still leave no room for the two high-density tool units.  Reserve
	# the tank's four electronics and its local titanium share before dispatching
	# those tools; each transfer remains an auditable public custody operation.
	var lunar_tank_funding_start := observed_events.size()
	var lunar_fluid_tank := _queue_and_fund("grid_fluid_tank", "", {"x":220, "y":100}, "J10 Lunar helium FLUID custody tank", true, lunar_world_id, lunar_helium_depot_id)
	var lunar_tank_titanium_funded := _events_after(lunar_tank_funding_start).any(func(event_value):
		var tank_funding_event := event_value as Dictionary
		return str(tank_funding_event.get("type", "")) == "FactoryConstructionFunded" and str(tank_funding_event.get("storage_id", "")) == lunar_helium_depot_id and int((tank_funding_event.get("moved", {}) as Dictionary).get("titanium_alloy", 0)) == 4
	)
	var lunar_tank_electronics_funded := _events_after(lunar_tank_funding_start).any(func(event_value):
		var tank_funding_event := event_value as Dictionary
		return str(tank_funding_event.get("type", "")) == "FactoryConstructionFunded" and str(tank_funding_event.get("location_id", "")) == "lunar_space" and int((tank_funding_event.get("moved", {}) as Dictionary).get("electronics", 0)) == 4
	)
	_check(lunar_tank_titanium_funded and lunar_tank_electronics_funded, "the Lunar FLUID tank is auditable mixed custody: Factory titanium alloy four plus same-location electronics four before construction")
	if lunar_fluid_tank.is_empty() or failures.size() > 0:
		return
	# Component staging is finite: the last three electronics are not needed by
	# either funded order, so explicitly move them into the observed Lunar Factory
	# depot before the two high-density tools arrive.
	_import_from_location("electronics", 3, lunar_helium_depot_id, "release finite Lunar COMPONENT staging before deferred cryogenic tools", lunar_world_id)
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "electronics")
	game.clear_location_logistics_policy("lunar_space", "electronics")
	lunar_component_after = _snapshot(lunar_world_id).get("location_available_inventory", {})
	var lunar_tools_target := int(lunar_component_after.get("industrial_machine_tools", 0)) + 2
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "industrial_machine_tools", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "industrial_machine_tools", "DEMAND", 0, lunar_tools_target, 100, 1)), "public Logistics publishes the deferred two-tool extractor portion only after the reserved electronics free finite Lunar component staging")
	var lunar_tools_freight_events := _advance(120000.0, "J10 Lunar cryogenic tools logistics")
	lunar_component_after = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(_events_have_type(lunar_tools_freight_events, "ShipmentArrived") and int(lunar_component_after.get("industrial_machine_tools", 0)) >= lunar_tools_target, "public Logistics delivers the deferred two-tool extractor portion after the electronic reservation releases capacity; lunar_available=%s earth_available=%s earth_blockers=%s lunar_blockers=%s" % [JSON.stringify(lunar_component_after), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})), JSON.stringify(game.active_blockers(EARTH_LOCATION_ID)), JSON.stringify(game.active_blockers("lunar_space"))])
	if failures.size() > 0:
		return
	var lunar_cryo_tools_funding := _factory_command("FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":str(lunar_cryo_extractor.get("order_id", ""))}, lunar_world_id)
	_check(bool(lunar_cryo_tools_funding.get("accepted", false)) and bool(lunar_cryo_tools_funding.get("result", {}).get("fully_funded", false)) and int(lunar_cryo_tools_funding.get("result", {}).get("moved", {}).get("industrial_machine_tools", 0)) == 2, "the second public same-location funding intent stages the deferred two tools and fully funds the Lunar cryogenic extractor")
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "industrial_machine_tools")
	game.clear_location_logistics_policy("lunar_space", "industrial_machine_tools")
	var lunar_cryogenic_construction_events := _advance(180000.0, "J10 Lunar cryogenic extractor and FLUID tank construction")
	var lunar_cryo_id := str(lunar_cryo_extractor.get("entity_id", ""))
	var lunar_tank_id := str(lunar_fluid_tank.get("entity_id", ""))
	var lunar_cryogenic_snapshot := _snapshot(lunar_world_id)
	_check(_events_have_type(lunar_cryogenic_construction_events, "FactoryConstructionCompleted") and str(_entity(lunar_cryogenic_snapshot, lunar_cryo_id).get("definition_id", "")) == "grid_cryogenic_extractor" and str(_entity(lunar_cryogenic_snapshot, lunar_tank_id).get("definition_id", "")) == "grid_fluid_tank", "Factory completes the canonical Lunar helium extractor and explicit FLUID-class custody tank through mixed Factory/Location funding")
	if failures.size() > 0:
		return
	for lunar_solar_value in _entities_with_definition(lunar_cryogenic_snapshot, "grid_solar_array"):
		_ensure_connection("POWER", str((lunar_solar_value as Dictionary).get("id", "")), lunar_cryo_id, "", lunar_world_id)
	_clear_competing_cargo_outputs(lunar_cryo_id, "helium_3", lunar_tank_id, lunar_world_id)
	_ensure_connection("CARGO", lunar_cryo_id, lunar_tank_id, "helium_3", lunar_world_id)
	var lunar_helium_events := _advance(60000.0, "J10 renewable Lunar helium-3 extraction")
	var lunar_tank_runtime := _entity(_snapshot(lunar_world_id), lunar_tank_id)
	_check(lunar_helium_events.any(func(event_value):
		var helium_event := event_value as Dictionary
		return str(helium_event.get("type", "")) == "FactoryResourceExtracted" and str(helium_event.get("world_id", "")) == lunar_world_id and str(helium_event.get("entity_id", "")) == lunar_cryo_id and str(helium_event.get("resource_id", "")) == "helium_3"
	) and int(lunar_tank_runtime.get("inventory", {}).get("helium_3", 0)) >= 2, "the powered Lunar cryogenic extractor physically deposits renewable helium-3 into the exact FLUID tank; tank=%s" % JSON.stringify(lunar_tank_runtime))
	if failures.size() > 0:
		return
	_export_to_location("helium_3", 2, "J10 exact renewable helium export from the Lunar FLUID tank", lunar_world_id, lunar_tank_id)
	var lunar_helium_location: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(int(lunar_helium_location.get("helium_3", 0)) >= 2, "Factory export proves the renewable helium leaves the exact canonical FLUID tank through public same-location custody; available=%s" % JSON.stringify(lunar_helium_location))
	if failures.size() > 0:
		return

	# Start the five-stage Jovian Operations program from a new, explicit
	# Factory-backed electronics output.  This preserves the one-time Jovian
	# guardian helium reward for the later Energy Array rather than treating it
	# as a generic research currency.
	var jovian_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_electronics"})
	_check(bool(jovian_electronics_recipe.get("accepted", false)), "Factory protocol selects renewable electronics for Jovian Operations theory")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "electronics")
	var jovian_electronics_events := _advance(48000.0, "J10 Jovian Operations theory electronics fabrication")
	var jovian_electronics_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(jovian_electronics_events, "grid_fabricate_electronics") and int(jovian_electronics_bulk.get("inventory", {}).get("electronics", 0)) >= 4, "Earth Factory physically stages the Jovian Operations theory component plus a bounded next-stage electronic reserve; bulk=%s" % JSON.stringify(jovian_electronics_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	var jovian_research_complex := _entity_with_definition(_snapshot(EARTH_WORLD_ID), "grid_research_complex")
	var jovian_research_power := _entity_with_definition(_snapshot(EARTH_WORLD_ID), "grid_power_substation_ii")
	_check(not jovian_research_complex.is_empty() and not jovian_research_power.is_empty(), "the public Factory snapshot retains a Research Complex and Grid Expansion II provider for the Jovian Operations capacity requirement")
	if failures.size() > 0:
		return
	var jovian_research_complex_id := str(jovian_research_complex.get("id", ""))
	var jovian_research_power_id := str(jovian_research_power.get("id", ""))
	_isolate_power_for(jovian_research_complex_id, jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, jovian_research_complex_id, "")
	var jovian_research_powered := _entity(_snapshot(EARTH_WORLD_ID), jovian_research_complex_id)
	_check(float(jovian_research_powered.get("power_factor", 0.0)) >= 1.0, "public Factory POWER topology gives the active Jovian Operations Research Complex its full one-capacity throughput; complex=%s" % JSON.stringify(jovian_research_powered))
	if failures.size() > 0:
		return
	_export_to_location("electronics", 1, "J10 Jovian Operations theory", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	_check(bool(game.start_research_project("research_jovian_operations")), "public Research command starts the five-stage Jovian Operations program from the physical theory electronics custody")
	var jovian_theory_events := _advance(20000.0, "J10 Jovian Operations fusion-confinement theory")
	var jovian_research_runtime: Dictionary = game.research_runtime_snapshot()
	_check(_events_have_type(jovian_theory_events, "ResearchStageCompleted") and str(jovian_research_runtime.get("project_id", "")) == "research_jovian_operations" and str(jovian_research_runtime.get("stage_id", "")) == "experiment", "Jovian Operations completes the Factory-backed theory stage and projects the exact next experiment identity through the public research snapshot; runtime=%s" % JSON.stringify(jovian_research_runtime))
	if failures.size() > 0:
		return

	# Five future rare-earth returns need physical source operating stock.  Restore
	# it through the actual Engineering Works before publishing any Location
	# policy, so neither the research project nor a lingering policy grants cargo.
	_ensure_connection("POWER", jovian_research_power_id, cruiser_electronics_id, "")
	var quantum_repair_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_repair_material"})
	_check(bool(quantum_repair_recipe.get("accepted", false)), "Factory protocol selects physical repair-material production for bounded Lunar quantum freight")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_electronics_id, "repair_material", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "repair_material")
	var quantum_repair_events := _advance(120000.0, "J10 Lunar rare-earth return maintenance fabrication")
	var quantum_repair_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(quantum_repair_events, "grid_fabricate_repair_material") and int(quantum_repair_bulk.get("inventory", {}).get("repair_material", 0)) >= 12, "Earth Factory physically stages the bounded Lunar rare-earth return maintenance reserve; bulk=%s" % JSON.stringify(quantum_repair_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	var lunar_quantum_operating_before: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	var earth_quantum_operating_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	# One repair shipment costs one propellant, then the five-unit propellant
	# shipment also pays one propellant from its own source custody.
	var quantum_cp_export := maxi(0, 7 - int(earth_quantum_operating_before.get("chemical_propellant", 0)))
	# The two general-cargo dispatches themselves each consume two repair
	# materials.  Earth must therefore hold the ten-unit Lunar cargo plus four
	# dispatch-cost units before both all-or-none shipments can settle.
	var quantum_repair_export := maxi(0, 14 - int(earth_quantum_operating_before.get("repair_material", 0)))
	if quantum_cp_export > 0:
		_export_to_location("chemical_propellant", quantum_cp_export, "J10 five bounded Lunar rare-earth return propellant reserve", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	if quantum_repair_export > 0:
		_export_to_location("repair_material", quantum_repair_export, "J10 five bounded Lunar rare-earth return maintenance reserve", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	for operating_location_id in [EARTH_LOCATION_ID, "lunar_space"]:
		game.clear_location_logistics_policy(operating_location_id, "chemical_propellant")
		game.clear_location_logistics_policy(operating_location_id, "repair_material")
	var lunar_quantum_cp_target := int(lunar_quantum_operating_before.get("chemical_propellant", 0)) + 5
	var lunar_quantum_repair_target := int(lunar_quantum_operating_before.get("repair_material", 0)) + 10
	# Dispatch repair first: its own path cost needs the Earth propellant reserve,
	# while a same-tick propellant shipment can otherwise consume the finite route
	# budget before this ten-unit all-or-none maintenance manifest is considered.
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "repair_material", "DEMAND", 0, lunar_quantum_repair_target, 100, 1)), "public Logistics publishes the finite Lunar five-return maintenance reserve")
	var quantum_repair_freight_events := _advance(120000.0, "J10 Earth-Lunar quantum-return maintenance logistics")
	var lunar_quantum_repair_after: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(_events_have_type(quantum_repair_freight_events, "ShipmentArrived") and int(lunar_quantum_repair_after.get("repair_material", 0)) >= lunar_quantum_repair_target, "public Logistics physically stages the bounded Lunar rare-earth return maintenance reserve before propellant competes for route capacity; available=%s blockers=%s events=%s" % [JSON.stringify(lunar_quantum_repair_after), JSON.stringify(game.active_blockers("lunar_space")), JSON.stringify(quantum_repair_freight_events)])
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "repair_material")
	game.clear_location_logistics_policy("lunar_space", "repair_material")
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "chemical_propellant", "DEMAND", 0, lunar_quantum_cp_target, 100, 1)), "public Logistics publishes the finite Lunar five-return propellant reserve after maintenance staging")
	var quantum_propellant_freight_events := _advance(120000.0, "J10 Earth-Lunar quantum-return propellant logistics")
	var lunar_quantum_operating_after: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(_events_have_type(quantum_propellant_freight_events, "ShipmentArrived") and int(lunar_quantum_operating_after.get("chemical_propellant", 0)) >= lunar_quantum_cp_target and int(lunar_quantum_operating_after.get("repair_material", 0)) >= lunar_quantum_repair_target, "public Logistics physically stages the bounded Lunar rare-earth return operating reserve; available=%s blockers=%s events=%s" % [JSON.stringify(lunar_quantum_operating_after), JSON.stringify(game.active_blockers("lunar_space")), JSON.stringify(quantum_propellant_freight_events)])
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
	game.clear_location_logistics_policy("lunar_space", "chemical_propellant")

	# The first two-unit SPECIAL-safe rare-earth return produces the experiment
	# component and the next engineering-stage component.  The Fusion Test Rig
	# receives its own later, Factory-retained two-component batch.
	var lunar_rare_before := _entity(_snapshot(lunar_world_id), lunar_depot_id)
	_check(int(lunar_rare_before.get("inventory", {}).get("rare_earth_concentrate", 0)) >= 2, "the continuously powered Lunar rare-earth extractor retains the first bounded quantum feed in Factory custody; depot=%s" % JSON.stringify(lunar_rare_before.get("inventory", {})))
	if failures.size() > 0:
		return
	_export_to_location("rare_earth_concentrate", 2, "J10 first post-Belt Lunar quantum feed return", lunar_world_id, lunar_depot_id)
	game.clear_location_logistics_policy("lunar_space", "rare_earth_concentrate")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate")
	var earth_rare_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("rare_earth_concentrate", 0))
	_check(bool(game.set_location_logistics_policy("lunar_space", "rare_earth_concentrate", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate", "DEMAND", 0, earth_rare_before + 2, 100, 1)), "public Logistics publishes the first post-Belt capacity-safe Lunar rare-earth return")
	var first_quantum_return_events := _advance(180000.0, "J10 first post-Belt Lunar rare-earth return")
	_check(_events_have_type(first_quantum_return_events, "ShipmentArrived") and int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("rare_earth_concentrate", 0)) >= earth_rare_before + 2, "public Logistics returns the first two-unit SPECIAL-safe Lunar rare-earth batch to Earth custody")
	if failures.size() > 0:
		return
	_import_from_location("rare_earth_concentrate", 2, STARTER_DEPOT_ID, "J10 first post-Belt quantum Factory feed")
	game.clear_location_logistics_policy("lunar_space", "rare_earth_concentrate")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate")
	_isolate_power_for_targets([jovian_research_complex_id, quantum_assembly_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, quantum_assembly_id, "")
	var first_quantum_recipe := _factory_command("SET_RECIPE", {"entity_id":quantum_assembly_id, "recipe_id":"grid_fabricate_quantum_component"})
	_check(bool(first_quantum_recipe.get("accepted", false)), "Factory protocol selects the physical Assembly Array quantum recipe for Jovian Operations experiment")
	_clear_competing_cargo_inputs(quantum_assembly_id, "copper_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(quantum_assembly_id, "electronics", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(quantum_assembly_id, "rare_earth_concentrate", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(quantum_assembly_id, "quantum_component", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, quantum_assembly_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, quantum_assembly_id, "electronics")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, quantum_assembly_id, "rare_earth_concentrate")
	_ensure_connection("CARGO", quantum_assembly_id, cruiser_bulk_depot_id, "quantum_component")
	var first_quantum_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("quantum_component", 0))
	var first_quantum_events := _advance(60000.0, "J10 first post-Belt quantum-component fabrication")
	var first_quantum_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(first_quantum_events, "grid_fabricate_quantum_component") and int(first_quantum_bulk.get("inventory", {}).get("quantum_component", 0)) >= first_quantum_before + 2, "Assembly Array physically fabricates the exact first two quantum components from the returned Lunar rare-earth custody; bulk=%s" % JSON.stringify(first_quantum_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	_export_to_location("quantum_component", 2, "J10 Jovian Operations experiment and Fusion Test Rig quantum custody", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	var jovian_experiment_events := _advance(60000.0, "J10 Jovian Operations plasma experiment")
	jovian_research_runtime = game.research_runtime_snapshot()
	_check(_events_have_type(jovian_experiment_events, "ResearchStageCompleted") and str(jovian_research_runtime.get("project_id", "")) == "research_jovian_operations" and str(jovian_research_runtime.get("stage_id", "")) == "engineering", "Jovian Operations consumes the first returned quantum component, grants the experimental-fusion spillover, and projects the exact engineering stage; runtime=%s" % JSON.stringify(jovian_research_runtime))
	if failures.size() > 0:
		return

	# Return a distinct two-unit SPECIAL-safe rare-earth batch for the Fusion Test
	# Rig.  The already-exported Location quantum component is reserved for the
	# imminent engineering stage, so it is never double-counted as rig funding.
	var rig_lunar_depot := _entity(_snapshot(lunar_world_id), lunar_depot_id)
	_check(int(rig_lunar_depot.get("inventory", {}).get("rare_earth_concentrate", 0)) >= 2, "the powered Lunar rare-earth mine retains a second physical two-unit quantum feed for the Fusion Test Rig; depot=%s" % JSON.stringify(rig_lunar_depot.get("inventory", {})))
	if failures.size() > 0:
		return
	_export_to_location("rare_earth_concentrate", 2, "J10 Fusion Test Rig dedicated Lunar quantum feed", lunar_world_id, lunar_depot_id)
	game.clear_location_logistics_policy("lunar_space", "rare_earth_concentrate")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate")
	var rig_earth_rare_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("rare_earth_concentrate", 0))
	_check(bool(game.set_location_logistics_policy("lunar_space", "rare_earth_concentrate", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate", "DEMAND", 0, rig_earth_rare_before + 2, 100, 1)), "public Logistics publishes the dedicated capacity-safe Fusion Test Rig rare-earth return")
	var rig_rare_return_events := _advance(180000.0, "J10 Fusion Test Rig Lunar rare-earth return")
	_check(_events_have_type(rig_rare_return_events, "ShipmentArrived") and int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("rare_earth_concentrate", 0)) >= rig_earth_rare_before + 2, "public Logistics delivers the dedicated two-unit rare-earth batch to Earth Location custody")
	if failures.size() > 0:
		return
	_import_from_location("rare_earth_concentrate", 2, STARTER_DEPOT_ID, "J10 Fusion Test Rig quantum Factory feed")
	game.clear_location_logistics_policy("lunar_space", "rare_earth_concentrate")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate")
	_isolate_power_for_targets([quantum_assembly_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, quantum_assembly_id, "")
	var rig_quantum_assembly := _entity(_snapshot(EARTH_WORLD_ID), quantum_assembly_id)
	_check(str(rig_quantum_assembly.get("recipe_id", "")) == "grid_fabricate_quantum_component", "Factory snapshot retains the selected quantum recipe for the dedicated Fusion Test Rig batch; assembly=%s" % JSON.stringify(rig_quantum_assembly))
	_clear_competing_cargo_inputs(quantum_assembly_id, "copper_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(quantum_assembly_id, "electronics", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(quantum_assembly_id, "rare_earth_concentrate", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(quantum_assembly_id, "quantum_component", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, quantum_assembly_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, quantum_assembly_id, "electronics")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, quantum_assembly_id, "rare_earth_concentrate")
	_ensure_connection("CARGO", quantum_assembly_id, cruiser_bulk_depot_id, "quantum_component")
	var rig_quantum_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("quantum_component", 0))
	var rig_quantum_events := _advance(60000.0, "J10 dedicated Fusion Test Rig quantum-component fabrication")
	var rig_quantum_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(rig_quantum_events, "grid_fabricate_quantum_component") and int(rig_quantum_bulk.get("inventory", {}).get("quantum_component", 0)) >= rig_quantum_before + 2, "Assembly Array physically retains the dedicated two-quantum Fusion Test Rig construction batch in Factory custody; bulk=%s" % JSON.stringify(rig_quantum_bulk.get("inventory", {})))
	if failures.size() > 0:
		return

	# Re-power the already surveyed Asteroid cobalt mine only for the bounded
	# four-ore steel feed.  The prior local Repair Dock deliberately held this
	# finite solar source; releasing that completed service is a public topology
	# change, not an inventory grant.
	var rig_asteroid_snapshot := _snapshot(asteroid_world_id)
	var rig_asteroid_cobalt_mine := _entity_with_resource(rig_asteroid_snapshot, "cobalt_ore")
	var rig_asteroid_solar := _entity_with_definition(rig_asteroid_snapshot, "grid_solar_array")
	_check(not rig_asteroid_cobalt_mine.is_empty() and not rig_asteroid_solar.is_empty(), "the surveyed Asteroid Factory retains the public cobalt field and solar provider for the bounded Fusion Test Rig steel feed")
	if failures.size() > 0:
		return
	var rig_asteroid_solar_id := str(rig_asteroid_solar.get("id", ""))
	var rig_asteroid_cobalt_mine_id := str(rig_asteroid_cobalt_mine.get("id", ""))
	for rig_power_link_value in rig_asteroid_snapshot.get("links", []):
		var rig_power_link := rig_power_link_value as Dictionary
		if str(rig_power_link.get("kind", "")) == "POWER" and str(rig_power_link.get("source_id", "")) == rig_asteroid_solar_id and str(rig_power_link.get("target_id", "")) != rig_asteroid_cobalt_mine_id:
			var rig_power_release := _factory_command("REMOVE_LINK", {"link_id":str(rig_power_link.get("id", ""))}, asteroid_world_id)
			_check(bool(rig_power_release.get("accepted", false)), "Factory protocol releases completed Asteroid service load for the bounded cobalt mine restart")
	if failures.size() > 0:
		return
	_ensure_connection("POWER", rig_asteroid_solar_id, rig_asteroid_cobalt_mine_id, "", asteroid_world_id)
	_ensure_connection("CARGO", rig_asteroid_cobalt_mine_id, asteroid_steel_depot_id, "cobalt_ore", asteroid_world_id)
	_advance(2000.0, "J10 bounded Asteroid cobalt extraction for Fusion Test Rig steel")
	var rig_asteroid_depot := _entity(_snapshot(asteroid_world_id), asteroid_steel_depot_id)
	var rig_powered_cobalt_mine := _entity(_snapshot(asteroid_world_id), rig_asteroid_cobalt_mine_id)
	_check(float(rig_powered_cobalt_mine.get("power_factor", 0.0)) > 0.0 and int(rig_asteroid_depot.get("inventory", {}).get("cobalt_ore", 0)) >= 4, "the re-powered Asteroid Factory retains physical cobalt ore for the exact two-composite Fusion Test Rig steel batch; mine=%s depot=%s" % [JSON.stringify(rig_powered_cobalt_mine), JSON.stringify(rig_asteroid_depot.get("inventory", {}))])
	if failures.size() > 0:
		return
	var rig_asteroid_operating_before: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	var rig_cp_shortfall := maxi(0, 3 - int(rig_asteroid_operating_before.get("chemical_propellant", 0)))
	var rig_repair_shortfall := maxi(0, 2 - int(rig_asteroid_operating_before.get("repair_material", 0)))
	var rig_operating_shipments := (1 if rig_cp_shortfall > 0 else 0) + (1 if rig_repair_shortfall > 0 else 0)
	var rig_earth_operating_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var rig_earth_cp_target := rig_cp_shortfall + rig_operating_shipments * 3
	var rig_earth_repair_target := rig_repair_shortfall + rig_operating_shipments * 2
	var rig_cp_export := maxi(0, rig_earth_cp_target - int(rig_earth_operating_before.get("chemical_propellant", 0)))
	var rig_repair_export := maxi(0, rig_earth_repair_target - int(rig_earth_operating_before.get("repair_material", 0)))
	if rig_repair_export > 0:
		# The prior Lunar reserve shipment legitimately consumed the previous
		# Factory repair batch.  Replenish only this bounded Asteroid manifest
		# through the same physical Engineering Works before exporting it.
		# The two dedicated quantum batches also consumed the preceding copper
		# stock.  Re-open the real copper refinery into the explicit Bulk depot
		# (including its waste co-product) instead of treating the remaining three
		# repair units as enough for a four-unit all-or-none Location export.
		_isolate_power_for_targets([cruiser_copper_id], jovian_research_power_id)
		_ensure_connection("POWER", jovian_research_power_id, cruiser_copper_id, "")
		var rig_copper_refinery_before := _entity(_snapshot(EARTH_WORLD_ID), cruiser_copper_id)
		if str(rig_copper_refinery_before.get("recipe_id", "")) != "grid_refine_copper":
			var rig_copper_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_copper_id, "recipe_id":"grid_refine_copper"})
			_check(bool(rig_copper_recipe.get("accepted", false)), "Factory protocol restores the physical copper-refinery recipe for the bounded Fusion Test Rig repair batch")
		_clear_competing_cargo_outputs(cruiser_copper_id, "copper_ingot", cruiser_bulk_depot_id)
		_clear_competing_cargo_outputs(cruiser_copper_id, "industrial_waste", cruiser_bulk_depot_id)
		# Assembly's retained copper input is intentionally dormant without rare
		# earth, but it still owns a valid output port.  Retire that competing link
		# and make the Engineering Works the only copper recipient for this repair
		# batch; copper staged in its legal input buffer remains physical custody.
		_clear_competing_cargo_outputs(cruiser_bulk_depot_id, "copper_ingot", cruiser_electronics_id)
		_ensure_connection("CARGO", cruiser_copper_id, cruiser_bulk_depot_id, "copper_ingot")
		_ensure_connection("CARGO", cruiser_copper_id, cruiser_bulk_depot_id, "industrial_waste")
		_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_electronics_id, "copper_ingot")
		var rig_copper_chain_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("copper_ingot", 0)) + int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id).get("inputs", {}).get("copper_ingot", 0))
		var rig_copper_events := _advance(90000.0, "J10 Fusion Test Rig Asteroid-return copper refinement")
		var rig_copper_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
		var rig_copper_repair_works := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
		var rig_copper_chain_after := int(rig_copper_bulk.get("inventory", {}).get("copper_ingot", 0)) + int(rig_copper_repair_works.get("inputs", {}).get("copper_ingot", 0))
		_check(_events_have_recipe(rig_copper_events, "grid_refine_copper") and rig_copper_chain_after >= rig_copper_chain_before + rig_repair_export, "Earth Factory physically restores the exact copper custody needed for the bounded Fusion Test Rig repair batch across Bulk and its legal Engineering Works input buffer; bulk=%s works=%s" % [JSON.stringify(rig_copper_bulk.get("inventory", {})), JSON.stringify(rig_copper_repair_works)])
		if failures.size() > 0:
			return
		# The reusable Works has a legitimate historic buffer (copper, electronics,
		# and one iron) at its finite input capacity.  Do not discard that custody:
		# temporarily consume its resident iron/copper with one electronics cycle to
		# release two slots, then restore the actual iron-refinery input path.
		_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
		_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", "")
		_isolate_power_for_targets([cruiser_electronics_id], jovian_research_power_id)
		_ensure_connection("POWER", jovian_research_power_id, cruiser_electronics_id, "")
		var rig_buffer_recovery_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_electronics"})
		_check(bool(rig_buffer_recovery_recipe.get("accepted", false)), "Factory protocol reconfigures the full Engineering Works to consume its resident physical copper and iron without clearing buffers")
		_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", cruiser_bulk_depot_id)
		_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "electronics")
		var rig_buffer_recovery_events := _advance(30000.0, "J10 Fusion Test Rig Engineering Works physical buffer recovery")
		var rig_buffer_recovery_works := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
		var rig_buffer_recovery_total := 0
		for rig_buffer_recovery_quantity in rig_buffer_recovery_works.get("inputs", {}).values():
			rig_buffer_recovery_total += int(rig_buffer_recovery_quantity)
		_check(_events_have_recipe(rig_buffer_recovery_events, "grid_fabricate_electronics") and rig_buffer_recovery_total <= 94, "one public electronics cycle consumes resident inputs and releases at least two Engineering Works buffer slots; inputs=%s recipe_events=%s" % [JSON.stringify(rig_buffer_recovery_works.get("inputs", {})), JSON.stringify(rig_buffer_recovery_events.filter(func(event: Dictionary) -> bool: return str(event.get("recipe_id", "")) == "grid_fabricate_electronics"))])
		if failures.size() > 0:
			return
		var rig_iron_refinery := _entity_with_recipe(_snapshot(EARTH_WORLD_ID), "grid_refine_iron")
		_check(not rig_iron_refinery.is_empty(), "Earth Factory exposes the existing renewable iron refinery needed to replenish the recovered Engineering Works")
		if rig_iron_refinery.is_empty():
			return
		var rig_iron_refinery_id := str(rig_iron_refinery.get("id", ""))
		_isolate_power_for_targets([cruiser_electronics_id, rig_iron_refinery_id], jovian_research_power_id)
		_ensure_connection("POWER", jovian_research_power_id, rig_iron_refinery_id, "")
		_ensure_connection("POWER", jovian_research_power_id, cruiser_electronics_id, "")
		_clear_competing_cargo_outputs(rig_iron_refinery_id, "iron_ingot", cruiser_electronics_id)
		_ensure_connection("CARGO", rig_iron_refinery_id, cruiser_electronics_id, "iron_ingot")
		_isolate_power_for_targets([cruiser_electronics_id], jovian_research_power_id)
		_ensure_connection("POWER", jovian_research_power_id, cruiser_electronics_id, "")
		var rig_repair_works_before := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
		if str(rig_repair_works_before.get("recipe_id", "")) != "grid_fabricate_repair_material":
			var rig_repair_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_repair_material"})
			_check(bool(rig_repair_recipe.get("accepted", false)), "Factory protocol restores physical repair-material fabrication for the bounded Fusion Test Rig cobalt return")
		_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", rig_iron_refinery_id)
		_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", cruiser_bulk_depot_id)
		_clear_competing_cargo_outputs(cruiser_electronics_id, "repair_material", cruiser_bulk_depot_id)
		_ensure_connection("CARGO", rig_iron_refinery_id, cruiser_electronics_id, "iron_ingot")
		_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_electronics_id, "copper_ingot")
		_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "repair_material")
		var rig_repair_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("repair_material", 0))
		var rig_repair_events := _advance(90000.0, "J10 Fusion Test Rig Asteroid-return repair-material fabrication")
		var rig_repair_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
		_check(_events_have_recipe(rig_repair_events, "grid_fabricate_repair_material") and int(rig_repair_bulk.get("inventory", {}).get("repair_material", 0)) >= rig_repair_before + rig_repair_export, "Earth Factory physically replenishes the exact repair-material cargo needed for the bounded Fusion Test Rig Asteroid cobalt return; bulk=%s" % JSON.stringify(rig_repair_bulk.get("inventory", {})))
		if failures.size() > 0:
			return
	if rig_cp_export > 0:
		_export_to_location("chemical_propellant", rig_cp_export, "J10 Fusion Test Rig Asteroid cobalt return propellant", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	if rig_repair_export > 0:
		_export_to_location("repair_material", rig_repair_export, "J10 Fusion Test Rig Asteroid cobalt return maintenance", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	for rig_operating_location_id in [EARTH_LOCATION_ID, "asteroid_belt"]:
		game.clear_location_logistics_policy(rig_operating_location_id, "chemical_propellant")
		game.clear_location_logistics_policy(rig_operating_location_id, "repair_material")
	if rig_cp_shortfall > 0:
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "chemical_propellant", "DEMAND", 0, int(rig_asteroid_operating_before.get("chemical_propellant", 0)) + rig_cp_shortfall, 100, 1)), "public Logistics publishes the finite Fusion Test Rig Asteroid propellant reserve")
	if rig_repair_shortfall > 0:
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "repair_material", "DEMAND", 0, int(rig_asteroid_operating_before.get("repair_material", 0)) + rig_repair_shortfall, 100, 1)), "public Logistics publishes the finite Fusion Test Rig Asteroid maintenance reserve")
	var rig_asteroid_operating_events := _advance(360000.0, "J10 Fusion Test Rig Asteroid cobalt return operating staging")
	var rig_asteroid_operating_after: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	_check((rig_operating_shipments == 0 or _events_have_type(rig_asteroid_operating_events, "ShipmentArrived")) and int(rig_asteroid_operating_after.get("chemical_propellant", 0)) >= 3 and int(rig_asteroid_operating_after.get("repair_material", 0)) >= 2, "public Logistics stages the exact Asteroid source costs for one bounded Fusion Test Rig cobalt return; available=%s events=%s" % [JSON.stringify(rig_asteroid_operating_after), JSON.stringify(rig_asteroid_operating_events)])
	if failures.size() > 0:
		return
	for rig_operating_location_id in [EARTH_LOCATION_ID, "asteroid_belt"]:
		game.clear_location_logistics_policy(rig_operating_location_id, "chemical_propellant")
		game.clear_location_logistics_policy(rig_operating_location_id, "repair_material")
	var rig_earth_cobalt_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("cobalt_ore", 0))
	_export_to_location("cobalt_ore", 4, "J10 bounded Fusion Test Rig steel cobalt feed", asteroid_world_id, asteroid_steel_depot_id)
	game.clear_location_logistics_policy("asteroid_belt", "cobalt_ore")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore")
	_check(bool(game.set_location_logistics_policy("asteroid_belt", "cobalt_ore", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore", "DEMAND", 0, rig_earth_cobalt_before + 4, 100, 1)), "public Logistics publishes the bounded Fusion Test Rig cobalt return")
	var rig_cobalt_return_events := _advance(360000.0, "J10 Fusion Test Rig Asteroid-Earth cobalt return")
	_check(_events_have_type(rig_cobalt_return_events, "ShipmentArrived") and int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("cobalt_ore", 0)) >= rig_earth_cobalt_before + 4, "public Logistics returns the exact four Asteroid cobalt ore needed for the Fusion Test Rig steel feed")
	if failures.size() > 0:
		return
	_import_from_location("cobalt_ore", 4, cruiser_bulk_depot_id, "J10 Fusion Test Rig steel cobalt Factory feed")
	game.clear_location_logistics_policy("asteroid_belt", "cobalt_ore")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore")
	_isolate_power_for_targets([cruiser_foundry_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, cruiser_foundry_id, "")
	var rig_cobalt_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_cobalt"})
	_check(bool(rig_cobalt_recipe.get("accepted", false)), "Factory protocol selects the two-cycle Fusion Test Rig cobalt refinement recipe")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "industrial_waste", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "industrial_waste", cruiser_foundry_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ore")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "cobalt_ingot")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "industrial_waste")
	_advance(1000.0, "J10 exact Fusion Test Rig cobalt input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", "")
	var rig_cobalt_events := _advance(30000.0, "J10 two-cycle Fusion Test Rig cobalt refinement")
	var rig_cobalt_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(rig_cobalt_events, "grid_refine_cobalt") and int(rig_cobalt_bulk.get("inventory", {}).get("cobalt_ingot", 0)) >= 2, "Earth Factory physically refines the exact cobalt input for two Fusion Test Rig steel composites; bulk=%s" % JSON.stringify(rig_cobalt_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	print("RIG_STEEL_STAGE=before-set-recipe")
	_clear_competing_cargo_outputs(cruiser_foundry_id, "cobalt_ingot", "")
	print("RIG_STEEL_STAGE=after-cobalt-output-release")
	var rig_steel_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_steel_electric"})
	_check(bool(rig_steel_recipe.get("accepted", false)), "Factory protocol selects the two-cycle Fusion Test Rig electric-steel recipe")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "steel_composite", cruiser_bulk_depot_id)
	# SET_RECIPE retires incompatible cobalt outputs.  Clear only a retained
	# steel-composite input from a different source before assigning this
	# Foundry's bounded two-cycle output to the same public Bulk depot.
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "steel_composite", cruiser_foundry_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_foundry_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ingot")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "steel_composite")
	_advance(1000.0, "J10 exact Fusion Test Rig steel input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", "")
	var rig_steel_events := _advance(30000.0, "J10 two-cycle Fusion Test Rig electric steelmaking")
	var rig_material_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(rig_steel_events, "grid_refine_steel_electric") and int(rig_material_bulk.get("inventory", {}).get("steel_composite", 0)) >= 2 and int(rig_material_bulk.get("inventory", {}).get("quantum_component", 0)) >= 2, "Earth Factory retains the exact physical Fusion Test Rig steel-and-quantum construction manifest; bulk=%s" % JSON.stringify(rig_material_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	var fusion_test_rig_order := _queue_and_fund("grid_fusion_test_rig", "", {"x":300, "y":190}, "J10 powered Fusion Test Rig", false, EARTH_WORLD_ID, cruiser_bulk_depot_id)
	if fusion_test_rig_order.is_empty() or failures.size() > 0:
		return
	var fusion_test_rig_id := str(fusion_test_rig_order.get("entity_id", ""))
	var fusion_test_rig_events := _advance(120000.0, "J10 powered Fusion Test Rig construction")
	var fusion_test_rig_snapshot := _entity(_snapshot(EARTH_WORLD_ID), fusion_test_rig_id)
	_check(_events_have_type(fusion_test_rig_events, "FactoryConstructionCompleted") and str(fusion_test_rig_snapshot.get("definition_id", "")) == "grid_fusion_test_rig", "Factory physically completes the exact Fusion Test Rig before assigning its public POWER topology; rig=%s" % JSON.stringify(fusion_test_rig_snapshot))
	if failures.size() > 0:
		return
	_isolate_power_for_targets([jovian_research_complex_id, fusion_test_rig_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, jovian_research_complex_id, "")
	_ensure_connection("POWER", jovian_research_power_id, fusion_test_rig_id, "")
	var fusion_test_rig_power_events := _advance(1000.0, "J10 completed Fusion Test Rig POWER adapter synchronization")
	var fusion_test_rig_powered := _entity(_snapshot(EARTH_WORLD_ID), fusion_test_rig_id)
	var fusion_adapter_runtime: Dictionary = game.research_runtime_snapshot()
	_check(float(fusion_test_rig_powered.get("power_factor", 0.0)) > 0.0 and str(fusion_adapter_runtime.get("project_id", "")) == "research_jovian_operations" and str(fusion_adapter_runtime.get("stage_id", "")) == "engineering" and str(fusion_adapter_runtime.get("status", "")) == "RUNNING" and str(fusion_adapter_runtime.get("blocked_reason", "")).is_empty(), "public Factory POWER activates the completed Fusion Test Rig adapter and removes the Jovian Operations engineering facility blocker; rig=%s runtime=%s events=%s" % [JSON.stringify(fusion_test_rig_powered), JSON.stringify(fusion_adapter_runtime), JSON.stringify(fusion_test_rig_power_events)])
	if failures.size() > 0:
		return
	var jovian_engineering_events := _advance(60000.0, "J10 Jovian Operations maintainable fusion engineering")
	jovian_research_runtime = game.research_runtime_snapshot()
	_check(_events_have_type(jovian_engineering_events, "ResearchStageCompleted") and str(jovian_research_runtime.get("project_id", "")) == "research_jovian_operations" and str(jovian_research_runtime.get("stage_id", "")) == "prototype", "Jovian Operations consumes its separately reserved engineering quantum component after the powered Fusion Test Rig removes the facility/cooling gate; runtime=%s" % JSON.stringify(jovian_research_runtime))
	if failures.size() > 0:
		return

	# Prototype is intentionally a new physical custody chain.  It does not reuse
	# the quantum components already exported to Research or consumed by the Rig:
	# Lunar thorium and a third SPECIAL-safe rare-earth return are each moved
	# through Location custody before their Earth Factory recipes begin.
	var prototype_lunar_snapshot := _snapshot(lunar_world_id)
	var thorium_field := _resource_field(prototype_lunar_snapshot, "thorium_ore")
	var prototype_lunar_depot := _entity(prototype_lunar_snapshot, lunar_depot_id)
	_check(not thorium_field.is_empty() and not prototype_lunar_depot.is_empty(), "the public Lunar Factory snapshot exposes the surveyed thorium field and existing physical depot for the Jovian Operations prototype")
	if failures.size() > 0:
		return
	# The first finite Asteroid-route reward was intentionally reserved for the
	# J8 bootstrap.  Recover this separate, repeatable Lunar combat reward through
	# the currently proven Pathfinder-Cruiser formation rather than changing
	# starter inventory or content.  A repeatable combat runtime does not unload
	# itself, so recall it explicitly after one bounded public time window.
	var patrol_scrap_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(patrol_scrap_before.get("scrap_metal", 0)) == 3 and not pathfinder_formation_id.is_empty() and game.formation_ready(pathfinder_formation_id) and not game.formation_is_active(pathfinder_formation_id), "the deployed Pathfinder-Cruiser formation is publicly idle, maintained, and retains the exact three-unit Earth scrap custody before the repeatable Lunar patrol")
	if failures.size() > 0:
		return
	var patrol_events_start := observed_events.size()
	var patrol_started := bool(game.start_activity("expedition", "combat_lunar_raider_patrol", pathfinder_formation_id))
	_check(patrol_started, "public Expedition activity command starts the canonical repeatable Lunar Raider patrol with the proven armed-and-shielded formation")
	if failures.size() > 0:
		return
	var patrol_events := _advance(60000.0, "J10 one bounded Lunar Raider patrol recovery")
	var patrol_event_slice := _events_after(patrol_events_start)
	var patrol_enemy_defeated := patrol_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "EnemyDefeated" and str(event.get("enemy_id", "")) == "lunar_raider_patrol" and not bool(event.get("boss", false))
	)
	_check(not _events_with_activity(patrol_event_slice, "OperationStarted", "combat_lunar_raider_patrol").is_empty() and patrol_enemy_defeated and not _events_with_activity(patrol_events, "OperationCycleCompleted", "combat_lunar_raider_patrol").is_empty() and not _events_have_type(patrol_events, "ExpeditionFailed") and not _events_have_type(patrol_events, "FleetCargoFull"), "the bounded public Lunar patrol records its exact activity identity, a real Raider defeat, and a completed cycle without expedition failure or stranded cargo; events=%s" % JSON.stringify(patrol_events))
	if failures.size() > 0:
		return
	var patrol_stop_events_start := observed_events.size()
	_check(bool(game.stop_activity("expedition")), "public Expedition stop command recalls the repeatable patrol after its bounded recovery window")
	var patrol_stop_events := _events_after(patrol_stop_events_start)
	var patrol_scrap_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(_events_have_type(patrol_stop_events, "OperationStopped") and int(patrol_scrap_after.get("scrap_metal", 0)) >= int(patrol_scrap_before.get("scrap_metal", 0)) + 2, "public patrol recall unloads the guaranteed two-unit scrap reward into Earth Location custody; before=%s after=%s events=%s" % [JSON.stringify(patrol_scrap_before), JSON.stringify(patrol_scrap_after), JSON.stringify(patrol_stop_events)])
	if failures.size() > 0:
		return
	var earth_thorium_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(earth_thorium_available.get("scrap_metal", 0)) >= 4, "public patrol recovery retains at least four guaranteed scrap units directly in Earth Location custody for the Lunar thorium-mine manifest; available=%s" % JSON.stringify(earth_thorium_available))
	if failures.size() > 0:
		return
	# The four scrap units are a real combined-custody preflight: retain any
	# Earth Location cargo already there and export only the Factory shortfall
	# from an explicitly observed physical storage.  This never assumes a route
	# reward's display name or silently grants a new construction material.
	var earth_thorium_location_scrap := mini(4, int(earth_thorium_available.get("scrap_metal", 0)))
	var earth_thorium_scrap_shortfall := 4 - earth_thorium_location_scrap
	if earth_thorium_scrap_shortfall > 0:
		var earth_thorium_scrap_source := _entity_with_inventory_item(_snapshot(EARTH_WORLD_ID), "scrap_metal", earth_thorium_scrap_shortfall)
		_check(not earth_thorium_scrap_source.is_empty(), "Earth Factory exposes the exact physical scrap shortfall for the Lunar thorium mine; location=%s factory=%s" % [JSON.stringify(earth_thorium_available), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("entities", []))])
		if failures.size() > 0:
			return
		_export_to_location("scrap_metal", earth_thorium_scrap_shortfall, "J10 Lunar thorium mine Factory shortfall", EARTH_WORLD_ID, str(earth_thorium_scrap_source.get("id", "")))
	earth_thorium_available = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(earth_thorium_available.get("scrap_metal", 0)) >= 4, "Earth Location combines retained and explicit Factory scrap custody into the exact four-unit Lunar thorium mine manifest; available=%s" % JSON.stringify(earth_thorium_available))
	if failures.size() > 0:
		return
	# Each cargo kind receives its own bounded policy window and is imported at
	# the next boundary.  Lunar Location already retains operating cargo from the
	# prior finite manifests, so the new construction shipment only moves scrap.
	# General-cargo dispatch costs are paid at Earth, not at Lunar.  Earlier
	# bounded manifests legitimately consumed their Earth-side operating cargo,
	# so stage exactly one of each cost from the observed high-capacity Factory
	# depot before publishing the independent four-scrap construction manifest.
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
	game.clear_location_logistics_policy("lunar_space", "chemical_propellant")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "repair_material")
	game.clear_location_logistics_policy("lunar_space", "repair_material")
	var thorium_dispatch_depot := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(int(thorium_dispatch_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 1 and int(thorium_dispatch_depot.get("inventory", {}).get("repair_material", 0)) >= 1, "Earth Factory explicitly retains the exact propellant and maintenance dispatch costs for the bounded Lunar thorium scrap shipment; depot=%s" % JSON.stringify(thorium_dispatch_depot.get("inventory", {})))
	if failures.size() > 0:
		return
	_export_to_location("chemical_propellant", 1, "J10 Lunar thorium scrap manifest origin dispatch cost", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	_export_to_location("repair_material", 1, "J10 Lunar thorium scrap manifest origin transport-maintenance cost", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	var earth_thorium_dispatch_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(earth_thorium_dispatch_available.get("chemical_propellant", 0)) >= 1 and int(earth_thorium_dispatch_available.get("repair_material", 0)) >= 1, "Earth Location holds the exact origin costs before it publishes the bounded Lunar thorium scrap shipment; available=%s" % JSON.stringify(earth_thorium_dispatch_available))
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "scrap_metal")
	game.clear_location_logistics_policy("lunar_space", "scrap_metal")
	var lunar_thorium_scrap_before := int(_snapshot(lunar_world_id).get("location_available_inventory", {}).get("scrap_metal", 0))
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "scrap_metal", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "scrap_metal", "DEMAND", 0, lunar_thorium_scrap_before + 4, 100, 1)), "public Logistics publishes the exact one-batch Lunar thorium scrap manifest")
	var thorium_scrap_freight_events := _advance(180000.0, "J10 Lunar thorium mine scrap logistics")
	var lunar_thorium_location: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(_events_have_type(thorium_scrap_freight_events, "ShipmentArrived") and int(lunar_thorium_location.get("scrap_metal", 0)) >= lunar_thorium_scrap_before + 4, "public Logistics delivers the exact four-unit thorium-mine scrap manifest into same-location construction custody; available=%s events=%s" % [JSON.stringify(lunar_thorium_location), JSON.stringify(thorium_scrap_freight_events)])
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "scrap_metal")
	game.clear_location_logistics_policy("lunar_space", "scrap_metal")

	var lunar_thorium_electronics_before := int(_snapshot(lunar_world_id).get("location_available_inventory", {}).get("electronics", 0))
	if lunar_thorium_electronics_before < 1:
		var thorium_electronics_earth_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(int(thorium_electronics_earth_available.get("electronics", 0)) >= 1, "the public patrol recovery leaves the exact one electronics component in Earth Location custody for the Lunar thorium mine; available=%s" % JSON.stringify(thorium_electronics_earth_available))
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "electronics")
		game.clear_location_logistics_policy("lunar_space", "electronics")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
		game.clear_location_logistics_policy("lunar_space", "chemical_propellant")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "repair_material")
		game.clear_location_logistics_policy("lunar_space", "repair_material")
		var thorium_electronics_dispatch_depot := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
		_check(int(thorium_electronics_dispatch_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 1 and int(thorium_electronics_dispatch_depot.get("inventory", {}).get("repair_material", 0)) >= 1, "Earth Factory retains the exact origin costs for the distinct one-electronics Lunar thorium shipment; depot=%s" % JSON.stringify(thorium_electronics_dispatch_depot.get("inventory", {})))
		if failures.size() > 0:
			return
		_export_to_location("chemical_propellant", 1, "J10 Lunar thorium electronics manifest origin dispatch cost", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		_export_to_location("repair_material", 1, "J10 Lunar thorium electronics manifest origin transport-maintenance cost", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		var thorium_electronics_dispatch_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(int(thorium_electronics_dispatch_available.get("electronics", 0)) >= 1 and int(thorium_electronics_dispatch_available.get("chemical_propellant", 0)) >= 1 and int(thorium_electronics_dispatch_available.get("repair_material", 0)) >= 1, "Earth Location stages the electronics cargo and exact origin costs for the bounded Lunar thorium component shipment; available=%s" % JSON.stringify(thorium_electronics_dispatch_available))
		if failures.size() > 0:
			return
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "electronics", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "electronics", "DEMAND", 0, 1, 100, 1)), "public Logistics publishes the one-electronics Lunar thorium construction shortfall")
		var thorium_electronics_freight_events := _advance(180000.0, "J10 Lunar thorium mine electronics logistics")
		lunar_thorium_location = _snapshot(lunar_world_id).get("location_available_inventory", {})
		_check(_events_have_type(thorium_electronics_freight_events, "ShipmentArrived") and int(lunar_thorium_location.get("electronics", 0)) >= 1, "public Logistics delivers the exact one-electronics thorium construction shortfall; available=%s" % JSON.stringify(lunar_thorium_location))
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "electronics")
		game.clear_location_logistics_policy("lunar_space", "electronics")
	# The new mine is funded entirely from its exact same-site, capacity-safe
	# Logistics manifest.  It neither relies on a saturated historical depot nor
	# treats remote Factory inventory as an implicit construction source.
	var thorium_queue := _factory_command("QUEUE_CONSTRUCTION", {"definition_id":"grid_surface_mine", "recipe_id":"", "origin":thorium_field.get("footprint", {}).get("origin", {}), "priority":50}, lunar_world_id)
	var thorium_order_id := str(thorium_queue.get("result", {}).get("order_id", ""))
	var thorium_mine_id := str(thorium_queue.get("result", {}).get("entity_id", ""))
	_check(bool(thorium_queue.get("accepted", false)) and not thorium_order_id.is_empty() and not thorium_mine_id.is_empty(), "Factory protocol queues the exact Lunar thorium surface mine from the surveyed field origin")
	if failures.size() > 0:
		return
	var thorium_location_fund := _factory_command("FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":thorium_order_id}, lunar_world_id)
	var thorium_location_moved: Dictionary = thorium_location_fund.get("result", {}).get("moved", {})
	_check(bool(thorium_location_fund.get("accepted", false)) and int(thorium_location_moved.get("electronics", 0)) == 1 and int(thorium_location_moved.get("scrap_metal", 0)) == 4 and bool(thorium_location_fund.get("result", {}).get("fully_funded", false)), "the one public same-location funding intent atomically contributes the exact four scrap and one electronics units to fully fund the Lunar thorium mine; result=%s" % JSON.stringify(thorium_location_fund))
	if failures.size() > 0:
		return
	var thorium_construction_events := _advance(120000.0, "J10 Lunar thorium surface-mine construction")
	var thorium_mine_snapshot := _entity(_snapshot(lunar_world_id), thorium_mine_id)
	_check(_events_have_type(thorium_construction_events, "FactoryConstructionCompleted") and str(thorium_mine_snapshot.get("definition_id", "")) == "grid_surface_mine", "Factory physically completes the canonical Lunar thorium surface mine through exact mixed custody; mine=%s" % JSON.stringify(thorium_mine_snapshot))
	if failures.size() > 0:
		return
	var thorium_solar := _entity_with_definition(_snapshot(lunar_world_id), "grid_solar_array")
	_check(not thorium_solar.is_empty(), "the public Lunar Factory snapshot retains a solar POWER provider for thorium extraction")
	if failures.size() > 0:
		return
	# The long-running rare-earth mine has legitimately filled the original bulk
	# depot.  Reserve its next two-unit service-component feed at the same Lunar
	# Location before freeing exactly two physical depot slots for thorium.  First
	# stop its CARGO refill link so that released capacity cannot be reclaimed by a
	# background extractor tick.
	var rare_earth_output_links: Array = []
	for lunar_link_value in _snapshot(lunar_world_id).get("links", []):
		var lunar_link := lunar_link_value as Dictionary
		if str(lunar_link.get("kind", "")) == "CARGO" and str(lunar_link.get("source_id", "")) == rare_earth_mine_id and str(lunar_link.get("target_id", "")) == lunar_depot_id and str(lunar_link.get("item_id", "")) == "rare_earth_concentrate":
			rare_earth_output_links.append(lunar_link)
	_check(rare_earth_output_links.size() == 1, "the public Lunar snapshot exposes the single live rare-earth-to-depot CARGO link that would otherwise refill the saturated thorium destination; links=%s" % JSON.stringify(rare_earth_output_links))
	if failures.size() > 0:
		return
	var rare_earth_unlink := _factory_command("REMOVE_LINK", {"link_id":str((rare_earth_output_links[0] as Dictionary).get("id", ""))}, lunar_world_id)
	_check(bool(rare_earth_unlink.get("accepted", false)), "Factory protocol removes only the observed rare-earth output link before capacity-safe thorium storage; result=%s" % JSON.stringify(rare_earth_unlink))
	if failures.size() > 0:
		return
	var thorium_depot_before_release := _entity(_snapshot(lunar_world_id), lunar_depot_id)
	_check(int(thorium_depot_before_release.get("inventory", {}).get("rare_earth_concentrate", 0)) >= 2, "the saturated Lunar depot retains the exact two rare-earth units needed later for fusion-service quantum components; depot=%s" % JSON.stringify(thorium_depot_before_release.get("inventory", {})))
	if failures.size() > 0:
		return
	_export_to_location("rare_earth_concentrate", 2, "J10 reserve fusion-service rare-earth feed and release Lunar thorium storage", lunar_world_id, lunar_depot_id)
	var thorium_depot_after_release := _entity(_snapshot(lunar_world_id), lunar_depot_id)
	var lunar_reserved_service_rare: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(int(thorium_depot_after_release.get("inventory", {}).get("rare_earth_concentrate", 0)) == int(thorium_depot_before_release.get("inventory", {}).get("rare_earth_concentrate", 0)) - 2 and int(lunar_reserved_service_rare.get("rare_earth_concentrate", 0)) >= 2, "the public export preserves two rare-earth units in Lunar Location custody and releases exactly two Factory storage slots; depot=%s location=%s" % [JSON.stringify(thorium_depot_after_release.get("inventory", {})), JSON.stringify(lunar_reserved_service_rare)])
	if failures.size() > 0:
		return
	_ensure_connection("POWER", str(thorium_solar.get("id", "")), thorium_mine_id, "", lunar_world_id)
	_clear_competing_cargo_outputs(thorium_mine_id, "thorium_ore", lunar_depot_id, lunar_world_id)
	_ensure_connection("CARGO", thorium_mine_id, lunar_depot_id, "thorium_ore", lunar_world_id)
	var thorium_extraction_events := _advance(1000.0, "J10 one exact Lunar thorium extraction batch")
	var thorium_depot := _entity(_snapshot(lunar_world_id), lunar_depot_id)
	var thorium_extraction_batches := thorium_extraction_events.filter(func(event_value):
		var thorium_event := event_value as Dictionary
		return str(thorium_event.get("type", "")) == "FactoryResourceExtracted" and str(thorium_event.get("world_id", "")) == lunar_world_id and str(thorium_event.get("entity_id", "")) == thorium_mine_id and str(thorium_event.get("resource_id", "")) == "thorium_ore"
	)
	_check(not thorium_extraction_batches.is_empty() and int((thorium_extraction_batches[0] as Dictionary).get("quantity", 0)) == 2 and int(thorium_depot.get("inventory", {}).get("thorium_ore", 0)) == 2, "the powered Lunar surface mine physically transfers its exact first two-unit thorium batch through the released public storage path; depot=%s events=%s" % [JSON.stringify(thorium_depot.get("inventory", {})), JSON.stringify(thorium_extraction_events)])
	if failures.size() > 0:
		return
	# The rare-earth feed is already staged at Lunar Location.  Return and import
	# it before returning raw thorium: this finite, independently funded shipment
	# releases the location capacity that a two-unit RAW-resource payload needs.
	var service_lunar_rare_location: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(int(service_lunar_rare_location.get("rare_earth_concentrate", 0)) >= 2, "Lunar Location retains the explicitly reserved two-unit rare-earth batch for fusion-service quantum components; available=%s" % JSON.stringify(service_lunar_rare_location))
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy("lunar_space", "rare_earth_concentrate")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate")
	var lunar_service_rare_operating: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(int(lunar_service_rare_operating.get("chemical_propellant", 0)) >= 1 and int(lunar_service_rare_operating.get("repair_material", 0)) >= 1, "Lunar Location retains the exact public origin costs before it dispatches the reserved rare-earth return; available=%s" % JSON.stringify(lunar_service_rare_operating))
	if failures.size() > 0:
		return
	var earth_service_rare_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("rare_earth_concentrate", 0))
	_check(bool(game.set_location_logistics_policy("lunar_space", "rare_earth_concentrate", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate", "DEMAND", 0, earth_service_rare_before + 2, 100, 1)), "public Logistics publishes the reserved two-unit Lunar rare-earth return before raw-thorium staging")
	var service_rare_return_events := _advance(180000.0, "J10 capacity-safe Lunar-to-Earth fusion-service rare-earth return")
	_check(_events_have_type(service_rare_return_events, "ShipmentArrived") and int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("rare_earth_concentrate", 0)) >= earth_service_rare_before + 2, "public Logistics returns the reserved two-unit rare-earth batch to Earth custody before raw-thorium export")
	if failures.size() > 0:
		return
	_import_from_location("rare_earth_concentrate", 2, cruiser_bulk_depot_id, "J10 fusion-service quantum rare-earth Factory staging")
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy("lunar_space", "rare_earth_concentrate")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate")

	_export_to_location("thorium_ore", 2, "J10 Lunar thorium prototype return", lunar_world_id, lunar_depot_id)
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy("lunar_space", "thorium_ore")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "thorium_ore")
	var lunar_thorium_return_operating: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	_check(int(lunar_thorium_return_operating.get("chemical_propellant", 0)) >= 1 and int(lunar_thorium_return_operating.get("repair_material", 0)) >= 1, "Lunar Location retains the exact public origin costs before it dispatches the bounded thorium return; available=%s" % JSON.stringify(lunar_thorium_return_operating))
	if failures.size() > 0:
		return
	var earth_thorium_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("thorium_ore", 0))
	_check(bool(game.set_location_logistics_policy("lunar_space", "thorium_ore", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "thorium_ore", "DEMAND", 0, earth_thorium_before + 2, 100, 1)), "public Logistics publishes the capacity-safe two-unit Lunar thorium prototype return")
	var thorium_return_events := _advance(180000.0, "J10 Lunar-to-Earth thorium prototype return")
	var earth_thorium_returned: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(_events_have_type(thorium_return_events, "ShipmentArrived") and int(earth_thorium_returned.get("thorium_ore", 0)) >= earth_thorium_before + 2, "public Logistics returns exactly two Lunar thorium ore to Earth Location custody; available=%s events=%s" % [JSON.stringify(earth_thorium_returned), JSON.stringify(thorium_return_events)])
	if failures.size() > 0:
		return
	_import_from_location("thorium_ore", 2, cruiser_bulk_depot_id, "J10 Earth prototype thorium Factory staging")
	game.clear_location_logistics_policy("lunar_space", "thorium_ore")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "thorium_ore")

	var prototype_assembly := _entity_with_definition(_snapshot(EARTH_WORLD_ID), "grid_assembly_array")
	var prototype_high_energy := _entity_with_definition(_snapshot(EARTH_WORLD_ID), "grid_electronics_works")
	_check(not prototype_assembly.is_empty() and not prototype_high_energy.is_empty(), "Earth Factory exposes the completed Assembly Array and High-Energy Electronics Works for the public fusion-service production chain")
	if failures.size() > 0:
		return
	var prototype_assembly_id := str(prototype_assembly.get("id", ""))
	var prototype_high_energy_id := str(prototype_high_energy.get("id", ""))
	var prototype_material_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(int(prototype_assembly.get("inputs", {}).get("copper_ingot", 0)) >= 4 and int(prototype_assembly.get("inputs", {}).get("electronics", 0)) >= 4 and int(prototype_material_bulk.get("inventory", {}).get("rare_earth_concentrate", 0)) >= 2 and int(prototype_material_bulk.get("inventory", {}).get("thorium_ore", 0)) >= 2, "the public Factory snapshot proves the Assembly Array retains legal resident copper/electronics inputs while explicit Bulk custody holds the exact rare-earth and thorium prototype feed; assembly=%s bulk=%s" % [JSON.stringify(prototype_assembly.get("inputs", {})), JSON.stringify(prototype_material_bulk.get("inventory", {}))])
	if failures.size() > 0:
		return
	_isolate_power_for_targets([prototype_assembly_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, prototype_assembly_id, "")
	var prototype_quantum_before := int(prototype_material_bulk.get("inventory", {}).get("quantum_component", 0))
	var prototype_quantum_recipe := _factory_command("SET_RECIPE", {"entity_id":prototype_assembly_id, "recipe_id":"grid_fabricate_quantum_component"})
	_check(bool(prototype_quantum_recipe.get("accepted", false)), "Factory protocol selects the two-cycle fusion-service quantum-component recipe that consumes resident Assembly inputs")
	_clear_competing_cargo_inputs(prototype_assembly_id, "rare_earth_concentrate", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(prototype_assembly_id, "quantum_component", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, prototype_assembly_id, "rare_earth_concentrate")
	_ensure_connection("CARGO", prototype_assembly_id, cruiser_bulk_depot_id, "quantum_component")
	var prototype_quantum_events := _advance(60000.0, "J10 two-cycle fusion-service quantum fabrication")
	prototype_material_bulk = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(prototype_quantum_events, "grid_fabricate_quantum_component") and int(prototype_material_bulk.get("inventory", {}).get("quantum_component", 0)) >= prototype_quantum_before + 2, "Assembly Array physically fabricates two fusion-service quantum components from its resident copper/electronics and the distinct Lunar rare-earth batch; bulk=%s" % JSON.stringify(prototype_material_bulk.get("inventory", {})))
	if failures.size() > 0:
		return

	# The Rig legitimately consumed its earlier steel batch.  Reuse the existing
	# asteroid cobalt field only when neither its new Bulk output nor the Foundry
	# buffer retains the two ingots required for this exact service batch.
	var prototype_foundry := _entity(_snapshot(EARTH_WORLD_ID), cruiser_foundry_id)
	var prototype_cobalt_custody := int(prototype_material_bulk.get("inventory", {}).get("cobalt_ingot", 0)) + int(prototype_foundry.get("inputs", {}).get("cobalt_ingot", 0))
	if prototype_cobalt_custody < 2:
		var prototype_asteroid_snapshot := _snapshot(asteroid_world_id)
		var prototype_asteroid_cobalt_mine := _entity_with_resource(prototype_asteroid_snapshot, "cobalt_ore")
		var prototype_asteroid_solar := _entity_with_definition(prototype_asteroid_snapshot, "grid_solar_array")
		var prototype_asteroid_depot_before := _entity(prototype_asteroid_snapshot, asteroid_steel_depot_id)
		_check(not prototype_asteroid_cobalt_mine.is_empty() and not prototype_asteroid_solar.is_empty() and not prototype_asteroid_depot_before.is_empty(), "the surveyed Asteroid Factory retains the public cobalt field, storage, and solar provider for the exact prototype steel feed")
		if failures.size() > 0:
			return
		if int(prototype_asteroid_depot_before.get("inventory", {}).get("cobalt_ore", 0)) < 4:
			var prototype_asteroid_solar_id := str(prototype_asteroid_solar.get("id", ""))
			var prototype_asteroid_cobalt_mine_id := str(prototype_asteroid_cobalt_mine.get("id", ""))
			for prototype_power_link_value in prototype_asteroid_snapshot.get("links", []):
				var prototype_power_link := prototype_power_link_value as Dictionary
				if str(prototype_power_link.get("kind", "")) == "POWER" and str(prototype_power_link.get("source_id", "")) == prototype_asteroid_solar_id and str(prototype_power_link.get("target_id", "")) != prototype_asteroid_cobalt_mine_id:
					var prototype_power_release := _factory_command("REMOVE_LINK", {"link_id":str(prototype_power_link.get("id", ""))}, asteroid_world_id)
					_check(bool(prototype_power_release.get("accepted", false)), "Factory protocol releases completed Asteroid service load for the bounded prototype cobalt restart")
			if failures.size() > 0:
				return
			_ensure_connection("POWER", prototype_asteroid_solar_id, prototype_asteroid_cobalt_mine_id, "", asteroid_world_id)
			_clear_competing_cargo_outputs(prototype_asteroid_cobalt_mine_id, "cobalt_ore", asteroid_steel_depot_id, asteroid_world_id)
			_ensure_connection("CARGO", prototype_asteroid_cobalt_mine_id, asteroid_steel_depot_id, "cobalt_ore", asteroid_world_id)
			var prototype_cobalt_extract_events := _advance(2000.0, "J10 bounded Asteroid cobalt extraction for prototype steel")
			var prototype_asteroid_depot_after_extract := _entity(_snapshot(asteroid_world_id), asteroid_steel_depot_id)
			_check(prototype_cobalt_extract_events.any(func(event_value):
				var prototype_cobalt_event := event_value as Dictionary
				return str(prototype_cobalt_event.get("type", "")) == "FactoryResourceExtracted" and str(prototype_cobalt_event.get("entity_id", "")) == prototype_asteroid_cobalt_mine_id and str(prototype_cobalt_event.get("resource_id", "")) == "cobalt_ore"
			) and int(prototype_asteroid_depot_after_extract.get("inventory", {}).get("cobalt_ore", 0)) >= 4, "the re-powered Asteroid Factory extracts the exact public cobalt feed when stock is depleted; depot=%s events=%s" % [JSON.stringify(prototype_asteroid_depot_after_extract.get("inventory", {})), JSON.stringify(prototype_cobalt_extract_events)])
			if failures.size() > 0:
				return
		else:
			_check(int(prototype_asteroid_depot_before.get("inventory", {}).get("cobalt_ore", 0)) >= 4, "the public Asteroid depot already retains the exact four-cobalt prototype return feed without a duplicate extraction cycle; depot=%s" % JSON.stringify(prototype_asteroid_depot_before.get("inventory", {})))
		var prototype_asteroid_operating_before: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
		# Asteroid-to-Earth general cargo traverses lunar_belt and earth_lunar,
		# so its public dispatch consumes three propellant and two maintenance
		# units at the source, not merely the one-unit local staging minimum.
		var prototype_cp_shortfall := maxi(0, 3 - int(prototype_asteroid_operating_before.get("chemical_propellant", 0)))
		var prototype_repair_shortfall := maxi(0, 2 - int(prototype_asteroid_operating_before.get("repair_material", 0)))
		var prototype_operating_shipments := (1 if prototype_cp_shortfall > 0 else 0) + (1 if prototype_repair_shortfall > 0 else 0)
		var prototype_earth_operating_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var prototype_earth_cp_target := prototype_cp_shortfall + prototype_operating_shipments * 3
		var prototype_earth_repair_target := prototype_repair_shortfall + prototype_operating_shipments * 2
		var prototype_cp_export := maxi(0, prototype_earth_cp_target - int(prototype_earth_operating_before.get("chemical_propellant", 0)))
		var prototype_repair_export := maxi(0, prototype_earth_repair_target - int(prototype_earth_operating_before.get("repair_material", 0)))
		if prototype_cp_export > 0:
			_export_to_location("chemical_propellant", prototype_cp_export, "J10 prototype Asteroid cobalt return propellant", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		if prototype_repair_export > 0:
			_export_to_location("repair_material", prototype_repair_export, "J10 prototype Asteroid cobalt return maintenance", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		if failures.size() > 0:
			return
		for prototype_operating_location_id in [EARTH_LOCATION_ID, "asteroid_belt"]:
			game.clear_location_logistics_policy(prototype_operating_location_id, "chemical_propellant")
			game.clear_location_logistics_policy(prototype_operating_location_id, "repair_material")
		if prototype_cp_shortfall > 0:
			_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "chemical_propellant", "DEMAND", 0, int(prototype_asteroid_operating_before.get("chemical_propellant", 0)) + prototype_cp_shortfall, 100, 1)), "public Logistics publishes the finite prototype Asteroid propellant reserve")
		if prototype_repair_shortfall > 0:
			_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "repair_material", "DEMAND", 0, int(prototype_asteroid_operating_before.get("repair_material", 0)) + prototype_repair_shortfall, 100, 1)), "public Logistics publishes the finite prototype Asteroid maintenance reserve")
		var prototype_operating_events := _advance(360000.0, "J10 prototype Asteroid cobalt return operating staging")
		var prototype_asteroid_operating_after: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
		_check((prototype_operating_shipments == 0 or _events_have_type(prototype_operating_events, "ShipmentArrived")) and int(prototype_asteroid_operating_after.get("chemical_propellant", 0)) >= 3 and int(prototype_asteroid_operating_after.get("repair_material", 0)) >= 2, "public Logistics stages the exact two-hop Asteroid source costs for the bounded prototype cobalt return; available=%s events=%s" % [JSON.stringify(prototype_asteroid_operating_after), JSON.stringify(prototype_operating_events)])
		if failures.size() > 0:
			return
		for prototype_operating_location_id in [EARTH_LOCATION_ID, "asteroid_belt"]:
			game.clear_location_logistics_policy(prototype_operating_location_id, "chemical_propellant")
			game.clear_location_logistics_policy(prototype_operating_location_id, "repair_material")
		var prototype_earth_cobalt_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("cobalt_ore", 0))
		_export_to_location("cobalt_ore", 4, "J10 bounded prototype steel cobalt feed", asteroid_world_id, asteroid_steel_depot_id)
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy("asteroid_belt", "cobalt_ore")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore")
		_check(bool(game.set_location_logistics_policy("asteroid_belt", "cobalt_ore", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore", "DEMAND", 0, prototype_earth_cobalt_before + 4, 100, 1)), "public Logistics publishes the bounded prototype cobalt return")
		var prototype_cobalt_return_events := _advance(360000.0, "J10 prototype Asteroid-Earth cobalt return")
		var prototype_earth_cobalt_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var prototype_asteroid_cobalt_after: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
		_check(_events_have_type(prototype_cobalt_return_events, "ShipmentArrived") and int(prototype_earth_cobalt_after.get("cobalt_ore", 0)) >= prototype_earth_cobalt_before + 4, "public Logistics returns the exact four Asteroid cobalt ore needed for prototype steel; earth_before=%d earth_after=%s asteroid_after=%s events=%s blockers=%s" % [prototype_earth_cobalt_before, JSON.stringify(prototype_earth_cobalt_after), JSON.stringify(prototype_asteroid_cobalt_after), JSON.stringify(prototype_cobalt_return_events), JSON.stringify(game.active_blockers())])
		if failures.size() > 0:
			return
		_import_from_location("cobalt_ore", 4, cruiser_bulk_depot_id, "J10 prototype steel cobalt Factory feed")
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy("asteroid_belt", "cobalt_ore")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore")
		_isolate_power_for_targets([cruiser_foundry_id], jovian_research_power_id)
		_ensure_connection("POWER", jovian_research_power_id, cruiser_foundry_id, "")
		var prototype_cobalt_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_cobalt"})
		_check(bool(prototype_cobalt_recipe.get("accepted", false)), "Factory protocol selects the two-cycle prototype cobalt-refinement recipe")
		_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", cruiser_bulk_depot_id)
		_clear_competing_cargo_outputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
		_clear_competing_cargo_outputs(cruiser_foundry_id, "industrial_waste", cruiser_bulk_depot_id)
		_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "industrial_waste", cruiser_foundry_id)
		_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ore")
		_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "cobalt_ingot")
		_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "industrial_waste")
		_advance(1000.0, "J10 exact prototype cobalt input staging")
		_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", "")
		var prototype_cobalt_events := _advance(30000.0, "J10 two-cycle prototype cobalt refinement")
		prototype_material_bulk = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
		_check(_events_have_recipe(prototype_cobalt_events, "grid_refine_cobalt") and int(prototype_material_bulk.get("inventory", {}).get("cobalt_ingot", 0)) >= 2, "Earth Factory physically refines the exact cobalt input for two prototype steel composites; bulk=%s" % JSON.stringify(prototype_material_bulk.get("inventory", {})))
		if failures.size() > 0:
			return

	prototype_material_bulk = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var prototype_steel_before := int(prototype_material_bulk.get("inventory", {}).get("steel_composite", 0))
	if prototype_steel_before < 2:
		var prototype_starter := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		_check(int(prototype_starter.get("inventory", {}).get("iron_ingot", 0)) >= 4 and int(prototype_material_bulk.get("inventory", {}).get("cobalt_ingot", 0)) >= 2, "Earth Factory retains Starter iron and explicit Bulk cobalt for the exact two-cycle prototype steel batch; starter=%s bulk=%s" % [JSON.stringify(prototype_starter.get("inventory", {})), JSON.stringify(prototype_material_bulk.get("inventory", {}))])
		if failures.size() > 0:
			return
		_isolate_power_for_targets([cruiser_foundry_id], jovian_research_power_id)
		_ensure_connection("POWER", jovian_research_power_id, cruiser_foundry_id, "")
		var prototype_steel_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_steel_electric"})
		_check(bool(prototype_steel_recipe.get("accepted", false)), "Factory protocol selects the exact two-cycle prototype electric-steel recipe")
		_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", STARTER_DEPOT_ID)
		_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
		_clear_competing_cargo_outputs(cruiser_foundry_id, "steel_composite", cruiser_bulk_depot_id)
		_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "steel_composite", cruiser_foundry_id)
		_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_foundry_id, "iron_ingot")
		_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ingot")
		_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "steel_composite")
		_advance(1000.0, "J10 exact prototype steel input staging")
		_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", "")
		_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", "")
		var prototype_steel_events := _advance(30000.0, "J10 two-cycle prototype electric steelmaking")
		prototype_material_bulk = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
		_check(_events_have_recipe(prototype_steel_events, "grid_refine_steel_electric") and int(prototype_material_bulk.get("inventory", {}).get("steel_composite", 0)) >= prototype_steel_before + 2, "Earth Factory physically retains the exact two-composite prototype steel batch; bulk=%s" % JSON.stringify(prototype_material_bulk.get("inventory", {})))
		if failures.size() > 0:
			return
	var thorium_fuel_recipe := _factory_command("SET_RECIPE", {"entity_id":prototype_high_energy_id, "recipe_id":"grid_prepare_thorium_fuel"})
	_check(bool(thorium_fuel_recipe.get("accepted", false)), "Factory protocol selects the exact two-cycle thorium-fuel recipe for Jovian Operations prototype service")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "thorium_ore", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(prototype_high_energy_id, "thorium_fuel", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(prototype_high_energy_id, "industrial_waste", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "industrial_waste", prototype_high_energy_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, prototype_high_energy_id, "thorium_ore")
	_ensure_connection("CARGO", prototype_high_energy_id, cruiser_bulk_depot_id, "thorium_fuel")
	_ensure_connection("CARGO", prototype_high_energy_id, cruiser_bulk_depot_id, "industrial_waste")
	_isolate_power_for_targets([jovian_research_complex_id, fusion_test_rig_id, prototype_high_energy_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, jovian_research_complex_id, "")
	_ensure_connection("POWER", jovian_research_power_id, fusion_test_rig_id, "")
	_ensure_connection("POWER", jovian_research_power_id, prototype_high_energy_id, "")
	_advance(1000.0, "J10 thorium fuel input staging")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "thorium_ore", "")
	var thorium_fuel_events := _advance(60000.0, "J10 two-cycle thorium-fuel preparation")
	var prototype_service_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(thorium_fuel_events, "grid_prepare_thorium_fuel") and int(prototype_service_bulk.get("inventory", {}).get("thorium_fuel", 0)) >= 2, "High-Energy Electronics Works physically prepares two thorium fuel units from the returned Lunar ore; bulk=%s" % JSON.stringify(prototype_service_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	var fusion_service_recipe := _factory_command("SET_RECIPE", {"entity_id":prototype_high_energy_id, "recipe_id":"grid_fabricate_fusion_service_component"})
	_check(bool(fusion_service_recipe.get("accepted", false)), "Factory protocol selects the two-cycle fusion-service-component recipe after the public prototype spillover")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "steel_composite", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(prototype_high_energy_id, "quantum_component", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(prototype_high_energy_id, "thorium_fuel", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(prototype_high_energy_id, "fusion_service_component", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, prototype_high_energy_id, "steel_composite")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, prototype_high_energy_id, "quantum_component")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, prototype_high_energy_id, "thorium_fuel")
	_ensure_connection("CARGO", prototype_high_energy_id, cruiser_bulk_depot_id, "fusion_service_component")
	_advance(1000.0, "J10 fusion-service component input staging")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "steel_composite", "")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "quantum_component", "")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "thorium_fuel", "")
	var fusion_service_events := _advance(60000.0, "J10 two-cycle fusion-service-component fabrication")
	prototype_service_bulk = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(fusion_service_events, "grid_fabricate_fusion_service_component") and int(prototype_service_bulk.get("inventory", {}).get("fusion_service_component", 0)) >= 4, "High-Energy Electronics Works physically fabricates four fusion service components from exact thorium, steel, and quantum custody; bulk=%s" % JSON.stringify(prototype_service_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	_export_to_location("fusion_service_component", 2, "J10 Jovian Operations prototype research custody", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	prototype_service_bulk = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(int(prototype_service_bulk.get("inventory", {}).get("fusion_service_component", 0)) >= 2, "Earth Factory retains two physical fusion service components for the later Energy Array after exporting the exact two-unit Jovian Operations prototype cost; bulk=%s" % JSON.stringify(prototype_service_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	var prototype_resume_runtime: Dictionary = game.research_runtime_snapshot()
	_check(str(prototype_resume_runtime.get("project_id", "")) == "research_jovian_operations" and str(prototype_resume_runtime.get("stage_id", "")) == "prototype" and str(prototype_resume_runtime.get("status", "")) == "RUNNING", "the public research runtime resumes the exact Jovian Operations prototype only after its exported physical service cost is available; runtime=%s" % JSON.stringify(prototype_resume_runtime))
	if failures.size() > 0:
		return
	var jovian_prototype_events := _advance(60000.0, "J10 Jovian Operations fusion-service prototype")
	jovian_research_runtime = game.research_runtime_snapshot()
	var jovian_field_test_blocker := jovian_research_runtime.get("blocker", {}) as Dictionary
	var jovian_field_test_requirement := jovian_field_test_blocker.get("requirement", {}) as Dictionary
	_check(_events_have_type(jovian_prototype_events, "ResearchStageCompleted") and str(jovian_research_runtime.get("project_id", "")) == "research_jovian_operations" and str(jovian_research_runtime.get("stage_id", "")) == "field_test" and str(jovian_research_runtime.get("status", "")) == "BLOCKED" and str(jovian_field_test_blocker.get("primary_reason", "")) == "FIELD_TEST_REQUIRED" and str(jovian_field_test_requirement.get("type", "")) == "own_facility" and str(jovian_field_test_requirement.get("id", "")) == "energy_array", "Jovian Operations completes prototype from public physical service custody and reaches field_test blocked only by the canonical Energy Array facility; runtime=%s" % JSON.stringify(jovian_research_runtime))
	if failures.size() > 0:
		return

	# The field test's Fusion Power Array is not granted by the Jovian reward.
	# Build its exact material manifest through the same bounded public Factory and
	# Logistics paths used for the earlier Operations stages.  The two ensuing
	# rare-earth returns are SPECIAL-safe, are immediately imported into the
	# explicit Earth Bulk depot, and consume the physical Lunar operating reserve
	# staged for this continuing player-facing chain.
	var array_lunar_operating: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	var array_rare_cp_shortfall := maxi(0, 2 - int(array_lunar_operating.get("chemical_propellant", 0)))
	if array_rare_cp_shortfall > 0:
		# Each Lunar return spends the source-side route propellant.  Stage only the
		# missing single unit through public Logistics, while also preserving the
		# Earth-origin propellant and maintenance that dispatch this replenishment.
		var array_rare_earth_location: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var array_rare_origin_cp_shortfall := maxi(0, 1 - int(array_rare_earth_location.get("chemical_propellant", 0)))
		var array_rare_origin_repair_shortfall := maxi(0, 1 - int(array_rare_earth_location.get("repair_material", 0)))
		if array_rare_origin_cp_shortfall > 0:
			_export_to_location("chemical_propellant", array_rare_origin_cp_shortfall, "J10 Energy Array Lunar rare-return replenishment dispatch propellant", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		if array_rare_origin_repair_shortfall > 0:
			_export_to_location("repair_material", array_rare_origin_repair_shortfall, "J10 Energy Array Lunar rare-return replenishment dispatch maintenance", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		_export_to_location("chemical_propellant", array_rare_cp_shortfall, "J10 Energy Array Lunar rare-return source propellant")
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
		game.clear_location_logistics_policy("lunar_space", "chemical_propellant")
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "chemical_propellant", "DEMAND", 0, int(array_lunar_operating.get("chemical_propellant", 0)) + array_rare_cp_shortfall, 100, 1)), "public Logistics stages the exact missing Lunar rare-return propellant")
		var array_rare_cp_events := _advance(180000.0, "J10 Energy Array Lunar rare-return propellant staging")
		array_lunar_operating = _snapshot(lunar_world_id).get("location_available_inventory", {})
		_check(_events_have_type(array_rare_cp_events, "ShipmentArrived") and int(array_lunar_operating.get("chemical_propellant", 0)) >= 2, "public Logistics delivers the exact missing Lunar source propellant before the two bounded Energy Array rare returns; available=%s events=%s" % [JSON.stringify(array_lunar_operating), JSON.stringify(array_rare_cp_events)])
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
		game.clear_location_logistics_policy("lunar_space", "chemical_propellant")
		if failures.size() > 0:
			return
	_check(int(array_lunar_operating.get("chemical_propellant", 0)) >= 2 and int(array_lunar_operating.get("repair_material", 0)) >= 2, "Lunar Location retains the exact two bounded return-route operating manifests for the Energy Array quantum feed; available=%s" % JSON.stringify(array_lunar_operating))
	if failures.size() > 0:
		return
	_ensure_connection("POWER", str(lunar_power.get("id", "")), rare_earth_mine_id, "", lunar_world_id)
	_clear_competing_cargo_outputs(rare_earth_mine_id, "rare_earth_concentrate", lunar_depot_id, lunar_world_id)
	_ensure_connection("CARGO", rare_earth_mine_id, lunar_depot_id, "rare_earth_concentrate", lunar_world_id)
	# The prior prototype run left a valid Bulk-to-Assembly rare-earth port alive.
	# Remove it before the two public return windows so those exact imported units
	# remain auditable in Bulk rather than silently entering a blocked machine.
	var array_rare_stale_links: Array = []
	for array_rare_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var array_rare_link := array_rare_link_value as Dictionary
		if str(array_rare_link.get("kind", "")) == "CARGO" and str(array_rare_link.get("source_id", "")) == cruiser_bulk_depot_id and str(array_rare_link.get("target_id", "")) == quantum_assembly_id and str(array_rare_link.get("item_id", "")) == "rare_earth_concentrate":
			array_rare_stale_links.append(array_rare_link)
	_check(array_rare_stale_links.size() == 1, "public Earth Factory snapshot exposes the single retained Bulk-to-Assembly rare-earth CARGO link that must be removed before Energy Array custody staging; links=%s" % JSON.stringify(array_rare_stale_links))
	if failures.size() > 0:
		return
	_clear_competing_cargo_outputs(cruiser_bulk_depot_id, "rare_earth_concentrate", "")
	var array_rare_links_after_cleanup: Array = []
	for array_rare_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var array_rare_link := array_rare_link_value as Dictionary
		if str(array_rare_link.get("kind", "")) == "CARGO" and str(array_rare_link.get("source_id", "")) == cruiser_bulk_depot_id and str(array_rare_link.get("target_id", "")) == quantum_assembly_id and str(array_rare_link.get("item_id", "")) == "rare_earth_concentrate":
			array_rare_links_after_cleanup.append(array_rare_link)
	_check(array_rare_links_after_cleanup.is_empty(), "public Factory REMOVE_LINK leaves no Bulk-to-Assembly rare-earth port before the two auditable Energy Array staging batches; links=%s" % JSON.stringify(array_rare_links_after_cleanup))
	var array_rare_assembly_input_before := int(_entity(_snapshot(EARTH_WORLD_ID), quantum_assembly_id).get("inputs", {}).get("rare_earth_concentrate", 0))
	var array_rare_bulk_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("rare_earth_concentrate", 0))
	_check(array_rare_bulk_before == 0, "Energy Array starts its two public Lunar rare-earth returns with no pre-existing Bulk rare-earth inventory; bulk=%s" % JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {})))
	if failures.size() > 0:
		return
	var array_rare_return_events: Array = []
	for array_rare_batch_index in [1, 2]:
		var array_rare_depot := _entity(_snapshot(lunar_world_id), lunar_depot_id)
		if int(array_rare_depot.get("inventory", {}).get("rare_earth_concentrate", 0)) < 2:
			var array_rare_extract_events := _advance(1000.0, "J10 Energy Array Lunar rare-earth extraction batch %d" % array_rare_batch_index)
			array_rare_depot = _entity(_snapshot(lunar_world_id), lunar_depot_id)
			_check(array_rare_extract_events.any(func(event_value):
				var array_rare_event := event_value as Dictionary
				return str(array_rare_event.get("type", "")) == "FactoryResourceExtracted" and str(array_rare_event.get("entity_id", "")) == rare_earth_mine_id and str(array_rare_event.get("resource_id", "")) == "rare_earth_concentrate"
			) and int(array_rare_depot.get("inventory", {}).get("rare_earth_concentrate", 0)) >= 2, "the powered Lunar rare-earth mine physically recovers the exact Energy Array quantum batch when prior custody is depleted; depot=%s events=%s" % [JSON.stringify(array_rare_depot.get("inventory", {})), JSON.stringify(array_rare_extract_events)])
		if failures.size() > 0:
			return
		_export_to_location("rare_earth_concentrate", 2, "J10 Energy Array quantum feed batch %d" % array_rare_batch_index, lunar_world_id, lunar_depot_id)
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy("lunar_space", "rare_earth_concentrate")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate")
		var array_earth_rare_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("rare_earth_concentrate", 0))
		_check(bool(game.set_location_logistics_policy("lunar_space", "rare_earth_concentrate", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate", "DEMAND", 0, array_earth_rare_before + 2, 100, 1)), "public Logistics publishes Energy Array rare-earth return batch %d" % array_rare_batch_index)
		var array_rare_batch_events := _advance(180000.0, "J10 Energy Array Lunar rare-earth logistics batch %d" % array_rare_batch_index)
		array_rare_return_events.append_array(array_rare_batch_events)
		var array_earth_rare_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(_events_have_type(array_rare_batch_events, "ShipmentArrived") and int(array_earth_rare_after.get("rare_earth_concentrate", 0)) >= array_earth_rare_before + 2, "public Logistics returns the complete two-unit SPECIAL-safe Energy Array rare-earth batch %d to Earth custody; available=%s events=%s" % [array_rare_batch_index, JSON.stringify(array_earth_rare_after), JSON.stringify(array_rare_batch_events)])
		if failures.size() > 0:
			return
		_import_from_location("rare_earth_concentrate", 2, cruiser_bulk_depot_id, "J10 Energy Array quantum Factory staging batch %d" % array_rare_batch_index)
		game.clear_location_logistics_policy("lunar_space", "rare_earth_concentrate")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "rare_earth_concentrate")
		var array_rare_bulk_after_batch := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
		var array_rare_assembly_after_batch := _entity(_snapshot(EARTH_WORLD_ID), quantum_assembly_id)
		_check(int(array_rare_bulk_after_batch.get("inventory", {}).get("rare_earth_concentrate", 0)) == array_rare_batch_index * 2 and int(array_rare_assembly_after_batch.get("inputs", {}).get("rare_earth_concentrate", 0)) == array_rare_assembly_input_before, "Energy Array rare-earth batch %d remains in explicit Bulk custody after the public import and does not refill the disconnected Assembly input; bulk=%s assembly=%s" % [array_rare_batch_index, JSON.stringify(array_rare_bulk_after_batch.get("inventory", {})), JSON.stringify(array_rare_assembly_after_batch.get("inputs", {}))])
		if failures.size() > 0:
			return
	_check(_events_have_type(array_rare_return_events, "ShipmentArrived") and int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("rare_earth_concentrate", 0)) >= 4, "Energy Array retains four physically returned Lunar rare-earth units in explicit Earth Factory custody for its quantum manifest")
	if failures.size() > 0:
		return
	_isolate_power_for_targets([quantum_assembly_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, quantum_assembly_id, "")
	var array_quantum_recipe := _factory_command("SET_RECIPE", {"entity_id":quantum_assembly_id, "recipe_id":"grid_fabricate_quantum_component"})
	_check(bool(array_quantum_recipe.get("accepted", false)), "Factory protocol selects the Energy Array's four-unit quantum component recipe")
	_clear_competing_cargo_inputs(quantum_assembly_id, "rare_earth_concentrate", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(quantum_assembly_id, "quantum_component", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, quantum_assembly_id, "rare_earth_concentrate")
	_ensure_connection("CARGO", quantum_assembly_id, cruiser_bulk_depot_id, "quantum_component")
	var array_quantum_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("quantum_component", 0))
	_advance(1000.0, "J10 Energy Array quantum input staging")
	_clear_competing_cargo_inputs(quantum_assembly_id, "rare_earth_concentrate", "")
	var array_quantum_events := _advance(120000.0, "J10 Energy Array four-unit quantum fabrication")
	var array_quantum_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(array_quantum_events, "grid_fabricate_quantum_component") and int(array_quantum_bulk.get("inventory", {}).get("quantum_component", 0)) >= array_quantum_before + 4, "Assembly Array turns the exact returned Lunar rare-earth manifest and resident copper/electronics buffers into four Energy Array quantum components; bulk=%s assembly=%s" % [JSON.stringify(array_quantum_bulk.get("inventory", {})), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), quantum_assembly_id))])
	if failures.size() > 0:
		return

	# The Array needs five titanium alloy in total: two for heavy structural
	# sections and three for power buses.  Reuse the surveyed, powered Lunar
	# titanium chain and return its exact complete manifest before production on
	# Earth consumes any of it.
	var array_lunar_snapshot := _snapshot(lunar_world_id)
	var array_titanium_foundry := _entity_with_recipe(array_lunar_snapshot, "grid_refine_titanium")
	if array_titanium_foundry.is_empty():
		array_titanium_foundry = _entity_with_definition(array_lunar_snapshot, "grid_arc_smelter")
	var array_titanium_mine := _entity_with_resource(array_lunar_snapshot, "titanium_ore")
	_check(not array_titanium_foundry.is_empty() and not array_titanium_mine.is_empty(), "Lunar Factory exposes the surveyed titanium mine and reusable Arc Smelter for the Energy Array titanium manifest")
	if failures.size() > 0:
		return
	var array_titanium_legacy_smelters := _entities_with_definition(array_lunar_snapshot, "grid_arc_smelter")
	var array_titanium_legacy_inputs: Dictionary = {}
	for array_titanium_legacy_smelter_value in array_titanium_legacy_smelters:
		var array_titanium_legacy_smelter := array_titanium_legacy_smelter_value as Dictionary
		array_titanium_legacy_inputs[str(array_titanium_legacy_smelter.get("id", ""))] = (array_titanium_legacy_smelter.get("inputs", {}) as Dictionary).duplicate(true)
	_check(array_titanium_legacy_inputs.size() == 2 and array_titanium_legacy_inputs.values().all(func(inputs_value):
		var array_titanium_legacy_input := inputs_value as Dictionary
		return int(array_titanium_legacy_input.get("titanium_ore", 0)) == 48 and int(array_titanium_legacy_input.get("iron_ingot", 0)) == 0
	), "the public Lunar snapshot records both historic saturated Arc-Smelter buffers before the clean-line recovery; inputs=%s" % JSON.stringify(array_titanium_legacy_inputs))
	if failures.size() > 0:
		return
	var array_titanium_legacy_depot := _entity(_snapshot(lunar_world_id), lunar_depot_id)
	var array_titanium_current := int(array_titanium_legacy_depot.get("inventory", {}).get("titanium_alloy", 0))
	var array_titanium_needed := maxi(0, 5 - array_titanium_current)
	_check(array_titanium_current == 1 and array_titanium_needed == 4, "the fresh Energy Array titanium recovery has one historic alloy and therefore requires exactly four clean-line alloy cycles; legacy=%s current=%d needed=%d" % [JSON.stringify(array_titanium_legacy_depot.get("inventory", {})), array_titanium_current, array_titanium_needed])
	if failures.size() > 0:
		return
	var array_titanium_depot_id := lunar_depot_id
	var array_titanium_depot := array_titanium_legacy_depot
	if array_titanium_needed > 0:
		# Both pre-existing Lunar Arc Smelters retain full, incompatible titanium
		# input buffers.  Do not erase or reconfigure those physical buffers: stage
		# the finite Array alloy manifest through a third, newly constructed and
		# observable empty smelter instead.
		var array_titanium_smelter_iron_cost := 4
		var array_titanium_smelter_electronics_cost := 2
		var array_titanium_smelter_frame_cost := 1
		var array_titanium_iron_manifest := array_titanium_needed + 10 + array_titanium_smelter_iron_cost
		var array_titanium_iron_first_wave := 10 + array_titanium_smelter_iron_cost
		# The construction wave is three independent cargo manifests.  Do not
		# pre-stage the recipe wave's operating costs across the two long
		# construction advances: remote provider O&M may correctly settle them
		# before that fourth shipment is published.
		var array_titanium_construction_freight_shipments := 3
		# The preceding prototype reserves the final Assembly electronics in its
		# resident buffer, so replenish this distinct two-unit construction BOM via
		# one exact public Engineering-Works cycle before freight is published.
		var array_smelter_electronics_snapshot := _snapshot(EARTH_WORLD_ID)
		var array_smelter_electronics_works := _entity(array_smelter_electronics_snapshot, cruiser_electronics_id)
		var array_smelter_starter := _entity(array_smelter_electronics_snapshot, STARTER_DEPOT_ID)
		_check(not array_smelter_electronics_works.is_empty() and int(array_smelter_starter.get("inventory", {}).get("iron_ingot", 0)) >= array_titanium_iron_manifest + 1 and int(array_smelter_starter.get("inventory", {}).get("copper_ingot", 0)) >= 1, "Earth Factory retains the separate Engineering Works and exact Starter-depot iron-one/copper-one sources for one fresh Lunar-smelter electronics cycle plus its finite iron manifest; works=%s starter=%s" % [JSON.stringify(array_smelter_electronics_works), JSON.stringify(array_smelter_starter.get("inventory", {}))])
		if failures.size() > 0:
			return
		var array_smelter_electronics_before := int(array_smelter_starter.get("inventory", {}).get("electronics", 0))
		var array_smelter_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_electronics"})
		_check(bool(array_smelter_electronics_recipe.get("accepted", false)), "Factory protocol selects the one-cycle fresh Lunar-smelter electronics recipe")
		_isolate_power_for_targets([cruiser_electronics_id], jovian_research_power_id)
		_ensure_connection("POWER", jovian_research_power_id, cruiser_electronics_id, "")
		_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
		_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", "")
		_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "iron_ingot", cruiser_electronics_id)
		_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "copper_ingot", cruiser_electronics_id)
		_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", STARTER_DEPOT_ID)
		var array_smelter_iron_link := _factory_command("CONNECT_ENTITIES", {"link_kind":"CARGO", "source_id":STARTER_DEPOT_ID, "target_id":cruiser_electronics_id, "item_id":"iron_ingot", "capacity_per_second":1.0})
		var array_smelter_copper_link := _factory_command("CONNECT_ENTITIES", {"link_kind":"CARGO", "source_id":STARTER_DEPOT_ID, "target_id":cruiser_electronics_id, "item_id":"copper_ingot", "capacity_per_second":1.0})
		_check(bool(array_smelter_iron_link.get("accepted", false)) and bool(array_smelter_copper_link.get("accepted", false)), "public Factory CARGO commands connect exactly one iron and one copper per second into the fresh Lunar-smelter electronics cycle; iron=%s copper=%s" % [JSON.stringify(array_smelter_iron_link), JSON.stringify(array_smelter_copper_link)])
		if failures.size() > 0:
			return
		_ensure_connection("CARGO", cruiser_electronics_id, STARTER_DEPOT_ID, "electronics")
		_advance(1000.0, "J10 fresh Lunar-smelter electronics one-cycle input staging")
		var array_smelter_electronics_staged := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
		_check(int(array_smelter_electronics_staged.get("inputs", {}).get("iron_ingot", 0)) >= 1 and int(array_smelter_electronics_staged.get("inputs", {}).get("copper_ingot", 0)) >= 1, "public Factory links physically stage the Starter-depot copper-one and iron-one sources for the exact fresh Lunar-smelter electronics cycle; works=%s starter=%s" % [JSON.stringify(array_smelter_electronics_staged), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}))])
		if failures.size() > 0:
			return
		_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
		_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", "")
		var array_smelter_electronics_events := _advance(14000.0, "J10 exact one-cycle fresh Lunar-smelter electronics fabrication")
		var array_smelter_electronics_after := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		var array_smelter_electronics_completed := array_smelter_electronics_events.filter(func(event_value):
			var event := event_value as Dictionary
			return str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == EARTH_WORLD_ID and str(event.get("entity_id", "")) == cruiser_electronics_id and str(event.get("recipe_id", "")) == "grid_fabricate_electronics" and int((event.get("produced", {}) as Dictionary).get("electronics", 0)) == 2
		)
		_check(array_smelter_electronics_completed.size() == 1 and int(array_smelter_electronics_after.get("inventory", {}).get("electronics", 0)) == array_smelter_electronics_before + 2, "Earth Factory completes exactly one scoped Earth Engineering-Works electronics cycle with its two-unit output and retains it in explicit starter-depot custody; before=%d after=%s events=%s" % [array_smelter_electronics_before, JSON.stringify(array_smelter_electronics_after.get("inventory", {})), JSON.stringify(array_smelter_electronics_completed)])
		if failures.size() > 0:
			return
		var array_earth_iron_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var array_earth_cp_shortfall := maxi(0, array_titanium_construction_freight_shipments - int(array_earth_iron_available.get("chemical_propellant", 0)))
		var array_earth_repair_shortfall := maxi(0, array_titanium_construction_freight_shipments - int(array_earth_iron_available.get("repair_material", 0)))
		if array_earth_cp_shortfall > 0:
			_export_to_location("chemical_propellant", array_earth_cp_shortfall, "J10 Lunar Energy Array titanium and fresh-smelter freight propellant", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		if array_earth_repair_shortfall > 0:
			_export_to_location("repair_material", array_earth_repair_shortfall, "J10 Lunar Energy Array titanium and fresh-smelter freight maintenance", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		# The original Lunar Bulk depot is physically full with the preceding
		# rare-earth chain.  Build a second canonical BULK depot from Location
		# custody.  The finite Location staging accepts the Bulk-depot plus clean
		# smelter construction wave first; a second four-iron wave follows only
		# after both orders physically consume their construction materials.
		_export_to_location("iron_ingot", array_titanium_iron_first_wave, "J10 Lunar Energy Array canonical Bulk-depot and empty-smelter construction wave")
		_export_to_location("electronics", array_titanium_smelter_electronics_cost, "J10 fresh Lunar titanium-smelter construction")
		_export_to_location("structural_frame", array_titanium_smelter_frame_cost, "J10 fresh Lunar titanium-smelter construction")
		if failures.size() > 0:
			return
		for array_titanium_policy_location in [EARTH_LOCATION_ID, "lunar_space"]:
			game.clear_location_logistics_policy(array_titanium_policy_location, "iron_ingot")
			game.clear_location_logistics_policy(array_titanium_policy_location, "electronics")
			game.clear_location_logistics_policy(array_titanium_policy_location, "structural_frame")
			game.clear_location_logistics_policy(array_titanium_policy_location, "chemical_propellant")
			game.clear_location_logistics_policy(array_titanium_policy_location, "repair_material")
		var array_lunar_iron_before := int(_snapshot(lunar_world_id).get("location_available_inventory", {}).get("iron_ingot", 0))
		var array_lunar_electronics_before := int(_snapshot(lunar_world_id).get("location_available_inventory", {}).get("electronics", 0))
		var array_lunar_frames_before := int(_snapshot(lunar_world_id).get("location_available_inventory", {}).get("structural_frame", 0))
		var array_first_wave_earth_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(int(array_first_wave_earth_available.get("chemical_propellant", 0)) >= array_titanium_construction_freight_shipments and int(array_first_wave_earth_available.get("repair_material", 0)) >= array_titanium_construction_freight_shipments, "Earth Location visibly retains the exact three-dispatch construction-wave operating reserve before public Logistics settlement; available=%s" % JSON.stringify(array_first_wave_earth_available))
		if failures.size() > 0:
			return
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "electronics", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "structural_frame", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "iron_ingot", "DEMAND", 0, array_lunar_iron_before + array_titanium_iron_first_wave, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "electronics", "DEMAND", 0, array_lunar_electronics_before + array_titanium_smelter_electronics_cost, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "structural_frame", "DEMAND", 0, array_lunar_frames_before + array_titanium_smelter_frame_cost, 100, 1)), "public Logistics publishes the finite first Lunar Bulk-depot and fresh-smelter construction wave")
		var array_titanium_iron_events := _advance(240000.0, "J10 Earth-Lunar Energy Array first construction logistics wave")
		var array_lunar_iron_after: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
		var array_first_wave_dispatches := array_titanium_iron_events.filter(func(event_value):
			var event := event_value as Dictionary
			var cargo := event.get("cargo", {}) as Dictionary
			return str(event.get("type", "")) == "ShipmentDispatched" and str(event.get("origin", "")) == EARTH_LOCATION_ID and str(event.get("destination", "")) == "lunar_space" and ((int(cargo.get("iron_ingot", 0)) == array_titanium_iron_first_wave and cargo.size() == 1) or (int(cargo.get("electronics", 0)) == array_titanium_smelter_electronics_cost and cargo.size() == 1) or (int(cargo.get("structural_frame", 0)) == array_titanium_smelter_frame_cost and cargo.size() == 1))
		)
		var array_first_wave_iron_dispatches := array_first_wave_dispatches.filter(func(event_value): return int(((event_value as Dictionary).get("cargo", {}) as Dictionary).get("iron_ingot", 0)) == array_titanium_iron_first_wave)
		var array_first_wave_electronics_dispatches := array_first_wave_dispatches.filter(func(event_value): return int(((event_value as Dictionary).get("cargo", {}) as Dictionary).get("electronics", 0)) == array_titanium_smelter_electronics_cost)
		var array_first_wave_frame_dispatches := array_first_wave_dispatches.filter(func(event_value): return int(((event_value as Dictionary).get("cargo", {}) as Dictionary).get("structural_frame", 0)) == array_titanium_smelter_frame_cost)
		var array_first_wave_earth_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(array_first_wave_dispatches.size() == array_titanium_construction_freight_shipments and array_first_wave_iron_dispatches.size() == 1 and array_first_wave_electronics_dispatches.size() == 1 and array_first_wave_frame_dispatches.size() == 1 and int(array_lunar_iron_after.get("iron_ingot", 0)) >= array_lunar_iron_before + array_titanium_iron_first_wave and int(array_lunar_iron_after.get("electronics", 0)) >= array_lunar_electronics_before + array_titanium_smelter_electronics_cost and int(array_lunar_iron_after.get("structural_frame", 0)) >= array_lunar_frames_before + array_titanium_smelter_frame_cost and int(array_first_wave_earth_after.get("chemical_propellant", 0)) <= int(array_first_wave_earth_available.get("chemical_propellant", 0)) - array_titanium_construction_freight_shipments and int(array_first_wave_earth_after.get("repair_material", 0)) <= int(array_first_wave_earth_available.get("repair_material", 0)) - array_titanium_construction_freight_shipments, "public Logistics dispatches one exact iron, electronics, and frame construction cargo map, delivers their capacity-safe custody, and visibly settles the three source operating costs; lunar=%s earth_before=%s earth_after=%s dispatches=%s events=%s" % [JSON.stringify(array_lunar_iron_after), JSON.stringify(array_first_wave_earth_available), JSON.stringify(array_first_wave_earth_after), JSON.stringify(array_first_wave_dispatches), JSON.stringify(array_titanium_iron_events)])
		if failures.size() > 0:
			return
		for array_titanium_policy_location in [EARTH_LOCATION_ID, "lunar_space"]:
			game.clear_location_logistics_policy(array_titanium_policy_location, "iron_ingot")
			game.clear_location_logistics_policy(array_titanium_policy_location, "electronics")
			game.clear_location_logistics_policy(array_titanium_policy_location, "structural_frame")
		# The original Lunar solar array occupies the earlier (224, 0) candidate.
		# Use a distant storage-only origin and prove against the current public
		# entity/order/resource footprints that its 20x20 depot footprint is clear.
		var array_titanium_storage_origin := {"x":320, "y":160}
		var array_titanium_storage_conflicts: Array = []
		var array_titanium_placement_snapshot := _snapshot(lunar_world_id)
		for array_titanium_placement_collection in ["entities", "construction_orders", "resource_fields"]:
			for array_titanium_occupant_value in array_titanium_placement_snapshot.get(array_titanium_placement_collection, []):
				var array_titanium_occupant := array_titanium_occupant_value as Dictionary
				var array_titanium_occupant_footprint: Dictionary = array_titanium_occupant.get("footprint", {})
				var array_titanium_occupant_origin: Dictionary = array_titanium_occupant_footprint.get("origin", {})
				var array_titanium_occupant_size: Dictionary = array_titanium_occupant_footprint.get("size", {})
				var array_titanium_x_overlaps := int(array_titanium_storage_origin.get("x", 0)) < int(array_titanium_occupant_origin.get("x", 0)) + int(array_titanium_occupant_size.get("x", 0)) and int(array_titanium_occupant_origin.get("x", 0)) < int(array_titanium_storage_origin.get("x", 0)) + 20
				var array_titanium_y_overlaps := int(array_titanium_storage_origin.get("y", 0)) < int(array_titanium_occupant_origin.get("y", 0)) + int(array_titanium_occupant_size.get("y", 0)) and int(array_titanium_occupant_origin.get("y", 0)) < int(array_titanium_storage_origin.get("y", 0)) + 20
				if array_titanium_x_overlaps and array_titanium_y_overlaps:
					array_titanium_storage_conflicts.append({"collection":array_titanium_placement_collection, "id":str(array_titanium_occupant.get("id", "")), "footprint":array_titanium_occupant_footprint})
		_check(array_titanium_storage_conflicts.is_empty(), "public Lunar Factory snapshot confirms the distant canonical Bulk-depot origin is outside every current entity, order, and surveyed-resource footprint; origin=%s conflicts=%s" % [JSON.stringify(array_titanium_storage_origin), JSON.stringify(array_titanium_storage_conflicts)])
		if failures.size() > 0:
			return
		var array_titanium_storage_queued := _factory_command("QUEUE_CONSTRUCTION", {"definition_id":"grid_bulk_depot", "recipe_id":"", "origin":array_titanium_storage_origin, "priority":50}, lunar_world_id)
		var array_titanium_storage_order_id := str(array_titanium_storage_queued.get("result", {}).get("order_id", ""))
		array_titanium_depot_id = str(array_titanium_storage_queued.get("result", {}).get("entity_id", ""))
		_check(bool(array_titanium_storage_queued.get("accepted", false)) and not array_titanium_storage_order_id.is_empty() and not array_titanium_depot_id.is_empty(), "Factory queues a second canonical Lunar Bulk depot instead of overflowing the full rare-earth store; result=%s" % JSON.stringify(array_titanium_storage_queued))
		if failures.size() > 0:
			return
		var array_titanium_storage_funding := _factory_command("FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":array_titanium_storage_order_id}, lunar_world_id)
		_check(bool(array_titanium_storage_funding.get("accepted", false)) and bool(array_titanium_storage_funding.get("result", {}).get("fully_funded", false)) and int((array_titanium_storage_funding.get("result", {}).get("moved", {}) as Dictionary).get("iron_ingot", 0)) == 10, "same-location public funding consumes the exact ten-iron canonical Lunar Bulk-depot cost; result=%s" % JSON.stringify(array_titanium_storage_funding))
		if failures.size() > 0:
			return
		var array_titanium_storage_events := _advance(120000.0, "J10 second canonical Lunar Bulk-depot construction")
		array_titanium_depot = _entity(_snapshot(lunar_world_id), array_titanium_depot_id)
		_check(array_titanium_storage_events.any(func(event_value):
			var array_titanium_storage_event := event_value as Dictionary
			return str(array_titanium_storage_event.get("type", "")) == "FactoryConstructionCompleted" and str(array_titanium_storage_event.get("entity_id", "")) == array_titanium_depot_id and str(array_titanium_storage_event.get("definition_id", "")) == "grid_bulk_depot"
		) and str(array_titanium_depot.get("definition_id", "")) == "grid_bulk_depot", "Factory physically completes the separate canonical Lunar Bulk depot for Energy Array titanium custody; depot=%s events=%s" % [JSON.stringify(array_titanium_depot), JSON.stringify(array_titanium_storage_events)])
		if failures.size() > 0:
			return
		# The two existing Arc Smelters are not discarded: their compatible
		# configuration preserves the full historic ore buffers while this distant
		# clean line receives the exact finite construction BOM in Location custody.
		var array_titanium_foundry_origin := {"x":360, "y":160}
		var array_titanium_foundry_conflicts: Array = []
		var array_titanium_foundry_placement_snapshot := _snapshot(lunar_world_id)
		for array_titanium_foundry_collection in ["entities", "construction_orders", "resource_fields"]:
			for array_titanium_foundry_occupant_value in array_titanium_foundry_placement_snapshot.get(array_titanium_foundry_collection, []):
				var array_titanium_foundry_occupant := array_titanium_foundry_occupant_value as Dictionary
				var array_titanium_foundry_footprint: Dictionary = array_titanium_foundry_occupant.get("footprint", {})
				var array_titanium_foundry_occupant_origin: Dictionary = array_titanium_foundry_footprint.get("origin", {})
				var array_titanium_foundry_occupant_size: Dictionary = array_titanium_foundry_footprint.get("size", {})
				var array_titanium_foundry_x_overlaps := int(array_titanium_foundry_origin.get("x", 0)) < int(array_titanium_foundry_occupant_origin.get("x", 0)) + int(array_titanium_foundry_occupant_size.get("x", 0)) and int(array_titanium_foundry_occupant_origin.get("x", 0)) < int(array_titanium_foundry_origin.get("x", 0)) + 16
				var array_titanium_foundry_y_overlaps := int(array_titanium_foundry_origin.get("y", 0)) < int(array_titanium_foundry_occupant_origin.get("y", 0)) + int(array_titanium_foundry_occupant_size.get("y", 0)) and int(array_titanium_foundry_occupant_origin.get("y", 0)) < int(array_titanium_foundry_origin.get("y", 0)) + 12
				if array_titanium_foundry_x_overlaps and array_titanium_foundry_y_overlaps:
					array_titanium_foundry_conflicts.append({"collection":array_titanium_foundry_collection, "id":str(array_titanium_foundry_occupant.get("id", "")), "footprint":array_titanium_foundry_footprint})
		_check(array_titanium_foundry_conflicts.is_empty(), "public Lunar Factory snapshot proves the clean Energy Array titanium Arc-Smelter footprint is free before queueing; origin=%s conflicts=%s" % [JSON.stringify(array_titanium_foundry_origin), JSON.stringify(array_titanium_foundry_conflicts)])
		if failures.size() > 0:
			return
		var array_titanium_foundry_queued := _factory_command("QUEUE_CONSTRUCTION", {"definition_id":"grid_arc_smelter", "recipe_id":"grid_refine_titanium", "origin":array_titanium_foundry_origin, "priority":50}, lunar_world_id)
		var array_titanium_foundry_order_id := str(array_titanium_foundry_queued.get("result", {}).get("order_id", ""))
		var array_titanium_foundry_id := str(array_titanium_foundry_queued.get("result", {}).get("entity_id", ""))
		_check(bool(array_titanium_foundry_queued.get("accepted", false)) and not array_titanium_foundry_order_id.is_empty() and not array_titanium_foundry_id.is_empty(), "Factory queues an empty third Lunar Arc Smelter instead of mutating either saturated historic buffer; result=%s" % JSON.stringify(array_titanium_foundry_queued))
		if failures.size() > 0:
			return
		var array_titanium_foundry_funding := _factory_command("FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":array_titanium_foundry_order_id}, lunar_world_id)
		var array_titanium_foundry_moved: Dictionary = array_titanium_foundry_funding.get("result", {}).get("moved", {})
		_check(bool(array_titanium_foundry_funding.get("accepted", false)) and bool(array_titanium_foundry_funding.get("result", {}).get("fully_funded", false)) and int(array_titanium_foundry_moved.get("iron_ingot", 0)) == array_titanium_smelter_iron_cost and int(array_titanium_foundry_moved.get("electronics", 0)) == array_titanium_smelter_electronics_cost and int(array_titanium_foundry_moved.get("structural_frame", 0)) == array_titanium_smelter_frame_cost, "same-location public funding consumes the exact clean Lunar Arc-Smelter BOM without altering historic buffers; result=%s" % JSON.stringify(array_titanium_foundry_funding))
		if failures.size() > 0:
			return
		var array_titanium_foundry_construction_events := _advance(240000.0, "J10 clean Lunar titanium Arc-Smelter construction")
		array_titanium_foundry = _entity(_snapshot(lunar_world_id), array_titanium_foundry_id)
		_check(array_titanium_foundry_construction_events.any(func(event_value):
			var array_titanium_foundry_event := event_value as Dictionary
			return str(array_titanium_foundry_event.get("type", "")) == "FactoryConstructionCompleted" and str(array_titanium_foundry_event.get("entity_id", "")) == array_titanium_foundry_id and str(array_titanium_foundry_event.get("definition_id", "")) == "grid_arc_smelter"
		) and str(array_titanium_foundry.get("definition_id", "")) == "grid_arc_smelter" and (array_titanium_foundry.get("inputs", {}) as Dictionary).is_empty(), "Factory completes an empty clean Lunar Arc Smelter for the Energy Array alloy chain; foundry=%s events=%s" % [JSON.stringify(array_titanium_foundry), JSON.stringify(array_titanium_foundry_construction_events)])
		if failures.size() > 0:
			return
		# Both construction orders have now consumed wave one's complete manifest,
		# releasing Lunar BULK staging before a final, four-iron recipe-only wave.
		# Replenish this fourth shipment's source costs only after the long
		# constructions have completed.  The public projection includes continuous
		# maintenance due in the first dispatch boundary, so the Factory exports a
		# physical gross shortfall rather than assuming one nominal unit survives.
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
		game.clear_location_logistics_policy("lunar_space", "chemical_propellant")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "repair_material")
		game.clear_location_logistics_policy("lunar_space", "repair_material")
		var array_titanium_second_wave_earth_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var array_titanium_second_wave_cp_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", 1, 5000.0)
		var array_titanium_second_wave_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", 1, 5000.0)
		var array_titanium_second_wave_cp_export := maxi(0, int(array_titanium_second_wave_cp_projection.get("gross_production_target", 0)) - int(array_titanium_second_wave_earth_available.get("chemical_propellant", 0)))
		var array_titanium_second_wave_repair_export := maxi(0, int(array_titanium_second_wave_repair_projection.get("gross_production_target", 0)) - int(array_titanium_second_wave_earth_available.get("repair_material", 0)))
		if array_titanium_second_wave_cp_export > 0:
			_export_to_location("chemical_propellant", array_titanium_second_wave_cp_export, "J10 separate Lunar Bulk titanium recipe-wave gross propellant recovery", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		if array_titanium_second_wave_repair_export > 0:
			_export_to_location("repair_material", array_titanium_second_wave_repair_export, "J10 separate Lunar Bulk titanium recipe-wave gross maintenance recovery", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		if failures.size() > 0:
			return
		array_titanium_second_wave_earth_available = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(int(array_titanium_second_wave_earth_available.get("chemical_propellant", 0)) >= int(array_titanium_second_wave_cp_projection.get("gross_production_target", 0)) and int(array_titanium_second_wave_earth_available.get("repair_material", 0)) >= int(array_titanium_second_wave_repair_projection.get("gross_production_target", 0)), "Earth Location reaches the public gross maintenance-recovery targets for the final four-iron Lunar recipe wave; available=%s propellant_projection=%s repair_projection=%s exports={chemical_propellant:%d,repair_material:%d}" % [JSON.stringify(array_titanium_second_wave_earth_available), JSON.stringify(array_titanium_second_wave_cp_projection), JSON.stringify(array_titanium_second_wave_repair_projection), array_titanium_second_wave_cp_export, array_titanium_second_wave_repair_export])
		if failures.size() > 0:
			return
		_export_to_location("iron_ingot", array_titanium_needed, "J10 separate Lunar Bulk Energy Array titanium recipe-only second freight wave")
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot")
		game.clear_location_logistics_policy("lunar_space", "iron_ingot")
		var array_lunar_recipe_iron_before := int(_snapshot(lunar_world_id).get("location_available_inventory", {}).get("iron_ingot", 0))
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "iron_ingot", "DEMAND", 0, array_lunar_recipe_iron_before + array_titanium_needed, 100, 1)), "public Logistics publishes the isolated four-iron Energy Array titanium recipe wave only after construction staging is empty")
		var array_titanium_second_wave_earth_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var array_titanium_second_wave_dispatch_events := _advance(5000.0, "J10 Earth-Lunar Energy Array titanium recipe-wave dispatch boundary")
		var array_titanium_second_wave_dispatches := array_titanium_second_wave_dispatch_events.filter(func(event_value):
			var event := event_value as Dictionary
			return str(event.get("type", "")) == "ShipmentDispatched" and str(event.get("origin", "")) == EARTH_LOCATION_ID and str(event.get("destination", "")) == "lunar_space" and int((event.get("cargo", {}) as Dictionary).get("iron_ingot", 0)) == array_titanium_needed and (event.get("cargo", {}) as Dictionary).size() == 1
		)
		var array_titanium_second_wave_earth_after_dispatch: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(array_titanium_second_wave_dispatches.size() == 1, "the isolated four-iron Lunar recipe wave dispatches at the first public Logistics boundary after gross maintenance recovery; propellant_projection=%s repair_projection=%s before=%s after=%s dispatches=%s blockers=%s events=%s" % [JSON.stringify(array_titanium_second_wave_cp_projection), JSON.stringify(array_titanium_second_wave_repair_projection), JSON.stringify(array_titanium_second_wave_earth_before), JSON.stringify(array_titanium_second_wave_earth_after_dispatch), JSON.stringify(array_titanium_second_wave_dispatches), JSON.stringify(game.active_blockers()), JSON.stringify(array_titanium_second_wave_dispatch_events)])
		if failures.size() > 0:
			return
		var array_titanium_second_wave_shipment := array_titanium_second_wave_dispatches[0] as Dictionary
		var array_titanium_second_wave_shipment_id := str(array_titanium_second_wave_shipment.get("shipment_id", ""))
		var array_titanium_second_wave_eta_ms := float(array_titanium_second_wave_shipment.get("eta_ms", 0.0))
		_check(not array_titanium_second_wave_shipment_id.is_empty() and array_titanium_second_wave_eta_ms > 0.0, "the isolated four-iron recipe shipment exposes its public identity and ETA before policies are retired; shipment=%s" % JSON.stringify(array_titanium_second_wave_shipment))
		if failures.size() > 0:
			return
		# Once the one bounded shipment is in flight, retire its policies before a
		# later time slice can publish an accidental replacement manifest.
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot")
		game.clear_location_logistics_policy("lunar_space", "iron_ingot")
		var array_titanium_recipe_iron_events := _advance(array_titanium_second_wave_eta_ms + 1000.0, "J10 Earth-Lunar Energy Array titanium recipe-only second logistics arrival")
		var array_lunar_recipe_iron_after: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
		var array_titanium_second_wave_arrivals := array_titanium_recipe_iron_events.filter(func(event_value):
			var event := event_value as Dictionary
			return str(event.get("type", "")) == "ShipmentArrived" and str(event.get("shipment_id", "")) == array_titanium_second_wave_shipment_id and str(event.get("origin", "")) == EARTH_LOCATION_ID and str(event.get("destination", "")) == "lunar_space" and int((event.get("cargo", {}) as Dictionary).get("iron_ingot", 0)) == array_titanium_needed and (event.get("cargo", {}) as Dictionary).size() == 1
		)
		_check(array_titanium_second_wave_arrivals.size() == 1 and int(array_lunar_recipe_iron_after.get("iron_ingot", 0)) == array_lunar_recipe_iron_before + array_titanium_needed, "public Logistics delivers the already-dispatched isolated four-iron Energy Array titanium recipe wave after finite construction custody is consumed; available=%s arrivals=%s events=%s" % [JSON.stringify(array_lunar_recipe_iron_after), JSON.stringify(array_titanium_second_wave_arrivals), JSON.stringify(array_titanium_recipe_iron_events)])
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot")
		game.clear_location_logistics_policy("lunar_space", "iron_ingot")
		_import_from_location("iron_ingot", array_titanium_needed, array_titanium_depot_id, "J10 separate Lunar Bulk Energy Array titanium Factory iron staging", lunar_world_id)
		var array_titanium_mine_id := str(array_titanium_mine.get("id", ""))
		var array_titanium_recipe := _factory_command("SET_RECIPE", {"entity_id":array_titanium_foundry_id, "recipe_id":"grid_refine_titanium"}, lunar_world_id)
		_check(bool(array_titanium_recipe.get("accepted", false)), "Factory protocol selects the exact Lunar titanium-alloy recipe for the Energy Array manifest")
		# Retarget only the real Lunar solar providers through public topology
		# commands.  The old full-buffer foundries remain intact but no longer share
		# their finite providers with this bounded clean-line manifest.
		var array_titanium_power_sources := _entities_with_definition(_snapshot(lunar_world_id), "grid_solar_array")
		var array_titanium_power_source_ids: Array[String] = []
		for array_titanium_power_source_value in array_titanium_power_sources:
			array_titanium_power_source_ids.append(str((array_titanium_power_source_value as Dictionary).get("id", "")))
		for array_titanium_power_link_value in _snapshot(lunar_world_id).get("links", []):
			var array_titanium_power_link := array_titanium_power_link_value as Dictionary
			if str(array_titanium_power_link.get("kind", "")) == "POWER" and array_titanium_power_source_ids.has(str(array_titanium_power_link.get("source_id", ""))) and not [array_titanium_mine_id, array_titanium_foundry_id].has(str(array_titanium_power_link.get("target_id", ""))):
				var array_titanium_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(array_titanium_power_link.get("id", ""))}, lunar_world_id)
				_check(bool(array_titanium_power_removed.get("accepted", false)), "Factory protocol retargets each finite Lunar solar provider to the clean titanium line")
		if failures.size() > 0:
			return
		for array_titanium_power_source_id in array_titanium_power_source_ids:
			_ensure_connection("POWER", array_titanium_power_source_id, array_titanium_mine_id, "", lunar_world_id)
		_clear_competing_cargo_inputs(array_titanium_foundry_id, "titanium_ore", array_titanium_mine_id, lunar_world_id)
		_clear_competing_cargo_inputs(array_titanium_foundry_id, "iron_ingot", array_titanium_depot_id, lunar_world_id)
		_clear_competing_cargo_outputs(array_titanium_foundry_id, "titanium_alloy", array_titanium_depot_id, lunar_world_id)
		_clear_competing_cargo_inputs(array_titanium_depot_id, "titanium_alloy", array_titanium_foundry_id, lunar_world_id)
		_ensure_connection("CARGO", array_titanium_depot_id, array_titanium_foundry_id, "iron_ingot", lunar_world_id)
		# The source has exactly four iron units, so this two-second public transfer
		# window cannot overfill the empty smelter.  Retire the edge before staging
		# ore, proving the iron manifest is a finite physical commitment.
		_advance(2000.0, "J10 Energy Array clean-smelter iron input staging")
		var array_titanium_staged_foundry := _entity(_snapshot(lunar_world_id), array_titanium_foundry_id)
		var array_titanium_iron_stage_depot := _entity(_snapshot(lunar_world_id), array_titanium_depot_id)
		_check(int(array_titanium_staged_foundry.get("inputs", {}).get("iron_ingot", 0)) == array_titanium_needed and int(array_titanium_iron_stage_depot.get("inventory", {}).get("iron_ingot", 0)) == 0, "the finite separate-Bulk iron manifest physically transfers exactly four units into the empty Lunar titanium foundry and leaves no iron in the new Bulk depot before its Cargo edge is retired; foundry=%s depot=%s" % [JSON.stringify(array_titanium_staged_foundry), JSON.stringify(array_titanium_iron_stage_depot)])
		if failures.size() > 0:
			return
		_clear_competing_cargo_inputs(array_titanium_foundry_id, "iron_ingot", "", lunar_world_id)
		# A powered 4/s titanium mine needs exactly two seconds to place the
		# recipe's eight-ore manifest in the newly empty smelter.  Disconnect it
		# before manufacturing so no background ore stream can hide overproduction.
		_ensure_connection("CARGO", array_titanium_mine_id, array_titanium_foundry_id, "titanium_ore", lunar_world_id)
		_advance(2000.0, "J10 Energy Array clean-smelter titanium-ore staging")
		array_titanium_staged_foundry = _entity(_snapshot(lunar_world_id), array_titanium_foundry_id)
		_check(int(array_titanium_staged_foundry.get("inputs", {}).get("titanium_ore", 0)) == array_titanium_needed * 2, "the powered Lunar mine stages only the exact eight-ore Energy Array titanium manifest in the clean smelter before its Cargo edge is retired; foundry=%s mine=%s" % [JSON.stringify(array_titanium_staged_foundry), JSON.stringify(_entity(_snapshot(lunar_world_id), array_titanium_mine_id))])
		if failures.size() > 0:
			return
		_clear_competing_cargo_inputs(array_titanium_foundry_id, "titanium_ore", "", lunar_world_id)
		for array_titanium_power_source_id in array_titanium_power_source_ids:
			_ensure_connection("POWER", array_titanium_power_source_id, array_titanium_foundry_id, "", lunar_world_id)
		var array_titanium_power_snapshot := _snapshot(lunar_world_id)
		var array_titanium_old_smelters_unpowered := true
		for array_titanium_legacy_id_value in array_titanium_legacy_inputs.keys():
			if float(_entity(array_titanium_power_snapshot, str(array_titanium_legacy_id_value)).get("power_factor", 0.0)) != 0.0:
				array_titanium_old_smelters_unpowered = false
		var array_titanium_powered_mine := _entity(array_titanium_power_snapshot, array_titanium_mine_id)
		var array_titanium_powered_foundry := _entity(array_titanium_power_snapshot, array_titanium_foundry_id)
		_check(array_titanium_old_smelters_unpowered and float(array_titanium_powered_mine.get("power_factor", 0.0)) == 1.0 and float(array_titanium_powered_foundry.get("power_factor", 0.0)) == 1.0, "public POWER topology leaves the two historic full-buffer smelters at zero factor while giving the surveyed titanium mine and clean third smelter full factor; mine=%s foundry=%s legacy=%s" % [JSON.stringify(array_titanium_powered_mine), JSON.stringify(array_titanium_powered_foundry), JSON.stringify(array_titanium_legacy_inputs)])
		if failures.size() > 0:
			return
		_ensure_connection("CARGO", array_titanium_foundry_id, array_titanium_depot_id, "titanium_alloy", lunar_world_id)
		var array_titanium_events := _advance(120000.0, "J10 Lunar Energy Array titanium alloy fabrication")
		array_titanium_depot = _entity(_snapshot(lunar_world_id), array_titanium_depot_id)
		var array_titanium_clean_cycles := 0
		var array_titanium_clean_produced := 0
		for array_titanium_event_value in array_titanium_events:
			var array_titanium_event := array_titanium_event_value as Dictionary
			if str(array_titanium_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_titanium_event.get("world_id", "")) == lunar_world_id and str(array_titanium_event.get("entity_id", "")) == array_titanium_foundry_id and str(array_titanium_event.get("recipe_id", "")) == "grid_refine_titanium":
				array_titanium_clean_cycles += int(array_titanium_event.get("completed_cycles", 0))
				array_titanium_clean_produced += int((array_titanium_event.get("produced", {}) as Dictionary).get("titanium_alloy", 0))
		var array_titanium_legacy_after_snapshot := _snapshot(lunar_world_id)
		var array_titanium_legacy_preserved := true
		for array_titanium_legacy_id_value in array_titanium_legacy_inputs.keys():
			var array_titanium_legacy_id := str(array_titanium_legacy_id_value)
			var array_titanium_legacy_after := _entity(array_titanium_legacy_after_snapshot, array_titanium_legacy_id)
			if (array_titanium_legacy_after.get("inputs", {}) as Dictionary) != (array_titanium_legacy_inputs.get(array_titanium_legacy_id, {}) as Dictionary):
				array_titanium_legacy_preserved = false
		_check(array_titanium_clean_cycles == array_titanium_needed and array_titanium_clean_produced == array_titanium_needed and int(array_titanium_depot.get("inventory", {}).get("titanium_alloy", 0)) == array_titanium_needed and array_titanium_legacy_preserved, "the clean Lunar Arc Smelter alone completes exactly the finite Energy Array titanium recipe manifest while both historic saturated buffers remain byte-for-byte custody-stable; cycles=%d produced=%d depot=%s old_inputs=%s" % [array_titanium_clean_cycles, array_titanium_clean_produced, JSON.stringify(array_titanium_depot.get("inventory", {})), JSON.stringify(array_titanium_legacy_inputs)])
		if failures.size() > 0:
			return
	array_titanium_depot = _entity(_snapshot(lunar_world_id), array_titanium_depot_id)
	array_titanium_legacy_depot = _entity(_snapshot(lunar_world_id), lunar_depot_id)
	var array_titanium_total := int(array_titanium_depot.get("inventory", {}).get("titanium_alloy", 0)) + int(array_titanium_legacy_depot.get("inventory", {}).get("titanium_alloy", 0))
	_check(array_titanium_total == 5, "the original and separate Lunar Bulk depots retain the exact five-alloy Energy Array manifest after bounded titanium production; new=%s legacy=%s" % [JSON.stringify(array_titanium_depot.get("inventory", {})), JSON.stringify(array_titanium_legacy_depot.get("inventory", {}))])
	if failures.size() > 0:
		return
	var array_lunar_return_operating: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
	var array_titanium_return_cp_shortfall := maxi(0, 1 - int(array_lunar_return_operating.get("chemical_propellant", 0)))
	if array_titanium_return_cp_shortfall > 0:
		var array_titanium_return_earth_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var array_titanium_return_origin_cp_shortfall := maxi(0, 1 - int(array_titanium_return_earth_available.get("chemical_propellant", 0)))
		var array_titanium_return_origin_repair_shortfall := maxi(0, 1 - int(array_titanium_return_earth_available.get("repair_material", 0)))
		if array_titanium_return_origin_cp_shortfall > 0:
			_export_to_location("chemical_propellant", array_titanium_return_origin_cp_shortfall, "J10 Energy Array titanium-return propellant replenishment dispatch", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		if array_titanium_return_origin_repair_shortfall > 0:
			_export_to_location("repair_material", array_titanium_return_origin_repair_shortfall, "J10 Energy Array titanium-return propellant replenishment maintenance", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		_export_to_location("chemical_propellant", array_titanium_return_cp_shortfall, "J10 Energy Array titanium-return Lunar source propellant")
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
		game.clear_location_logistics_policy("lunar_space", "chemical_propellant")
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "chemical_propellant", "DEMAND", 0, int(array_lunar_return_operating.get("chemical_propellant", 0)) + array_titanium_return_cp_shortfall, 100, 1)), "public Logistics stages the exact missing Lunar titanium-return propellant")
		var array_titanium_return_cp_events := _advance(180000.0, "J10 Energy Array Lunar titanium-return propellant staging")
		array_lunar_return_operating = _snapshot(lunar_world_id).get("location_available_inventory", {})
		_check(_events_have_type(array_titanium_return_cp_events, "ShipmentArrived") and int(array_lunar_return_operating.get("chemical_propellant", 0)) >= 1, "public Logistics delivers the exact source propellant for the complete Energy Array titanium return; available=%s events=%s" % [JSON.stringify(array_lunar_return_operating), JSON.stringify(array_titanium_return_cp_events)])
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant")
		game.clear_location_logistics_policy("lunar_space", "chemical_propellant")
		if failures.size() > 0:
			return
	_check(int(array_lunar_return_operating.get("chemical_propellant", 0)) >= 1 and int(array_lunar_return_operating.get("repair_material", 0)) >= 1, "Lunar Location retains the exact source costs for the single Energy Array titanium return; available=%s" % JSON.stringify(array_lunar_return_operating))
	if failures.size() > 0:
		return
	var array_titanium_legacy_return := mini(5, int(array_titanium_legacy_depot.get("inventory", {}).get("titanium_alloy", 0)))
	var array_titanium_new_return := 5 - array_titanium_legacy_return
	if array_titanium_legacy_return > 0:
		_export_to_location("titanium_alloy", array_titanium_legacy_return, "J10 legacy Lunar Bulk share of complete Energy Array titanium manifest", lunar_world_id, lunar_depot_id)
	if array_titanium_new_return > 0:
		_export_to_location("titanium_alloy", array_titanium_new_return, "J10 separate Lunar Bulk share of complete Energy Array titanium manifest", lunar_world_id, array_titanium_depot_id)
	_check(array_titanium_legacy_return + array_titanium_new_return == 5, "the two public Lunar Bulk exports preserve the exact five-alloy Energy Array return manifest")
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy("lunar_space", "titanium_alloy")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "titanium_alloy")
	var array_earth_titanium_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("titanium_alloy", 0))
	_check(bool(game.set_location_logistics_policy("lunar_space", "titanium_alloy", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "titanium_alloy", "DEMAND", 0, array_earth_titanium_before + 5, 100, 1)), "public Logistics publishes the one bounded complete Energy Array titanium return")
	var array_titanium_return_events := _advance(180000.0, "J10 Lunar-to-Earth Energy Array titanium logistics")
	var array_earth_titanium_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(_events_have_type(array_titanium_return_events, "ShipmentArrived") and int(array_earth_titanium_after.get("titanium_alloy", 0)) >= array_earth_titanium_before + 5, "public Logistics returns the complete five-alloy Energy Array titanium manifest to Earth custody; available=%s events=%s" % [JSON.stringify(array_earth_titanium_after), JSON.stringify(array_titanium_return_events)])
	if failures.size() > 0:
		return
	_import_from_location("titanium_alloy", 5, cruiser_bulk_depot_id, "J10 Energy Array titanium Factory staging")
	game.clear_location_logistics_policy("lunar_space", "titanium_alloy")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "titanium_alloy")
	if failures.size() > 0:
		return

	# Return only the twenty raw cobalt required for ten steel composites.  The
	# Asteroid Location's raw-resource limit allows eight, eight, and four items;
	# source propellant and maintenance are staged once for those three two-hop
	# shipments, then each capacity-safe batch is immediately imported to Bulk.
	var array_asteroid_available: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	var array_asteroid_cp_shortfall := maxi(0, 9 - int(array_asteroid_available.get("chemical_propellant", 0)))
	var array_asteroid_repair_shortfall := maxi(0, 6 - int(array_asteroid_available.get("repair_material", 0)))
	var array_asteroid_operating_shipments := (1 if array_asteroid_cp_shortfall > 0 else 0) + (1 if array_asteroid_repair_shortfall > 0 else 0)
	var array_earth_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var array_earth_cp_target := array_asteroid_cp_shortfall + array_asteroid_operating_shipments * 3
	var array_earth_repair_target := array_asteroid_repair_shortfall + array_asteroid_operating_shipments * 2
	var array_earth_cp_export := maxi(0, array_earth_cp_target - int(array_earth_available.get("chemical_propellant", 0)))
	var array_earth_repair_export := maxi(0, array_earth_repair_target - int(array_earth_available.get("repair_material", 0)))
	if array_earth_cp_export > 0:
		_export_to_location("chemical_propellant", array_earth_cp_export, "J10 three bounded Energy Array cobalt-return propellant reserve", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	if array_earth_repair_export > 0:
		_export_to_location("repair_material", array_earth_repair_export, "J10 three bounded Energy Array cobalt-return maintenance reserve", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	if failures.size() > 0:
		return
	for array_operating_location in [EARTH_LOCATION_ID, "asteroid_belt"]:
		game.clear_location_logistics_policy(array_operating_location, "chemical_propellant")
		game.clear_location_logistics_policy(array_operating_location, "repair_material")
	if array_asteroid_cp_shortfall > 0:
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "chemical_propellant", "DEMAND", 0, int(array_asteroid_available.get("chemical_propellant", 0)) + array_asteroid_cp_shortfall, 100, 1)), "public Logistics publishes the exact Asteroid propellant reserve for Energy Array cobalt returns")
	if array_asteroid_repair_shortfall > 0:
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "repair_material", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("asteroid_belt", "repair_material", "DEMAND", 0, int(array_asteroid_available.get("repair_material", 0)) + array_asteroid_repair_shortfall, 100, 1)), "public Logistics publishes the exact Asteroid maintenance reserve for Energy Array cobalt returns")
	var array_asteroid_operating_events := _advance(360000.0, "J10 Energy Array Asteroid cobalt-return operating staging")
	var array_asteroid_operating_after: Dictionary = _snapshot(asteroid_world_id).get("location_available_inventory", {})
	_check((array_asteroid_operating_shipments == 0 or _events_have_type(array_asteroid_operating_events, "ShipmentArrived")) and int(array_asteroid_operating_after.get("chemical_propellant", 0)) >= 9 and int(array_asteroid_operating_after.get("repair_material", 0)) >= 6, "public Logistics stages the complete physical Asteroid source reserve for all three Energy Array cobalt returns; available=%s events=%s" % [JSON.stringify(array_asteroid_operating_after), JSON.stringify(array_asteroid_operating_events)])
	if failures.size() > 0:
		return
	for array_operating_location in [EARTH_LOCATION_ID, "asteroid_belt"]:
		game.clear_location_logistics_policy(array_operating_location, "chemical_propellant")
		game.clear_location_logistics_policy(array_operating_location, "repair_material")
	var array_cobalt_return_events: Array = []
	for array_cobalt_chunk in [8, 8, 4]:
		var array_earth_cobalt_before := int(_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}).get("cobalt_ore", 0))
		_export_to_location("cobalt_ore", array_cobalt_chunk, "J10 capacity-safe Energy Array cobalt feed", asteroid_world_id, asteroid_steel_depot_id)
		if failures.size() > 0:
			return
		game.clear_location_logistics_policy("asteroid_belt", "cobalt_ore")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore")
		_check(bool(game.set_location_logistics_policy("asteroid_belt", "cobalt_ore", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore", "DEMAND", 0, array_earth_cobalt_before + array_cobalt_chunk, 100, 1)), "public Logistics publishes the capacity-safe Energy Array cobalt stream of %d raw ore" % array_cobalt_chunk)
		var array_cobalt_chunk_events := _advance(360000.0, "J10 Energy Array Asteroid-Earth cobalt stream %d" % array_cobalt_chunk)
		array_cobalt_return_events.append_array(array_cobalt_chunk_events)
		var array_earth_cobalt_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(_events_have_type(array_cobalt_chunk_events, "ShipmentArrived") and int(array_earth_cobalt_after.get("cobalt_ore", 0)) >= array_earth_cobalt_before + array_cobalt_chunk, "public Logistics settles the complete capacity-safe Energy Array cobalt batch %d; available=%s events=%s" % [array_cobalt_chunk, JSON.stringify(array_earth_cobalt_after), JSON.stringify(array_cobalt_chunk_events)])
		if failures.size() > 0:
			return
		_import_from_location("cobalt_ore", array_cobalt_chunk, cruiser_bulk_depot_id, "J10 Energy Array cobalt Factory staging")
		game.clear_location_logistics_policy("asteroid_belt", "cobalt_ore")
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, "cobalt_ore")
		if failures.size() > 0:
			return
	_check(_events_have_type(array_cobalt_return_events, "ShipmentArrived") and int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("cobalt_ore", 0)) >= 20, "Earth Bulk custody retains the exact twenty Asteroid raw cobalt input for ten Energy Array steel composites")
	if failures.size() > 0:
		return
	_isolate_power_for_targets([cruiser_foundry_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, cruiser_foundry_id, "")
	var array_cobalt_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_cobalt"})
	_check(bool(array_cobalt_recipe.get("accepted", false)), "Factory protocol selects exact ten-cycle Energy Array cobalt refinement")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "industrial_waste", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "industrial_waste", cruiser_foundry_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ore")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "cobalt_ingot")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "industrial_waste")
	var array_cobalt_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("cobalt_ingot", 0))
	_advance(5000.0, "J10 Energy Array cobalt input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", "")
	var array_cobalt_events := _advance(180000.0, "J10 ten-cycle Energy Array cobalt refinement")
	var array_cobalt_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(array_cobalt_events, "grid_refine_cobalt") and int(array_cobalt_bulk.get("inventory", {}).get("cobalt_ingot", 0)) >= array_cobalt_before + 10, "Earth Factory refines the exact ten cobalt ingots for Energy Array steel through public cargo custody; bulk=%s" % JSON.stringify(array_cobalt_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	var array_steel_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_steel_electric"})
	_check(bool(array_steel_recipe.get("accepted", false)), "Factory protocol selects exact ten-cycle Energy Array electric steelmaking")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "steel_composite", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "steel_composite", cruiser_foundry_id)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_foundry_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "steel_composite")
	var array_steel_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("steel_composite", 0))
	# The clean Arc Smelter's weighted 48-slot input buffer cannot stage all
	# twenty iron plus ten cobalt at once.  Commit a six-cycle manifest first,
	# then stage the remaining four cycles from the already-refined cobalt stock.
	_advance(3000.0, "J10 Energy Array steel first-batch iron input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", "")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ingot")
	_advance(1500.0, "J10 Energy Array steel first-batch cobalt input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", "")
	var array_steel_first_staged := _entity(_snapshot(EARTH_WORLD_ID), cruiser_foundry_id)
	_check(int(array_steel_first_staged.get("inputs", {}).get("iron_ingot", 0)) == 12 and int(array_steel_first_staged.get("inputs", {}).get("cobalt_ingot", 0)) == 6, "public Factory stages the exact six-cycle Energy Array steel manifest before retiring both first-batch cargo edges; foundry=%s" % JSON.stringify(array_steel_first_staged))
	if failures.size() > 0:
		return
	var array_steel_first_events := _advance(90000.0, "J10 six-cycle Energy Array electric steelmaking first batch")
	var array_steel_after_first_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var array_steel_after_first_foundry := _entity(_snapshot(EARTH_WORLD_ID), cruiser_foundry_id)
	var array_steel_first_cycles := 0
	for array_steel_first_event_value in array_steel_first_events:
		var array_steel_first_event := array_steel_first_event_value as Dictionary
		if str(array_steel_first_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_steel_first_event.get("entity_id", "")) == cruiser_foundry_id and str(array_steel_first_event.get("recipe_id", "")) == "grid_refine_steel_electric":
			array_steel_first_cycles += int(array_steel_first_event.get("completed_cycles", 0))
	var array_steel_after_first_inputs: Dictionary = array_steel_after_first_foundry.get("inputs", {}) as Dictionary
	_check(array_steel_first_cycles == 6 and int(array_steel_after_first_bulk.get("inventory", {}).get("steel_composite", 0)) == array_steel_before + 6 and int(array_steel_after_first_bulk.get("inventory", {}).get("cobalt_ingot", 0)) == 4 and int(array_steel_after_first_inputs.get("iron_ingot", 0)) == 0 and int(array_steel_after_first_inputs.get("cobalt_ingot", 0)) == 0 and int(array_steel_after_first_inputs.get("cobalt_ore", 0)) == 0, "the first bounded steel batch consumes only twelve iron/six cobalt, produces six composites, and retains four refined cobalt in public Bulk custody for the second batch; zero-valued snapshot keys are not residual cargo; bulk=%s foundry=%s events=%s" % [JSON.stringify(array_steel_after_first_bulk.get("inventory", {})), JSON.stringify(array_steel_after_first_foundry), JSON.stringify(array_steel_first_events)])
	if failures.size() > 0:
		return
	# The finite starter iron manifest has been entirely committed to Lunar
	# construction and the first six steel cycles. The existing Earth Engineering
	# Works already holds a legal, full raw-iron buffer; recover only the needed
	# eight ingots through that public machine instead of clearing or bypassing it.
	var array_iron_recovery_snapshot := _snapshot(EARTH_WORLD_ID)
	var array_iron_recovery_refinery := _entity_with_recipe(array_iron_recovery_snapshot, "grid_refine_iron")
	_check(not array_iron_recovery_refinery.is_empty(), "Earth Factory exposes the existing raw-iron refinery needed for the finite Energy Array steel remainder")
	if failures.size() > 0:
		return
	var array_iron_recovery_refinery_id := str(array_iron_recovery_refinery.get("id", ""))
	var array_iron_recovery_inputs: Dictionary = array_iron_recovery_refinery.get("inputs", {}) as Dictionary
	_check(int(array_iron_recovery_inputs.get("iron_ore", 0)) >= 16 and int(array_iron_recovery_refinery.get("outputs", {}).get("iron_ingot", 0)) == 0, "the public Earth Factory snapshot exposes at least the sixteen buffered ore units and no queued iron output required for exactly eight recovery cycles; refinery=%s" % JSON.stringify(array_iron_recovery_refinery))
	if failures.size() > 0:
		return
	var array_iron_recovery_input_before := int(array_iron_recovery_inputs.get("iron_ore", 0))
	var array_iron_recovery_bulk_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("iron_ingot", 0))
	# The renewable mine already refilled this historical buffer during earlier
	# play. Retire only that same-item input edge before restoring power, so this
	# bounded recovery demonstrably consumes the existing 16 raw ore rather than
	# silently replacing them during the verification window.
	_clear_competing_cargo_inputs(array_iron_recovery_refinery_id, "iron_ore", "")
	_clear_competing_cargo_outputs(array_iron_recovery_refinery_id, "iron_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "iron_ingot", array_iron_recovery_refinery_id)
	_ensure_connection("CARGO", array_iron_recovery_refinery_id, cruiser_bulk_depot_id, "iron_ingot")
	_isolate_power_for_targets([cruiser_foundry_id, array_iron_recovery_refinery_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, array_iron_recovery_refinery_id, "")
	var array_iron_recovery_powered := _entity(_snapshot(EARTH_WORLD_ID), array_iron_recovery_refinery_id)
	_check(float(array_iron_recovery_powered.get("power_factor", 0.0)) > 0.0, "public POWER topology restores the buffered iron refinery for the finite eight-cycle recovery; refinery=%s" % JSON.stringify(array_iron_recovery_powered))
	if failures.size() > 0:
		return
	var array_iron_recovery_events := _advance(16000.0, "J10 exact eight-ingot Energy Array steel-remainder refinement")
	var array_iron_recovery_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var array_iron_recovery_cycles := 0
	var array_iron_recovery_produced := 0
	for array_iron_recovery_event_value in array_iron_recovery_events:
		var array_iron_recovery_event := array_iron_recovery_event_value as Dictionary
		if str(array_iron_recovery_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_iron_recovery_event.get("world_id", "")) == EARTH_WORLD_ID and str(array_iron_recovery_event.get("entity_id", "")) == array_iron_recovery_refinery_id and str(array_iron_recovery_event.get("recipe_id", "")) == "grid_refine_iron":
			array_iron_recovery_cycles += int(array_iron_recovery_event.get("completed_cycles", 0))
			array_iron_recovery_produced += int((array_iron_recovery_event.get("produced", {}) as Dictionary).get("iron_ingot", 0))
	var array_iron_recovery_after := _entity(_snapshot(EARTH_WORLD_ID), array_iron_recovery_refinery_id)
	_check(array_iron_recovery_cycles == 8 and array_iron_recovery_produced == 8 and int(array_iron_recovery_bulk.get("inventory", {}).get("iron_ingot", 0)) == array_iron_recovery_bulk_before + 8 and int(array_iron_recovery_after.get("inputs", {}).get("iron_ore", 0)) == array_iron_recovery_input_before - 16, "Earth Factory physically consumes only sixteen units from its existing raw-ore buffer and refines the exact eight iron ingots needed for the four-cycle Energy Array steel remainder; bulk=%s refinery=%s cycles=%d produced=%d events=%s" % [JSON.stringify(array_iron_recovery_bulk.get("inventory", {})), JSON.stringify(array_iron_recovery_after), array_iron_recovery_cycles, array_iron_recovery_produced, JSON.stringify(array_iron_recovery_events)])
	if failures.size() > 0:
		return
	_isolate_power_for_targets([cruiser_foundry_id], jovian_research_power_id)
	_clear_competing_cargo_outputs(array_iron_recovery_refinery_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "iron_ingot")
	_advance(2000.0, "J10 Energy Array steel second-batch iron input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", "")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ingot")
	_advance(1000.0, "J10 Energy Array steel second-batch cobalt input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", "")
	var array_steel_second_staged := _entity(_snapshot(EARTH_WORLD_ID), cruiser_foundry_id)
	_check(int(array_steel_second_staged.get("inputs", {}).get("iron_ingot", 0)) == 8 and int(array_steel_second_staged.get("inputs", {}).get("cobalt_ingot", 0)) == 4, "public Factory stages the exact four-cycle Energy Array steel remainder without re-refining cobalt; foundry=%s bulk=%s" % [JSON.stringify(array_steel_second_staged), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}))])
	if failures.size() > 0:
		return
	var array_steel_second_events := _advance(60000.0, "J10 four-cycle Energy Array electric steelmaking second batch")
	var array_steel_events: Array = []
	array_steel_events.append_array(array_steel_first_events)
	array_steel_events.append_array(array_steel_second_events)
	var array_steel_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var array_steel_foundry := _entity(_snapshot(EARTH_WORLD_ID), cruiser_foundry_id)
	var array_steel_cycles := 0
	var array_steel_produced := 0
	for array_steel_event_value in array_steel_events:
		var array_steel_event := array_steel_event_value as Dictionary
		if str(array_steel_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_steel_event.get("entity_id", "")) == cruiser_foundry_id and str(array_steel_event.get("recipe_id", "")) == "grid_refine_steel_electric":
			array_steel_cycles += int(array_steel_event.get("completed_cycles", 0))
			array_steel_produced += int((array_steel_event.get("produced", {}) as Dictionary).get("steel_composite", 0))
	_check(_events_have_recipe(array_steel_events, "grid_refine_steel_electric") and array_steel_cycles == 10 and array_steel_produced == 10 and int(array_steel_bulk.get("inventory", {}).get("steel_composite", 0)) >= array_steel_before + 10, "Earth Factory produces the complete ten-composite Energy Array steel manifest; bulk=%s foundry=%s cycles=%d produced=%d events=%s" % [JSON.stringify(array_steel_bulk.get("inventory", {})), JSON.stringify(array_steel_foundry), array_steel_cycles, array_steel_produced, JSON.stringify(array_steel_events)])
	if failures.size() > 0:
		return
	var array_hss_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("heavy_structural_section", 0))
	var array_hss_events := _cold_stage_recipe_batch(
		cruiser_foundry_id,
		"grid_fabricate_heavy_structural_section",
		jovian_research_power_id,
		[
			{"item_id":"steel_composite", "source_id":cruiser_bulk_depot_id, "quantity":6},
			{"item_id":"titanium_alloy", "source_id":cruiser_bulk_depot_id, "quantity":2},
			{"item_id":"structural_frame", "source_id":STARTER_DEPOT_ID, "quantity":4}
		],
		cruiser_bulk_depot_id,
		"heavy_structural_section",
		60000.0,
		"J10 exact two-cycle Energy Array heavy-structural-section fabrication"
	)
	if failures.size() > 0:
		return
	var array_hss_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var array_hss_cycles := 0
	var array_hss_produced := 0
	for array_hss_event_value in array_hss_events:
		var array_hss_event := array_hss_event_value as Dictionary
		if str(array_hss_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_hss_event.get("world_id", "")) == EARTH_WORLD_ID and str(array_hss_event.get("entity_id", "")) == cruiser_foundry_id and str(array_hss_event.get("recipe_id", "")) == "grid_fabricate_heavy_structural_section":
			array_hss_cycles += int(array_hss_event.get("completed_cycles", 0))
			array_hss_produced += int((array_hss_event.get("produced", {}) as Dictionary).get("heavy_structural_section", 0))
	_check(array_hss_cycles == 2 and array_hss_produced == 2 and int(array_hss_bulk.get("inventory", {}).get("heavy_structural_section", 0)) == array_hss_before + 2 and int(array_hss_bulk.get("inventory", {}).get("steel_composite", 0)) == 4 and int(array_hss_bulk.get("inventory", {}).get("titanium_alloy", 0)) == 3, "Earth Factory cold-stages and fabricates exactly two Energy Array heavy structural sections while retaining the exact four steel/three titanium Array reserve; bulk=%s events=%s" % [JSON.stringify(array_hss_bulk.get("inventory", {})), JSON.stringify(array_hss_events)])
	if failures.size() > 0:
		return

	# The two bounded steel batches intentionally consume the eight recovered iron
	# ingots.  Recover exactly the three further ingots for the electronics
	# manifest from the still-buffered raw ore through the same public refinery;
	# do not reinterpret the previous steel reserve as an implicit source.
	var array_electronics_iron_refinery := _entity(_snapshot(EARTH_WORLD_ID), array_iron_recovery_refinery_id)
	_check(int(array_electronics_iron_refinery.get("inputs", {}).get("iron_ore", 0)) >= 6, "the public iron refinery retains enough physical raw ore for the distinct three-ingot Energy Array electronics manifest; refinery=%s" % JSON.stringify(array_electronics_iron_refinery))
	if failures.size() > 0:
		return
	_clear_competing_cargo_outputs(array_iron_recovery_refinery_id, "iron_ingot", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", array_iron_recovery_refinery_id, cruiser_bulk_depot_id, "iron_ingot")
	_isolate_power_for_targets([array_iron_recovery_refinery_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, array_iron_recovery_refinery_id, "")
	var array_electronics_iron_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("iron_ingot", 0))
	var array_electronics_iron_events := _advance(6000.0, "J10 exact three-ingot Energy Array electronics iron refinement")
	var array_electronics_iron_cycles := 0
	var array_electronics_iron_produced := 0
	for array_electronics_iron_event_value in array_electronics_iron_events:
		var array_electronics_iron_event := array_electronics_iron_event_value as Dictionary
		if str(array_electronics_iron_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_electronics_iron_event.get("world_id", "")) == EARTH_WORLD_ID and str(array_electronics_iron_event.get("entity_id", "")) == array_iron_recovery_refinery_id and str(array_electronics_iron_event.get("recipe_id", "")) == "grid_refine_iron":
			array_electronics_iron_cycles += int(array_electronics_iron_event.get("completed_cycles", 0))
			array_electronics_iron_produced += int((array_electronics_iron_event.get("produced", {}) as Dictionary).get("iron_ingot", 0))
	var array_electronics_iron_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(array_electronics_iron_cycles == 3 and array_electronics_iron_produced == 3 and int(array_electronics_iron_bulk.get("inventory", {}).get("iron_ingot", 0)) == array_electronics_iron_before + 3, "Earth Factory physically refines the exact three additional iron ingots for Energy Array electronics into explicit Bulk custody; bulk=%s events=%s" % [JSON.stringify(array_electronics_iron_bulk.get("inventory", {})), JSON.stringify(array_electronics_iron_events)])
	if failures.size() > 0:
		return
	_clear_competing_cargo_outputs(array_iron_recovery_refinery_id, "iron_ingot", "")

	# Reconfigure the established engineering and High-Energy works for the final
	# six electronics and three power buses.  The Bus manifest consumes the other
	# three returned titanium units; all item-specific cargo ports are isolated.
	# The cargo staging boundary must be cold.  A live POWER edge can let the
	# one-second transfer window consume the just-delivered inputs before this
	# explicit three-cycle evidence window begins.
	for power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var power_link := power_link_value as Dictionary
		if str(power_link.get("kind", "")) != "POWER" or str(power_link.get("target_id", "")) != cruiser_electronics_id:
			continue
		var cold_stage_disconnect := _factory_command("REMOVE_LINK", {"link_id":str(power_link.get("id", ""))})
		_check(bool(cold_stage_disconnect.get("accepted", false)), "Factory protocol removes every live POWER edge before cold Energy Array electronics staging; result=%s" % JSON.stringify(cold_stage_disconnect))
	if failures.size() > 0:
		return
	var array_electronics_cold_links: Array = (_snapshot(EARTH_WORLD_ID).get("links", []) as Array).filter(func(link_value):
		var link := link_value as Dictionary
		return str(link.get("kind", "")) == "POWER" and str(link.get("target_id", "")) == cruiser_electronics_id
	)
	_check(array_electronics_cold_links.is_empty(), "the explicit Energy Array electronics input-staging boundary has no live POWER edge; links=%s" % JSON.stringify(array_electronics_cold_links))
	if failures.size() > 0:
		return
	var array_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_electronics"})
	_check(bool(array_electronics_recipe.get("accepted", false)), "Factory protocol selects exact three-cycle Energy Array electronics fabrication")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "electronics", cruiser_electronics_id)
	# Bulk is the manifest sink, not a transient pass-through.  Retire every
	# existing Bulk electronics outbound edge before production so another machine
	# cannot consume this exact six-unit construction reserve in the same tick.
	_clear_competing_cargo_outputs(cruiser_bulk_depot_id, "electronics", "")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_electronics_id, "iron_ingot")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "electronics")
	var array_electronics_before_snapshot := _snapshot(EARTH_WORLD_ID)
	var array_electronics_before := int(_entity(array_electronics_before_snapshot, cruiser_bulk_depot_id).get("inventory", {}).get("electronics", 0))
	var array_electronics_iron_source_before := int(_entity(array_electronics_before_snapshot, cruiser_bulk_depot_id).get("inventory", {}).get("iron_ingot", 0))
	var array_electronics_copper_source_before := int(_entity(array_electronics_before_snapshot, STARTER_DEPOT_ID).get("inventory", {}).get("copper_ingot", 0))
	var array_electronics_inputs_before: Dictionary = _entity(array_electronics_before_snapshot, cruiser_electronics_id).get("inputs", {}).duplicate(true)
	var array_electronics_cold_events := _advance(750.0, "J10 Energy Array cold electronics input staging")
	var array_electronics_staged := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
	var array_electronics_cold_snapshot := _snapshot(EARTH_WORLD_ID)
	_check(not _events_have_recipe(array_electronics_cold_events, "grid_fabricate_electronics") and int(_entity(array_electronics_cold_snapshot, cruiser_bulk_depot_id).get("inventory", {}).get("iron_ingot", 0)) == array_electronics_iron_source_before - 3 and int(_entity(array_electronics_cold_snapshot, STARTER_DEPOT_ID).get("inventory", {}).get("copper_ingot", 0)) == array_electronics_copper_source_before - 3 and int(array_electronics_staged.get("inputs", {}).get("iron_ingot", 0)) == int(array_electronics_inputs_before.get("iron_ingot", 0)) + 3 and int(array_electronics_staged.get("inputs", {}).get("copper_ingot", 0)) == int(array_electronics_inputs_before.get("copper_ingot", 0)) + 3, "the cold public boundary transfers exactly three iron and three copper inputs without completing an electronics cycle; before_inputs=%s works=%s events=%s" % [JSON.stringify(array_electronics_inputs_before), JSON.stringify(array_electronics_staged), JSON.stringify(array_electronics_cold_events)])
	if failures.size() > 0:
		return
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", "")
	_isolate_all_machine_power_for_target(cruiser_electronics_id)
	_ensure_connection("POWER", jovian_research_power_id, cruiser_electronics_id, "")
	var array_electronics_statistics_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("statistics", {}) as Dictionary).duplicate(true)
	var array_electronics_events := _advance(60000.0, "J10 three-cycle Energy Array electronics fabrication")
	var array_electronics_cycles := 0
	var array_electronics_produced := 0
	for array_electronics_event_value in array_electronics_events:
		var array_electronics_event := array_electronics_event_value as Dictionary
		if str(array_electronics_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_electronics_event.get("world_id", "")) == EARTH_WORLD_ID and str(array_electronics_event.get("entity_id", "")) == cruiser_electronics_id and str(array_electronics_event.get("recipe_id", "")) == "grid_fabricate_electronics":
			array_electronics_cycles += int(array_electronics_event.get("completed_cycles", 0))
			array_electronics_produced += int((array_electronics_event.get("produced", {}) as Dictionary).get("electronics", 0))
	var array_electronics_runtime := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
	var array_electronics_output_links: Array = (_snapshot(EARTH_WORLD_ID).get("links", []) as Array).filter(func(link_value):
		var link := link_value as Dictionary
		return str(link.get("kind", "")) == "CARGO" and str(link.get("source_id", "")) == cruiser_electronics_id and str(link.get("target_id", "")) == cruiser_bulk_depot_id and str(link.get("item_id", "")) == "electronics"
	)
	var array_electronics_statistics_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("statistics", {}) as Dictionary
	var array_electronics_consumed_before: Dictionary = array_electronics_statistics_before.get("consumed", {}) as Dictionary
	var array_electronics_produced_before: Dictionary = array_electronics_statistics_before.get("produced", {}) as Dictionary
	var array_electronics_consumed_after: Dictionary = array_electronics_statistics_after.get("consumed", {}) as Dictionary
	var array_electronics_produced_after: Dictionary = array_electronics_statistics_after.get("produced", {}) as Dictionary
	var array_electronics_bulk_outbound: Array = (_snapshot(EARTH_WORLD_ID).get("links", []) as Array).filter(func(link_value):
		var link := link_value as Dictionary
		return str(link.get("kind", "")) == "CARGO" and str(link.get("source_id", "")) == cruiser_bulk_depot_id and str(link.get("item_id", "")) == "electronics"
	)
	_check(array_electronics_cycles == 3 and array_electronics_produced == 6 and int(array_electronics_staged.get("inputs", {}).get("iron_ingot", 0)) - int(array_electronics_runtime.get("inputs", {}).get("iron_ingot", 0)) == 3 and int(array_electronics_staged.get("inputs", {}).get("copper_ingot", 0)) - int(array_electronics_runtime.get("inputs", {}).get("copper_ingot", 0)) == 3 and int(array_electronics_consumed_after.get("iron_ingot", 0)) == int(array_electronics_consumed_before.get("iron_ingot", 0)) + 3 and int(array_electronics_consumed_after.get("copper_ingot", 0)) == int(array_electronics_consumed_before.get("copper_ingot", 0)) + 3 and int(array_electronics_produced_after.get("electronics", 0)) == int(array_electronics_produced_before.get("electronics", 0)) + 6 and int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("electronics", 0)) == array_electronics_before + 6 and array_electronics_output_links.size() == 1 and array_electronics_bulk_outbound.is_empty(), "Earth Factory completes exactly three scoped electronics cycles from the cold-staged inputs and transfers their six outputs into isolated Bulk custody; staged=%s works=%s bulk=%s links=%s outbound=%s events=%s" % [JSON.stringify(array_electronics_staged), JSON.stringify(array_electronics_runtime), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {})), JSON.stringify(array_electronics_output_links), JSON.stringify(array_electronics_bulk_outbound), JSON.stringify(array_electronics_events)])
	if failures.size() > 0:
		return
	# The established High-Energy works deliberately retains the historic J9
	# electronics/titanium buffer.  Do not treat that buffer as this tiny Energy
	# Array manifest, and do not clear it: consume it through two named public
	# recipes into later-J10 materials before cold-staging the exact bus batch.
	var array_resident_high_energy := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	var array_resident_inputs: Dictionary = array_resident_high_energy.get("inputs", {}) as Dictionary
	_check(int(array_resident_inputs.get("electronics", 0)) == 50 and int(array_resident_inputs.get("titanium_alloy", 0)) == 6 and int(array_resident_inputs.get("copper_ingot", 0)) == 0, "public Factory custody identifies the complete retained High-Energy input buffer before it is physically transformed for later J10 use; inputs=%s" % JSON.stringify(array_resident_inputs))
	if failures.size() > 0:
		return
	_isolate_power_for_targets([prototype_high_energy_id], jovian_research_power_id)
	var array_buffer_rad_recipe := _factory_command("SET_RECIPE", {"entity_id":prototype_high_energy_id, "recipe_id":"grid_fabricate_radiation_hardened_electronics"})
	_check(bool(array_buffer_rad_recipe.get("accepted", false)), "Factory protocol selects the retained-buffer radiation-hardened electronics recipe; result=%s" % JSON.stringify(array_buffer_rad_recipe))
	_clear_competing_cargo_outputs(prototype_high_energy_id, "radiation_hardened_electronics", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "radiation_hardened_electronics", prototype_high_energy_id)
	_clear_competing_cargo_outputs(cruiser_bulk_depot_id, "radiation_hardened_electronics", "")
	_ensure_connection("CARGO", prototype_high_energy_id, cruiser_bulk_depot_id, "radiation_hardened_electronics")
	var array_buffer_rad_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("radiation_hardened_electronics", 0))
	var array_buffer_rad_output_before := int(_entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id).get("outputs", {}).get("radiation_hardened_electronics", 0))
	var array_buffer_rad_statistics_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("statistics", {}) as Dictionary).duplicate(true)
	_check(array_buffer_rad_output_before == 0, "retained-buffer radiation hardening begins with no stale machine output able to mask its new explicit Bulk custody; output=%s" % JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id).get("outputs", {})))
	_isolate_all_machine_power_for_target(prototype_high_energy_id)
	_ensure_connection("POWER", jovian_research_power_id, prototype_high_energy_id, "")
	var array_buffer_rad_events := _advance(66000.0, "J10 retained High-Energy buffer radiation-hardening")
	for array_buffer_rad_power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var array_buffer_rad_power_link := array_buffer_rad_power_link_value as Dictionary
		if str(array_buffer_rad_power_link.get("kind", "")) != "POWER" or str(array_buffer_rad_power_link.get("target_id", "")) != prototype_high_energy_id:
			continue
		var array_buffer_rad_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(array_buffer_rad_power_link.get("id", ""))})
		_check(bool(array_buffer_rad_power_removed.get("accepted", false)), "Factory protocol removes every High-Energy POWER edge before retained radiation-hardening cargo settlement; result=%s" % JSON.stringify(array_buffer_rad_power_removed))
	var array_buffer_rad_settlement_machine := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	var array_buffer_rad_settlement_power_links: Array = (_snapshot(EARTH_WORLD_ID).get("links", []) as Array).filter(func(link_value):
		var link := link_value as Dictionary
		return str(link.get("kind", "")) == "POWER" and str(link.get("target_id", "")) == prototype_high_energy_id
	)
	_check(array_buffer_rad_settlement_power_links.is_empty() and float(array_buffer_rad_settlement_machine.get("progress", 0.0)) == 0.0, "retained radiation-hardening reaches a completed-cycle boundary with no POWER edge before its output-only cargo settlement; machine=%s links=%s" % [JSON.stringify(array_buffer_rad_settlement_machine), JSON.stringify(array_buffer_rad_settlement_power_links)])
	if failures.size() > 0:
		return
	_advance(1000.0, "J10 retained radiation-hardening cargo settlement")
	var array_buffer_rad_cycles := 0
	var array_buffer_rad_produced := 0
	for array_buffer_rad_event_value in array_buffer_rad_events:
		var array_buffer_rad_event := array_buffer_rad_event_value as Dictionary
		if str(array_buffer_rad_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_buffer_rad_event.get("world_id", "")) == EARTH_WORLD_ID and str(array_buffer_rad_event.get("entity_id", "")) == prototype_high_energy_id and str(array_buffer_rad_event.get("recipe_id", "")) == "grid_fabricate_radiation_hardened_electronics":
			array_buffer_rad_cycles += int(array_buffer_rad_event.get("completed_cycles", 0))
			array_buffer_rad_produced += int((array_buffer_rad_event.get("produced", {}) as Dictionary).get("radiation_hardened_electronics", 0))
	var array_after_rad_buffer := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	var array_buffer_rad_statistics_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("statistics", {}) as Dictionary
	var array_buffer_rad_consumed_before: Dictionary = array_buffer_rad_statistics_before.get("consumed", {}) as Dictionary
	var array_buffer_rad_produced_before: Dictionary = array_buffer_rad_statistics_before.get("produced", {}) as Dictionary
	var array_buffer_rad_consumed_after: Dictionary = array_buffer_rad_statistics_after.get("consumed", {}) as Dictionary
	var array_buffer_rad_produced_after: Dictionary = array_buffer_rad_statistics_after.get("produced", {}) as Dictionary
	_check(array_buffer_rad_cycles == 3 and array_buffer_rad_produced == 3 and int(array_after_rad_buffer.get("inputs", {}).get("electronics", 0)) == 44 and int(array_after_rad_buffer.get("inputs", {}).get("titanium_alloy", 0)) == 3 and int(array_after_rad_buffer.get("outputs", {}).get("radiation_hardened_electronics", 0)) == 0 and int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("radiation_hardened_electronics", 0)) == array_buffer_rad_before + 3 and int(array_buffer_rad_consumed_after.get("electronics", 0)) == int(array_buffer_rad_consumed_before.get("electronics", 0)) + 6 and int(array_buffer_rad_consumed_after.get("titanium_alloy", 0)) == int(array_buffer_rad_consumed_before.get("titanium_alloy", 0)) + 3 and int(array_buffer_rad_produced_after.get("radiation_hardened_electronics", 0)) == int(array_buffer_rad_produced_before.get("radiation_hardened_electronics", 0)) + 3, "three real High-Energy cycles transform half of the retained titanium/electronics buffer into explicit radiation-hardened custody while preserving the exact three titanium units for the Energy Array bus manifest; machine=%s bulk=%s statistics=%s events=%s" % [JSON.stringify(array_after_rad_buffer), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {})), JSON.stringify(array_buffer_rad_statistics_after), JSON.stringify(array_buffer_rad_events)])
	if failures.size() > 0:
		return
	for array_buffer_data_power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var array_buffer_data_power_link := array_buffer_data_power_link_value as Dictionary
		if str(array_buffer_data_power_link.get("kind", "")) != "POWER" or str(array_buffer_data_power_link.get("target_id", "")) != prototype_high_energy_id:
			continue
		var array_buffer_data_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(array_buffer_data_power_link.get("id", ""))})
		_check(bool(array_buffer_data_power_removed.get("accepted", false)), "Factory protocol removes every High-Energy POWER edge before cold retained-buffer data-core staging; result=%s" % JSON.stringify(array_buffer_data_power_removed))
	var array_buffer_data_cold_power_links: Array = (_snapshot(EARTH_WORLD_ID).get("links", []) as Array).filter(func(link_value):
		var link := link_value as Dictionary
		return str(link.get("kind", "")) == "POWER" and str(link.get("target_id", "")) == prototype_high_energy_id
	)
	_check(array_buffer_data_cold_power_links.is_empty(), "the retained-buffer data-core copper-staging boundary has no live High-Energy POWER edge; links=%s" % JSON.stringify(array_buffer_data_cold_power_links))
	var array_buffer_data_recipe := _factory_command("SET_RECIPE", {"entity_id":prototype_high_energy_id, "recipe_id":"grid_fabricate_data_core"})
	_check(bool(array_buffer_data_recipe.get("accepted", false)), "Factory protocol selects the retained-buffer data-core recipe; result=%s" % JSON.stringify(array_buffer_data_recipe))
	_clear_competing_cargo_inputs(prototype_high_energy_id, "copper_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(prototype_high_energy_id, "data_core", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "data_core", prototype_high_energy_id)
	_clear_competing_cargo_outputs(cruiser_bulk_depot_id, "data_core", "")
	_ensure_connection("CARGO", STARTER_DEPOT_ID, prototype_high_energy_id, "copper_ingot")
	_ensure_connection("CARGO", prototype_high_energy_id, cruiser_bulk_depot_id, "data_core")
	var array_buffer_data_source_before := int(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}).get("copper_ingot", 0))
	var array_buffer_data_machine_before := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	var array_buffer_data_output_before := int(array_buffer_data_machine_before.get("outputs", {}).get("data_core", 0))
	_check(array_buffer_data_output_before == 0, "retained-buffer data-core fabrication begins with no stale machine output able to mask its new explicit Bulk custody; outputs=%s" % JSON.stringify(array_buffer_data_machine_before.get("outputs", {})))
	var array_buffer_data_cold_events := _advance(5500.0, "J10 retained High-Energy data-core copper staging")
	var array_buffer_data_staged := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	_check(not _events_have_recipe(array_buffer_data_cold_events, "grid_fabricate_data_core") and int(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}).get("copper_ingot", 0)) == array_buffer_data_source_before - 22 and int(array_buffer_data_staged.get("inputs", {}).get("copper_ingot", 0)) == int(array_buffer_data_machine_before.get("inputs", {}).get("copper_ingot", 0)) + 22 and int(array_buffer_data_staged.get("inputs", {}).get("electronics", 0)) == 44 and int(array_buffer_data_staged.get("inputs", {}).get("titanium_alloy", 0)) == 3, "the cold public boundary stages the exact twenty-two missing copper ingots for retained-buffer data-core production while preserving the three resident Energy Array titanium units; before=%s staged=%s events=%s" % [JSON.stringify(array_buffer_data_machine_before), JSON.stringify(array_buffer_data_staged), JSON.stringify(array_buffer_data_cold_events)])
	if failures.size() > 0:
		return
	_clear_competing_cargo_inputs(prototype_high_energy_id, "copper_ingot", "")
	var array_buffer_data_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("data_core", 0))
	var array_buffer_data_statistics_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("statistics", {}) as Dictionary).duplicate(true)
	_isolate_all_machine_power_for_target(prototype_high_energy_id)
	_ensure_connection("POWER", jovian_research_power_id, prototype_high_energy_id, "")
	var array_buffer_data_events := _advance(396000.0, "J10 retained High-Energy data-core fabrication")
	_advance(1000.0, "J10 retained data-core cargo settlement")
	var array_buffer_data_cycles := 0
	var array_buffer_data_produced := 0
	for array_buffer_data_event_value in array_buffer_data_events:
		var array_buffer_data_event := array_buffer_data_event_value as Dictionary
		if str(array_buffer_data_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_buffer_data_event.get("world_id", "")) == EARTH_WORLD_ID and str(array_buffer_data_event.get("entity_id", "")) == prototype_high_energy_id and str(array_buffer_data_event.get("recipe_id", "")) == "grid_fabricate_data_core":
			array_buffer_data_cycles += int(array_buffer_data_event.get("completed_cycles", 0))
			array_buffer_data_produced += int((array_buffer_data_event.get("produced", {}) as Dictionary).get("data_core", 0))
	var array_after_data_buffer := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	var array_buffer_data_statistics_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("statistics", {}) as Dictionary
	var array_buffer_data_consumed_before: Dictionary = array_buffer_data_statistics_before.get("consumed", {}) as Dictionary
	var array_buffer_data_produced_before: Dictionary = array_buffer_data_statistics_before.get("produced", {}) as Dictionary
	var array_buffer_data_consumed_after: Dictionary = array_buffer_data_statistics_after.get("consumed", {}) as Dictionary
	var array_buffer_data_produced_after: Dictionary = array_buffer_data_statistics_after.get("produced", {}) as Dictionary
	_check(array_buffer_data_cycles == 22 and array_buffer_data_produced == 22 and int(array_after_data_buffer.get("inputs", {}).get("electronics", 0)) == 0 and int(array_after_data_buffer.get("inputs", {}).get("copper_ingot", 0)) == 0 and int(array_after_data_buffer.get("inputs", {}).get("titanium_alloy", 0)) == 3 and int(array_after_data_buffer.get("outputs", {}).get("data_core", 0)) == 0 and int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("data_core", 0)) == array_buffer_data_before + 22 and int(array_buffer_data_consumed_after.get("electronics", 0)) == int(array_buffer_data_consumed_before.get("electronics", 0)) + 44 and int(array_buffer_data_consumed_after.get("copper_ingot", 0)) == int(array_buffer_data_consumed_before.get("copper_ingot", 0)) + 22 and int(array_buffer_data_produced_after.get("data_core", 0)) == int(array_buffer_data_produced_before.get("data_core", 0)) + 22, "twenty-two real High-Energy cycles consume the remaining retained electronics buffer into explicit data-core custody while retaining the exact three titanium units for the Energy Array bus manifest; machine=%s bulk=%s statistics=%s events=%s" % [JSON.stringify(array_after_data_buffer), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {})), JSON.stringify(array_buffer_data_statistics_after), JSON.stringify(array_buffer_data_events)])
	if failures.size() > 0:
		return
	_isolate_power_for_targets([prototype_high_energy_id], jovian_research_power_id)
	_clear_competing_cargo_outputs(prototype_high_energy_id, "radiation_hardened_electronics", "")
	_clear_competing_cargo_outputs(prototype_high_energy_id, "data_core", "")
	var array_power_bus_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("power_bus_component", 0))
	var array_power_bus_events := _cold_stage_recipe_batch(
		prototype_high_energy_id,
		"grid_fabricate_power_bus_component",
		jovian_research_power_id,
		[
			{"item_id":"copper_ingot", "source_id":STARTER_DEPOT_ID, "quantity":9},
			{"item_id":"electronics", "source_id":cruiser_bulk_depot_id, "quantity":6},
			{"item_id":"titanium_alloy", "source_id":cruiser_bulk_depot_id, "quantity":3}
		],
		cruiser_bulk_depot_id,
		"power_bus_component",
		90000.0,
		"J10 exact three-cycle Energy Array power-bus fabrication"
	)
	if failures.size() > 0:
		return
	var array_power_bus_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var array_power_bus_cycles := 0
	var array_power_bus_produced := 0
	for array_power_bus_event_value in array_power_bus_events:
		var array_power_bus_event := array_power_bus_event_value as Dictionary
		if str(array_power_bus_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_power_bus_event.get("world_id", "")) == EARTH_WORLD_ID and str(array_power_bus_event.get("entity_id", "")) == prototype_high_energy_id and str(array_power_bus_event.get("recipe_id", "")) == "grid_fabricate_power_bus_component":
			array_power_bus_cycles += int(array_power_bus_event.get("completed_cycles", 0))
			array_power_bus_produced += int((array_power_bus_event.get("produced", {}) as Dictionary).get("power_bus_component", 0))
	_check(array_power_bus_cycles == 3 and array_power_bus_produced == 3 and int(array_power_bus_bulk.get("inventory", {}).get("power_bus_component", 0)) == array_power_bus_before + 3, "High-Energy Electronics Works fabricates the exact three cold-staged Energy Array power buses into explicit Bulk custody; bulk=%s events=%s" % [JSON.stringify(array_power_bus_bulk.get("inventory", {})), JSON.stringify(array_power_bus_events)])
	if failures.size() > 0:
		return
	var array_final_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var array_final_inventory: Dictionary = array_final_bulk.get("inventory", {})
	_check(int(array_final_inventory.get("quantum_component", 0)) >= 4 and int(array_final_inventory.get("steel_composite", 0)) >= 4 and int(array_final_inventory.get("titanium_alloy", 0)) >= 0 and int(array_final_inventory.get("fusion_service_component", 0)) >= 2 and int(array_final_inventory.get("power_bus_component", 0)) >= 3 and int(array_final_inventory.get("heavy_structural_section", 0)) >= 2, "Earth Bulk retains every non-helium physical Energy Array construction item after bounded Factory production; inventory=%s" % JSON.stringify(array_final_inventory))
	if failures.size() > 0:
		return
	var array_helium_location: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(array_helium_location.get("helium_3", 0)) >= 6, "Earth Location retains the exact six-unit Jovian guardian helium reward in public custody for Energy Array funding; available=%s" % JSON.stringify(array_helium_location))
	if failures.size() > 0:
		return
	var array_queued := _factory_command("QUEUE_CONSTRUCTION", {"definition_id":"grid_energy_array", "recipe_id":"", "origin":{"x":400, "y":180}, "priority":50})
	var array_order_id := str(array_queued.get("result", {}).get("order_id", ""))
	var array_entity_id := str(array_queued.get("result", {}).get("entity_id", ""))
	_check(bool(array_queued.get("accepted", false)) and not array_order_id.is_empty() and not array_entity_id.is_empty(), "Factory queues the exact public Energy Array construction order; result=%s" % JSON.stringify(array_queued))
	if failures.size() > 0:
		return
	var array_factory_funding := _factory_command("FUND_CONSTRUCTION", {"order_id":array_order_id, "storage_id":cruiser_bulk_depot_id})
	_check(bool(array_factory_funding.get("accepted", false)) and int((array_factory_funding.get("result", {}).get("moved", {}) as Dictionary).get("steel_composite", 0)) == 4 and int((array_factory_funding.get("result", {}).get("moved", {}) as Dictionary).get("quantum_component", 0)) == 4 and int((array_factory_funding.get("result", {}).get("moved", {}) as Dictionary).get("fusion_service_component", 0)) == 2 and int((array_factory_funding.get("result", {}).get("moved", {}) as Dictionary).get("power_bus_component", 0)) == 3 and int((array_factory_funding.get("result", {}).get("moved", {}) as Dictionary).get("heavy_structural_section", 0)) == 2, "Earth Factory funds the complete non-helium Energy Array BOM from exact Bulk custody; result=%s" % JSON.stringify(array_factory_funding))
	if failures.size() > 0:
		return
	var array_location_funding := _factory_command("FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":array_order_id})
	_check(bool(array_location_funding.get("accepted", false)) and bool(array_location_funding.get("result", {}).get("fully_funded", false)) and int((array_location_funding.get("result", {}).get("moved", {}) as Dictionary).get("helium_3", 0)) == 6, "same-location public funding consumes the exact Jovian guardian helium reward and fully funds the Energy Array; result=%s" % JSON.stringify(array_location_funding))
	if failures.size() > 0:
		return
	var array_construction_events := _advance(240000.0, "J10 Energy Array construction")
	var array_runtime := _entity(_snapshot(EARTH_WORLD_ID), array_entity_id)
	_check(array_construction_events.any(func(event_value):
		var array_construction_event := event_value as Dictionary
		return str(array_construction_event.get("type", "")) == "FactoryConstructionCompleted" and str(array_construction_event.get("entity_id", "")) == array_entity_id and str(array_construction_event.get("definition_id", "")) == "grid_energy_array"
	) and str(array_runtime.get("definition_id", "")) == "grid_energy_array" and float(array_runtime.get("power_generation_kw", 0.0)) >= 2400.0, "Factory physically completes the canonical Energy Array provider from its exact mixed-custody BOM; entity=%s events=%s" % [JSON.stringify(array_runtime), JSON.stringify(array_construction_events)])
	if failures.size() > 0:
		return
	# The completed Energy Array—not the temporary provider used while producing
	# its parts—must physically power the Research Complex for this field test.
	# Prove the field test is actually restored by this newly completed Array.
	# Remove every historic provider edge to the Research Complex first; merely
	# connecting the Array alongside an older solar or substation link would not
	# establish the required causal custody.
	for array_prior_power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var array_prior_power_link := array_prior_power_link_value as Dictionary
		if str(array_prior_power_link.get("kind", "")) == "POWER" and str(array_prior_power_link.get("target_id", "")) == jovian_research_complex_id:
			var array_prior_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(array_prior_power_link.get("id", ""))})
			_check(bool(array_prior_power_removed.get("accepted", false)), "public Factory protocol removes a historic Research Complex POWER edge before the Energy Array causality proof; result=%s" % JSON.stringify(array_prior_power_removed))
	if failures.size() > 0:
		return
	var array_unpowered_links: Array = (_snapshot(EARTH_WORLD_ID).get("links", []) as Array).filter(func(link_value):
		var link := link_value as Dictionary
		return str(link.get("kind", "")) == "POWER" and str(link.get("target_id", "")) == jovian_research_complex_id
	)
	var array_unpowered_runtime: Dictionary = game.research_runtime_snapshot()
	var array_unpowered_capacity_blockers: Array = game.active_blockers().filter(func(blocker_value):
		var blocker := blocker_value as Dictionary
		return str(blocker.get("domain", "")) == "research" and str(blocker.get("project_id", "")) == "research_jovian_operations" and str(blocker.get("primary_reason", "")) == "RESEARCH_CAPACITY_SHORTAGE"
	)
	_check(array_unpowered_links.is_empty() and str(array_unpowered_runtime.get("status", "")) == "BLOCKED" and not array_unpowered_capacity_blockers.is_empty(), "without any incoming Research Complex POWER edge, the Energy Array field test is visibly capacity-blocked before causal reconnection; links=%s runtime=%s blockers=%s" % [JSON.stringify(array_unpowered_links), JSON.stringify(array_unpowered_runtime), JSON.stringify(array_unpowered_capacity_blockers)])
	if failures.size() > 0:
		return
	_ensure_connection("POWER", array_entity_id, jovian_research_complex_id, "")
	var array_power_links: Array = (_snapshot(EARTH_WORLD_ID).get("links", []) as Array).filter(func(link_value):
		var link := link_value as Dictionary
		return str(link.get("kind", "")) == "POWER" and str(link.get("target_id", "")) == jovian_research_complex_id
	)
	var array_power_link_present := array_power_links.size() == 1 and str((array_power_links[0] as Dictionary).get("source_id", "")) == array_entity_id
	var array_research_complex_runtime := _entity(_snapshot(EARTH_WORLD_ID), jovian_research_complex_id)
	var array_field_test_runtime_before: Dictionary = game.research_runtime_snapshot()
	var array_field_test_capacity_blockers: Array = game.active_blockers().filter(func(blocker_value):
		var blocker := blocker_value as Dictionary
		return str(blocker.get("domain", "")) == "research" and str(blocker.get("project_id", "")) == "research_jovian_operations" and str(blocker.get("primary_reason", "")) == "RESEARCH_CAPACITY_SHORTAGE"
	)
	_check(array_power_link_present and float(array_research_complex_runtime.get("power_factor", 0.0)) == 1.0 and str(array_field_test_runtime_before.get("project_id", "")) == "research_jovian_operations" and str(array_field_test_runtime_before.get("status", "")) == "RUNNING" and array_field_test_capacity_blockers.is_empty(), "the completed Energy Array is the sole direct provider to the Jovian Research Complex adapter, restoring the field test to RUNNING without a capacity blocker; array=%s links=%s complex=%s runtime=%s blockers=%s" % [array_entity_id, JSON.stringify(array_power_links), JSON.stringify(array_research_complex_runtime), JSON.stringify(array_field_test_runtime_before), JSON.stringify(array_field_test_capacity_blockers)])
	if failures.size() > 0:
		return
	var array_field_test_events := _advance(60000.0, "J10 Jovian Operations Energy Array field test")
	var jovian_operations_runtime: Dictionary = game.research_runtime_snapshot()
	_check(array_field_test_events.any(func(event_value):
		var array_field_event := event_value as Dictionary
		return str(array_field_event.get("type", "")) == "ResearchCompleted" and str(array_field_event.get("project_id", "")) == "research_jovian_operations" and str(array_field_event.get("technology_id", "")) == "jovian_operations"
	) and str(jovian_operations_runtime.get("status", "")) == "COMPLETE" and str(jovian_operations_runtime.get("project_id", "")) == "", "the public Energy Array field test completes Jovian Operations with a real ResearchCompleted event and a completed, project-free public research runtime; events=%s runtime=%s" % [JSON.stringify(array_field_test_events), JSON.stringify(jovian_operations_runtime)])
	if failures.size() > 0:
		return

	# Outer-system industry starts with a normal public survey of the unlocked
	# Jovian region.  Stage only the canonical finite SURVEYED package at Earth;
	# every shortfall is exported from a named public Factory storage and the
	# survey itself consumes that Location custody instead of accepting a hidden
	# bootstrap grant.
	for gas_survey_policy_item in ["chemical_propellant", "repair_material", "industrial_machine_tools", "structural_frame", "electronics"]:
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, str(gas_survey_policy_item))
		game.clear_location_logistics_policy("gas_giant_region", str(gas_survey_policy_item))
	var gas_survey_manifest := {
		"chemical_propellant":2,
		"repair_material":1,
		"industrial_machine_tools":1,
		"structural_frame":2,
		"electronics":2
	}
	var gas_survey_staging := {}
	for gas_survey_manifest_item_value in gas_survey_manifest:
		var gas_survey_manifest_item := str(gas_survey_manifest_item_value)
		gas_survey_staging[gas_survey_manifest_item] = _stage_location_shortfall_from_factory(gas_survey_manifest_item, int(gas_survey_manifest.get(gas_survey_manifest_item, 0)), "J10 Jovian DETECTED-to-SURVEYED mission package")
	if failures.size() > 0:
		return
	var gas_survey_availability: Dictionary = game.survey_mission_availability("gas_giant_region", "SURVEYED", [pathfinder_ship_id], EARTH_LOCATION_ID)
	_check(bool(gas_survey_availability.get("allowed", false)), "public Survey availability accepts the route-unlocked Jovian region with the exact Factory-backed mission package; availability=%s staging=%s" % [JSON.stringify(gas_survey_availability), JSON.stringify(gas_survey_staging)])
	if not bool(gas_survey_availability.get("allowed", false)) or failures.size() > 0:
		return
	var gas_survey_events_start := observed_events.size()
	_check(bool(game.start_survey_mission("gas_giant_region", "SURVEYED", [pathfinder_ship_id], EARTH_LOCATION_ID)), "public Survey command starts the canonical Jovian DETECTED-to-SURVEYED mission with the constructed Pathfinder")
	var gas_survey_events := _advance(60000.0, "J10 Jovian gas-giant industrial survey")
	var gas_survey_completion := _first_event(gas_survey_events, "SurveyMissionCompleted")
	_check(str(gas_survey_completion.get("target", "")) == "gas_giant_region" and str(gas_survey_completion.get("survey_state", "")) == "SURVEYED" and _ordered_types(["SurveyMissionStarted", "SurveyMissionCompleted"], _events_after(gas_survey_events_start)), "J10 completes the exact Jovian DETECTED-to-SURVEYED mission through public time advancement; completion=%s events=%s" % [JSON.stringify(gas_survey_completion), JSON.stringify(gas_survey_events)])
	if failures.size() > 0:
		return
	_check(bool(game.initialize_surveyed_factory_world("gas_giant_region")), "public Survey completion initializes the Jovian Factory workspace for physical methane and superalloy industry")
	var jovian_world_ids: Array[String] = game.factory_world_ids_for_location("gas_giant_region")
	var jovian_world_id := str(jovian_world_ids[0] if jovian_world_ids.size() == 1 else "")
	var jovian_factory_snapshot := _snapshot(jovian_world_id)
	_check(jovian_world_ids.size() == 1 and bool(jovian_factory_snapshot.get("valid", false)) and not _resource_field(jovian_factory_snapshot, "methane").is_empty(), "the public Factory-world query exposes one initialized Jovian workspace with its methane field; world_ids=%s snapshot=%s" % [JSON.stringify(jovian_world_ids), JSON.stringify(jovian_factory_snapshot)])
	if failures.size() > 0:
		return


func _connect(link_kind: String, source_id: String, target_id: String, item_id: String, world_id: String = EARTH_WORLD_ID) -> void:
	var payload := {"link_kind":link_kind, "source_id":source_id, "target_id":target_id}
	if link_kind == "CARGO":
		payload["item_id"] = item_id
		payload["capacity_per_second"] = 4.0
	var result := _factory_command("CONNECT_ENTITIES", payload, world_id)
	_check(bool(result.get("accepted", false)), "%s connection is accepted for %s -> %s item=%s; result=%s" % [link_kind, source_id, target_id, item_id, JSON.stringify(result)])
	if bool(result.get("accepted", false)):
		var events: Array = result.get("events", [])
		_check(events.size() == 1 and str((events[0] as Dictionary).get("type", "")) == "FactoryEntitiesConnected", "Factory connection result returns one correlated event")


## Prepare one finite machine manifest without allowing its cargo-transfer
## boundary to opportunistically begin production.  Later J10 slices use this
## shape whenever a real Factory buffer must be preserved: all target POWER
## edges are retired first, inputs are staged for one bounded CARGO window,
## their edges are retired, and only then is one named provider connected.
func _cold_stage_recipe_batch(machine_id: String, recipe_id: String, power_source_id: String, input_specs: Array, output_target_id: String, output_item_id: String, production_ms: float, label: String, world_id: String = EARTH_WORLD_ID) -> Array:
	for power_link_value in _snapshot(world_id).get("links", []):
		var power_link := power_link_value as Dictionary
		if str(power_link.get("kind", "")) != "POWER" or str(power_link.get("target_id", "")) != machine_id:
			continue
		var power_removed := _factory_command("REMOVE_LINK", {"link_id":str(power_link.get("id", ""))}, world_id)
		_check(bool(power_removed.get("accepted", false)), "%s removes a live POWER link before bounded cold staging; result=%s" % [label, JSON.stringify(power_removed)])
	if failures.size() > 0:
		return []
	var cold_power_links: Array = (_snapshot(world_id).get("links", []) as Array).filter(func(link_value):
		var link := link_value as Dictionary
		return str(link.get("kind", "")) == "POWER" and str(link.get("target_id", "")) == machine_id
	)
	_check(cold_power_links.is_empty(), "%s confirms its target machine is cold before real input custody moves; links=%s" % [label, JSON.stringify(cold_power_links)])
	if failures.size() > 0:
		return []
	var recipe_result := _factory_command("SET_RECIPE", {"entity_id":machine_id, "recipe_id":recipe_id}, world_id)
	_check(bool(recipe_result.get("accepted", false)), "%s selects its canonical Factory recipe through protocol v1" % label)
	if failures.size() > 0:
		return []
	var recipe_definition: Dictionary = {}
	for recipe_value in (_snapshot(world_id).get("palette", {}) as Dictionary).get("recipes", []):
		var palette_recipe := recipe_value as Dictionary
		if str(palette_recipe.get("id", "")) == recipe_id:
			recipe_definition = palette_recipe
			break
	_check(not recipe_definition.is_empty(), "%s resolves its canonical recipe definition from the public Factory palette" % label)
	if failures.size() > 0:
		return []
	var recipe_inputs := {}
	for recipe_input_value in recipe_definition.get("inputs", []):
		var recipe_input := recipe_input_value as Dictionary
		recipe_inputs[str(recipe_input.get("item", ""))] = int(recipe_input.get("quantity", 0))
	var expected_cycles := -1
	for input_value in input_specs:
		var input := input_value as Dictionary
		var item_id := str(input.get("item_id", ""))
		var source_id := str(input.get("source_id", ""))
		var quantity := int(input.get("quantity", 0))
		var per_cycle := int(recipe_inputs.get(item_id, 0))
		_check(not item_id.is_empty() and not source_id.is_empty() and quantity > 0 and per_cycle > 0 and quantity % per_cycle == 0, "%s has a finite whole-cycle cold-staging input manifest matching its public recipe; input=%s recipe=%s" % [label, JSON.stringify(input), JSON.stringify(recipe_definition)])
		var input_cycles := quantity / per_cycle
		if expected_cycles < 0:
			expected_cycles = input_cycles
		else:
			_check(expected_cycles == input_cycles, "%s cold manifest carries the same exact number of cycles for every recipe input; item=%s expected=%d actual=%d" % [label, item_id, expected_cycles, input_cycles])
	_check(expected_cycles > 0 and recipe_inputs.size() == input_specs.size(), "%s cold manifest covers every canonical recipe input exactly once; recipe_inputs=%s manifest=%s" % [label, JSON.stringify(recipe_inputs), JSON.stringify(input_specs)])
	if failures.size() > 0:
		return []
	if not output_item_id.is_empty() and not output_target_id.is_empty():
		_clear_competing_cargo_inputs(output_target_id, output_item_id, machine_id, world_id)
		_clear_competing_cargo_outputs(output_target_id, output_item_id, "", world_id)
		_clear_competing_cargo_outputs(machine_id, output_item_id, output_target_id, world_id)
		_ensure_connection("CARGO", machine_id, output_target_id, output_item_id, world_id)
	var staged_inputs := {}
	for input_value in input_specs:
		var input := input_value as Dictionary
		var item_id := str(input.get("item_id", ""))
		var source_id := str(input.get("source_id", ""))
		var quantity := int(input.get("quantity", 0))
		var before_snapshot := _snapshot(world_id)
		var source_before := int(_entity(before_snapshot, source_id).get("inventory", {}).get(item_id, 0))
		var machine_before := int(_entity(before_snapshot, machine_id).get("inputs", {}).get(item_id, 0))
		var required_quantity := int(recipe_inputs.get(item_id, 0)) * expected_cycles
		_check(machine_before <= required_quantity, "%s refuses an overfilled retained %s buffer that would exceed its exact manifest; required=%d machine=%s" % [label, item_id, required_quantity, JSON.stringify(_entity(before_snapshot, machine_id))])
		if failures.size() > 0:
			return []
		var deficit := required_quantity - machine_before
		var item_staging_events: Array = []
		if deficit > 0:
			_clear_competing_cargo_inputs(machine_id, item_id, source_id, world_id)
			_ensure_connection("CARGO", source_id, machine_id, item_id, world_id)
			item_staging_events = _advance(float(deficit) / 4.0 * 1000.0, "%s exact %s cold input staging" % [label, item_id])
		var item_cold_cycle_seen := item_staging_events.any(func(event_value):
			var event := event_value as Dictionary
			return str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == world_id and str(event.get("entity_id", "")) == machine_id and str(event.get("recipe_id", "")) == recipe_id
		)
		var after_snapshot := _snapshot(world_id)
		var source_after := int(_entity(after_snapshot, source_id).get("inventory", {}).get(item_id, 0))
		var machine_after := int(_entity(after_snapshot, machine_id).get("inputs", {}).get(item_id, 0))
		_check(not item_cold_cycle_seen and source_after == source_before - deficit and machine_after == required_quantity, "%s transfers the exact %d-unit %s deficit across one cold public CARGO boundary and retains the required total; source_before=%d source_after=%d machine_before=%d required=%d machine_after=%d events=%s" % [label, deficit, item_id, source_before, source_after, machine_before, required_quantity, machine_after, JSON.stringify(item_staging_events)])
		_clear_competing_cargo_inputs(machine_id, item_id, "", world_id)
		staged_inputs[item_id] = machine_after
		if failures.size() > 0:
			return []
	var expected_staged_inputs := {}
	for recipe_item_id_value in recipe_inputs:
		var recipe_item_id := str(recipe_item_id_value)
		expected_staged_inputs[recipe_item_id] = int(recipe_inputs.get(recipe_item_id, 0)) * expected_cycles
	var staged_machine := _entity(_snapshot(world_id), machine_id)
	_check(staged_inputs == expected_staged_inputs, "%s completes a finite cold staging manifest before POWER is restored; staged=%s expected=%s machine=%s" % [label, JSON.stringify(staged_inputs), JSON.stringify(expected_staged_inputs), JSON.stringify(staged_machine)])
	if failures.size() > 0:
		return []
	var statistics_before: Dictionary = (_snapshot(world_id).get("statistics", {}) as Dictionary).duplicate(true)
	var output_before := int(_entity(_snapshot(world_id), output_target_id).get("inventory", {}).get(output_item_id, 0))
	_isolate_all_machine_power_for_target(machine_id, world_id)
	_ensure_connection("POWER", power_source_id, machine_id, "", world_id)
	var production_events := _advance(production_ms, "%s powered finite production" % label)
	var statistics_after: Dictionary = _snapshot(world_id).get("statistics", {}) as Dictionary
	var consumed_before: Dictionary = statistics_before.get("consumed", {}) as Dictionary
	var consumed_after: Dictionary = statistics_after.get("consumed", {}) as Dictionary
	var produced_before: Dictionary = statistics_before.get("produced", {}) as Dictionary
	var produced_after: Dictionary = statistics_after.get("produced", {}) as Dictionary
	for item_id_value in recipe_inputs:
		var input_item_id := str(item_id_value)
		_check(int(consumed_after.get(input_item_id, 0)) == int(consumed_before.get(input_item_id, 0)) + int(recipe_inputs.get(input_item_id, 0)) * expected_cycles, "%s records exact public Factory statistics consumption for %s" % [label, input_item_id])
	var output_per_cycle := 0
	for recipe_output_value in recipe_definition.get("outputs", []):
		var recipe_output := recipe_output_value as Dictionary
		if str(recipe_output.get("item", "")) == output_item_id:
			output_per_cycle = int(recipe_output.get("quantity", 0))
	var target_outbound: Array = (_snapshot(world_id).get("links", []) as Array).filter(func(link_value):
		var link := link_value as Dictionary
		return str(link.get("kind", "")) == "CARGO" and str(link.get("source_id", "")) == output_target_id and str(link.get("item_id", "")) == output_item_id
	)
	var scoped_cycles := 0
	var scoped_produced := 0
	for production_event_value in production_events:
		var production_event := production_event_value as Dictionary
		if str(production_event.get("type", "")) == "FactoryRecipeCompleted" and str(production_event.get("world_id", "")) == world_id and str(production_event.get("entity_id", "")) == machine_id and str(production_event.get("recipe_id", "")) == recipe_id:
			scoped_cycles += int(production_event.get("completed_cycles", 0))
			scoped_produced += int((production_event.get("produced", {}) as Dictionary).get(output_item_id, 0))
	_check(output_per_cycle > 0 and scoped_cycles == expected_cycles and scoped_produced == output_per_cycle * expected_cycles and int(produced_after.get(output_item_id, 0)) == int(produced_before.get(output_item_id, 0)) + output_per_cycle * expected_cycles and int(_entity(_snapshot(world_id), output_target_id).get("inventory", {}).get(output_item_id, 0)) == output_before + output_per_cycle * expected_cycles and target_outbound.is_empty(), "%s records exact scoped recipe cycles, production, and isolated public-storage custody; output_before=%d output_after=%d cycles=%d produced=%d events=%s outbound=%s" % [label, output_before, int(_entity(_snapshot(world_id), output_target_id).get("inventory", {}).get(output_item_id, 0)), scoped_cycles, scoped_produced, JSON.stringify(production_events), JSON.stringify(target_outbound)])
	return production_events


func _isolate_all_machine_power_for_target(target_machine_id: String, world_id: String = EARTH_WORLD_ID) -> void:
	var snapshot := _snapshot(world_id)
	var machine_ids := {}
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("node_kind", "")) == "MACHINE":
			machine_ids[str(entity.get("id", ""))] = true
	for link_value in snapshot.get("links", []):
		var link := link_value as Dictionary
		if str(link.get("kind", "")) != "POWER" or str(link.get("target_id", "")) == target_machine_id or not machine_ids.has(str(link.get("target_id", ""))):
			continue
		var result := _factory_command("REMOVE_LINK", {"link_id":str(link.get("id", ""))}, world_id)
		_check(bool(result.get("accepted", false)), "Factory protocol isolates all non-target machine POWER edges for deterministic recipe statistics")


func _ensure_connection(link_kind: String, source_id: String, target_id: String, item_id: String, world_id: String = EARTH_WORLD_ID) -> void:
	for link_value in _snapshot(world_id).get("links", []):
		var link := link_value as Dictionary
		if str(link.get("kind", "")) == link_kind and str(link.get("source_id", "")) == source_id and str(link.get("target_id", "")) == target_id and (link_kind != "CARGO" or str(link.get("item_id", "")) == item_id):
			return
	_connect(link_kind, source_id, target_id, item_id, world_id)


func _clear_competing_cargo_inputs(target_id: String, item_id: String, retained_source_id: String, world_id: String = EARTH_WORLD_ID) -> void:
	for link_value in _snapshot(world_id).get("links", []):
		var link := link_value as Dictionary
		if str(link.get("kind", "")) != "CARGO" or str(link.get("target_id", "")) != target_id or str(link.get("item_id", "")) != item_id or str(link.get("source_id", "")) == retained_source_id:
			continue
		var result := _factory_command("REMOVE_LINK", {"link_id":str(link.get("id", ""))}, world_id)
		_check(bool(result.get("accepted", false)), "Factory protocol clears the incompatible competing %s cargo input" % item_id)


func _clear_competing_cargo_outputs(source_id: String, item_id: String, retained_target_id: String, world_id: String = EARTH_WORLD_ID) -> void:
	for link_value in _snapshot(world_id).get("links", []):
		var link := link_value as Dictionary
		if str(link.get("kind", "")) != "CARGO" or str(link.get("source_id", "")) != source_id or str(link.get("item_id", "")) != item_id or str(link.get("target_id", "")) == retained_target_id:
			continue
		var result := _factory_command("REMOVE_LINK", {"link_id":str(link.get("id", ""))}, world_id)
		_check(bool(result.get("accepted", false)), "Factory protocol clears the competing %s cargo output" % item_id)


func _factory_command(kind: String, payload: Dictionary, world_id: String = EARTH_WORLD_ID) -> Dictionary:
	var snapshot := _snapshot(world_id)
	_command_sequence += 1
	var command_id := "runtime-gate-%03d" % _command_sequence
	var result: Dictionary = game.execute_factory_command({
		"protocol_version":PROTOCOL_VERSION,
		"command_id":command_id,
		"kind":kind,
		"world_id":world_id,
		"base_topology_revision":int(snapshot.get("topology_revision", -1)),
		"base_runtime_revision":int(snapshot.get("runtime_revision", -1)),
		"payload":payload
	})
	for event_value in result.get("events", []):
		_record_event(event_value as Dictionary)
	return result


func _snapshot(world_id: String) -> Dictionary:
	return game.factory_workspace_snapshot(world_id)


func _entity(snapshot: Dictionary, entity_id: String) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity
	return {}


func _entity_with_recipe(snapshot: Dictionary, recipe_id: String) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("recipe_id", "")) == recipe_id:
			return entity
	return {}


func _entity_with_resource(snapshot: Dictionary, resource_id: String) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("resource_id", "")) == resource_id:
			return entity
	return {}


func _resource_field(snapshot: Dictionary, resource_id: String) -> Dictionary:
	for field_value in snapshot.get("resource_fields", []):
		var field := field_value as Dictionary
		if str(field.get("resource_id", "")) == resource_id:
			return field
	return {}


func _entity_with_definition(snapshot: Dictionary, definition_id: String) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("definition_id", "")) == definition_id:
			return entity
	return {}


func _entity_with_inventory_item(snapshot: Dictionary, item_id: String, minimum_quantity: int) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if int((entity.get("inventory", {}) as Dictionary).get(item_id, 0)) >= minimum_quantity:
			return entity
	return {}


func _entities_with_definition(snapshot: Dictionary, definition_id: String) -> Array:
	var matches: Array = []
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("definition_id", "")) == definition_id:
			matches.append(entity)
	return matches


func _advance(elapsed_ms: float, label: String) -> Array:
	var report: Dictionary = game.advance_game_time(elapsed_ms)
	_check(float(report.get("unprocessed_ms", 1.0)) <= 0.001, "%s drains its requested deterministic time window" % label)
	var events: Array = report.get("events", [])
	for event_value in events:
		_record_event(event_value as Dictionary)
	return events


func _on_domain_event(event: Dictionary) -> void:
	_record_event(event)


func _record_event(event: Dictionary) -> void:
	if event.is_empty():
		return
	var fingerprint := _event_fingerprint(event)
	if observed_events.any(func(existing): return _event_fingerprint(existing as Dictionary) == fingerprint):
		return
	observed_events.append(event.duplicate(true))


func _event_fingerprint(event: Dictionary) -> String:
	return "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % [str(event.get("type", "")), str(event.get("world_id", "")), str(event.get("location_id", "")), str(event.get("route_id", "")), str(event.get("command_id", "")), str(event.get("order_id", "")), str(event.get("entity_id", "")), str(event.get("recipe_id", "")), str(event.get("shipment_id", "")), str(event.get("project_id", "")), str(event.get("target", "")), str(event.get("megastructure_id", "")), str(event.get("stage_index", "")), str(event.get("phase_index", "")), str(event.get("phase_id", event.get("stage_id", event.get("activity_id", "")))), str(event.get("design_id", "")), str(event.get("plan_id", "")), str(event.get("ship_id", "")), str(event.get("formation_id", event.get("fleet_id", ""))), str(event.get("segments", "")), str(event.get("quantity_completed", "")), JSON.stringify(event.get("ship_ids", []))]


func _events_have_type(events: Array, type_id: String) -> bool:
	return events.any(func(event_value): return str((event_value as Dictionary).get("type", "")) == type_id)


func _first_event(events: Array, type_id: String) -> Dictionary:
	for event_value in events:
		var event := event_value as Dictionary
		if str(event.get("type", "")) == type_id:
			return event
	return {}


func _events_have_recipe(events: Array, recipe_id: String) -> bool:
	return events.any(func(event_value): return str((event_value as Dictionary).get("type", "")) == "FactoryRecipeCompleted" and str((event_value as Dictionary).get("recipe_id", "")) == recipe_id)


func _events_with_activity(events: Array, type_id: String, activity_id: String) -> Array:
	return events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == type_id and str(event.get("activity_id", "")) == activity_id
	)


func _events_after(index: int) -> Array:
	return observed_events.slice(clampi(index, 0, observed_events.size()), observed_events.size())


func _ordered_types(required: Array[String], event_slice: Array = observed_events) -> bool:
	var cursor := 0
	for event_value in event_slice:
		if cursor < required.size() and str((event_value as Dictionary).get("type", "")) == required[cursor]:
			cursor += 1
	return cursor == required.size()


func _journey_pass(short_id: String, name: String) -> void:
	if failures.is_empty():
		passed_journeys[short_id] = true
		print("PASS %s: %s" % [short_id, name])


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	elif not failures.has(message):
		failures.append(message)


func _finish() -> void:
	for journey_id in REQUIRED_JOURNEYS:
		if not journey_limit.is_empty() and REQUIRED_JOURNEYS.find(journey_id) > REQUIRED_JOURNEYS.find(journey_limit):
			continue
		if not passed_journeys.has(journey_id):
			failures.append("runtime journey was not executed: %s" % journey_id)
	if game != null and game.domain_event.is_connected(_on_domain_event):
		game.domain_event.disconnect(_on_domain_event)
	if failures.is_empty():
		print("CORE_GAMEPLAY_RUNTIME_GATE_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: " + failure)
	quit(1)


func _journey_limit_reached(completed_journey_id: String) -> bool:
	return not journey_limit.is_empty() and completed_journey_id == journey_limit
