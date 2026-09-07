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
const RUNTIME_GATE_BUILD := "event-stream-v2"

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
	var location_funded := {}
	if include_location_inventory:
		location_funded = _factory_command("FUND_CONSTRUCTION_FROM_LOCATION", {"order_id":order_id}, world_id)
		_check(bool(location_funded.get("accepted", false)), "same-location inventory completes physical funding for %s; result=%s" % [label, JSON.stringify(location_funded)])
	return {"order_id":order_id, "entity_id":entity_id, "location_funding":location_funded}


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
	var expected_moved := maxi(0, target_available - before_available)
	_check(remaining == 0 and after_available == before_available + expected_moved and after_available >= target_available, "public Factory custody stages the finite %s Location shortfall for %s without treating pre-existing availability as an error; before=%d target=%d expected_moved=%d after=%d sources=%s" % [item_id, label, before_available, target_available, expected_moved, after_available, JSON.stringify(source_breakdown)])
	return {"before":before_available, "after":after_available, "moved":expected_moved, "sources":source_breakdown}


## Move one finite, item-keyed Earth Factory manifest to a remote surveyed
## Location.  Every cargo item gets an independent public policy; the helper
## stages only the finite three-hop operating reserve at Earth and retires each
## policy once its shipment identities have settled.
func _freight_earth_manifest_to_remote(remote_location_id: String, remote_world_id: String, manifest: Dictionary, label: String, path_costs: Dictionary, repair_recovery: Dictionary = {}) -> Dictionary:
	var manifest_items: Array[String] = []
	for item_value in manifest:
		var item_id := str(item_value)
		if int(manifest.get(item_id, 0)) > 0:
			manifest_items.append(item_id)
	manifest_items.sort()
	_check(not manifest_items.is_empty(), "%s supplies at least one finite Earth-to-remote cargo item" % label)
	if failures.size() > 0:
		return {}
	var remote_before: Dictionary = (_snapshot(remote_world_id).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	for item_id in manifest_items:
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, item_id)
		game.clear_location_logistics_policy(remote_location_id, item_id)
	var shipment_count := manifest_items.size()
	var operating_costs := {"chemical_propellant":shipment_count * int(path_costs.get("chemical_propellant", 0)), "repair_material":shipment_count * int(path_costs.get("repair_material", 0))}
	var repair_payload := int(manifest.get("repair_material", 0))
	var propellant_payload := int(manifest.get("chemical_propellant", 0))
	# A construction/repair pass advances time, so converge both operating reserves
	# against fresh public projections immediately before manifest staging.  The
	# physical-machine packet keeps recovery on the public Factory path, while the
	# retained manifest prevents repair/propellant recipes from consuming cargo.
	for repair_recovery_pass in range(2):
		var repair_target := repair_payload + int((game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", int(operating_costs.get("repair_material", 0)), 5000.0) as Dictionary).get("gross_production_target", 0))
		var propellant_target := propellant_payload + int((game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", int(operating_costs.get("chemical_propellant", 0)), 5000.0) as Dictionary).get("gross_production_target", 0))
		var repair_total := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
		var propellant_total := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("chemical_propellant", 0))
		for repair_entity_value in _snapshot(EARTH_WORLD_ID).get("entities", []):
			var repair_entity_inventory := (repair_entity_value as Dictionary).get("inventory", {}) as Dictionary
			repair_total += int(repair_entity_inventory.get("repair_material", 0))
			propellant_total += int(repair_entity_inventory.get("chemical_propellant", 0))
		var repair_shortfall := maxi(0, repair_target - repair_total)
		var propellant_shortfall := maxi(0, propellant_target - propellant_total)
		if repair_shortfall <= 0 and propellant_shortfall <= 0:
			break
		_check(not repair_recovery.is_empty(), "%s exposes an explicit public operating-production packet whenever the exact remote freight reserve is physically short; propellant_target=%d propellant_total=%d propellant_shortfall=%d repair_target=%d repair_total=%d repair_shortfall=%d" % [label, propellant_target, propellant_total, propellant_shortfall, repair_target, repair_total, repair_shortfall])
		if failures.size() > 0:
			return {}
		var recovered_works_id := str(repair_recovery.get("engineering_works_id", ""))
		var recovery_storage_id := str(repair_recovery.get("bulk_storage_id", ""))
		var recovery_storage_before := int((_entity(_snapshot(EARTH_WORLD_ID), recovery_storage_id).get("inventory", {}) as Dictionary).get("repair_material", 0))
		var recovery_propellant_before := int((_entity(_snapshot(EARTH_WORLD_ID), recovery_storage_id).get("inventory", {}) as Dictionary).get("chemical_propellant", 0))
		_manufacture_earth_operating_shortfall(recovery_propellant_before + propellant_shortfall, recovery_storage_before + repair_shortfall, str(repair_recovery.get("copper_refinery_id", "")), recovered_works_id, str(repair_recovery.get("power_source_id", "")), recovery_storage_id, "%s public renewable operating-reserve recovery pass %d" % [label, repair_recovery_pass + 1], manifest)
		repair_recovery["engineering_works_id"] = recovered_works_id
		if recovered_works_id.is_empty() or failures.size() > 0:
			return {}
	var final_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", int(operating_costs.get("repair_material", 0)), 5000.0)
	var final_propellant_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", int(operating_costs.get("chemical_propellant", 0)), 5000.0)
	var final_repair_target := repair_payload + int(final_repair_projection.get("gross_production_target", 0))
	var final_propellant_target := propellant_payload + int(final_propellant_projection.get("gross_production_target", 0))
	var final_repair_total := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
	var final_propellant_total := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("chemical_propellant", 0))
	for final_repair_entity_value in _snapshot(EARTH_WORLD_ID).get("entities", []):
		var final_operating_inventory := (final_repair_entity_value as Dictionary).get("inventory", {}) as Dictionary
		final_repair_total += int(final_operating_inventory.get("repair_material", 0))
		final_propellant_total += int(final_operating_inventory.get("chemical_propellant", 0))
	_check(final_repair_total >= final_repair_target and final_propellant_total >= final_propellant_target, "%s converges both operating reserves after bounded physical fabrication and before cargo staging; propellant_target=%d propellant_total=%d propellant_projection=%s repair_target=%d repair_total=%d repair_projection=%s" % [label, final_propellant_target, final_propellant_total, JSON.stringify(final_propellant_projection), final_repair_target, final_repair_total, JSON.stringify(final_repair_projection)])
	if failures.size() > 0:
		return {}
	var operating_projections := {}
	var source_targets: Dictionary = manifest.duplicate(true)
	for operating_item_value in operating_costs:
		var operating_item := str(operating_item_value)
		var spendable_target := int(operating_costs.get(operating_item, 0))
		var projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, operating_item, spendable_target, 5000.0)
		operating_projections[operating_item] = projection
		source_targets[operating_item] = int(source_targets.get(operating_item, 0)) + maxi(spendable_target, int(projection.get("gross_production_target", spendable_target)))
	for source_item_value in source_targets:
		var source_item := str(source_item_value)
		_stage_location_shortfall_from_factory(source_item, int(source_targets.get(source_item, 0)), "%s combined %s cargo and dispatch reserve" % [label, source_item])
	if failures.size() > 0:
		return {}
	var earth_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	var policies_accepted := true
	for item_id in manifest_items:
		policies_accepted = policies_accepted and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, item_id, "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(remote_location_id, item_id, "DEMAND", 0, int(remote_before.get(item_id, 0)) + int(manifest.get(item_id, 0)), 100, 1))
	_check(policies_accepted, "public Logistics publishes every independent finite cargo policy for %s" % label)
	if failures.size() > 0:
		return {}
	var dispatch_events := _advance(5000.0, "%s remote-manifest dispatch" % label)
	var dispatch_cargo_by_id := {}
	var matched_dispatch_count := 0
	var dispatched_manifest_items := {}
	var singleton_dispatch_cargo := true
	var maximum_eta_ms := 0.0
	for event_value in dispatch_events:
		var event := event_value as Dictionary
		if str(event.get("type", "")) != "ShipmentDispatched" or str(event.get("origin", "")) != EARTH_LOCATION_ID or str(event.get("destination", "")) != remote_location_id:
			continue
		matched_dispatch_count += 1
		var shipment_id := str(event.get("shipment_id", ""))
		var shipment_cargo: Dictionary = (event.get("cargo", {}) as Dictionary).duplicate(true)
		dispatch_cargo_by_id[shipment_id] = shipment_cargo
		if shipment_cargo.size() != 1:
			singleton_dispatch_cargo = false
		else:
			var dispatched_item := str(shipment_cargo.keys()[0])
			if not manifest_items.has(dispatched_item) or dispatched_manifest_items.has(dispatched_item) or int(shipment_cargo.get(dispatched_item, 0)) != int(manifest.get(dispatched_item, 0)):
				singleton_dispatch_cargo = false
			else:
				dispatched_manifest_items[dispatched_item] = true
		maximum_eta_ms = maxf(maximum_eta_ms, float(event.get("eta_ms", 0.0)))
	var dispatch_totals := {}
	for item_id in manifest_items:
		dispatch_totals[item_id] = 0
	for cargo_value in dispatch_cargo_by_id.values():
		var cargo := cargo_value as Dictionary
		for item_id in manifest_items:
			dispatch_totals[item_id] = int(dispatch_totals.get(item_id, 0)) + int(cargo.get(item_id, 0))
	var earth_after_dispatch: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var remote_after_dispatch: Dictionary = (_snapshot(remote_world_id).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	var exact_manifest_dispatch := matched_dispatch_count == shipment_count and dispatch_cargo_by_id.size() == shipment_count and dispatched_manifest_items.size() == shipment_count and singleton_dispatch_cargo and not dispatch_cargo_by_id.has("") and maximum_eta_ms > 0.0
	for item_id in manifest_items:
		exact_manifest_dispatch = exact_manifest_dispatch and int(dispatch_totals.get(item_id, 0)) == int(manifest.get(item_id, 0))
	var debit_items: Dictionary = manifest.duplicate(true)
	for operating_item_value in operating_costs:
		var operating_item := str(operating_item_value)
		var operating_projection: Dictionary = operating_projections.get(operating_item, {}) as Dictionary
		debit_items[operating_item] = int(debit_items.get(operating_item, 0)) + int(operating_costs.get(operating_item, 0)) + int(operating_projection.get("recovery_quantity", 0))
	for debit_item_value in debit_items:
		var debit_item := str(debit_item_value)
		exact_manifest_dispatch = exact_manifest_dispatch and int(earth_after_dispatch.get(debit_item, 0)) == int(earth_before.get(debit_item, 0)) - int(debit_items.get(debit_item, 0))
	_check(exact_manifest_dispatch, "%s dispatches the exact finite remote manifest with one correlated cargo identity per item and the caller-declared public path-cost debit; manifest=%s path_costs=%s dispatch=%s before=%s after=%s projections=%s" % [label, JSON.stringify(manifest), JSON.stringify(path_costs), JSON.stringify(dispatch_cargo_by_id), JSON.stringify(earth_before), JSON.stringify(earth_after_dispatch), JSON.stringify(operating_projections)])
	if failures.size() > 0:
		return {}
	var destination_maintenance_projections := {}
	for item_id in manifest_items:
		destination_maintenance_projections[item_id] = game.maintenance_recovery_snapshot(remote_location_id, item_id, 0, maximum_eta_ms + 1000.0)
	var arrival_events := _advance(maximum_eta_ms + 1000.0, "%s remote-manifest arrival" % label)
	var arrival_cargo_by_id := {}
	var matched_arrival_count := 0
	var singleton_arrival_cargo := true
	for event_value in arrival_events:
		var event := event_value as Dictionary
		var arrival_id := str(event.get("shipment_id", ""))
		if str(event.get("type", "")) == "ShipmentArrived" and str(event.get("origin", "")) == EARTH_LOCATION_ID and str(event.get("destination", "")) == remote_location_id and dispatch_cargo_by_id.has(arrival_id):
			matched_arrival_count += 1
			var arrival_cargo: Dictionary = (event.get("cargo", {}) as Dictionary).duplicate(true)
			arrival_cargo_by_id[arrival_id] = arrival_cargo
			singleton_arrival_cargo = singleton_arrival_cargo and arrival_cargo.size() == 1
	var remote_after: Dictionary = _snapshot(remote_world_id).get("location_available_inventory", {})
	# The recovery helper is a finite cold conversion, not a renewable hidden
	# supplier.  No Earth repair recipe may complete between the manifest's
	# dispatch and its matched arrival boundary, regardless of which concrete
	# Engineering Works the public recovery selected.
	var repair_recipe_completed_during_freight := (dispatch_events + arrival_events).any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == EARTH_WORLD_ID and str(event.get("recipe_id", "")) == "grid_fabricate_repair_material"
	)
	var exact_manifest_arrival := matched_arrival_count == shipment_count and arrival_cargo_by_id.size() == shipment_count and singleton_arrival_cargo and arrival_cargo_by_id == dispatch_cargo_by_id
	var destination_maintenance_debits := {}
	for item_id in manifest_items:
		var expected_without_maintenance := int(remote_after_dispatch.get(item_id, 0)) + int(manifest.get(item_id, 0))
		var destination_maintenance_debit := expected_without_maintenance - int(remote_after.get(item_id, 0))
		destination_maintenance_debits[item_id] = destination_maintenance_debit
		var projected_debit := int((destination_maintenance_projections.get(item_id, {}) as Dictionary).get("recovery_quantity", 0))
		exact_manifest_arrival = exact_manifest_arrival and destination_maintenance_debit >= 0 and destination_maintenance_debit <= projected_debit
	_check(exact_manifest_arrival and not repair_recipe_completed_during_freight, "%s settles every finite remote shipment by the same public identity and a destination delta explained only by its public O&M projection; manifest=%s dispatch=%s arrival=%s before_dispatch=%s after_dispatch=%s after_arrival=%s maintenance_debits=%s projections=%s repair_recipe_completed=%s" % [label, JSON.stringify(manifest), JSON.stringify(dispatch_cargo_by_id), JSON.stringify(arrival_cargo_by_id), JSON.stringify(remote_before), JSON.stringify(remote_after_dispatch), JSON.stringify(remote_after), JSON.stringify(destination_maintenance_debits), JSON.stringify(destination_maintenance_projections), repair_recipe_completed_during_freight])
	for item_id in manifest_items:
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, item_id)
		game.clear_location_logistics_policy(remote_location_id, item_id)
	return {"dispatch":dispatch_cargo_by_id, "arrival":arrival_cargo_by_id, "before":remote_before, "after":remote_after, "operating_projections":operating_projections, "repair_works_id":str(repair_recovery.get("engineering_works_id", ""))}


## Settle one already-exported remote Location cargo to another Location.  This
## deliberately has no fabrication or inventory staging branch: callers first
## place the exact cargo and source operating reserve in physical Location
## custody, then this helper proves the single public shipment identity, path
## debit, and arrival before its policies are retired.
func _freight_location_cargo(origin_location_id: String, origin_world_id: String, destination_location_id: String, destination_world_id: String, item_id: String, quantity: int, path_costs: Dictionary, label: String) -> Dictionary:
	_check(not origin_location_id.is_empty() and not destination_location_id.is_empty() and not item_id.is_empty() and quantity > 0, "%s supplies a finite nonempty public remote freight manifest" % label)
	if failures.size() > 0:
		return {}
	game.clear_location_logistics_policy(origin_location_id, item_id)
	game.clear_location_logistics_policy(destination_location_id, item_id)
	var origin_before: Dictionary = (_snapshot(origin_world_id).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	var destination_before: Dictionary = (_snapshot(destination_world_id).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	var cp_cost := int(path_costs.get("chemical_propellant", 0))
	var repair_cost := int(path_costs.get("repair_material", 0))
	var cp_projection: Dictionary = game.maintenance_recovery_snapshot(origin_location_id, "chemical_propellant", cp_cost, 5000.0)
	var repair_projection: Dictionary = game.maintenance_recovery_snapshot(origin_location_id, "repair_material", repair_cost, 5000.0)
	_check(int(origin_before.get(item_id, 0)) >= quantity and int(origin_before.get("chemical_propellant", 0)) >= int(cp_projection.get("gross_production_target", cp_cost)) and int(origin_before.get("repair_material", 0)) >= int(repair_projection.get("gross_production_target", repair_cost)), "%s starts only with exact physical source cargo and public gross operating reserves; origin=%s cp_projection=%s repair_projection=%s" % [label, JSON.stringify(origin_before), JSON.stringify(cp_projection), JSON.stringify(repair_projection)])
	if failures.size() > 0:
		return {}
	_check(bool(game.set_location_logistics_policy(origin_location_id, item_id, "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy(destination_location_id, item_id, "DEMAND", 0, int(destination_before.get(item_id, 0)) + quantity, 100, 1)), "%s publishes a single finite public source/destination cargo policy" % label)
	if failures.size() > 0:
		return {}
	var dispatch_events := _advance(5000.0, "%s dispatch" % label)
	var dispatches: Array = dispatch_events.filter(func(event_value):
		var event := event_value as Dictionary
		var cargo := event.get("cargo", {}) as Dictionary
		return str(event.get("type", "")) == "ShipmentDispatched" and str(event.get("origin", "")) == origin_location_id and str(event.get("destination", "")) == destination_location_id and cargo.size() == 1 and int(cargo.get(item_id, 0)) == quantity
	)
	var origin_after_dispatch: Dictionary = _snapshot(origin_world_id).get("location_available_inventory", {})
	_check(dispatches.size() == 1 and not str((dispatches[0] as Dictionary).get("shipment_id", "")).is_empty() and float((dispatches[0] as Dictionary).get("eta_ms", 0.0)) > 0.0 and int(origin_after_dispatch.get(item_id, 0)) == int(origin_before.get(item_id, 0)) - quantity and int(origin_after_dispatch.get("chemical_propellant", 0)) == int(origin_before.get("chemical_propellant", 0)) - cp_cost - int(cp_projection.get("recovery_quantity", 0)) and int(origin_after_dispatch.get("repair_material", 0)) == int(origin_before.get("repair_material", 0)) - repair_cost - int(repair_projection.get("recovery_quantity", 0)), "%s dispatches one exact public cargo identity with exact source custody and per-route operating debit; dispatches=%s before=%s after=%s cp_projection=%s repair_projection=%s" % [label, JSON.stringify(dispatches), JSON.stringify(origin_before), JSON.stringify(origin_after_dispatch), JSON.stringify(cp_projection), JSON.stringify(repair_projection)])
	if failures.size() > 0:
		return {}
	var dispatch := dispatches[0] as Dictionary
	var shipment_id := str(dispatch.get("shipment_id", ""))
	var eta_ms := float(dispatch.get("eta_ms", 0.0))
	game.clear_location_logistics_policy(origin_location_id, item_id)
	game.clear_location_logistics_policy(destination_location_id, item_id)
	var arrival_events := _advance(eta_ms + 1000.0, "%s arrival" % label)
	var arrivals: Array = arrival_events.filter(func(event_value):
		var event := event_value as Dictionary
		var cargo := event.get("cargo", {}) as Dictionary
		return str(event.get("type", "")) == "ShipmentArrived" and str(event.get("shipment_id", "")) == shipment_id and str(event.get("origin", "")) == origin_location_id and str(event.get("destination", "")) == destination_location_id and cargo.size() == 1 and int(cargo.get(item_id, 0)) == quantity
	)
	var destination_after: Dictionary = _snapshot(destination_world_id).get("location_available_inventory", {})
	_check(arrivals.size() == 1 and int(destination_after.get(item_id, 0)) == int(destination_before.get(item_id, 0)) + quantity, "%s settles the exact single shipment into public destination Location custody; shipment=%s arrivals=%s before=%s after=%s" % [label, JSON.stringify(dispatch), JSON.stringify(arrivals), JSON.stringify(destination_before), JSON.stringify(destination_after)])
	game.clear_location_logistics_policy(origin_location_id, item_id)
	game.clear_location_logistics_policy(destination_location_id, item_id)
	return {"shipment_id":shipment_id, "eta_ms":eta_ms, "dispatch":dispatch, "arrival":arrivals[0] if not arrivals.is_empty() else {}, "before":origin_before, "after":destination_after}


## Produce a finite repair-material shortfall from already-built Earth machines.
## The caller derives the quantity solely from a public maintenance projection;
## this helper keeps the material path observable rather than treating freight
## operating reserve as a virtual balance.
func _fabricate_earth_repair_shortfall(required_cycles: int, copper_refinery_id: String, engineering_works_id: String, iron_refinery_id: String, power_source_id: String, bulk_storage_id: String, label: String) -> String:
	if required_cycles <= 0:
		return engineering_works_id
	var source_snapshot := _snapshot(EARTH_WORLD_ID)
	var bulk_before := _entity(source_snapshot, bulk_storage_id)
	var repair_before := int(bulk_before.get("inventory", {}).get("repair_material", 0))
	var required_iron := required_cycles * 2
	# The established Engineering Works can honestly retain cargo from earlier
	# production.  A one-cycle repair manifest must not pretend that this legacy
	# buffer was newly staged or silently clear it.  Build a fresh, publicly
	# funded Works when that historic buffer exceeds this bounded manifest.
	var repair_machine_id := engineering_works_id
	var legacy_repair_machine := _entity(source_snapshot, engineering_works_id)
	var legacy_inputs: Dictionary = legacy_repair_machine.get("inputs", {})
	var needs_clean_repair_works := int(legacy_inputs.get("iron_ingot", 0)) > required_iron or int(legacy_inputs.get("copper_ingot", 0)) > required_cycles
	if needs_clean_repair_works:
		var clean_origin := {"x":440, "y":240}
		var clean_conflicts: Array = []
		for collection_id in ["entities", "construction_orders", "resource_fields"]:
			for occupant_value in source_snapshot.get(collection_id, []):
				var occupant := occupant_value as Dictionary
				var occupant_footprint: Dictionary = occupant.get("footprint", {})
				var occupant_origin: Dictionary = occupant_footprint.get("origin", {})
				var occupant_size: Dictionary = occupant_footprint.get("size", {})
				var overlaps_x := int(clean_origin.get("x", 0)) < int(occupant_origin.get("x", 0)) + int(occupant_size.get("x", 0)) and int(occupant_origin.get("x", 0)) < int(clean_origin.get("x", 0)) + 12
				var overlaps_y := int(clean_origin.get("y", 0)) < int(occupant_origin.get("y", 0)) + int(occupant_size.get("y", 0)) and int(occupant_origin.get("y", 0)) < int(clean_origin.get("y", 0)) + 10
				if overlaps_x and overlaps_y:
					clean_conflicts.append({"collection":collection_id, "id":str(occupant.get("id", "")), "footprint":occupant_footprint})
		_check(clean_conflicts.is_empty(), "%s proves a clean non-overlapping Earth Engineering Works footprint before preserving the legacy repair buffer; origin=%s conflicts=%s" % [label, JSON.stringify(clean_origin), JSON.stringify(clean_conflicts)])
		if failures.size() > 0:
			return ""
		# These are already player-produced Location assets.  The clean repair Works
		# is an internal freight-support investment, so consuming its exact public
		# construction BOM is legitimate; requiring an artificial *increment* above
		# the available balance would reject valid custody whenever the Factory depot
		# happens to be empty.
		var clean_location_initial: Dictionary = source_snapshot.get("location_available_inventory", {})
		_check(int(clean_location_initial.get("scrap_metal", 0)) >= 4 and int(clean_location_initial.get("electronics", 0)) >= 2, "%s has the exact public Location construction BOM for a clean Engineering Works; available=%s" % [label, JSON.stringify(clean_location_initial)])
		if failures.size() > 0:
			return ""
		var clean_location_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var clean_order := _queue_and_fund("grid_engineering_works", "grid_fabricate_repair_material", clean_origin, "%s clean exact-manifest Engineering Works" % label, true, EARTH_WORLD_ID, "")
		if clean_order.is_empty() or failures.size() > 0:
			return ""
		repair_machine_id = str(clean_order.get("entity_id", ""))
		var clean_construction_events := _advance(60000.0, "%s clean Engineering Works construction" % label)
		var clean_machine := _entity(_snapshot(EARTH_WORLD_ID), repair_machine_id)
		var clean_location_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(clean_construction_events.any(func(event_value):
			var event := event_value as Dictionary
			return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("world_id", "")) == EARTH_WORLD_ID and str(event.get("entity_id", "")) == repair_machine_id and str(event.get("definition_id", "")) == "grid_engineering_works"
		) and (clean_machine.get("inputs", {}) as Dictionary).is_empty() and int(clean_location_after.get("scrap_metal", 0)) == int(clean_location_before.get("scrap_metal", 0)) - 4 and int(clean_location_after.get("electronics", 0)) == int(clean_location_before.get("electronics", 0)) - 2, "%s physically completes an empty clean Engineering Works from exact same-location scrap/electronics funding while leaving the legacy repair buffer intact; legacy_inputs=%s clean=%s before=%s after=%s events=%s" % [label, JSON.stringify(legacy_inputs), JSON.stringify(clean_machine), JSON.stringify(clean_location_before), JSON.stringify(clean_location_after), JSON.stringify(clean_construction_events)])
		if failures.size() > 0:
			return ""
	var repair_source_snapshot := _snapshot(EARTH_WORLD_ID)
	var iron_source := _entity_with_inventory_item(repair_source_snapshot, "iron_ingot", required_iron)
	var copper_source := _entity_with_inventory_item(repair_source_snapshot, "copper_ingot", required_cycles)
	# Prefer an already-player-produced physical manifest.  It lets the shared
	# cold-staging helper prove that no supplier continues manufacturing during
	# the later logistics settlement window.
	if not iron_source.is_empty() and not copper_source.is_empty():
		var cold_events := _cold_stage_recipe_batch(repair_machine_id, "grid_fabricate_repair_material", power_source_id, [
			{"item_id":"iron_ingot", "source_id":str(iron_source.get("id", "")), "quantity":required_iron},
			{"item_id":"copper_ingot", "source_id":str(copper_source.get("id", "")), "quantity":required_cycles}
		], bulk_storage_id, "repair_material", float(required_cycles) * 12000.0 + 1000.0, label, EARTH_WORLD_ID)
		if failures.size() > 0:
			return ""
		for cold_power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
			var cold_power_link := cold_power_link_value as Dictionary
			if str(cold_power_link.get("kind", "")) == "POWER" and str(cold_power_link.get("target_id", "")) == repair_machine_id:
				var cold_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(cold_power_link.get("id", ""))})
				_check(bool(cold_power_removed.get("accepted", false)), "%s retires the repair Works POWER edge after exact bounded production; result=%s" % [label, JSON.stringify(cold_power_removed)])
		var cold_remaining_power: Array = (_snapshot(EARTH_WORLD_ID).get("links", []) as Array).filter(func(link_value):
			var link := link_value as Dictionary
			return str(link.get("kind", "")) == "POWER" and str(link.get("target_id", "")) == repair_machine_id
		)
		_check(cold_events.size() > 0 and cold_remaining_power.is_empty(), "%s leaves the exact repair batch cold before later freight settlement, preventing an unbounded supplier continuation; remaining_power=%s" % [label, JSON.stringify(cold_remaining_power)])
		return repair_machine_id
	_check(false, "%s fails closed because no public Factory storage holds the exact cold iron/copper repair manifest; iron_source=%s copper_source=%s required_iron=%d required_copper=%d" % [label, JSON.stringify(iron_source), JSON.stringify(copper_source), required_iron, required_cycles])
	return ""


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
	for tool_power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var tool_power_link := tool_power_link_value as Dictionary
		if str(tool_power_link.get("kind", "")) != "POWER" or str(tool_power_link.get("target_id", "")) != machine_id:
			continue
		var removed_tool_power := _factory_command("REMOVE_LINK", {"link_id":str(tool_power_link.get("id", ""))})
		_check(bool(removed_tool_power.get("accepted", false)), "J2 retires the bounded machine-tool POWER edge after the first capital-good batch")
	if not failures.is_empty():
		return
	var upgraded_power := _queue_and_fund("grid_power_substation_ii", "", {"x":200, "y":0}, "power_substation_ii", false)
	if upgraded_power.is_empty() or not failures.is_empty():
		return
	var construction_events := _advance(120000.0, "capital power expansion")
	_check(_events_have_type(construction_events, "FactoryConstructionCompleted"), "renewable capital goods fund and complete the first Factory expansion")
	var capital_snapshot := _snapshot(EARTH_WORLD_ID)
	var capital_iron_refinery := _entity_with_recipe(capital_snapshot, "grid_refine_iron")
	var capital_copper_refinery := _entity_with_recipe(capital_snapshot, "grid_refine_copper")
	var capital_electronics_works := _entity_with_recipe(capital_snapshot, "grid_fabricate_electronics")
	_check(
		not capital_iron_refinery.is_empty() and not capital_copper_refinery.is_empty() and not capital_electronics_works.is_empty(),
		"J2 retains the physical starter iron, copper, and electronics production chain for Construction Yard investment"
	)
	for capital_machine_value in [capital_iron_refinery, capital_copper_refinery, capital_electronics_works]:
		_ensure_connection("POWER", str(upgraded_power.get("entity_id", "")), str((capital_machine_value as Dictionary).get("id", "")), "")
	var yard_material_events := _advance(180000.0, "renewable Construction Yard material replenishment")
	var yard_material_inventory: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})
	_check(
		int(yard_material_inventory.get("iron_ingot", 0)) >= 20
		and int(yard_material_inventory.get("electronics", 0)) >= 8
		and int(yard_material_inventory.get("structural_frame", 0)) >= 2
		and int(yard_material_inventory.get("industrial_machine_tools", 0)) >= 2,
		"the repowered renewable chain stages the complete tier-one and tier-two Construction Yard manifest; inventory=%s events=%s" % [JSON.stringify(yard_material_inventory), JSON.stringify(yard_material_events)]
	)
	if not failures.is_empty():
		return
	var construction_yard_one := _queue_and_fund(
		"grid_construction_yard",
		"",
		_find_clear_factory_origin("grid_construction_yard", EARTH_WORLD_ID),
		"Construction Yard I",
		false
	)
	if construction_yard_one.is_empty() or not failures.is_empty():
		return
	var construction_yard_one_events := _advance(120000.0, "capital Construction Yard I establishment")
	_check(
		str(_entity(_snapshot(EARTH_WORLD_ID), str(construction_yard_one.get("entity_id", ""))).get("definition_id", "")) == "grid_construction_yard"
		and _events_have_type(construction_yard_one_events, "FactoryConstructionCompleted"),
		"renewable capital goods establish the physical tier-one Construction Yard adapter"
	)
	_connect("POWER", str(upgraded_power.get("entity_id", "")), str(construction_yard_one.get("entity_id", "")), "")
	if not failures.is_empty():
		return
	var construction_yard_two := _queue_and_fund(
		"grid_construction_yard_ii",
		"",
		_find_clear_factory_origin("grid_construction_yard_ii", EARTH_WORLD_ID),
		"Construction Yard II",
		false
	)
	if construction_yard_two.is_empty() or not failures.is_empty():
		return
	var construction_yard_two_events := _advance(120000.0, "capital Construction Yard II expansion")
	_check(
		str(_entity(_snapshot(EARTH_WORLD_ID), str(construction_yard_two.get("entity_id", ""))).get("definition_id", "")) == "grid_construction_yard_ii"
		and _events_have_type(construction_yard_two_events, "FactoryConstructionCompleted"),
		"renewable capital goods complete Construction Yard II and establish the canonical tier-two construction capability"
	)
	_connect("POWER", str(upgraded_power.get("entity_id", "")), str(construction_yard_two.get("entity_id", "")), "")
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
	var clean_recovery_works := _queue_and_fund(
		"grid_engineering_works",
		"grid_reprocess_industrial_waste",
		_find_clear_factory_origin("grid_engineering_works", EARTH_WORLD_ID),
		"clean post-bottleneck recovery works",
		false
	)
	if clean_recovery_works.is_empty() or not failures.is_empty():
		return
	var clean_recovery_construction_events := _advance(60000.0, "clean post-bottleneck recovery construction")
	machine_id = str(clean_recovery_works.get("entity_id", ""))
	_check(
		str(_entity(_snapshot(EARTH_WORLD_ID), machine_id).get("definition_id", "")) == "grid_engineering_works"
		and _events_have_type(clean_recovery_construction_events, "FactoryConstructionCompleted"),
		"J4 preserves the legacy machine input buffer by completing a separately funded clean recovery Works"
	)
	var recovery_power := _entity_with_definition(_snapshot(EARTH_WORLD_ID), "grid_power_substation_ii")
	_check(not recovery_power.is_empty(), "the capital power expansion remains available for the post-bottleneck recovery line")
	_connect("CARGO", str(copper_refinery.get("id", "")), machine_id, "industrial_waste")
	_clear_competing_cargo_inputs(earth_bulk_depot_id, "iron_ingot", machine_id)
	_clear_competing_cargo_outputs(machine_id, "iron_ingot", earth_bulk_depot_id)
	_ensure_connection("CARGO", machine_id, earth_bulk_depot_id, "iron_ingot")
	var cold_recovery_staging_events := _advance(1000.0, "bounded post-shift waste staging")
	var cold_recovery_machine := _entity(_snapshot(EARTH_WORLD_ID), machine_id)
	_check(not _events_have_recipe(cold_recovery_staging_events, "grid_reprocess_industrial_waste") and int((cold_recovery_machine.get("inputs", {}) as Dictionary).get("industrial_waste", 0)) == 4, "J4 cold-stages exactly four physical waste units before bounded recovery; machine=%s" % JSON.stringify(cold_recovery_machine))
	_clear_competing_cargo_inputs(machine_id, "industrial_waste", "")
	_ensure_connection("POWER", str(recovery_power.get("id", "")), machine_id, "")
	var recovery_events := _advance(17000.0, "post-shift industrial-waste recovery")
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
		# Reuse the clean J4 recovery Works instead of spending another four finite
		# starter scrap on a duplicate building.  The original tool machine keeps its
		# legitimate large buffer; the recovery sibling is selected by its small,
		# publicly visible waste-only buffer and drained output.
		var frame_machine := {}
		var frame_machine_score := 2147483647
		for works_value in _entities_with_definition(renewable_snapshot, "grid_engineering_works"):
			var works := works_value as Dictionary
			if str(works.get("recipe_id", "")) != "grid_reprocess_industrial_waste":
				continue
			var buffer_score := 0
			for input_item_value in (works.get("inputs", {}) as Dictionary):
				buffer_score += int((works.get("inputs", {}) as Dictionary).get(str(input_item_value), 0))
			for output_item_value in (works.get("outputs", {}) as Dictionary):
				buffer_score += int((works.get("outputs", {}) as Dictionary).get(str(output_item_value), 0))
			if buffer_score < frame_machine_score:
				frame_machine = works
				frame_machine_score = buffer_score
		_check(not frame_machine.is_empty() and frame_machine_score <= 1, "Factory snapshot reuses the drained J4 recovery Works for bounded remote-bootstrap cargo; selected=%s score=%d" % [JSON.stringify(frame_machine), frame_machine_score])
		if frame_machine.is_empty() or not failures.is_empty():
			return
		_clear_competing_cargo_inputs(str(frame_machine.get("id", "")), "industrial_waste", "")
		var renewable_events := _run_exact_recipe_batches(str(frame_machine.get("id", "")), "grid_assemble_frame", str(capital_power.get("id", "")), STARTER_DEPOT_ID, "structural_frame", 4, 4, "J5 remote-bootstrap structural-frame lot")
		_check(_events_have_recipe(renewable_events, "grid_assemble_frame"), "Earth Factory renews the structural frames required for remote bootstrap")
		if not _events_have_recipe(renewable_events, "grid_assemble_frame"):
			return
		var electronics_events := _run_exact_recipe_batches(str(frame_machine.get("id", "")), "grid_fabricate_electronics", str(capital_power.get("id", "")), STARTER_DEPOT_ID, "electronics", 5, 5, "J5 remote-bootstrap electronics lot")
		_check(_events_have_recipe(electronics_events, "grid_fabricate_electronics"), "Earth Factory renews the electronic components required for remote bootstrap")
		var renewable_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		var renewable_electronics := int(renewable_depot.get("inventory", {}).get("electronics", 0))
		var renewable_machine := _entity(_snapshot(EARTH_WORLD_ID), str(frame_machine.get("id", "")))
		_check(renewable_electronics >= 5, "dedicated Factory electronics production stages three remote components and two fuel-cycle components before export; depot=%s machine=%s" % [JSON.stringify(renewable_depot.get("inventory", {})), JSON.stringify(renewable_machine)])
		var emergency_machine_id := str(frame_machine.get("id", ""))
		var clear_buffer_recipe := _factory_command("SET_RECIPE", {"entity_id":emergency_machine_id, "recipe_id":"grid_reprocess_industrial_waste"})
		_check(bool(clear_buffer_recipe.get("accepted", false)), "Factory protocol inspects the existing engineering Works for an incompatible industrial-waste buffer before its propellant changeover")
		var buffered_waste_before := int((_entity(_snapshot(EARTH_WORLD_ID), emergency_machine_id).get("inputs", {}) as Dictionary).get("industrial_waste", 0))
		var buffer_clear_events: Array = []
		if buffered_waste_before > 0:
			buffer_clear_events = _advance(180000.0, "reused engineering-works buffer clearance")
			_check(_events_have_recipe(buffer_clear_events, "grid_reprocess_industrial_waste"), "the reused engineering works physically consumes its retained industrial-waste buffer before receiving emergency-propellant inputs")
		else:
			_check(buffered_waste_before == 0, "the clean remote-bootstrap Works has no inherited industrial waste to discard before its propellant changeover")
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
		_check(not emergency_works.is_empty(), "the reused Earth engineering works remains available to physically replenish freight propellant")
		if emergency_works.is_empty():
			return
		var propellant_machine_id := str(emergency_works.get("entity_id", ""))
		var propellant_machine := _entity(propellant_snapshot, propellant_machine_id)
		_check(str(propellant_machine.get("recipe_id", "")) == "grid_manufacture_emergency_propellant", "reused engineering works applies its requested emergency-propellant recipe through the Factory protocol")
		var propellant_events := _run_exact_recipe_batches(propellant_machine_id, "grid_manufacture_emergency_propellant", str(capital_power.get("id", "")), STARTER_DEPOT_ID, "chemical_propellant", 9, 9, "J5 emergency freight-propellant reserve")
		var propellant_runtime := _entity(_snapshot(EARTH_WORLD_ID), propellant_machine_id)
		_check(_events_have_recipe(propellant_events, "grid_manufacture_emergency_propellant"), "Earth Factory physically fabricates the propellant needed for subsequent logistics dispatches; runtime=%s" % JSON.stringify(propellant_runtime))
		var propellant_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		_check(int(propellant_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 18, "the emergency Factory line stages eighteen physical propellant units before public freight export; inventory=%s" % JSON.stringify(propellant_depot.get("inventory", {})))
		_export_to_location("chemical_propellant", 18, "Lunar bootstrap freight reserve")
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "chemical_propellant", "SUPPLY", 0, 0, 100, 1)), "Earth publishes the emergency freight-fuel supply policy")
		var repair_events := _run_exact_recipe_batches(propellant_machine_id, "grid_fabricate_repair_material", str(capital_power.get("id", "")), STARTER_DEPOT_ID, "repair_material", 16, 16, "J5 freight-maintenance material reserve")
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
		_advance(4000.0, "bounded copper industrial-waste rerouting")
		_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "iron_ingot", "")
		var waste_depot_runtime := _entity(_snapshot(EARTH_WORLD_ID), earth_bulk_depot_id)
		var copper_after_reroute := _entity(_snapshot(EARTH_WORLD_ID), str(research_copper_source.get("id", "")))
		var starter_iron_after_reroute := int(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}).get("iron_ingot", 0))
		_check(int(waste_depot_runtime.get("inventory", {}).get("industrial_waste", 0)) > 0 and int(waste_depot_runtime.get("inventory", {}).get("iron_ingot", 0)) > 0 and starter_iron_after_reroute < starter_iron_before_reroute and int(copper_after_reroute.get("outputs", {}).get("industrial_waste", 0)) < 63, "the completed Earth bulk depot physically receives both the copper line's waste byproduct and starter iron, releasing copper output and finite component-storage headroom; depot=%s starter_iron=%d->%d copper=%s" % [JSON.stringify(waste_depot_runtime), starter_iron_before_reroute, starter_iron_after_reroute, JSON.stringify(copper_after_reroute)])
		if not failures.is_empty():
			return
		# Older valid runs can retain a finite J4/J5 component buffer, while the
		# bounded path above leaves the same machine clean.  Consume the former into
		# useful tools and explicitly accept the latter; neither case erases inputs.
		var buffer_tools_recipe := _factory_command("SET_RECIPE", {"entity_id":research_supply_machine_id, "recipe_id":"grid_fabricate_basic_machine_tools"})
		_check(bool(buffer_tools_recipe.get("accepted", false)), "Factory protocol assigns a compatible physical recipe to consume the reused machine's electronic and frame buffer")
		_clear_competing_cargo_inputs(research_supply_machine_id, "iron_ingot", "")
		_clear_competing_cargo_inputs(research_supply_machine_id, "electronics", "")
		_clear_competing_cargo_inputs(research_supply_machine_id, "structural_frame", "")
		_ensure_connection("POWER", str(capital_power.get("id", "")), research_supply_machine_id, "")
		_ensure_connection("CARGO", research_supply_machine_id, STARTER_DEPOT_ID, "industrial_machine_tools")
		var buffered_frames_before := int((_entity(_snapshot(EARTH_WORLD_ID), research_supply_machine_id).get("inputs", {}) as Dictionary).get("structural_frame", 0))
		var buffer_tools_events: Array = []
		if buffered_frames_before > 0:
			buffer_tools_events = _advance(40000.0, "reused-machine cached-component recovery")
		var buffer_recovered_machine := _entity(_snapshot(EARTH_WORLD_ID), research_supply_machine_id)
		var recovered_positive_inputs := 0
		for recovered_input_value in (buffer_recovered_machine.get("inputs", {}) as Dictionary).values():
			recovered_positive_inputs += int(recovered_input_value)
		_check(
			(buffered_frames_before > 0 and _events_have_recipe(buffer_tools_events, "grid_fabricate_basic_machine_tools") and int(buffer_recovered_machine.get("inputs", {}).get("structural_frame", 0)) == 0)
			or (buffered_frames_before == 0 and int(buffer_recovered_machine.get("inputs", {}).get("iron_ingot", 0)) > 0 and int(buffer_recovered_machine.get("inputs", {}).get("copper_ingot", 0)) > 0)
			or (buffered_frames_before == 0 and recovered_positive_inputs == 0),
			"the reused machine converts cached frames, retains a runnable electronics manifest, or proves its bounded buffer is empty; before_frames=%d positive_inputs=%d machine=%s" % [buffered_frames_before, recovered_positive_inputs, JSON.stringify(buffer_recovered_machine)]
		)
		if not failures.is_empty():
			return
		var research_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":research_supply_machine_id, "recipe_id":"grid_fabricate_electronics"})
		_check(bool(research_electronics_recipe.get("accepted", false)), "Factory protocol returns the reused engineering works to renewable electronics before the Advanced Propulsion theory stage")
		if not bool(research_electronics_recipe.get("accepted", false)):
			return
		_ensure_connection("POWER", str(capital_power.get("id", "")), research_supply_machine_id, "")
		_ensure_connection("POWER", str(capital_power.get("id", "")), str(research_iron_source.get("id", "")), "")
		_ensure_connection("POWER", str(capital_power.get("id", "")), str(research_copper_source.get("id", "")), "")
		_clear_competing_cargo_inputs(research_supply_machine_id, "iron_ingot", earth_bulk_depot_id)
		_ensure_connection("CARGO", earth_bulk_depot_id, research_supply_machine_id, "iron_ingot")
		var research_buffered_copper := int((_entity(_snapshot(EARTH_WORLD_ID), research_supply_machine_id).get("inputs", {}) as Dictionary).get("copper_ingot", 0))
		if research_buffered_copper >= 8:
			_clear_competing_cargo_inputs(research_supply_machine_id, "copper_ingot", "")
		else:
			_clear_competing_cargo_inputs(research_supply_machine_id, "copper_ingot", str(research_copper_source.get("id", "")))
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
		_ensure_connection("CARGO", str(research_iron_source.get("id", "")), research_supply_machine_id, "iron_ingot")
		var industrial_buffered_copper := int((_entity(_snapshot(EARTH_WORLD_ID), research_supply_machine_id).get("inputs", {}) as Dictionary).get("copper_ingot", 0))
		if industrial_buffered_copper >= 4:
			_clear_competing_cargo_inputs(research_supply_machine_id, "copper_ingot", "")
		else:
			_clear_competing_cargo_inputs(research_supply_machine_id, "copper_ingot", str(research_copper_source.get("id", "")))
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
	var reactor_input_inventory: Dictionary = _entity(earth_snapshot, STARTER_DEPOT_ID).get("inventory", {})
	_check(int(reactor_input_inventory.get("iron_ingot", 0)) >= 4, "J5's bounded internal transfer preserves the four physical iron ingots required for Pathfinder reactor parts; inventory=%s" % JSON.stringify(reactor_input_inventory))
	if not failures.is_empty():
		return
	var foundry_id := str(foundry.get("id", ""))
	var reactor_events := _run_exact_recipe_batches(foundry_id, "grid_fabricate_reactor_part", str(capital_power.get("id", "")), STARTER_DEPOT_ID, "reactor_part", 2, 2, "J6 Pathfinder reactor-part lot")
	_check(_events_have_recipe(reactor_events, "grid_fabricate_reactor_part"), "Factory manufactures the Pathfinder reactor parts without patrol-loot dependency")
	var reactor_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(int(reactor_depot.get("inventory", {}).get("reactor_part", 0)) >= 2, "Factory storage holds both physical Pathfinder reactor parts before Shipyard staging")
	if not failures.is_empty():
		return
	# The saved Pathfinder design carries a real hull-plus-module manufacturing
	# BOM. Reconfigure existing powered lines to replenish the missing precision
	# electronics and scanner data cores before exporting that manifest.
	var shipyard_supply_snapshot := _snapshot(EARTH_WORLD_ID)
	var renewable_electronics := {}
	var renewable_electronics_score := 2147483647
	for electronics_candidate_value in _entities_with_definition(shipyard_supply_snapshot, "grid_engineering_works"):
		var electronics_candidate := electronics_candidate_value as Dictionary
		if str(electronics_candidate.get("recipe_id", "")) != "grid_fabricate_electronics":
			continue
		var electronics_candidate_score := 0
		for electronics_input_value in (electronics_candidate.get("inputs", {}) as Dictionary).values():
			electronics_candidate_score += int(electronics_input_value)
		if electronics_candidate_score < renewable_electronics_score:
			renewable_electronics = electronics_candidate
			renewable_electronics_score = electronics_candidate_score
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
	_clear_competing_cargo_inputs(STARTER_DEPOT_ID, "electronics", renewable_electronics_id)
	_clear_competing_cargo_outputs(renewable_electronics_id, "electronics", STARTER_DEPOT_ID)
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
	# Yard II legitimately consumed J2's bounded machine-tool lot.  Reconfigure the
	# maintenance workshop only after its survey propellant is secured, and convert
	# its still-visible iron/electronics/frame buffers into a replacement tool.  This
	# keeps the J7 deployment BOM player-produced without restoring the old accidental
	# unbounded tool line or injecting inventory directly into Factory storage.
	_run_buffered_recipe_minimum(maintenance_id, "grid_fabricate_basic_machine_tools", power_id, STARTER_DEPOT_ID, "industrial_machine_tools", 1, 19000.0, "Asteroid survey replacement machine-tool lot")
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
	var earth_support_power := _entity_with_definition(earth_snapshot, "grid_power_substation_ii")
	var asteroid_propellant_works := {}
	var asteroid_repair_works := {}
	for support_works_value in _entities_with_definition(earth_snapshot, "grid_engineering_works"):
		var support_works := support_works_value as Dictionary
		var support_inputs: Dictionary = support_works.get("inputs", {})
		if asteroid_propellant_works.is_empty() and int(support_inputs.get("iron_ingot", 0)) >= 4 and int(support_inputs.get("electronics", 0)) >= 2:
			asteroid_propellant_works = support_works
		if asteroid_repair_works.is_empty() and int(support_inputs.get("iron_ingot", 0)) >= 16 and int(support_inputs.get("copper_ingot", 0)) >= 1:
			asteroid_repair_works = support_works
	_check(not earth_support_power.is_empty() and not asteroid_propellant_works.is_empty() and not asteroid_repair_works.is_empty() and str(asteroid_propellant_works.get("id", "")) != str(asteroid_repair_works.get("id", "")), "J8 resolves distinct existing Factory buffers for its bounded propellant and maintenance shortfalls; propellant=%s repair=%s" % [JSON.stringify(asteroid_propellant_works), JSON.stringify(asteroid_repair_works)])
	if not failures.is_empty():
		return
	var earth_support_power_id := str(earth_support_power.get("id", ""))
	var asteroid_propellant_works_id := str(asteroid_propellant_works.get("id", ""))
	_clear_competing_cargo_inputs(asteroid_propellant_works_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(asteroid_propellant_works_id, "electronics", "")
	var propellant_shortfall := maxi(0, 11 - int(earth_inventory.get("chemical_propellant", 0)))
	if propellant_shortfall > 0:
		var propellant_cycles := ceili(float(propellant_shortfall) / 2.0)
		_run_buffered_recipe_minimum(asteroid_propellant_works_id, "grid_manufacture_emergency_propellant", earth_support_power_id, STARTER_DEPOT_ID, "chemical_propellant", propellant_cycles * 2, float(propellant_cycles) * 18000.0 + 1000.0, "J8 bounded Asteroid-bootstrap propellant reserve")
	var asteroid_repair_works_id := str(asteroid_repair_works.get("id", ""))
	# Stage J8's eight-unit manifest plus both J9 Earth-Lunar maintenance debits.
	# The retained-iron Works can accept only nine copper units in its first cold
	# manifest, so close the twelve-unit reserve in capacity-safe 9+3 lots.
	var repair_shortfall := maxi(0, 12 - int(earth_inventory.get("repair_material", 0)))
	if repair_shortfall > 0 and failures.is_empty():
		var repair_first_batch := mini(9, repair_shortfall)
		_isolate_all_machine_power_for_target(asteroid_repair_works_id)
		_clear_competing_cargo_inputs(asteroid_repair_works_id, "iron_ingot", "")
		_clear_competing_cargo_inputs(asteroid_repair_works_id, "copper_ingot", "")
		var repair_copper_before := int((_entity(_snapshot(EARTH_WORLD_ID), asteroid_repair_works_id).get("inputs", {}) as Dictionary).get("copper_ingot", 0))
		var repair_copper_deficit := maxi(0, repair_first_batch - repair_copper_before)
		if repair_copper_deficit > 0:
			_ensure_connection("CARGO", STARTER_DEPOT_ID, asteroid_repair_works_id, "copper_ingot")
			_advance(float(repair_copper_deficit) / 4.0 * 1000.0, "J8 exact repair-copper cold staging")
			_clear_competing_cargo_inputs(asteroid_repair_works_id, "copper_ingot", "")
		var repair_copper_after := int((_entity(_snapshot(EARTH_WORLD_ID), asteroid_repair_works_id).get("inputs", {}) as Dictionary).get("copper_ingot", 0))
		_check(repair_copper_after >= repair_first_batch, "J8 cold-stages the first capacity-safe copper lot into the retained-iron repair Works; before=%d after=%d required=%d" % [repair_copper_before, repair_copper_after, repair_first_batch])
		_run_buffered_recipe_minimum(asteroid_repair_works_id, "grid_fabricate_repair_material", earth_support_power_id, STARTER_DEPOT_ID, "repair_material", repair_first_batch, float(repair_first_batch) * 12000.0 + 1000.0, "J8 first bounded Asteroid-bootstrap maintenance lot")
		var repair_second_batch := repair_shortfall - repair_first_batch
		if repair_second_batch > 0 and failures.is_empty():
			_isolate_all_machine_power_for_target(asteroid_repair_works_id)
			_clear_competing_cargo_inputs(asteroid_repair_works_id, "copper_ingot", "")
			_ensure_connection("CARGO", STARTER_DEPOT_ID, asteroid_repair_works_id, "copper_ingot")
			_advance(float(repair_second_batch) / 4.0 * 1000.0, "J8 second exact repair-copper cold staging")
			_clear_competing_cargo_inputs(asteroid_repair_works_id, "copper_ingot", "")
			var second_copper_after := int((_entity(_snapshot(EARTH_WORLD_ID), asteroid_repair_works_id).get("inputs", {}) as Dictionary).get("copper_ingot", 0))
			_check(second_copper_after >= repair_second_batch, "J8 cold-stages the second capacity-safe copper lot; staged=%d required=%d" % [second_copper_after, repair_second_batch])
			_run_buffered_recipe_minimum(asteroid_repair_works_id, "grid_fabricate_repair_material", earth_support_power_id, STARTER_DEPOT_ID, "repair_material", repair_second_batch, float(repair_second_batch) * 12000.0 + 1000.0, "J8 second bounded Asteroid-bootstrap maintenance lot")
	earth_snapshot = _snapshot(EARTH_WORLD_ID)
	earth_depot = _entity(earth_snapshot, STARTER_DEPOT_ID)
	earth_inventory = earth_depot.get("inventory", {})
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
			# A legacy path may retain industrial waste here, while the bounded J8 path
			# retains directly usable iron/electronics.  Only run the recovery recipe
			# when that physical waste buffer actually exists.
			var propellant_recovery_recipe := _factory_command("SET_RECIPE", {"entity_id":propellant_works_id, "recipe_id":"grid_reprocess_industrial_waste"})
			_check(bool(propellant_recovery_recipe.get("accepted", false)), "Factory protocol selects waste recovery to clear the retained emergency-line input buffer")
			var propellant_waste_before := int((propellant_works.get("inputs", {}) as Dictionary).get("industrial_waste", 0))
			var propellant_buffer_events: Array = []
			if propellant_waste_before > 0:
				_clear_competing_cargo_inputs(STARTER_DEPOT_ID, "iron_ingot", propellant_works_id)
				_clear_competing_cargo_outputs(propellant_works_id, "iron_ingot", STARTER_DEPOT_ID)
				_ensure_connection("CARGO", propellant_works_id, STARTER_DEPOT_ID, "iron_ingot")
				propellant_buffer_events = _advance(30000.0, "J9 emergency-line industrial-waste recovery")
			var cleared_propellant_works := _entity(_snapshot(EARTH_WORLD_ID), propellant_works_id)
			_check((propellant_waste_before > 0 and _events_have_recipe(propellant_buffer_events, "grid_reprocess_industrial_waste") and int(cleared_propellant_works.get("inputs", {}).get("industrial_waste", 0)) <= 1) or (propellant_waste_before == 0 and int(cleared_propellant_works.get("inputs", {}).get("industrial_waste", 0)) == 0), "Factory physically drains a retained emergency-line waste buffer or proves the bounded path has none; before=%d works=%s" % [propellant_waste_before, JSON.stringify(cleared_propellant_works)])
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
			_ensure_connection("POWER", str(earth_power.get("id", "")), component_works_id, "")
			var component_drain_events := _advance(14000.0, "J9 retained-iron consumption before replacement electronics")
			var component_after_drain := _entity(_snapshot(EARTH_WORLD_ID), component_works_id)
			_check(_events_have_recipe(component_drain_events, "grid_manufacture_kinetic_munitions") and int(component_after_drain.get("inputs", {}).get("iron_ingot", 0)) < int(component_works.get("inputs", {}).get("iron_ingot", 0)), "Factory physically consumes retained electronics-works iron before reconnecting copper; works=%s" % JSON.stringify(component_after_drain))
			if failures.size() > 0:
				return
			var component_recipe := _factory_command("SET_RECIPE", {"entity_id":component_works_id, "recipe_id":"grid_fabricate_electronics"})
			_check(bool(component_recipe.get("accepted", false)), "Factory protocol assigns the independent electronics line for second Lunar smelter construction")
			_ensure_connection("POWER", str(earth_power.get("id", "")), component_works_id, "")
			_ensure_connection("POWER", str(earth_power.get("id", "")), str(copper_source.get("id", "")), "")
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
	var composite_events := _advance(146000.0, "J9 superconducting-composite fabrication")
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
	var coil_events := _advance(98000.0, "J9 superconducting-coil fabrication")
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
	var radiation_events := _advance(90000.0, "J9 radiation-hardened electronics fabrication")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(radiation_events, "grid_fabricate_radiation_hardened_electronics") and int(component_depot.get("inventory", {}).get("radiation_hardened_electronics", 0)) >= 4, "Earth Factory physically stages all experiment, engineering, and prototype radiation electronics; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	var data_core_recipe := _factory_command("SET_RECIPE", {"entity_id":high_energy_id, "recipe_id":"grid_fabricate_data_core"})
	_check(bool(data_core_recipe.get("accepted", false)), "Factory protocol assigns the Heavy Industry industrial-release data-core batch")
	_clear_competing_cargo_outputs(high_energy_id, "data_core", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", high_energy_id, STARTER_DEPOT_ID, "data_core")
	var data_events := _advance(20000.0, "J9 industrial-release data-core fabrication")
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
	# Reuse the starter Arc Smelter when the exact J6 reactor lot left it clean. If
	# an earlier compatible flow retained a full physical input buffer, preserve
	# that history and commission an isolated material-test line instead.
	var retained_foundry_runtime := _entity(_snapshot(EARTH_WORLD_ID), str(foundry.get("id", "")))
	var retained_input_total := 0
	for retained_quantity in retained_foundry_runtime.get("inputs", {}).values():
		retained_input_total += int(retained_quantity)
	if retained_input_total > 0:
		_check(retained_input_total >= int(retained_foundry_runtime.get("input_capacity", 0)), "J9 preserves a legacy Arc Smelter only when its retained input buffer is full; foundry=%s" % JSON.stringify(retained_foundry_runtime))
		if not failures.is_empty():
			return
		# MACHINE placement requires a compatible initial recipe. Use the already
		# unlocked iron-refining recipe for construction, then reconfigure it below.
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
	else:
		_check(retained_input_total == 0, "J9 reuses the clean legacy Arc Smelter left by the exact reactor-component lot")
		foundry = retained_foundry_runtime
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
	if failures.is_empty() and int(ore_reserve_depot.get("inventory", {}).get("chemical_propellant", 0)) < 30:
		var ore_topup_works_id := ""
		var ore_topup_buffer_score := 2147483647
		for ore_topup_candidate_value in _entities_with_definition(_snapshot(EARTH_WORLD_ID), "grid_engineering_works"):
			var ore_topup_candidate := ore_topup_candidate_value as Dictionary
			var ore_topup_candidate_score := 0
			for ore_topup_input_value in (ore_topup_candidate.get("inputs", {}) as Dictionary).values():
				ore_topup_candidate_score += int(ore_topup_input_value)
			if ore_topup_candidate_score < ore_topup_buffer_score:
				ore_topup_buffer_score = ore_topup_candidate_score
				ore_topup_works_id = str(ore_topup_candidate.get("id", ""))
		_check(not ore_topup_works_id.is_empty(), "J9 resolves the least-buffered public engineering works for J10's bounded Lunar propellant top-up")
		var ore_topup_recipe := _factory_command("SET_RECIPE", {"entity_id":ore_topup_works_id, "recipe_id":"grid_manufacture_emergency_propellant"})
		_check(bool(ore_topup_recipe.get("accepted", false)), "J9 assigns the bounded J10 Lunar propellant top-up to the least-buffered works")
		for ore_topup_power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
			var ore_topup_power_link := ore_topup_power_link_value as Dictionary
			if str(ore_topup_power_link.get("kind", "")) == "POWER" and str(ore_topup_power_link.get("target_id", "")) == ore_topup_works_id:
				var ore_topup_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(ore_topup_power_link.get("id", ""))})
				_check(bool(ore_topup_power_removed.get("accepted", false)), "J9 freezes the selected propellant top-up works before one-unit electronics staging")
		_clear_competing_cargo_inputs(ore_topup_works_id, "electronics", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", STARTER_DEPOT_ID, ore_topup_works_id, "electronics")
		_advance(250.0, "J9 one-unit J10 propellant electronics staging")
		_clear_competing_cargo_inputs(ore_topup_works_id, "electronics", "")
		_run_buffered_recipe_minimum(ore_topup_works_id, "grid_manufacture_emergency_propellant", str(ore_power.get("id", "")), STARTER_DEPOT_ID, "chemical_propellant", 2, 20000.0, "J9 bounded J10 Lunar dispatch propellant top-up")
		ore_reserve_snapshot = _snapshot(EARTH_WORLD_ID)
		ore_reserve_depot = _entity(ore_reserve_snapshot, STARTER_DEPOT_ID)
	if failures.is_empty() and int(ore_reserve_depot.get("inventory", {}).get("repair_material", 0)) < 28:
		var ore_repair_works_id := ""
		var ore_repair_buffer_score := 2147483647
		for ore_repair_candidate_value in _entities_with_definition(_snapshot(EARTH_WORLD_ID), "grid_engineering_works"):
			var ore_repair_candidate := ore_repair_candidate_value as Dictionary
			var ore_repair_candidate_score := 0
			for ore_repair_input_value in (ore_repair_candidate.get("inputs", {}) as Dictionary).values():
				ore_repair_candidate_score += int(ore_repair_input_value)
			if ore_repair_candidate_score < ore_repair_buffer_score:
				ore_repair_buffer_score = ore_repair_candidate_score
				ore_repair_works_id = str(ore_repair_candidate.get("id", ""))
		_check(not ore_repair_works_id.is_empty(), "J9 resolves the least-buffered public engineering works for the final Asteroid maintenance reserve")
		var ore_repair_iron_source := _entity_with_recipe(_snapshot(EARTH_WORLD_ID), "grid_refine_iron")
		var ore_repair_copper_source := _entity_with_recipe(_snapshot(EARTH_WORLD_ID), "grid_refine_copper")
		_check(not ore_repair_iron_source.is_empty() and not ore_repair_copper_source.is_empty(), "J9 resolves both physical refinery sources before closing the maintenance-lot audit boundary")
		_clear_competing_cargo_inputs(STARTER_DEPOT_ID, "iron_ingot", "")
		_clear_competing_cargo_inputs(STARTER_DEPOT_ID, "copper_ingot", "")
		var ore_repair_shortfall := 28 - int(ore_reserve_depot.get("inventory", {}).get("repair_material", 0))
		var ore_repair_events := _run_exact_recipe_batches(ore_repair_works_id, "grid_fabricate_repair_material", str(ore_power.get("id", "")), STARTER_DEPOT_ID, "repair_material", ore_repair_shortfall, mini(16, ore_repair_shortfall), "J9 final Asteroid dispatch repair-material lot")
		_ensure_connection("CARGO", str(ore_repair_iron_source.get("id", "")), STARTER_DEPOT_ID, "iron_ingot")
		_ensure_connection("CARGO", str(ore_repair_copper_source.get("id", "")), STARTER_DEPOT_ID, "copper_ingot")
		ore_reserve_snapshot = _snapshot(EARTH_WORLD_ID)
		ore_reserve_depot = _entity(ore_reserve_snapshot, STARTER_DEPOT_ID)
		_check(_events_have_recipe(ore_repair_events, "grid_fabricate_repair_material") and int(ore_reserve_depot.get("inventory", {}).get("repair_material", 0)) >= 28, "Earth Factory physically stages the Asteroid dispatch lot plus J10's bounded Lunar maintenance reserve; inventory=%s" % JSON.stringify(ore_reserve_depot.get("inventory", {})))
	_check(int(ore_reserve_depot.get("inventory", {}).get("chemical_propellant", 0)) >= 30 and int(ore_reserve_depot.get("inventory", {}).get("repair_material", 0)) >= 28, "Earth Factory holds physical cargo plus dispatch headroom for Asteroid staging and the next bounded Lunar shipments; inventory=%s" % JSON.stringify(ore_reserve_depot.get("inventory", {})))
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
		return str(event.get("type", "")) == "ShipmentArrived" and str(event.get("origin", "")) == EARTH_LOCATION_ID and str(event.get("destination", "")) == "asteroid_belt" and int((event.get("cargo", {}) as Dictionary).get("chemical_propellant", 0)) > 0
	)
	var ore_propellant_arrived_quantity := 0
	for ore_propellant_arrival_value in ore_propellant_cargo_arrivals:
		ore_propellant_arrived_quantity += int(((ore_propellant_arrival_value as Dictionary).get("cargo", {}) as Dictionary).get("chemical_propellant", 0))
	_check(not ore_propellant_cargo_arrivals.is_empty() and ore_propellant_arrived_quantity == 15 and int(asteroid_operating_inventory.get("chemical_propellant", 0)) == 15 and int(asteroid_operating_inventory.get("repair_material", 0)) == 10, "public logistics physically stages the exact fifteen-unit Earth-to-Asteroid propellant reserve for five reverse shipments, including every capacity-bounded arrival; arrivals=%s arrived_total=%d available=%s raw_events=%s" % [JSON.stringify(ore_propellant_cargo_arrivals), ore_propellant_arrived_quantity, JSON.stringify(asteroid_operating_inventory), JSON.stringify(ore_propellant_staging_events)])
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
	_ensure_connection("POWER", power_id, str(foundry.get("id", "")), "")
	var cobalt_recipe := _factory_command("SET_RECIPE", {"entity_id":str(foundry.get("id", "")), "recipe_id":"grid_refine_cobalt"})
	_check(bool(cobalt_recipe.get("accepted", false)), "Factory protocol assigns Heavy Extraction cobalt refinement before steelmaking")
	_clear_competing_cargo_inputs(str(foundry.get("id", "")), "cobalt_ore", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(str(foundry.get("id", "")), "cobalt_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(str(foundry.get("id", "")), "industrial_waste", waste_works_id)
	_clear_competing_cargo_inputs(waste_works_id, "industrial_waste", str(foundry.get("id", "")))
	_ensure_connection("CARGO", STARTER_DEPOT_ID, str(foundry.get("id", "")), "cobalt_ore")
	_ensure_connection("CARGO", str(foundry.get("id", "")), STARTER_DEPOT_ID, "cobalt_ingot")
	_ensure_connection("CARGO", str(foundry.get("id", "")), waste_works_id, "industrial_waste")
	var cobalt_events := _advance(122000.0, "J9 cobalt-ingot refinement")
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
	var ceramic_events := _advance(98000.0, "J9 silicate-ceramic processing")
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
	var steel_events := _advance(130000.0, "J9 Heavy Industry steel refinement")
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(steel_events, "grid_refine_steel") and int(component_depot.get("inventory", {}).get("steel_composite", 0)) >= 8, "Earth Factory physically stages eight Heavy Industry steel composites for the assembly array; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	if not failures.is_empty():
		return
	# Long research windows legitimately consumed the earlier electronics batch.
	component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	if int(component_depot.get("inventory", {}).get("electronics", 0)) < 6:
		# Reconfigure the proven engineering works only when the physical construction
		# reserve is actually short; retained public custody is otherwise sufficient.
		var assembly_electronics_id := str(ore_propellant_works.get("id", ""))
		_ensure_connection("POWER", power_id, copper_refinery_id, "")
		_ensure_connection("POWER", power_id, assembly_electronics_id, "")
		var assembly_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":assembly_electronics_id, "recipe_id":"grid_fabricate_electronics"})
		_check(bool(assembly_electronics_recipe.get("accepted", false)), "Factory protocol restores renewable electronics for the Heavy Industry assembly construction")
		_clear_competing_cargo_inputs(assembly_electronics_id, "copper_ingot", copper_refinery_id)
		_clear_competing_cargo_outputs(copper_refinery_id, "copper_ingot", assembly_electronics_id)
		_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "electronics", "")
		_clear_competing_cargo_outputs(assembly_electronics_id, "electronics", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", copper_refinery_id, assembly_electronics_id, "copper_ingot")
		_ensure_connection("CARGO", assembly_electronics_id, STARTER_DEPOT_ID, "electronics")
		var assembly_electronics_events := _advance(50000.0, "J9 assembly-array construction electronics")
		component_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		_check(_events_have_recipe(assembly_electronics_events, "grid_fabricate_electronics") and int(component_depot.get("inventory", {}).get("electronics", 0)) >= 6, "Earth Factory physically replaces the six assembly-array construction electronics; inventory=%s" % JSON.stringify(component_depot.get("inventory", {})))
	else:
		_check(int(component_depot.get("inventory", {}).get("electronics", 0)) >= 6, "Earth Factory retains at least six physical electronics in public custody for the assembly-array order")
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
	_check(asteroid_route_imports.size() == 1, "J10 retains the one J7 public import proving custody of the finite Asteroid-route scrap reward")
	var earth_after_j9 := _snapshot(EARTH_WORLD_ID)
	var earth_after_j9_depot := _entity(earth_after_j9, STARTER_DEPOT_ID)
	if failures.is_empty() and int(earth_after_j9_depot.get("inventory", {}).get("scrap_metal", 0)) < 4:
		_check(not pathfinder_ship_id.is_empty() and not pathfinder_formation_id.is_empty() and game.formation_ready(pathfinder_formation_id) and not game.formation_is_active(pathfinder_formation_id), "J10 can deploy the proven Pathfinder formation for a bounded renewable scrap recovery")
		_export_to_location("kinetic_munitions", 19, "J10 bounded Lunar scrap-recovery ammunition")
		_check(bool(game.set_fleet_supply_plan("kinetic_munitions", 20, pathfinder_formation_id)), "J10 publishes a twenty-round cap for the bounded Pathfinder scrap recovery")
		_check(bool(game.auto_resupply_fleet(pathfinder_formation_id, [pathfinder_ship_id])), "J10 physically loads the bounded Pathfinder scrap-recovery ammunition")
		var bootstrap_scrap_before := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("scrap_metal", 0))
		_check(bool(game.start_activity("expedition", "combat_lunar_raider_patrol", pathfinder_formation_id)), "J10 starts the ammunition-bounded Lunar scrap-recovery patrol")
		var bootstrap_patrol_events := _advance(60000.0, "J10 bounded Lunar rare-earth bootstrap scrap patrol")
		var bootstrap_patrol_cycles := _events_with_activity(bootstrap_patrol_events, "OperationCycleCompleted", "combat_lunar_raider_patrol")
		var bootstrap_patrol_returned := not _events_with_activity(bootstrap_patrol_events, "ExpeditionReturnedForLogistics", "combat_lunar_raider_patrol").is_empty()
		var bootstrap_patrol_recalled := true
		if game.formation_is_active(pathfinder_formation_id):
			bootstrap_patrol_recalled = bool(game.stop_activity("expedition"))
		_check(bootstrap_patrol_cycles.size() >= 2 and not _events_have_type(bootstrap_patrol_events, "ExpeditionFailed") and (bootstrap_patrol_returned or bootstrap_patrol_recalled), "J10 completes at least two victorious patrol cycles and returns their renewable scrap to public custody; events=%s" % JSON.stringify(bootstrap_patrol_events))
		if failures.size() > 0:
			return
		var bootstrap_scrap_after := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("scrap_metal", 0))
		_check(bootstrap_scrap_after >= bootstrap_scrap_before + 4, "two bounded public Lunar patrols recover the four scrap units consumed by J8's Asteroid infrastructure; before=%d after=%d" % [bootstrap_scrap_before, bootstrap_scrap_after])
		_import_from_location("scrap_metal", 4, STARTER_DEPOT_ID, "J10 renewable Lunar rare-earth construction scrap")
		earth_after_j9 = _snapshot(EARTH_WORLD_ID)
		earth_after_j9_depot = _entity(earth_after_j9, STARTER_DEPOT_ID)
	_check(int(earth_after_j9_depot.get("inventory", {}).get("scrap_metal", 0)) >= 4, "J10 holds four physical renewable scrap units in Earth Factory custody for Lunar rare-earth construction; inventory=%s" % JSON.stringify(earth_after_j9_depot.get("inventory", {})))
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
	var lunar_electronics_origin_reserve: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(lunar_electronics_origin_reserve.get("chemical_propellant", 0)) >= 1 and int(lunar_electronics_origin_reserve.get("repair_material", 0)) >= 1, "the first bounded Lunar shipment leaves exactly the physical origin reserves needed for the electronic follow-up; available=%s" % JSON.stringify(lunar_electronics_origin_reserve))
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
	_check(not quantum_assembly.is_empty() and not quantum_power.is_empty(), "J10 retains the completed Assembly Array and powered grid for first quantum components")
	if failures.size() > 0:
		return
	var quantum_assembly_id := str(quantum_assembly.get("id", ""))
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
	_clear_competing_cargo_inputs(quantum_assembly_id, "copper_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(quantum_assembly_id, "electronics", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(quantum_assembly_id, "rare_earth_concentrate", STARTER_DEPOT_ID)
	_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "copper_ingot", quantum_assembly_id)
	_clear_competing_cargo_outputs(quantum_assembly_id, "quantum_component", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, quantum_assembly_id, "copper_ingot")
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
	if int(earth_belt_freight_available.get("chemical_propellant", 0)) < 2:
		var belt_propellant_shortfall := 2 - int(earth_belt_freight_available.get("chemical_propellant", 0))
		_export_to_location("chemical_propellant", belt_propellant_shortfall, "J10 Lunar titanium source-resupply cargo plus dispatch cost")
		earth_belt_freight_available = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(int(earth_belt_freight_available.get("chemical_propellant", 0)) >= 2 and int(earth_belt_freight_available.get("repair_material", 0)) >= 1, "Earth Location retains the physical propellant cargo, its dispatch cost, and transport maintenance for the bounded Belt Cruiser titanium source-resupply shipment; available=%s" % JSON.stringify(earth_belt_freight_available))
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
	var cruiser_copper_refinery := _entity_with_recipe(cruiser_supply_snapshot, "grid_refine_copper")
	var cruiser_iron_refinery := _entity_with_recipe(cruiser_supply_snapshot, "grid_refine_iron")
	var cruiser_electronics_works: Dictionary = {}
	var cruiser_electronics_score := 2147483647
	for cruiser_works_candidate_value in _entities_with_definition(cruiser_supply_snapshot, "grid_engineering_works"):
		var cruiser_works_candidate := cruiser_works_candidate_value as Dictionary
		var cruiser_works_candidate_id := str(cruiser_works_candidate.get("id", ""))
		if cruiser_works_candidate_id in [str(cruiser_copper_refinery.get("id", "")), str(cruiser_iron_refinery.get("id", ""))]:
			continue
		var cruiser_works_candidate_score := 0
		for cruiser_works_input_value in (cruiser_works_candidate.get("inputs", {}) as Dictionary).values():
			cruiser_works_candidate_score += int(cruiser_works_input_value)
		if cruiser_works_candidate_score < cruiser_electronics_score:
			cruiser_electronics_score = cruiser_works_candidate_score
			cruiser_electronics_works = cruiser_works_candidate
	var cruiser_power := _entity_with_definition(cruiser_supply_snapshot, "grid_power_substation_ii")
	_check(not cruiser_electronics_works.is_empty() and not cruiser_copper_refinery.is_empty() and not cruiser_iron_refinery.is_empty() and not cruiser_power.is_empty(), "J10 retains the public Earth machines needed to physically replenish the Belt Cruiser starting-module electronics BOM")
	if failures.size() > 0:
		return
	var cruiser_electronics_id := str(cruiser_electronics_works.get("id", ""))
	var cruiser_copper_id := str(cruiser_copper_refinery.get("id", ""))
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_electronics_id, "")
	var cruiser_electronics_input_total := 0
	for cruiser_electronics_input_value in (cruiser_electronics_works.get("inputs", {}) as Dictionary).values():
		cruiser_electronics_input_total += int(cruiser_electronics_input_value)
	if cruiser_electronics_input_total >= int(cruiser_electronics_works.get("input_capacity", 0)):
		var cruiser_headroom_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_manufacture_kinetic_munitions"})
		_check(bool(cruiser_headroom_recipe.get("accepted", false)), "J10 selects a useful iron-consuming recipe to release Belt Cruiser electronics input headroom")
		_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
		_clear_competing_cargo_outputs(cruiser_electronics_id, "kinetic_munitions", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", cruiser_electronics_id, STARTER_DEPOT_ID, "kinetic_munitions")
		var cruiser_headroom_events := _advance(28000.0, "J10 Belt Cruiser electronics input-headroom recovery")
		_check(_events_have_recipe(cruiser_headroom_events, "grid_manufacture_kinetic_munitions"), "J10 physically converts retained iron into useful fleet ammunition before electronics fabrication")
	var cruiser_electronics_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_electronics"})
	_check(bool(cruiser_electronics_recipe.get("accepted", false)), "Factory protocol restores renewable electronics for the remaining Belt Cruiser Shipyard manifest")
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_copper_id, "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", cruiser_copper_id)
	_clear_competing_cargo_outputs(cruiser_copper_id, "copper_ingot", cruiser_electronics_id)
	# The completed Array is intentionally INPUT_SHORTAGE on rare earth, but its
	# live electronics CARGO port would still absorb this exact Cruiser reserve.
	# Remove that public link before producing, rather than counting output that
	# silently remains in another machine's input buffer.
	_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "electronics", "")
	_clear_competing_cargo_inputs(STARTER_DEPOT_ID, "electronics", cruiser_electronics_id)
	_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "iron_ingot")
	_ensure_connection("CARGO", cruiser_copper_id, cruiser_electronics_id, "copper_ingot")
	_ensure_connection("CARGO", cruiser_electronics_id, STARTER_DEPOT_ID, "electronics")
	var cruiser_electronics_events := _advance(114000.0, "J10 Belt Cruiser and Starport II electronics fabrication")
	var cruiser_supply_depot := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(cruiser_electronics_events, "grid_fabricate_electronics") and int(cruiser_supply_depot.get("inventory", {}).get("electronics", 0)) >= 18, "after removing the Array electronics link, nine public Factory electronics cycles retain the full eighteen-unit Starport/tool/Cruiser lot in depot custody; inventory=%s works=%s copper=%s links=%s events=%s" % [JSON.stringify(cruiser_supply_depot.get("inventory", {})), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_copper_id)), JSON.stringify(_snapshot(EARTH_WORLD_ID).get("links", [])), JSON.stringify(cruiser_electronics_events)])
	if failures.size() > 0:
		return
	# Starport II also consumes two frames and two machine tools.  Preserve the
	# earlier journey's real machine custody: the electronics works has the exact
	# two-copper frame feed, while another engineering works retains a complete
	# two-cycle tool manifest.  Both batches cross public Factory CARGO links into
	# the starter depot before the construction order is allowed to exist.
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
	_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_assemble_frame", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "structural_frame", 2, 26000.0, "J10 Starport II structural-frame lot")
	var starport_tool_works: Dictionary = {}
	for starport_tool_candidate_value in _entities_with_definition(_snapshot(EARTH_WORLD_ID), "grid_engineering_works"):
		var starport_tool_candidate := starport_tool_candidate_value as Dictionary
		var starport_tool_inputs: Dictionary = starport_tool_candidate.get("inputs", {})
		if int(starport_tool_inputs.get("iron_ingot", 0)) >= 8 and int(starport_tool_inputs.get("structural_frame", 0)) >= 2:
			starport_tool_works = starport_tool_candidate
			break
	_check(not starport_tool_works.is_empty(), "J10 retains one visible engineering-works buffer with the physical iron and frame portion of a two-cycle Starport II machine-tool manifest")
	if failures.size() > 0:
		return
	var starport_tool_works_id := str(starport_tool_works.get("id", ""))
	_clear_competing_cargo_inputs(starport_tool_works_id, "iron_ingot", "")
	_clear_competing_cargo_inputs(starport_tool_works_id, "structural_frame", "")
	var starport_tool_headroom_snapshot := _snapshot(EARTH_WORLD_ID)
	var starport_tool_headroom_machine := _entity(starport_tool_headroom_snapshot, starport_tool_works_id)
	var starport_tool_input_total := 0
	for starport_tool_input_value in (starport_tool_headroom_machine.get("inputs", {}) as Dictionary).values():
		starport_tool_input_total += int(starport_tool_input_value)
	var starport_tool_initial_electronics := int(starport_tool_headroom_machine.get("inputs", {}).get("electronics", 0))
	var starport_tool_initial_deficit := maxi(0, 4 - starport_tool_initial_electronics)
	var starport_tool_headroom := int(starport_tool_headroom_machine.get("input_capacity", 0)) - starport_tool_input_total
	if starport_tool_headroom < starport_tool_initial_deficit:
		var starport_tool_headroom_cycles := starport_tool_initial_deficit - starport_tool_headroom
		# Allow the final twenty-round batch its full five-second CARGO drain after
		# the last seven-second recipe cycle, while stopping before another cycle.
		_run_buffered_recipe_minimum(starport_tool_works_id, "grid_manufacture_kinetic_munitions", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "kinetic_munitions", starport_tool_headroom_cycles * 20, float(starport_tool_headroom_cycles) * 7000.0 + 6000.0, "J10 Starport II machine-tool input-headroom recovery")
	if failures.size() > 0:
		return
	# Long-running propellant work can legitimately consume the retained
	# electronics while leaving the iron and frames.  Freeze this machine and
	# replenish only that observable shortfall from the ten-unit batch above.
	for starport_tool_power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var starport_tool_power_link := starport_tool_power_link_value as Dictionary
		if str(starport_tool_power_link.get("kind", "")) == "POWER" and str(starport_tool_power_link.get("target_id", "")) == starport_tool_works_id:
			var starport_tool_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(starport_tool_power_link.get("id", ""))})
			_check(bool(starport_tool_power_removed.get("accepted", false)), "J10 freezes the retained machine-tool works before staging its electronics shortfall")
	var starport_tool_recipe := _factory_command("SET_RECIPE", {"entity_id":starport_tool_works_id, "recipe_id":"grid_fabricate_basic_machine_tools"})
	_check(bool(starport_tool_recipe.get("accepted", false)), "J10 assigns the canonical basic-machine-tool recipe before cold electronics staging")
	var starport_tool_before_snapshot := _snapshot(EARTH_WORLD_ID)
	var starport_tool_electronics_before := int(_entity(starport_tool_before_snapshot, starport_tool_works_id).get("inputs", {}).get("electronics", 0))
	var starport_tool_source_before := int(_entity(starport_tool_before_snapshot, STARTER_DEPOT_ID).get("inventory", {}).get("electronics", 0))
	var starport_tool_electronics_deficit := maxi(0, 4 - starport_tool_electronics_before)
	_check(starport_tool_electronics_before <= 4 and starport_tool_source_before >= starport_tool_electronics_deficit, "J10 exposes a finite two-cycle machine-tool electronics shortfall backed by public depot custody; machine=%d depot=%d deficit=%d" % [starport_tool_electronics_before, starport_tool_source_before, starport_tool_electronics_deficit])
	if starport_tool_electronics_deficit > 0:
		_clear_competing_cargo_inputs(starport_tool_works_id, "electronics", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", STARTER_DEPOT_ID, starport_tool_works_id, "electronics")
		var starport_tool_staging_events := _advance(float(starport_tool_electronics_deficit) / 4.0 * 1000.0, "J10 Starport II machine-tool electronics cold staging")
		var starport_tool_after_snapshot := _snapshot(EARTH_WORLD_ID)
		var starport_tool_cold_cycle_seen := starport_tool_staging_events.any(func(event_value):
			var event := event_value as Dictionary
			return str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == EARTH_WORLD_ID and str(event.get("entity_id", "")) == starport_tool_works_id and str(event.get("recipe_id", "")) == "grid_fabricate_basic_machine_tools"
		)
		var starport_tool_source_after := int(_entity(starport_tool_after_snapshot, STARTER_DEPOT_ID).get("inventory", {}).get("electronics", 0))
		var starport_tool_electronics_after := int(_entity(starport_tool_after_snapshot, starport_tool_works_id).get("inputs", {}).get("electronics", 0))
		_check(not starport_tool_cold_cycle_seen and starport_tool_source_after == starport_tool_source_before - starport_tool_electronics_deficit and starport_tool_electronics_after == 4, "J10 transfers only the missing machine-tool electronics across a cold public CARGO edge; source_before=%d source_after=%d machine_before=%d machine_after=%d deficit=%d events=%s" % [starport_tool_source_before, starport_tool_source_after, starport_tool_electronics_before, starport_tool_electronics_after, starport_tool_electronics_deficit, JSON.stringify(starport_tool_staging_events)])
	_clear_competing_cargo_inputs(starport_tool_works_id, "electronics", "")
	if failures.size() > 0:
		return
	_run_buffered_recipe_minimum(starport_tool_works_id, "grid_fabricate_basic_machine_tools", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "industrial_machine_tools", 2, 38000.0, "J10 Starport II industrial-machine-tool lot")
	cruiser_supply_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(int(cruiser_supply_depot.get("inventory", {}).get("structural_frame", 0)) >= 2 and int(cruiser_supply_depot.get("inventory", {}).get("industrial_machine_tools", 0)) >= 2, "J10 public Factory custody holds the complete Starport II frame and machine-tool manifest before queueing; inventory=%s" % JSON.stringify(cruiser_supply_depot.get("inventory", {})))
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
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_copper_id, "")
	_clear_competing_cargo_outputs(cruiser_copper_id, "industrial_waste", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", cruiser_copper_id, STARTER_DEPOT_ID, "industrial_waste")
	# The electronic line no longer needs its copper port after the bounded batch.
	# Return the real provider to depot custody for the three raw copper units in
	# the light weapon, shield, and civilian reactor modules.
	_clear_competing_cargo_outputs(STARTER_DEPOT_ID, "copper_ingot", "")
	_clear_competing_cargo_outputs(cruiser_copper_id, "copper_ingot", STARTER_DEPOT_ID)
	_ensure_connection("CARGO", cruiser_copper_id, STARTER_DEPOT_ID, "copper_ingot")
	var cruiser_copper_staging_events := _advance(38000.0, "J10 Belt Cruiser module and replacement-foundry copper staging")
	cruiser_supply_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(cruiser_copper_staging_events, "grid_refine_copper") and int(cruiser_supply_depot.get("inventory", {}).get("industrial_waste", 0)) >= 63 and int(cruiser_supply_depot.get("inventory", {}).get("copper_ingot", 0)) >= 6, "Earth Factory physically drains the copper-refinery industrial-waste buffer and stages the six copper ingots required by the replacement reactor line and Belt Cruiser starting modules; inventory=%s refinery=%s events=%s" % [JSON.stringify(cruiser_supply_depot.get("inventory", {})), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_copper_id)), JSON.stringify(cruiser_copper_staging_events)])
	if failures.size() > 0:
		return
	# The earlier reactor part is legitimately consumed by the quantum/Starport
	# progression, while the first Arc Smelter correctly preserves a full 48-iron
	# input buffer that cannot accept the missing copper and electronics.  Use two
	# staged copper units to fabricate the exact frame/electronics construction lot
	# for a second empty Smelter instead of deleting that inherited custody.
	for cruiser_replacement_power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var cruiser_replacement_power_link := cruiser_replacement_power_link_value as Dictionary
		if str(cruiser_replacement_power_link.get("kind", "")) == "POWER" and str(cruiser_replacement_power_link.get("target_id", "")) == cruiser_electronics_id:
			var cruiser_replacement_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(cruiser_replacement_power_link.get("id", ""))})
			_check(bool(cruiser_replacement_power_removed.get("accepted", false)), "J10 freezes the replacement-foundry component works before two-unit copper staging")
	var cruiser_replacement_frame_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_assemble_frame"})
	_check(bool(cruiser_replacement_frame_recipe.get("accepted", false)), "J10 selects the public frame recipe for the replacement-foundry construction lot")
	var cruiser_replacement_before_snapshot := _snapshot(EARTH_WORLD_ID)
	var cruiser_replacement_copper_before := int(_entity(cruiser_replacement_before_snapshot, cruiser_electronics_id).get("inputs", {}).get("copper_ingot", 0))
	var cruiser_replacement_source_before := int(_entity(cruiser_replacement_before_snapshot, STARTER_DEPOT_ID).get("inventory", {}).get("copper_ingot", 0))
	var cruiser_replacement_copper_deficit := maxi(0, 2 - cruiser_replacement_copper_before)
	_check(cruiser_replacement_copper_before <= 2 and cruiser_replacement_source_before >= cruiser_replacement_copper_deficit, "J10 exposes a capacity-safe two-unit copper manifest for sequential replacement-foundry frame/electronics fabrication")
	if cruiser_replacement_copper_deficit > 0:
		_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", STARTER_DEPOT_ID)
		_ensure_connection("CARGO", STARTER_DEPOT_ID, cruiser_electronics_id, "copper_ingot")
		var cruiser_replacement_copper_staging_events := _advance(float(cruiser_replacement_copper_deficit) / 4.0 * 1000.0, "J10 replacement-foundry copper cold staging")
		var cruiser_replacement_after_snapshot := _snapshot(EARTH_WORLD_ID)
		var cruiser_replacement_cold_frame_seen := cruiser_replacement_copper_staging_events.any(func(event_value):
			var event := event_value as Dictionary
			return str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == EARTH_WORLD_ID and str(event.get("entity_id", "")) == cruiser_electronics_id and str(event.get("recipe_id", "")) == "grid_assemble_frame"
		)
		_check(not cruiser_replacement_cold_frame_seen and int(_entity(cruiser_replacement_after_snapshot, STARTER_DEPOT_ID).get("inventory", {}).get("copper_ingot", 0)) == cruiser_replacement_source_before - cruiser_replacement_copper_deficit and int(_entity(cruiser_replacement_after_snapshot, cruiser_electronics_id).get("inputs", {}).get("copper_ingot", 0)) == 2, "J10 transfers the exact replacement-foundry copper lot across a cold public CARGO edge")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "copper_ingot", "")
	if failures.size() > 0:
		return
	_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_assemble_frame", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "structural_frame", 1, 14000.0, "J10 replacement-foundry structural-frame lot")
	_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_electronics", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "electronics", 2, 14000.0, "J10 replacement-foundry electronics lot")
	cruiser_supply_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(int(cruiser_supply_depot.get("inventory", {}).get("structural_frame", 0)) >= 1 and int(cruiser_supply_depot.get("inventory", {}).get("electronics", 0)) >= 3, "J10 physically stages the complete replacement Arc Smelter construction manifest alongside the final reactor electronics; inventory=%s" % JSON.stringify(cruiser_supply_depot.get("inventory", {})))
	if failures.size() > 0:
		return
	var cruiser_replacement_foundry_order := _queue_and_fund("grid_arc_smelter", "grid_fabricate_reactor_part", {"x":300, "y":100}, "J10 replacement reactor-part Arc Smelter", false)
	if cruiser_replacement_foundry_order.is_empty() or failures.size() > 0:
		return
	var cruiser_replacement_foundry_events := _advance(140000.0, "J10 replacement reactor-part Arc Smelter construction")
	var cruiser_replacement_foundry_id := str(cruiser_replacement_foundry_order.get("entity_id", ""))
	var cruiser_reactor_foundry := _entity(_snapshot(EARTH_WORLD_ID), cruiser_replacement_foundry_id)
	_check(_events_have_type(cruiser_replacement_foundry_events, "FactoryConstructionCompleted") and str(cruiser_reactor_foundry.get("definition_id", "")) == "grid_arc_smelter", "J10 physically completes a clean second Arc Smelter without overwriting the original full iron buffer")
	if failures.size() > 0:
		return
	var cruiser_reactor_events := _cold_stage_recipe_batch(cruiser_replacement_foundry_id, "grid_fabricate_reactor_part", str(cruiser_power.get("id", "")), [
		{"item_id":"iron_ingot", "source_id":STARTER_DEPOT_ID, "quantity":2},
		{"item_id":"copper_ingot", "source_id":STARTER_DEPOT_ID, "quantity":1},
		{"item_id":"electronics", "source_id":STARTER_DEPOT_ID, "quantity":1}
	], STARTER_DEPOT_ID, "reactor_part", 16000.0, "J10 Belt Cruiser replacement reactor-part lot")
	cruiser_supply_depot = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	_check(_events_have_recipe(cruiser_reactor_events, "grid_fabricate_reactor_part") and int(cruiser_supply_depot.get("inventory", {}).get("reactor_part", 0)) >= 1, "J10 physically fabricates the missing one-unit Cruiser reactor part into public depot custody")
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
	if earth_propellant_top_up > 0 or earth_repair_top_up > 0:
		var asteroid_propellant_cycles := ceili(float(earth_propellant_top_up) / 2.0)
		# Three additional electronics cycles retain six units for the later
		# five-cycle Repair Dock propellant lot after this operating batch consumes
		# its own six-unit electronics manifest.
		var asteroid_electronics_cycles := ceili(float(asteroid_propellant_cycles) / 2.0) + 3
		var asteroid_operating_copper_required := asteroid_electronics_cycles + earth_repair_top_up
		if asteroid_operating_copper_required > 0:
			_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "copper_ingot", asteroid_operating_copper_required, float(asteroid_operating_copper_required) * 6000.0 + 2000.0, "J10 Asteroid operating-reserve renewable copper lot", STARTER_DEPOT_ID)
		if asteroid_electronics_cycles > 0:
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", STARTER_DEPOT_ID, "copper_ingot", asteroid_electronics_cycles, "J10 Asteroid operating-reserve electronics copper")
			_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_electronics", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "electronics", asteroid_electronics_cycles * 2, float(asteroid_electronics_cycles) * 12000.0 + 2000.0, "J10 Asteroid operating-reserve electronics lot")
		if asteroid_propellant_cycles > 0:
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", STARTER_DEPOT_ID, "electronics", asteroid_propellant_cycles, "J10 Asteroid operating-reserve propellant electronics")
			_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "chemical_propellant", asteroid_propellant_cycles * 2, float(asteroid_propellant_cycles) * 18000.0 + 2000.0, "J10 Asteroid operating-reserve propellant lot")
		if earth_repair_top_up > 0:
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "copper_ingot", earth_repair_top_up, "J10 Asteroid operating-reserve repair copper")
			_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "repair_material", earth_repair_top_up, float(earth_repair_top_up) * 12000.0 + 2000.0, "J10 Asteroid operating-reserve repair-material lot")
	if failures.size() > 0:
		return
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
	# clean public Arc Smelter instead of discarding that historical material or
	# forcing cobalt into an occupied port.  The replacement reactor-part Smelter
	# built above is now empty again, so reuse it rather than funding a redundant
	# third Earth Smelter.
	var retained_foundry: Dictionary = {}
	for retained_foundry_candidate in _entities_with_definition(_snapshot(EARTH_WORLD_ID), "grid_arc_smelter"):
		if int((retained_foundry_candidate as Dictionary).get("inputs", {}).get("iron_ingot", 0)) >= 48:
			retained_foundry = (retained_foundry_candidate as Dictionary).duplicate(true)
			break
	_check(str(retained_foundry.get("definition_id", "")) == "grid_arc_smelter" and int(retained_foundry.get("inputs", {}).get("iron_ingot", 0)) >= 48, "J10 observes the retained full J9 Arc-Smelter iron buffer before choosing the physical clean-line recovery; foundry=%s" % JSON.stringify(retained_foundry))
	if failures.size() > 0:
		return
	var cruiser_foundry_id := cruiser_replacement_foundry_id
	var cruiser_foundry_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_cobalt"})
	_check(bool(cruiser_foundry_recipe.get("accepted", false)), "Factory reconfigures the empty replacement Smelter for the Belt Cruiser cobalt-and-steel line")
	var cruiser_foundry := _entity(_snapshot(EARTH_WORLD_ID), cruiser_foundry_id)
	var cruiser_foundry_input_total := 0
	for cruiser_foundry_input_value in (cruiser_foundry.get("inputs", {}) as Dictionary).values():
		cruiser_foundry_input_total += int(cruiser_foundry_input_value)
	_check(str(cruiser_foundry.get("definition_id", "")) == "grid_arc_smelter" and cruiser_foundry_input_total == 0, "J10 addresses the reusable empty Arc Smelter through the versioned Factory snapshot; foundry=%s" % JSON.stringify(cruiser_foundry))
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
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_electronics_id, "")
	_clear_competing_cargo_inputs(cruiser_electronics_id, "iron_ingot", "")
	_clear_competing_cargo_outputs(cruiser_electronics_id, "kinetic_munitions", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "kinetic_munitions")
	var repair_dock_iron_recovery_events := _advance(100000.0, "J10 bounded historical Engineering Works iron-buffer recovery")
	var repair_dock_iron_recovery_snapshot := _snapshot(EARTH_WORLD_ID)
	var repair_dock_iron_recovery_works := _entity(repair_dock_iron_recovery_snapshot, cruiser_electronics_id)
	var repair_dock_iron_recovery_bulk := _entity(repair_dock_iron_recovery_snapshot, cruiser_bulk_depot_id)
	_check(_events_have_recipe(repair_dock_iron_recovery_events, "grid_manufacture_kinetic_munitions") and int(repair_dock_iron_recovery_works.get("inputs", {}).get("iron_ingot", 0)) <= 90 and int(repair_dock_iron_recovery_bulk.get("inventory", {}).get("kinetic_munitions", 0)) >= 120, "Engineering Works physically consumes at least six retained iron units into public Bulk custody before admitting five propellant electronics; works=%s bulk=%s" % [JSON.stringify(repair_dock_iron_recovery_works), JSON.stringify(repair_dock_iron_recovery_bulk.get("inventory", {}))])
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
	if repair_dock_maintenance_export > 0:
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "copper_ingot", repair_dock_maintenance_export, float(repair_dock_maintenance_export) * 6000.0 + 2000.0, "J10 Repair Dock cobalt-return renewable copper lot", STARTER_DEPOT_ID)
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "copper_ingot", repair_dock_maintenance_export, "J10 Repair Dock cobalt-return repair copper")
		_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "repair_material", repair_dock_maintenance_export, float(repair_dock_maintenance_export) * 12000.0 + 2000.0, "J10 Repair Dock cobalt-return repair-material lot")
	if failures.size() > 0:
		return
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
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_foundry_id, "")
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "cobalt_ore")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "cobalt_ingot")
	_ensure_connection("CARGO", cruiser_foundry_id, cruiser_bulk_depot_id, "industrial_waste")
	_advance(2000.0, "J10 bounded Repair Dock cobalt input staging")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ore", "")
	var repair_dock_cobalt_refining_events := _advance(62000.0, "J10 four-cycle Repair Dock cobalt refinement")
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
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_electronics_id, "")
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
	_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "copper_ingot", 2, 14000.0, "J10 Repair Dock delivery-maintenance renewable copper lot", STARTER_DEPOT_ID)
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "copper_ingot", 2, "J10 Repair Dock delivery-maintenance repair copper")
	if failures.size() > 0:
		return
	var repair_dock_maintenance_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_fabricate_repair_material"})
	_check(bool(repair_dock_maintenance_recipe.get("accepted", false)), "Factory protocol reconfigures the staged Engineering Works for the two-unit Repair Dock delivery maintenance batch")
	_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", "")
	_clear_competing_cargo_outputs(cruiser_electronics_id, "repair_material", cruiser_bulk_depot_id)
	_ensure_connection("CARGO", cruiser_electronics_id, cruiser_bulk_depot_id, "repair_material")
	_isolate_all_machine_power_for_target(cruiser_electronics_id)
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_electronics_id, "")
	var repair_dock_maintenance_events := _advance(32000.0, "J10 bounded Repair Dock delivery maintenance fabrication")
	var repair_dock_maintenance_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(repair_dock_maintenance_events.filter(func(event: Dictionary) -> bool: return str(event.get("recipe_id", "")) == "grid_fabricate_repair_material").size() >= 2 and int(repair_dock_maintenance_bulk.get("inventory", {}).get("repair_material", 0)) >= 2, "Factory physically completes the two-unit Bulk repair-material supplement for the two Repair Dock delivery dispatches; inventory=%s" % JSON.stringify(repair_dock_maintenance_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	var repair_dock_earth_operating_before: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var repair_dock_earth_cp_dispatch_export := maxi(0, 6 - int(repair_dock_earth_operating_before.get("chemical_propellant", 0)))
	var repair_dock_earth_maintenance_dispatch_export := maxi(0, 4 - int(repair_dock_earth_operating_before.get("repair_material", 0)))
	var repair_dock_delivery_factory_repair_before := int(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}).get("repair_material", 0)) + int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("repair_material", 0))
	var repair_dock_delivery_repair_production := maxi(0, repair_dock_earth_maintenance_dispatch_export - repair_dock_delivery_factory_repair_before)
	if repair_dock_earth_cp_dispatch_export > 0 or repair_dock_delivery_repair_production > 0:
		var repair_dock_delivery_propellant_cycles := ceili(float(repair_dock_earth_cp_dispatch_export) / 2.0)
		var repair_dock_delivery_electronics_cycles := ceili(float(repair_dock_delivery_propellant_cycles) / 2.0)
		var repair_dock_delivery_copper_required := repair_dock_delivery_electronics_cycles + repair_dock_delivery_repair_production
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "copper_ingot", repair_dock_delivery_copper_required, float(repair_dock_delivery_copper_required) * 6000.0 + 2000.0, "J10 Repair Dock two-item delivery renewable copper lot", STARTER_DEPOT_ID)
		if repair_dock_delivery_electronics_cycles > 0:
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", STARTER_DEPOT_ID, "copper_ingot", repair_dock_delivery_electronics_cycles, "J10 Repair Dock two-item delivery electronics copper")
			_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_electronics", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "electronics", repair_dock_delivery_electronics_cycles * 2, float(repair_dock_delivery_electronics_cycles) * 12000.0 + 2000.0, "J10 Repair Dock two-item delivery electronics lot")
		if repair_dock_delivery_propellant_cycles > 0:
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", STARTER_DEPOT_ID, "electronics", repair_dock_delivery_propellant_cycles, "J10 Repair Dock two-item delivery propellant electronics")
			_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "chemical_propellant", repair_dock_delivery_propellant_cycles * 2, float(repair_dock_delivery_propellant_cycles) * 18000.0 + 2000.0, "J10 Repair Dock two-item delivery propellant lot")
		if repair_dock_delivery_repair_production > 0:
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "copper_ingot", repair_dock_delivery_repair_production, "J10 Repair Dock two-item delivery repair copper")
			_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "repair_material", repair_dock_delivery_repair_production, float(repair_dock_delivery_repair_production) * 12000.0 + 2000.0, "J10 Repair Dock two-item delivery repair-material lot")
	if failures.size() > 0:
		return
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
	_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "copper_ingot", 4, 26000.0, "J10 Belt flagship repair-material renewable copper lot", STARTER_DEPOT_ID)
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "copper_ingot", 4, "J10 Belt flagship repair-material copper")
	if failures.size() > 0:
		return
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
	_isolate_all_machine_power_for_target(cruiser_electronics_id)
	_ensure_connection("POWER", str(cruiser_power.get("id", "")), cruiser_electronics_id, "")
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
	_check(str(belt_resupply_event.get("fleet_id", "")) == pathfinder_formation_id and belt_resupply_event.get("ship_ids", []) == [pathfinder_ship_id, belt_cruiser_ship_id] and int(belt_resupply_moved.get("repair_supplies", 0)) == 20 and int(belt_resupply_moved.get("kinetic_munitions", 0)) > 0 and int(belt_resupply_moved.get("kinetic_munitions", 0)) <= 120, "FleetResupplied records the exact formation, 20 repair supplies, and the positive bounded top-up needed after the earlier renewable-scrap patrol; event=%s" % JSON.stringify(belt_resupply_event))
	if failures.size() > 0:
		return
	# Fleet repair supplies cover combat damage; the continuous maintenance ledger
	# separately consumes repair material from the ships' current Location.  Close
	# the public projected debt plus the bounded route horizon before asking the
	# formation-readiness gate to admit the flagship expedition.
	var belt_maintenance_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", 0, 300000.0)
	var belt_maintenance_target := maxi(1, int(belt_maintenance_projection.get("gross_production_target", 0)))
	var belt_maintenance_source := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var belt_maintenance_machine := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
	var belt_maintenance_machine_inputs: Dictionary = belt_maintenance_machine.get("inputs", {})
	var belt_maintenance_iron_to_stage := maxi(0, belt_maintenance_target * 2 - int(belt_maintenance_machine_inputs.get("iron_ingot", 0)))
	var belt_maintenance_copper_to_stage := maxi(0, belt_maintenance_target - int(belt_maintenance_machine_inputs.get("copper_ingot", 0)))
	var belt_maintenance_iron_shortfall := maxi(0, belt_maintenance_iron_to_stage - int((belt_maintenance_source.get("inventory", {}) as Dictionary).get("iron_ingot", 0)))
	var belt_maintenance_copper_shortfall := maxi(0, belt_maintenance_copper_to_stage - int((belt_maintenance_source.get("inventory", {}) as Dictionary).get("copper_ingot", 0)))
	if belt_maintenance_iron_shortfall > 0:
		_run_buffered_recipe_minimum(str(cruiser_iron_refinery.get("id", "")), "grid_refine_iron", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "iron_ingot", belt_maintenance_iron_shortfall, float(belt_maintenance_iron_shortfall) * 2000.0 + 2000.0, "J10 Belt flagship maintenance-recovery iron lot")
	if belt_maintenance_copper_shortfall > 0:
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "copper_ingot", belt_maintenance_copper_shortfall, float(belt_maintenance_copper_shortfall) * 6000.0 + 2000.0, "J10 Belt flagship maintenance-recovery copper lot", STARTER_DEPOT_ID)
	if belt_maintenance_iron_to_stage > 0:
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "iron_ingot", belt_maintenance_target * 2, "J10 Belt flagship maintenance-recovery iron")
	if belt_maintenance_copper_to_stage > 0:
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "copper_ingot", belt_maintenance_target, "J10 Belt flagship maintenance-recovery copper")
	if failures.size() > 0:
		return
	_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "repair_material", belt_maintenance_target, float(belt_maintenance_target) * 12000.0 + 2000.0, "J10 Belt flagship public maintenance recovery")
	_export_to_location("repair_material", belt_maintenance_target, "J10 Belt flagship projected maintenance reserve", EARTH_WORLD_ID, cruiser_bulk_depot_id)
	var belt_maintenance_events := _advance(1000.0, "J10 Belt flagship maintenance settlement")
	_check(game.formation_ready(pathfinder_formation_id), "the projected public repair-material reserve settles Pathfinder-Cruiser maintenance before route start; projection=%s events=%s pathfinder=%s cruiser=%s" % [JSON.stringify(belt_maintenance_projection), JSON.stringify(belt_maintenance_events), JSON.stringify(game.ship_formation_assignment_availability(pathfinder_ship_id, pathfinder_formation_id)), JSON.stringify(game.ship_formation_assignment_availability(belt_cruiser_ship_id, pathfinder_formation_id))])
	if failures.size() > 0:
		return
	var belt_route_events_start := observed_events.size()
	var belt_reward_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	var belt_pathfinder_availability: Dictionary = game.ship_formation_assignment_availability(pathfinder_ship_id, pathfinder_formation_id)
	var belt_cruiser_availability: Dictionary = game.ship_formation_assignment_availability(belt_cruiser_ship_id, pathfinder_formation_id)
	var belt_route_started := bool(game.start_expedition_route("belt_flagship_route", [pathfinder_ship_id, belt_cruiser_ship_id], pathfinder_formation_id))
	_check(belt_route_started, "public Expedition command starts the canonical Belt flagship route with exactly the Pathfinder and constructed Belt Cruiser; notice=%s formation_ready=%s formation_active=%s pathfinder=%s cruiser=%s blockers=%s" % [game.last_notice, str(game.formation_ready(pathfinder_formation_id)), str(game.formation_is_active(pathfinder_formation_id)), JSON.stringify(belt_pathfinder_availability), JSON.stringify(belt_cruiser_availability), JSON.stringify(game.active_blockers())])
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
	# Produce a finite four-cycle lot for the seven-item manifest.  The previous
	# bounded maintenance recovery deliberately retired the Works' POWER edge, so
	# explicitly cold-stage copper and reconnect power for this separate batch.
	var lunar_support_works_before := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
	var lunar_support_copper_in_machine := int((lunar_support_works_before.get("inputs", {}) as Dictionary).get("copper_ingot", 0))
	var lunar_support_copper_in_bulk := int((_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}) as Dictionary).get("copper_ingot", 0))
	var lunar_support_copper_shortfall := maxi(0, 4 - lunar_support_copper_in_machine - lunar_support_copper_in_bulk)
	if lunar_support_copper_shortfall > 0:
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "copper_ingot", lunar_support_copper_shortfall, float(lunar_support_copper_shortfall) * 6000.0 + 2000.0, "J10 Lunar cryogenic-support renewable copper lot", cruiser_bulk_depot_id)
	if lunar_support_copper_in_machine < 4:
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", cruiser_bulk_depot_id, "copper_ingot", 4, "J10 Lunar cryogenic-support electronics copper")
	if failures.size() > 0:
		return
	var lunar_support_electronics_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_electronics", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "electronics", 8, 50000.0, "J10 Lunar cryogenic-support electronics lot")
	var lunar_support_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(lunar_support_electronics_events, "grid_fabricate_electronics") and int(lunar_support_bulk.get("inventory", {}).get("electronics", 0)) >= 7, "Earth Factory physically stages the seven-electronics Lunar extractor-and-tank manifest in its explicit bulk depot; depot=%s" % JSON.stringify(lunar_support_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	# Manufacture the four route-maintenance units that the two Earth-Lunar
	# component shipments actually consume at the current public maintenance
	# profile.  This does not treat historical O&M inventory as a free grant.
	var lunar_support_repair_works := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
	var lunar_support_repair_inputs: Dictionary = lunar_support_repair_works.get("inputs", {})
	var lunar_support_repair_iron_in_machine := int(lunar_support_repair_inputs.get("iron_ingot", 0))
	var lunar_support_repair_copper_in_machine := int(lunar_support_repair_inputs.get("copper_ingot", 0))
	var lunar_support_repair_source := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	var lunar_support_repair_iron_shortfall := maxi(0, 8 - lunar_support_repair_iron_in_machine - int((lunar_support_repair_source.get("inventory", {}) as Dictionary).get("iron_ingot", 0)))
	var lunar_support_repair_bulk_copper := int((_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}) as Dictionary).get("copper_ingot", 0))
	var lunar_support_repair_copper_shortfall := maxi(0, 4 - lunar_support_repair_copper_in_machine - lunar_support_repair_bulk_copper)
	if lunar_support_repair_iron_shortfall > 0:
		_run_buffered_recipe_minimum(str(cruiser_iron_refinery.get("id", "")), "grid_refine_iron", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "iron_ingot", lunar_support_repair_iron_shortfall, float(lunar_support_repair_iron_shortfall) * 2000.0 + 2000.0, "J10 Lunar support repair-material renewable iron lot")
	if lunar_support_repair_copper_shortfall > 0:
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "copper_ingot", lunar_support_repair_copper_shortfall, float(lunar_support_repair_copper_shortfall) * 6000.0 + 2000.0, "J10 Lunar support repair-material renewable copper lot", cruiser_bulk_depot_id)
	if lunar_support_repair_iron_in_machine < 8:
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "iron_ingot", 8, "J10 Lunar support repair-material iron")
	if lunar_support_repair_copper_in_machine < 4:
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", cruiser_bulk_depot_id, "copper_ingot", 4, "J10 Lunar support repair-material copper")
	if failures.size() > 0:
		return
	var lunar_support_repair_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "repair_material", 4, 50000.0, "J10 Lunar support repair-material lot")
	lunar_support_bulk = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(lunar_support_repair_events, "grid_fabricate_repair_material") and int(lunar_support_bulk.get("inventory", {}).get("repair_material", 0)) >= 4, "Earth Factory physically produces the four maintenance units for the bounded two-manifest Lunar support freight; depot=%s" % JSON.stringify(lunar_support_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	# The earlier Starport and Cruiser builds legitimately consumed the historical
	# tool/fuel surplus.  Close the current Lunar manifest from renewable public
	# batches while retaining the seven electronics already assigned to it.
	_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "copper_ingot", 1, 8000.0, "J10 Lunar support tool-frame copper recovery", cruiser_bulk_depot_id)
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_assemble_frame", STARTER_DEPOT_ID, "iron_ingot", 4, "J10 Lunar support tool-frame iron")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_assemble_frame", cruiser_bulk_depot_id, "copper_ingot", 2, "J10 Lunar support tool-frame copper")
	var lunar_support_frame_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_assemble_frame", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "structural_frame", 2, 26000.0, "J10 Lunar support tool-frame lot")
	_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "copper_ingot", 3, 20000.0, "J10 Lunar support dependency-electronics copper recovery", cruiser_bulk_depot_id)
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", STARTER_DEPOT_ID, "iron_ingot", 3, "J10 Lunar support dependency-electronics iron")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", cruiser_bulk_depot_id, "copper_ingot", 3, "J10 Lunar support dependency-electronics copper")
	var lunar_support_dependency_electronics_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_electronics", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "electronics", 6, 38000.0, "J10 Lunar support dependency-electronics lot")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_basic_machine_tools", STARTER_DEPOT_ID, "iron_ingot", 8, "J10 Lunar support industrial-tools iron")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_basic_machine_tools", cruiser_bulk_depot_id, "electronics", 4, "J10 Lunar support industrial-tools electronics")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_basic_machine_tools", STARTER_DEPOT_ID, "structural_frame", 2, "J10 Lunar support industrial-tools frames")
	var lunar_support_tool_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_basic_machine_tools", str(cruiser_power.get("id", "")), STARTER_DEPOT_ID, "industrial_machine_tools", 2, 38000.0, "J10 Lunar support industrial-tool lot")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", STARTER_DEPOT_ID, "iron_ingot", 4, "J10 Lunar support dispatch-propellant iron")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", cruiser_bulk_depot_id, "electronics", 2, "J10 Lunar support dispatch-propellant electronics")
	var lunar_support_propellant_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "chemical_propellant", 4, 38000.0, "J10 Lunar support dispatch-propellant lot")
	_check(_events_have_recipe(lunar_support_frame_events, "grid_assemble_frame") and _events_have_recipe(lunar_support_dependency_electronics_events, "grid_fabricate_electronics") and _events_have_recipe(lunar_support_tool_events, "grid_fabricate_basic_machine_tools") and _events_have_recipe(lunar_support_propellant_events, "grid_manufacture_emergency_propellant"), "Lunar support dependencies are each backed by their scoped public Factory recipe events")
	if failures.size() > 0:
		return
	var earth_support_starter := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
	lunar_support_bulk = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
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
	var jovian_electronics_machine := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
	var jovian_electronics_inputs: Dictionary = jovian_electronics_machine.get("inputs", {})
	var jovian_electronics_machine_iron := int(jovian_electronics_inputs.get("iron_ingot", 0))
	var jovian_electronics_machine_copper := int(jovian_electronics_inputs.get("copper_ingot", 0))
	var jovian_electronics_bulk_copper := int((_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}) as Dictionary).get("copper_ingot", 0))
	var jovian_electronics_copper_shortfall := maxi(0, 1 - jovian_electronics_machine_copper - jovian_electronics_bulk_copper)
	if jovian_electronics_copper_shortfall > 0:
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "copper_ingot", jovian_electronics_copper_shortfall, float(jovian_electronics_copper_shortfall) * 6000.0 + 2000.0, "J10 Jovian Operations theory copper recovery", cruiser_bulk_depot_id)
	if jovian_electronics_machine_iron < 1:
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", STARTER_DEPOT_ID, "iron_ingot", 1, "J10 Jovian Operations theory electronics iron")
	if jovian_electronics_machine_copper < 1:
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", cruiser_bulk_depot_id, "copper_ingot", 1, "J10 Jovian Operations theory electronics copper")
	if failures.size() > 0:
		return
	var jovian_electronics_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_electronics", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "electronics", 2, 14000.0, "J10 Jovian Operations theory electronics lot")
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
	var quantum_repair_machine := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
	var quantum_repair_inputs: Dictionary = quantum_repair_machine.get("inputs", {})
	var quantum_repair_machine_iron := int(quantum_repair_inputs.get("iron_ingot", 0))
	var quantum_repair_machine_copper := int(quantum_repair_inputs.get("copper_ingot", 0))
	var quantum_repair_bulk_copper := int((_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}) as Dictionary).get("copper_ingot", 0))
	var quantum_repair_copper_shortfall := maxi(0, 12 - quantum_repair_machine_copper - quantum_repair_bulk_copper)
	if quantum_repair_copper_shortfall > 0:
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", str(cruiser_power.get("id", "")), cruiser_bulk_depot_id, "copper_ingot", quantum_repair_copper_shortfall, float(quantum_repair_copper_shortfall) * 6000.0 + 2000.0, "J10 Lunar rare-earth return maintenance copper recovery", cruiser_bulk_depot_id)
	if quantum_repair_machine_iron < 24:
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "iron_ingot", 24, "J10 Lunar rare-earth return maintenance iron")
	if quantum_repair_machine_copper < 12:
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", cruiser_bulk_depot_id, "copper_ingot", 12, "J10 Lunar rare-earth return maintenance copper")
	if failures.size() > 0:
		return
	var quantum_repair_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", jovian_research_power_id, cruiser_bulk_depot_id, "repair_material", 12, 146000.0, "J10 Lunar rare-earth return maintenance lot")
	var quantum_repair_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(quantum_repair_events, "grid_fabricate_repair_material") and int(quantum_repair_bulk.get("inventory", {}).get("repair_material", 0)) >= 12, "Earth Factory physically stages the bounded Lunar rare-earth return maintenance reserve; bulk=%s" % JSON.stringify(quantum_repair_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	# Preserve the three bulk electronics intentionally reserved for the remaining
	# research stages: the starter depot still holds the exact two-electronics
	# dependency for this two-cycle emergency-propellant batch.
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", STARTER_DEPOT_ID, "iron_ingot", 4, "J10 Lunar rare-earth return propellant iron")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", STARTER_DEPOT_ID, "electronics", 2, "J10 Lunar rare-earth return propellant electronics")
	if failures.size() > 0:
		return
	var quantum_propellant_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", jovian_research_power_id, cruiser_bulk_depot_id, "chemical_propellant", 4, 38000.0, "J10 Lunar rare-earth return propellant lot")
	_check(_events_have_recipe(quantum_propellant_events, "grid_manufacture_emergency_propellant"), "the five Lunar returns' incremental propellant is backed by its scoped public Factory recipe events")
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
		# Replenish exactly the public export shortfall from the visible renewable
		# refineries.  Do not infer a nearly-full historic Works buffer: its current
		# snapshot is authoritative for both staging deficits.
		var rig_repair_works_before := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
		var rig_repair_inputs: Dictionary = rig_repair_works_before.get("inputs", {})
		var rig_repair_machine_iron := int(rig_repair_inputs.get("iron_ingot", 0))
		var rig_repair_machine_copper := int(rig_repair_inputs.get("copper_ingot", 0))
		var rig_repair_source := _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID)
		var rig_repair_iron_to_stage := maxi(0, rig_repair_export * 2 - rig_repair_machine_iron)
		var rig_repair_iron_shortfall := maxi(0, rig_repair_iron_to_stage - int((rig_repair_source.get("inventory", {}) as Dictionary).get("iron_ingot", 0)))
		var rig_repair_bulk_copper := int((_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}) as Dictionary).get("copper_ingot", 0))
		var rig_repair_copper_shortfall := maxi(0, rig_repair_export - rig_repair_machine_copper - rig_repair_bulk_copper)
		if rig_repair_iron_shortfall > 0:
			_run_buffered_recipe_minimum(str(cruiser_iron_refinery.get("id", "")), "grid_refine_iron", jovian_research_power_id, STARTER_DEPOT_ID, "iron_ingot", rig_repair_iron_shortfall, float(rig_repair_iron_shortfall) * 2000.0 + 2000.0, "J10 Fusion Test Rig Asteroid-return repair iron recovery")
		if rig_repair_copper_shortfall > 0:
			_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", jovian_research_power_id, cruiser_bulk_depot_id, "copper_ingot", rig_repair_copper_shortfall, float(rig_repair_copper_shortfall) * 6000.0 + 2000.0, "J10 Fusion Test Rig Asteroid-return repair copper recovery", cruiser_bulk_depot_id)
		if rig_repair_machine_iron < rig_repair_export * 2:
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "iron_ingot", rig_repair_export * 2, "J10 Fusion Test Rig Asteroid-return repair iron")
		if rig_repair_machine_copper < rig_repair_export:
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", cruiser_bulk_depot_id, "copper_ingot", rig_repair_export, "J10 Fusion Test Rig Asteroid-return repair copper")
		if failures.size() > 0:
			return
		var rig_repair_before := int((_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}) as Dictionary).get("repair_material", 0))
		var rig_repair_events := _run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", jovian_research_power_id, cruiser_bulk_depot_id, "repair_material", rig_repair_export, float(rig_repair_export) * 12000.0 + 2000.0, "J10 Fusion Test Rig Asteroid-return repair-material lot")
		var rig_repair_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
		_check(_events_have_recipe(rig_repair_events, "grid_fabricate_repair_material") and int(rig_repair_bulk.get("inventory", {}).get("repair_material", 0)) >= rig_repair_before + rig_repair_export, "Earth Factory physically replenishes the exact repair-material cargo needed for the bounded Fusion Test Rig Asteroid cobalt return; bulk=%s" % JSON.stringify(rig_repair_bulk.get("inventory", {})))
		if failures.size() > 0:
			return
	if rig_cp_export > 0:
		var rig_propellant_cycles := ceili(float(rig_cp_export) / 2.0)
		var rig_propellant_electronics_cycles := ceili(float(rig_propellant_cycles) / 2.0)
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", jovian_research_power_id, cruiser_bulk_depot_id, "copper_ingot", rig_propellant_electronics_cycles, float(rig_propellant_electronics_cycles) * 6000.0 + 2000.0, "J10 Fusion Test Rig Asteroid-return propellant copper recovery", cruiser_bulk_depot_id)
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", STARTER_DEPOT_ID, "iron_ingot", rig_propellant_electronics_cycles, "J10 Fusion Test Rig Asteroid-return propellant electronics iron")
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", cruiser_bulk_depot_id, "copper_ingot", rig_propellant_electronics_cycles, "J10 Fusion Test Rig Asteroid-return propellant electronics copper")
		if failures.size() > 0:
			return
		_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_electronics", jovian_research_power_id, cruiser_bulk_depot_id, "electronics", rig_propellant_electronics_cycles * 2, float(rig_propellant_electronics_cycles) * 12000.0 + 2000.0, "J10 Fusion Test Rig Asteroid-return propellant electronics lot")
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", STARTER_DEPOT_ID, "iron_ingot", rig_propellant_cycles * 2, "J10 Fusion Test Rig Asteroid-return propellant iron")
		_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", cruiser_bulk_depot_id, "electronics", rig_propellant_cycles, "J10 Fusion Test Rig Asteroid-return propellant electronics")
		if failures.size() > 0:
			return
		_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", jovian_research_power_id, cruiser_bulk_depot_id, "chemical_propellant", rig_propellant_cycles * 2, float(rig_propellant_cycles) * 18000.0 + 2000.0, "J10 Fusion Test Rig Asteroid-return propellant lot")
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
	_check(int(patrol_scrap_before.get("scrap_metal", 0)) >= 3 and not pathfinder_formation_id.is_empty() and game.formation_ready(pathfinder_formation_id) and not game.formation_is_active(pathfinder_formation_id), "the deployed Pathfinder-Cruiser formation is publicly idle, maintained, and retains at least the three-unit Belt reward before the repeatable Lunar patrol")
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
	# Two independent general-cargo shipments follow (scrap, then electronics),
	# so close both one-unit repair costs up front and add one two-unit emergency
	# propellant cycle to the retained single unit.
	_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", jovian_research_power_id, cruiser_bulk_depot_id, "copper_ingot", 1, 8000.0, "J10 Lunar thorium two-dispatch repair copper recovery", cruiser_bulk_depot_id)
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "iron_ingot", 4, "J10 Lunar thorium two-dispatch repair iron")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", cruiser_bulk_depot_id, "copper_ingot", 2, "J10 Lunar thorium two-dispatch repair copper")
	if failures.size() > 0:
		return
	_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", jovian_research_power_id, cruiser_bulk_depot_id, "repair_material", 2, 26000.0, "J10 Lunar thorium two-dispatch repair-material lot")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", STARTER_DEPOT_ID, "iron_ingot", 2, "J10 Lunar thorium two-dispatch propellant iron")
	_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", cruiser_bulk_depot_id, "electronics", 1, "J10 Lunar thorium two-dispatch propellant electronics")
	if failures.size() > 0:
		return
	_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", jovian_research_power_id, cruiser_bulk_depot_id, "chemical_propellant", 2, 20000.0, "J10 Lunar thorium two-dispatch propellant lot")
	if failures.size() > 0:
		return
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
	var thorium_extracted_total := 0
	for thorium_batch_value in thorium_extraction_batches:
		thorium_extracted_total += int((thorium_batch_value as Dictionary).get("quantity", 0))
	_check(not thorium_extraction_batches.is_empty() and thorium_extracted_total == 2 and int(thorium_depot.get("inventory", {}).get("thorium_ore", 0)) == 2, "the powered Lunar surface mine physically transfers its exact first two-unit thorium batch through the released public storage path; total=%d depot=%s events=%s" % [thorium_extracted_total, JSON.stringify(thorium_depot.get("inventory", {})), JSON.stringify(thorium_extraction_events)])
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
		if prototype_repair_export > 0 or prototype_cp_export > 0:
			var prototype_propellant_cycles := ceili(float(prototype_cp_export) / 2.0)
			var prototype_electronics_cycles := ceili(float(prototype_propellant_cycles) / 2.0)
			var prototype_copper_cycles := prototype_repair_export + prototype_electronics_cycles
			_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", jovian_research_power_id, cruiser_bulk_depot_id, "copper_ingot", prototype_copper_cycles, float(prototype_copper_cycles) * 6000.0 + 2000.0, "J10 prototype Asteroid-return operating copper lot", cruiser_bulk_depot_id)
			if prototype_repair_export > 0:
				_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "iron_ingot", prototype_repair_export * 2, "J10 prototype Asteroid-return repair iron")
				_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", cruiser_bulk_depot_id, "copper_ingot", prototype_repair_export, "J10 prototype Asteroid-return repair copper")
				if failures.size() > 0:
					return
				_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", jovian_research_power_id, cruiser_bulk_depot_id, "repair_material", prototype_repair_export, float(prototype_repair_export) * 12000.0 + 2000.0, "J10 prototype Asteroid-return repair-material lot")
			if prototype_cp_export > 0:
				_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", STARTER_DEPOT_ID, "iron_ingot", prototype_electronics_cycles, "J10 prototype Asteroid-return propellant electronics iron")
				_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_electronics", cruiser_bulk_depot_id, "copper_ingot", prototype_electronics_cycles, "J10 prototype Asteroid-return propellant electronics copper")
				if failures.size() > 0:
					return
				_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_electronics", jovian_research_power_id, cruiser_bulk_depot_id, "electronics", prototype_electronics_cycles * 2, float(prototype_electronics_cycles) * 12000.0 + 2000.0, "J10 prototype Asteroid-return propellant electronics lot")
				_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", STARTER_DEPOT_ID, "iron_ingot", prototype_propellant_cycles * 2, "J10 prototype Asteroid-return propellant iron")
				_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", cruiser_bulk_depot_id, "electronics", prototype_propellant_cycles, "J10 prototype Asteroid-return propellant electronics")
				if failures.size() > 0:
					return
				_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_manufacture_emergency_propellant", jovian_research_power_id, cruiser_bulk_depot_id, "chemical_propellant", prototype_propellant_cycles * 2, float(prototype_propellant_cycles) * 18000.0 + 2000.0, "J10 prototype Asteroid-return propellant lot")
			if failures.size() > 0:
				return
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
	# The established High-Energy Works legally retains a full 128-unit historic
	# buffer.  Consume one compatible data-core cycle with every feeder detached
	# to release three slots before cold-staging the two returned thorium units.
	_clear_competing_cargo_inputs(prototype_high_energy_id, "electronics", "")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "copper_ingot", "")
	_run_buffered_recipe_minimum(prototype_high_energy_id, "grid_fabricate_data_core", jovian_research_power_id, cruiser_bulk_depot_id, "data_core", 1, 20000.0, "J10 thorium-fuel High-Energy buffer release")
	_cold_stage_single_input_minimum(prototype_high_energy_id, "grid_prepare_thorium_fuel", cruiser_bulk_depot_id, "thorium_ore", 2, "J10 returned Lunar thorium fuel feed")
	if failures.size() > 0:
		return
	var thorium_fuel_events := _run_buffered_recipe_minimum(prototype_high_energy_id, "grid_prepare_thorium_fuel", jovian_research_power_id, cruiser_bulk_depot_id, "thorium_fuel", 2, 34000.0, "J10 two-cycle thorium-fuel preparation", cruiser_bulk_depot_id)
	var prototype_service_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	_check(_events_have_recipe(thorium_fuel_events, "grid_prepare_thorium_fuel") and int(prototype_service_bulk.get("inventory", {}).get("thorium_fuel", 0)) >= 2, "High-Energy Electronics Works physically prepares two thorium fuel units from the returned Lunar ore; bulk=%s" % JSON.stringify(prototype_service_bulk.get("inventory", {})))
	if failures.size() > 0:
		return
	# Release three more slots through the same conserved resident buffer, then
	# stage the exact six-unit, two-cycle fusion-service manifest while cold.
	_run_buffered_recipe_minimum(prototype_high_energy_id, "grid_fabricate_data_core", jovian_research_power_id, cruiser_bulk_depot_id, "data_core", 1, 20000.0, "J10 fusion-service High-Energy buffer release")
	_cold_stage_single_input_minimum(prototype_high_energy_id, "grid_fabricate_fusion_service_component", cruiser_bulk_depot_id, "steel_composite", 2, "J10 fusion-service steel")
	_cold_stage_single_input_minimum(prototype_high_energy_id, "grid_fabricate_fusion_service_component", cruiser_bulk_depot_id, "quantum_component", 2, "J10 fusion-service quantum components")
	_cold_stage_single_input_minimum(prototype_high_energy_id, "grid_fabricate_fusion_service_component", cruiser_bulk_depot_id, "thorium_fuel", 2, "J10 fusion-service thorium fuel")
	if failures.size() > 0:
		return
	var fusion_service_events := _run_buffered_recipe_minimum(prototype_high_energy_id, "grid_fabricate_fusion_service_component", jovian_research_power_id, cruiser_bulk_depot_id, "fusion_service_component", 4, 30000.0, "J10 two-cycle fusion-service-component fabrication")
	_ensure_connection("POWER", jovian_research_power_id, jovian_research_complex_id, "")
	_ensure_connection("POWER", jovian_research_power_id, fusion_test_rig_id, "")
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
		var array_rare_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", 1, 600000.0)
		var array_rare_repair_gross_target := maxi(1, int(array_rare_repair_projection.get("gross_production_target", 1)))
		var array_rare_repair_location_before := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
		var array_rare_repair_factory_target := maxi(0, array_rare_repair_gross_target - array_rare_repair_location_before)
		if array_rare_repair_factory_target > 0:
			_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", jovian_research_power_id, cruiser_bulk_depot_id, "copper_ingot", array_rare_repair_factory_target, float(array_rare_repair_factory_target) * 6000.0 + 2000.0, "J10 Energy Array Lunar rare-return dispatch repair copper", cruiser_bulk_depot_id)
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", STARTER_DEPOT_ID, "iron_ingot", array_rare_repair_factory_target * 2, "J10 Energy Array Lunar rare-return dispatch repair iron")
			_cold_stage_single_input_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", cruiser_bulk_depot_id, "copper_ingot", array_rare_repair_factory_target, "J10 Energy Array Lunar rare-return dispatch repair copper feed")
			if failures.size() > 0:
				return
			_run_buffered_recipe_minimum(cruiser_electronics_id, "grid_fabricate_repair_material", jovian_research_power_id, cruiser_bulk_depot_id, "repair_material", array_rare_repair_factory_target, float(array_rare_repair_factory_target) * 12000.0 + 2000.0, "J10 Energy Array Lunar rare-return dispatch repair-material lot")
		_ensure_connection("POWER", jovian_research_power_id, jovian_research_complex_id, "")
		_ensure_connection("POWER", jovian_research_power_id, fusion_test_rig_id, "")
		if failures.size() > 0:
			return
		var array_rare_earth_location: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var array_rare_origin_cp_shortfall := maxi(0, 1 - int(array_rare_earth_location.get("chemical_propellant", 0)))
		var array_rare_origin_repair_shortfall := maxi(0, array_rare_repair_gross_target - int(array_rare_earth_location.get("repair_material", 0)))
		if array_rare_origin_cp_shortfall > 0:
			_export_to_location("chemical_propellant", array_rare_origin_cp_shortfall, "J10 Energy Array Lunar rare-return replenishment dispatch propellant", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		if array_rare_origin_repair_shortfall > 0:
			_export_to_location("repair_material", array_rare_origin_repair_shortfall, "J10 Energy Array Lunar rare-return replenishment dispatch maintenance", EARTH_WORLD_ID, cruiser_bulk_depot_id)
		_export_to_location("chemical_propellant", array_rare_cp_shortfall, "J10 Energy Array Lunar rare-return source propellant", EARTH_WORLD_ID, cruiser_bulk_depot_id)
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
		var array_titanium_iron_first_wave := 10
		# The first construction wave is one capacity-safe depot manifest.  Do not
		# pre-stage later operating costs across long construction advances: remote
		# provider O&M may correctly settle them before the next wave is published.
		var array_titanium_construction_freight_shipments := 1
		# The preceding prototype reserves the final Assembly electronics in its
		# resident buffer, so replenish this distinct two-unit construction BOM via
		# one exact public Engineering-Works cycle before freight is published.
		var array_smelter_electronics_snapshot := _snapshot(EARTH_WORLD_ID)
		var array_smelter_electronics_works := _entity(array_smelter_electronics_snapshot, cruiser_electronics_id)
		var array_smelter_starter := _entity(array_smelter_electronics_snapshot, STARTER_DEPOT_ID)
		var array_smelter_bulk := _entity(array_smelter_electronics_snapshot, cruiser_bulk_depot_id)
		_check(not array_smelter_electronics_works.is_empty() and int(array_smelter_starter.get("inventory", {}).get("iron_ingot", 0)) >= array_titanium_iron_manifest + 1 and int(array_smelter_bulk.get("inventory", {}).get("copper_ingot", 0)) >= 1, "Earth Factory retains the separate Engineering Works plus exact Starter iron and Bulk copper sources for one fresh Lunar-smelter electronics cycle and its finite iron manifest; works=%s starter=%s bulk=%s" % [JSON.stringify(array_smelter_electronics_works), JSON.stringify(array_smelter_starter.get("inventory", {})), JSON.stringify(array_smelter_bulk.get("inventory", {}))])
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
		_clear_competing_cargo_outputs(cruiser_bulk_depot_id, "copper_ingot", cruiser_electronics_id)
		_clear_competing_cargo_outputs(cruiser_electronics_id, "electronics", STARTER_DEPOT_ID)
		var array_smelter_iron_link := _factory_command("CONNECT_ENTITIES", {"link_kind":"CARGO", "source_id":STARTER_DEPOT_ID, "target_id":cruiser_electronics_id, "item_id":"iron_ingot", "capacity_per_second":1.0})
		var array_smelter_copper_link := _factory_command("CONNECT_ENTITIES", {"link_kind":"CARGO", "source_id":cruiser_bulk_depot_id, "target_id":cruiser_electronics_id, "item_id":"copper_ingot", "capacity_per_second":1.0})
		_check(bool(array_smelter_iron_link.get("accepted", false)) and bool(array_smelter_copper_link.get("accepted", false)), "public Factory CARGO commands connect exactly one Starter iron and one Bulk copper per second into the fresh Lunar-smelter electronics cycle; iron=%s copper=%s" % [JSON.stringify(array_smelter_iron_link), JSON.stringify(array_smelter_copper_link)])
		if failures.size() > 0:
			return
		_ensure_connection("CARGO", cruiser_electronics_id, STARTER_DEPOT_ID, "electronics")
		_advance(1000.0, "J10 fresh Lunar-smelter electronics one-cycle input staging")
		var array_smelter_electronics_staged := _entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id)
		_check(int(array_smelter_electronics_staged.get("inputs", {}).get("iron_ingot", 0)) >= 1 and int(array_smelter_electronics_staged.get("inputs", {}).get("copper_ingot", 0)) >= 1, "public Factory links physically stage the Starter iron-one and Bulk copper-one sources for the exact fresh Lunar-smelter electronics cycle; works=%s starter=%s bulk=%s" % [JSON.stringify(array_smelter_electronics_staged), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}))])
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
		# Manufacture the construction wave's operating costs from finite public
		# Factory inputs.  Earlier fleet maintenance legitimately consumes historic
		# Location reserves, so plan against a conservative horizon, then refresh the
		# authoritative projection immediately before export.
		var array_first_wave_plan_cp_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", array_titanium_construction_freight_shipments, 600000.0)
		var array_first_wave_plan_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", array_titanium_construction_freight_shipments, 600000.0)
		var array_first_wave_plan_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var array_first_wave_cp_source_target := maxi(0, int(array_first_wave_plan_cp_projection.get("gross_production_target", 0)) - int(array_first_wave_plan_available.get("chemical_propellant", 0)))
		var array_first_wave_repair_source_target := maxi(0, int(array_first_wave_plan_repair_projection.get("gross_production_target", 0)) - int(array_first_wave_plan_available.get("repair_material", 0)))
		var array_first_wave_factory_before: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})
		var array_first_wave_cp_factory_shortfall := maxi(0, array_first_wave_cp_source_target - int(array_first_wave_factory_before.get("chemical_propellant", 0)))
		var array_first_wave_repair_factory_shortfall := maxi(0, array_first_wave_repair_source_target - int(array_first_wave_factory_before.get("repair_material", 0)))
		var array_first_wave_frame_factory_shortfall := maxi(0, array_titanium_smelter_frame_cost - int(array_first_wave_factory_before.get("structural_frame", 0)))
		var array_first_wave_propellant_cycles := ceili(float(array_first_wave_cp_factory_shortfall) / 2.0)
		var array_first_wave_electronics_target := array_titanium_smelter_electronics_cost + array_first_wave_propellant_cycles
		var array_first_wave_electronics_shortfall := maxi(0, array_first_wave_electronics_target - int(array_first_wave_factory_before.get("electronics", 0)))
		var array_first_wave_electronics_cycles := ceili(float(array_first_wave_electronics_shortfall) / 2.0)
		var array_first_wave_copper_target := array_first_wave_repair_factory_shortfall + array_first_wave_frame_factory_shortfall + array_first_wave_electronics_cycles
		var array_first_wave_copper_shortfall := maxi(0, array_first_wave_copper_target - int(array_first_wave_factory_before.get("copper_ingot", 0)))
		var array_first_wave_iron_target := array_titanium_iron_first_wave + array_first_wave_repair_factory_shortfall * 2 + array_first_wave_frame_factory_shortfall * 2 + array_first_wave_propellant_cycles * 2 + array_first_wave_electronics_cycles
		_check(int(array_first_wave_factory_before.get("iron_ingot", 0)) >= array_first_wave_iron_target, "Earth Starter custody retains the finite iron precursor for the first Lunar construction wave and its projected operating-cost fabrication; target=%d inventory=%s" % [array_first_wave_iron_target, JSON.stringify(array_first_wave_factory_before)])
		if failures.size() > 0:
			return
		if array_first_wave_copper_shortfall > 0:
			_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", jovian_research_power_id, STARTER_DEPOT_ID, "copper_ingot", array_first_wave_copper_shortfall, float(array_first_wave_copper_shortfall) * 6000.0 + 2000.0, "J10 first Lunar construction-wave copper precursor", STARTER_DEPOT_ID)
		if array_first_wave_electronics_cycles > 0:
			_run_exact_recipe_batches(cruiser_electronics_id, "grid_fabricate_electronics", jovian_research_power_id, STARTER_DEPOT_ID, "electronics", array_first_wave_electronics_cycles, mini(32, array_first_wave_electronics_cycles), "J10 first Lunar construction-wave electronics precursor")
		if array_first_wave_propellant_cycles > 0:
			_run_exact_recipe_batches(cruiser_electronics_id, "grid_manufacture_emergency_propellant", jovian_research_power_id, STARTER_DEPOT_ID, "chemical_propellant", array_first_wave_propellant_cycles, mini(32, array_first_wave_propellant_cycles), "J10 first Lunar construction-wave propellant")
		if array_first_wave_repair_factory_shortfall > 0:
			_run_exact_recipe_batches(cruiser_electronics_id, "grid_fabricate_repair_material", jovian_research_power_id, STARTER_DEPOT_ID, "repair_material", array_first_wave_repair_factory_shortfall, mini(32, array_first_wave_repair_factory_shortfall), "J10 first Lunar construction-wave repair material")
		if array_first_wave_frame_factory_shortfall > 0:
			_run_exact_recipe_batches(cruiser_electronics_id, "grid_assemble_frame", jovian_research_power_id, STARTER_DEPOT_ID, "structural_frame", array_first_wave_frame_factory_shortfall, array_first_wave_frame_factory_shortfall, "J10 first Lunar construction-wave structural frame")
		if failures.size() > 0:
			return
		var array_first_wave_cp_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", array_titanium_construction_freight_shipments, 240000.0)
		var array_first_wave_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", array_titanium_construction_freight_shipments, 240000.0)
		var array_first_wave_pre_export_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		var array_earth_cp_shortfall := maxi(0, int(array_first_wave_cp_projection.get("gross_production_target", 0)) - int(array_first_wave_pre_export_available.get("chemical_propellant", 0)))
		var array_earth_repair_shortfall := maxi(0, int(array_first_wave_repair_projection.get("gross_production_target", 0)) - int(array_first_wave_pre_export_available.get("repair_material", 0)))
		if array_earth_cp_shortfall > 0:
			_export_to_location("chemical_propellant", array_earth_cp_shortfall, "J10 Lunar Energy Array titanium and fresh-smelter freight propellant", EARTH_WORLD_ID, STARTER_DEPOT_ID)
		if array_earth_repair_shortfall > 0:
			_export_to_location("repair_material", array_earth_repair_shortfall, "J10 Lunar Energy Array titanium and fresh-smelter freight maintenance", EARTH_WORLD_ID, STARTER_DEPOT_ID)
		# The original Lunar Bulk depot is physically full with the preceding
		# rare-earth chain.  Build a second canonical BULK depot from Location
		# custody.  Its remaining capacity accepts only the ten-iron depot wave;
		# the clean-smelter BOM follows after that depot physically exists.
		_export_to_location("iron_ingot", array_titanium_iron_first_wave, "J10 Lunar Energy Array canonical Bulk-depot and empty-smelter construction wave")
		if failures.size() > 0:
			return
		for array_titanium_policy_location in [EARTH_LOCATION_ID, "lunar_space"]:
			game.clear_location_logistics_policy(array_titanium_policy_location, "iron_ingot")
			game.clear_location_logistics_policy(array_titanium_policy_location, "electronics")
			game.clear_location_logistics_policy(array_titanium_policy_location, "structural_frame")
			game.clear_location_logistics_policy(array_titanium_policy_location, "chemical_propellant")
			game.clear_location_logistics_policy(array_titanium_policy_location, "repair_material")
		var array_lunar_iron_before := int(_snapshot(lunar_world_id).get("location_available_inventory", {}).get("iron_ingot", 0))
		var array_first_wave_earth_available: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(int(array_first_wave_earth_available.get("chemical_propellant", 0)) >= array_titanium_construction_freight_shipments and int(array_first_wave_earth_available.get("repair_material", 0)) >= array_titanium_construction_freight_shipments, "Earth Location visibly retains the exact depot-dispatch operating reserve before public Logistics settlement; available=%s" % JSON.stringify(array_first_wave_earth_available))
		if failures.size() > 0:
			return
		_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("lunar_space", "iron_ingot", "DEMAND", 0, array_lunar_iron_before + array_titanium_iron_first_wave, 100, 1)), "public Logistics publishes the capacity-safe ten-iron Lunar Bulk-depot wave")
		var array_titanium_iron_events := _advance(240000.0, "J10 Earth-Lunar Energy Array first construction logistics wave")
		var array_lunar_iron_after: Dictionary = _snapshot(lunar_world_id).get("location_available_inventory", {})
		var array_first_wave_dispatches := array_titanium_iron_events.filter(func(event_value):
			var event := event_value as Dictionary
			var cargo := event.get("cargo", {}) as Dictionary
			return str(event.get("type", "")) == "ShipmentDispatched" and str(event.get("origin", "")) == EARTH_LOCATION_ID and str(event.get("destination", "")) == "lunar_space" and int(cargo.get("iron_ingot", 0)) == array_titanium_iron_first_wave and cargo.size() == 1
		)
		var array_first_wave_earth_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		_check(array_first_wave_dispatches.size() == array_titanium_construction_freight_shipments and int(array_lunar_iron_after.get("iron_ingot", 0)) >= array_lunar_iron_before + array_titanium_iron_first_wave and int(array_first_wave_earth_after.get("chemical_propellant", 0)) <= int(array_first_wave_earth_available.get("chemical_propellant", 0)) - array_titanium_construction_freight_shipments and int(array_first_wave_earth_after.get("repair_material", 0)) <= int(array_first_wave_earth_available.get("repair_material", 0)) - array_titanium_construction_freight_shipments, "public Logistics dispatches and delivers the exact capacity-safe ten-iron depot cargo and visibly settles its source operating cost; lunar=%s earth_before=%s earth_after=%s dispatches=%s events=%s" % [JSON.stringify(array_lunar_iron_after), JSON.stringify(array_first_wave_earth_available), JSON.stringify(array_first_wave_earth_after), JSON.stringify(array_first_wave_dispatches), JSON.stringify(array_titanium_iron_events)])
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
		# The depot construction window can consume the remaining Earth operating
		# reserve.  Recompute the three-item smelter freight cost and manufacture only
		# the public Factory shortfall before asking the generic freight boundary to
		# publish its three independent shipments.
		var array_foundry_freight_shipments := 3
		var array_foundry_cp_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", array_foundry_freight_shipments, 5000.0)
		var array_foundry_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", array_foundry_freight_shipments, 5000.0)
		var array_foundry_earth_snapshot := _snapshot(EARTH_WORLD_ID)
		var array_foundry_cp_total := int((array_foundry_earth_snapshot.get("location_available_inventory", {}) as Dictionary).get("chemical_propellant", 0))
		var array_foundry_repair_total := int((array_foundry_earth_snapshot.get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
		for array_foundry_source_value in array_foundry_earth_snapshot.get("entities", []):
			var array_foundry_source_inventory := (array_foundry_source_value as Dictionary).get("inventory", {}) as Dictionary
			array_foundry_cp_total += int(array_foundry_source_inventory.get("chemical_propellant", 0))
			array_foundry_repair_total += int(array_foundry_source_inventory.get("repair_material", 0))
		var array_foundry_cp_target := maxi(array_foundry_freight_shipments, int(array_foundry_cp_projection.get("gross_production_target", 0)))
		var array_foundry_repair_target := int(array_foundry_repair_projection.get("gross_production_target", 0))
		var array_foundry_cp_shortfall := maxi(0, array_foundry_cp_target - array_foundry_cp_total)
		var array_foundry_repair_shortfall := maxi(0, array_foundry_repair_target - array_foundry_repair_total)
		var array_foundry_propellant_cycles := ceili(float(array_foundry_cp_shortfall) / 2.0)
		var array_foundry_starter_inventory: Dictionary = _entity(array_foundry_earth_snapshot, STARTER_DEPOT_ID).get("inventory", {})
		_check(int(array_foundry_starter_inventory.get("iron_ingot", 0)) >= array_foundry_repair_shortfall * 2 + array_foundry_propellant_cycles * 2 and int(array_foundry_starter_inventory.get("electronics", 0)) >= array_foundry_propellant_cycles, "Earth Starter custody retains the finite precursors for the post-depot smelter-freight operating reserve; repair_shortfall=%d propellant_cycles=%d inventory=%s" % [array_foundry_repair_shortfall, array_foundry_propellant_cycles, JSON.stringify(array_foundry_starter_inventory)])
		if failures.size() > 0:
			return
		if array_foundry_repair_shortfall > 0:
			_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", jovian_research_power_id, STARTER_DEPOT_ID, "copper_ingot", array_foundry_repair_shortfall, float(array_foundry_repair_shortfall) * 6000.0 + 2000.0, "J10 post-depot smelter-freight repair copper", STARTER_DEPOT_ID)
		if array_foundry_propellant_cycles > 0:
			_run_exact_recipe_batches(cruiser_electronics_id, "grid_manufacture_emergency_propellant", jovian_research_power_id, STARTER_DEPOT_ID, "chemical_propellant", array_foundry_propellant_cycles, mini(32, array_foundry_propellant_cycles), "J10 post-depot smelter-freight propellant")
		if array_foundry_repair_shortfall > 0:
			_run_exact_recipe_batches(cruiser_electronics_id, "grid_fabricate_repair_material", jovian_research_power_id, STARTER_DEPOT_ID, "repair_material", array_foundry_repair_shortfall, mini(32, array_foundry_repair_shortfall), "J10 post-depot smelter-freight repair material")
		if failures.size() > 0:
			return
		var array_titanium_foundry_freight := _freight_earth_manifest_to_remote("lunar_space", lunar_world_id, {"iron_ingot":array_titanium_smelter_iron_cost, "electronics":array_titanium_smelter_electronics_cost, "structural_frame":array_titanium_smelter_frame_cost}, "J10 clean Lunar titanium-smelter construction BOM", {"chemical_propellant":1, "repair_material":1}, {"copper_refinery_id":cruiser_copper_id, "engineering_works_id":cruiser_electronics_id, "iron_refinery_id":str(cruiser_iron_refinery.get("id", "")), "power_source_id":jovian_research_power_id, "bulk_storage_id":STARTER_DEPOT_ID})
		_check(not array_titanium_foundry_freight.is_empty(), "public Factory and Logistics deliver the clean Lunar titanium-smelter BOM only after the capacity-expanding Bulk depot exists")
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
		var array_titanium_second_wave_cp_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", 1, 60000.0)
		var array_titanium_second_wave_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", 1, 60000.0)
		var array_titanium_second_wave_cp_export := maxi(0, int(array_titanium_second_wave_cp_projection.get("gross_production_target", 0)) - int(array_titanium_second_wave_earth_available.get("chemical_propellant", 0)))
		var array_titanium_second_wave_repair_export := maxi(0, int(array_titanium_second_wave_repair_projection.get("gross_production_target", 0)) - int(array_titanium_second_wave_earth_available.get("repair_material", 0)))
		var array_titanium_second_wave_factory_snapshot := _snapshot(EARTH_WORLD_ID)
		var array_titanium_second_wave_cp_factory_total := 0
		var array_titanium_second_wave_repair_factory_total := 0
		for array_titanium_second_wave_source_value in array_titanium_second_wave_factory_snapshot.get("entities", []):
			var array_titanium_second_wave_source_inventory := (array_titanium_second_wave_source_value as Dictionary).get("inventory", {}) as Dictionary
			array_titanium_second_wave_cp_factory_total += int(array_titanium_second_wave_source_inventory.get("chemical_propellant", 0))
			array_titanium_second_wave_repair_factory_total += int(array_titanium_second_wave_source_inventory.get("repair_material", 0))
		var array_titanium_second_wave_cp_factory_shortfall := maxi(0, array_titanium_second_wave_cp_export - array_titanium_second_wave_cp_factory_total)
		var array_titanium_second_wave_repair_factory_shortfall := maxi(0, array_titanium_second_wave_repair_export - array_titanium_second_wave_repair_factory_total)
		var array_titanium_second_wave_propellant_cycles := ceili(float(array_titanium_second_wave_cp_factory_shortfall) / 2.0)
		var array_titanium_second_wave_starter_inventory: Dictionary = _entity(array_titanium_second_wave_factory_snapshot, STARTER_DEPOT_ID).get("inventory", {})
		_check(int(array_titanium_second_wave_starter_inventory.get("iron_ingot", 0)) >= array_titanium_second_wave_repair_factory_shortfall * 2 + array_titanium_second_wave_propellant_cycles * 2 and int(array_titanium_second_wave_starter_inventory.get("electronics", 0)) >= array_titanium_second_wave_propellant_cycles, "Earth Starter custody retains the finite precursors for the final Lunar titanium recipe-wave operating reserve; repair_shortfall=%d propellant_cycles=%d inventory=%s" % [array_titanium_second_wave_repair_factory_shortfall, array_titanium_second_wave_propellant_cycles, JSON.stringify(array_titanium_second_wave_starter_inventory)])
		if failures.size() > 0:
			return
		if array_titanium_second_wave_repair_factory_shortfall > 0:
			_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", jovian_research_power_id, STARTER_DEPOT_ID, "copper_ingot", array_titanium_second_wave_repair_factory_shortfall, float(array_titanium_second_wave_repair_factory_shortfall) * 6000.0 + 2000.0, "J10 final Lunar titanium recipe-wave repair copper", STARTER_DEPOT_ID)
		if array_titanium_second_wave_propellant_cycles > 0:
			_run_exact_recipe_batches(cruiser_electronics_id, "grid_manufacture_emergency_propellant", jovian_research_power_id, STARTER_DEPOT_ID, "chemical_propellant", array_titanium_second_wave_propellant_cycles, mini(32, array_titanium_second_wave_propellant_cycles), "J10 final Lunar titanium recipe-wave propellant")
		if array_titanium_second_wave_repair_factory_shortfall > 0:
			_run_exact_recipe_batches(cruiser_electronics_id, "grid_fabricate_repair_material", jovian_research_power_id, STARTER_DEPOT_ID, "repair_material", array_titanium_second_wave_repair_factory_shortfall, mini(32, array_titanium_second_wave_repair_factory_shortfall), "J10 final Lunar titanium recipe-wave repair material")
		array_titanium_second_wave_cp_projection = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", 1, 5000.0)
		array_titanium_second_wave_repair_projection = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", 1, 5000.0)
		array_titanium_second_wave_earth_available = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		array_titanium_second_wave_cp_export = maxi(0, int(array_titanium_second_wave_cp_projection.get("gross_production_target", 0)) - int(array_titanium_second_wave_earth_available.get("chemical_propellant", 0)))
		array_titanium_second_wave_repair_export = maxi(0, int(array_titanium_second_wave_repair_projection.get("gross_production_target", 0)) - int(array_titanium_second_wave_earth_available.get("repair_material", 0)))
		if array_titanium_second_wave_cp_export > 0:
			_stage_location_shortfall_from_factory("chemical_propellant", int(array_titanium_second_wave_cp_projection.get("gross_production_target", 0)), "J10 separate Lunar Bulk titanium recipe-wave gross propellant recovery")
		if array_titanium_second_wave_repair_export > 0:
			_stage_location_shortfall_from_factory("repair_material", int(array_titanium_second_wave_repair_projection.get("gross_production_target", 0)), "J10 separate Lunar Bulk titanium recipe-wave gross maintenance recovery")
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
		var array_titanium_return_cp_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", 1, 180000.0)
		var array_titanium_return_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", 1, 180000.0)
		var array_titanium_return_cp_location_target := array_titanium_return_cp_shortfall + int(array_titanium_return_cp_projection.get("gross_production_target", 0))
		var array_titanium_return_repair_location_target := int(array_titanium_return_repair_projection.get("gross_production_target", 0))
		var array_titanium_return_cp_factory_target := maxi(0, array_titanium_return_cp_location_target - int(array_titanium_return_earth_available.get("chemical_propellant", 0)))
		var array_titanium_return_repair_factory_target := maxi(0, array_titanium_return_repair_location_target - int(array_titanium_return_earth_available.get("repair_material", 0)))
		_manufacture_earth_operating_shortfall(array_titanium_return_cp_factory_target, array_titanium_return_repair_factory_target, cruiser_copper_id, cruiser_electronics_id, jovian_research_power_id, STARTER_DEPOT_ID, "J10 Energy Array titanium-return operating reserve")
		array_titanium_return_cp_projection = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", 1, 180000.0)
		array_titanium_return_repair_projection = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", 1, 180000.0)
		array_titanium_return_earth_available = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
		array_titanium_return_cp_location_target = array_titanium_return_cp_shortfall + int(array_titanium_return_cp_projection.get("gross_production_target", 0))
		array_titanium_return_repair_location_target = int(array_titanium_return_repair_projection.get("gross_production_target", 0))
		array_titanium_return_cp_factory_target = maxi(0, array_titanium_return_cp_location_target - int(array_titanium_return_earth_available.get("chemical_propellant", 0)))
		array_titanium_return_repair_factory_target = maxi(0, array_titanium_return_repair_location_target - int(array_titanium_return_earth_available.get("repair_material", 0)))
		_manufacture_earth_operating_shortfall(array_titanium_return_cp_factory_target, array_titanium_return_repair_factory_target, cruiser_copper_id, cruiser_electronics_id, jovian_research_power_id, STARTER_DEPOT_ID, "J10 Energy Array titanium-return refreshed operating reserve")
		_stage_location_shortfall_from_factory("chemical_propellant", array_titanium_return_cp_location_target, "J10 Energy Array titanium-return propellant and dispatch reserve")
		_stage_location_shortfall_from_factory("repair_material", array_titanium_return_repair_location_target, "J10 Energy Array titanium-return maintenance reserve")
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
	var array_asteroid_cp_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", array_asteroid_operating_shipments * 3, 360000.0)
	var array_asteroid_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", array_asteroid_operating_shipments * 2, 360000.0)
	var array_earth_cp_target := array_asteroid_cp_shortfall + int(array_asteroid_cp_projection.get("gross_production_target", 0))
	var array_earth_repair_target := array_asteroid_repair_shortfall + int(array_asteroid_repair_projection.get("gross_production_target", 0))
	var array_earth_cp_export := maxi(0, array_earth_cp_target - int(array_earth_available.get("chemical_propellant", 0)))
	var array_earth_repair_export := maxi(0, array_earth_repair_target - int(array_earth_available.get("repair_material", 0)))
	_manufacture_earth_operating_shortfall(array_earth_cp_export, array_earth_repair_export, cruiser_copper_id, cruiser_electronics_id, jovian_research_power_id, STARTER_DEPOT_ID, "J10 three bounded Energy Array cobalt-return operating reserve")
	array_asteroid_cp_projection = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", array_asteroid_operating_shipments * 3, 360000.0)
	array_asteroid_repair_projection = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", array_asteroid_operating_shipments * 2, 360000.0)
	array_earth_available = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	array_earth_cp_target = array_asteroid_cp_shortfall + int(array_asteroid_cp_projection.get("gross_production_target", 0))
	array_earth_repair_target = array_asteroid_repair_shortfall + int(array_asteroid_repair_projection.get("gross_production_target", 0))
	array_earth_cp_export = maxi(0, array_earth_cp_target - int(array_earth_available.get("chemical_propellant", 0)))
	array_earth_repair_export = maxi(0, array_earth_repair_target - int(array_earth_available.get("repair_material", 0)))
	_manufacture_earth_operating_shortfall(array_earth_cp_export, array_earth_repair_export, cruiser_copper_id, cruiser_electronics_id, jovian_research_power_id, STARTER_DEPOT_ID, "J10 three bounded Energy Array cobalt-return refreshed operating reserve")
	_stage_location_shortfall_from_factory("chemical_propellant", array_earth_cp_target, "J10 three bounded Energy Array cobalt-return propellant reserve")
	_stage_location_shortfall_from_factory("repair_material", array_earth_repair_target, "J10 three bounded Energy Array cobalt-return maintenance reserve")
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
	# Operating-reserve fabrication has legitimately consumed the old Starter iron.
	# Recover the complete twenty-iron steel manifest up front from the existing
	# full raw-ore buffer, then split only the smelter staging into capacity-safe
	# twelve/six and eight/four batches.
	var array_iron_recovery_snapshot := _snapshot(EARTH_WORLD_ID)
	var array_iron_recovery_refinery := _entity_with_recipe(array_iron_recovery_snapshot, "grid_refine_iron")
	_check(not array_iron_recovery_refinery.is_empty(), "Earth Factory exposes the existing raw-iron refinery needed for the complete Energy Array steel manifest")
	if failures.size() > 0:
		return
	var array_iron_recovery_refinery_id := str(array_iron_recovery_refinery.get("id", ""))
	var array_iron_recovery_inputs: Dictionary = array_iron_recovery_refinery.get("inputs", {}) as Dictionary
	_check(int(array_iron_recovery_inputs.get("iron_ore", 0)) >= 40 and int(array_iron_recovery_refinery.get("outputs", {}).get("iron_ingot", 0)) == 0, "the public Earth Factory snapshot exposes the forty buffered ore units and no queued iron output required for exactly twenty steel-manifest recovery cycles; refinery=%s" % JSON.stringify(array_iron_recovery_refinery))
	if failures.size() > 0:
		return
	var array_iron_recovery_input_before := int(array_iron_recovery_inputs.get("iron_ore", 0))
	var array_iron_recovery_bulk_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("iron_ingot", 0))
	_clear_competing_cargo_inputs(array_iron_recovery_refinery_id, "iron_ore", "")
	_clear_competing_cargo_outputs(array_iron_recovery_refinery_id, "iron_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "iron_ingot", array_iron_recovery_refinery_id)
	_ensure_connection("CARGO", array_iron_recovery_refinery_id, cruiser_bulk_depot_id, "iron_ingot")
	_isolate_power_for_targets([cruiser_foundry_id, array_iron_recovery_refinery_id], jovian_research_power_id)
	_ensure_connection("POWER", jovian_research_power_id, array_iron_recovery_refinery_id, "")
	var array_iron_recovery_events := _advance(40000.0, "J10 exact twenty-ingot Energy Array steel-manifest refinement")
	var array_iron_recovery_bulk := _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id)
	var array_iron_recovery_cycles := 0
	var array_iron_recovery_produced := 0
	for array_iron_recovery_event_value in array_iron_recovery_events:
		var array_iron_recovery_event := array_iron_recovery_event_value as Dictionary
		if str(array_iron_recovery_event.get("type", "")) == "FactoryRecipeCompleted" and str(array_iron_recovery_event.get("world_id", "")) == EARTH_WORLD_ID and str(array_iron_recovery_event.get("entity_id", "")) == array_iron_recovery_refinery_id and str(array_iron_recovery_event.get("recipe_id", "")) == "grid_refine_iron":
			array_iron_recovery_cycles += int(array_iron_recovery_event.get("completed_cycles", 0))
			array_iron_recovery_produced += int((array_iron_recovery_event.get("produced", {}) as Dictionary).get("iron_ingot", 0))
	var array_iron_recovery_after := _entity(_snapshot(EARTH_WORLD_ID), array_iron_recovery_refinery_id)
	_check(array_iron_recovery_cycles == 20 and array_iron_recovery_produced == 20 and int(array_iron_recovery_bulk.get("inventory", {}).get("iron_ingot", 0)) == array_iron_recovery_bulk_before + 20 and int(array_iron_recovery_after.get("inputs", {}).get("iron_ore", 0)) == array_iron_recovery_input_before - 40, "Earth Factory physically consumes forty units from its existing raw-ore buffer and refines the exact twenty iron ingots for both Energy Array steel batches; bulk=%s refinery=%s cycles=%d produced=%d events=%s" % [JSON.stringify(array_iron_recovery_bulk.get("inventory", {})), JSON.stringify(array_iron_recovery_after), array_iron_recovery_cycles, array_iron_recovery_produced, JSON.stringify(array_iron_recovery_events)])
	if failures.size() > 0:
		return
	_isolate_power_for_targets([cruiser_foundry_id], jovian_research_power_id)
	_clear_competing_cargo_outputs(array_iron_recovery_refinery_id, "iron_ingot", "")
	var array_steel_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_foundry_id, "recipe_id":"grid_refine_steel_electric"})
	_check(bool(array_steel_recipe.get("accepted", false)), "Factory protocol selects exact ten-cycle Energy Array electric steelmaking")
	_clear_competing_cargo_inputs(cruiser_foundry_id, "iron_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_foundry_id, "cobalt_ingot", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(cruiser_foundry_id, "steel_composite", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "steel_composite", cruiser_foundry_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, cruiser_foundry_id, "iron_ingot")
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
	_isolate_power_for_targets([cruiser_foundry_id], jovian_research_power_id)
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
	# The same operating-cost closure consumed the old Starter frame/copper stock.
	# Rebuild only the four HSS frames and retain exactly three further copper
	# ingots for the immediately following electronics manifest.
	var array_hss_precursor_before: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})
	var array_hss_frame_shortfall := maxi(0, 4 - int(array_hss_precursor_before.get("structural_frame", 0)))
	var array_hss_iron_shortfall := maxi(0, array_hss_frame_shortfall * 2 - int(array_hss_precursor_before.get("iron_ingot", 0)))
	var array_hss_copper_shortfall := maxi(0, array_hss_frame_shortfall + 3 - int(array_hss_precursor_before.get("copper_ingot", 0)))
	if array_hss_iron_shortfall > 0:
		_run_buffered_recipe_minimum(array_iron_recovery_refinery_id, "grid_refine_iron", jovian_research_power_id, STARTER_DEPOT_ID, "iron_ingot", array_hss_iron_shortfall, float(array_hss_iron_shortfall) * 2000.0 + 2000.0, "J10 Energy Array HSS-frame iron precursor")
	if array_hss_copper_shortfall > 0:
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", jovian_research_power_id, STARTER_DEPOT_ID, "copper_ingot", array_hss_copper_shortfall, float(array_hss_copper_shortfall) * 6000.0 + 2000.0, "J10 Energy Array HSS-frame and electronics copper precursor", STARTER_DEPOT_ID)
	if array_hss_frame_shortfall > 0:
		_run_exact_recipe_batches(cruiser_electronics_id, "grid_assemble_frame", jovian_research_power_id, STARTER_DEPOT_ID, "structural_frame", array_hss_frame_shortfall, array_hss_frame_shortfall, "J10 Energy Array HSS structural frames")
	var array_hss_precursor_after: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})
	_check(int(array_hss_precursor_after.get("structural_frame", 0)) >= 4 and int(array_hss_precursor_after.get("copper_ingot", 0)) >= 3, "Earth Factory retains the exact four-frame HSS source plus three-copper electronics reserve after bounded precursor fabrication; inventory=%s" % JSON.stringify(array_hss_precursor_after))
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
	# copper/electronics/titanium buffer.  The two earlier public data-core cycles
	# released the slots used by thorium and fusion-service inputs, leaving the
	# exact 70/46/6 conserved remainder.  Transform that custody through named
	# recipes; never clear or reinterpret it as freely movable storage.
	var array_resident_high_energy := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	var array_resident_inputs: Dictionary = array_resident_high_energy.get("inputs", {}) as Dictionary
	_check(int(array_resident_inputs.get("electronics", 0)) == 46 and int(array_resident_inputs.get("titanium_alloy", 0)) == 6 and int(array_resident_inputs.get("copper_ingot", 0)) == 70, "public Factory custody identifies the complete post-fusion-service High-Energy input buffer before it is physically transformed for later J10 use; inputs=%s" % JSON.stringify(array_resident_inputs))
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
	_check(array_buffer_rad_cycles == 3 and array_buffer_rad_produced == 3 and int(array_after_rad_buffer.get("inputs", {}).get("copper_ingot", 0)) == 70 and int(array_after_rad_buffer.get("inputs", {}).get("electronics", 0)) == 40 and int(array_after_rad_buffer.get("inputs", {}).get("titanium_alloy", 0)) == 3 and int(array_after_rad_buffer.get("outputs", {}).get("radiation_hardened_electronics", 0)) == 0 and int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("radiation_hardened_electronics", 0)) == array_buffer_rad_before + 3 and int(array_buffer_rad_consumed_after.get("electronics", 0)) == int(array_buffer_rad_consumed_before.get("electronics", 0)) + 6 and int(array_buffer_rad_consumed_after.get("titanium_alloy", 0)) == int(array_buffer_rad_consumed_before.get("titanium_alloy", 0)) + 3 and int(array_buffer_rad_produced_after.get("radiation_hardened_electronics", 0)) == int(array_buffer_rad_produced_before.get("radiation_hardened_electronics", 0)) + 3, "three real High-Energy cycles transform half of the retained titanium/electronics buffer into explicit radiation-hardened custody while preserving its copper and the exact three titanium units for the Energy Array bus manifest; machine=%s bulk=%s statistics=%s events=%s" % [JSON.stringify(array_after_rad_buffer), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {})), JSON.stringify(array_buffer_rad_statistics_after), JSON.stringify(array_buffer_rad_events)])
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
	_clear_competing_cargo_inputs(prototype_high_energy_id, "copper_ingot", "")
	_clear_competing_cargo_outputs(prototype_high_energy_id, "data_core", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "data_core", prototype_high_energy_id)
	_clear_competing_cargo_outputs(cruiser_bulk_depot_id, "data_core", "")
	_ensure_connection("CARGO", prototype_high_energy_id, cruiser_bulk_depot_id, "data_core")
	var array_buffer_data_machine_before := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	var array_buffer_data_output_before := int(array_buffer_data_machine_before.get("outputs", {}).get("data_core", 0))
	var array_buffer_data_target_cycles := 20
	_check(array_buffer_data_output_before == 0 and int(array_buffer_data_machine_before.get("inputs", {}).get("copper_ingot", 0)) == 70 and int(array_buffer_data_machine_before.get("inputs", {}).get("electronics", 0)) == array_buffer_data_target_cycles * 2 and int(array_buffer_data_machine_before.get("inputs", {}).get("titanium_alloy", 0)) == 3, "retained-buffer data-core fabrication begins cold with its exact twenty resident cycles, three reserved titanium units, and no stale machine output; machine=%s" % JSON.stringify(array_buffer_data_machine_before))
	if failures.size() > 0:
		return
	var array_buffer_data_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("data_core", 0))
	var array_buffer_data_statistics_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("statistics", {}) as Dictionary).duplicate(true)
	_isolate_all_machine_power_for_target(prototype_high_energy_id)
	_ensure_connection("POWER", jovian_research_power_id, prototype_high_energy_id, "")
	var array_buffer_data_events := _advance(float(array_buffer_data_target_cycles) * 18000.0, "J10 retained High-Energy data-core fabrication")
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
	_check(array_buffer_data_cycles == array_buffer_data_target_cycles and array_buffer_data_produced == array_buffer_data_target_cycles and int(array_after_data_buffer.get("inputs", {}).get("electronics", 0)) == 0 and int(array_after_data_buffer.get("inputs", {}).get("copper_ingot", 0)) == 50 and int(array_after_data_buffer.get("inputs", {}).get("titanium_alloy", 0)) == 3 and int(array_after_data_buffer.get("outputs", {}).get("data_core", 0)) == 0 and int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("data_core", 0)) == array_buffer_data_before + array_buffer_data_target_cycles and int(array_buffer_data_consumed_after.get("electronics", 0)) == int(array_buffer_data_consumed_before.get("electronics", 0)) + array_buffer_data_target_cycles * 2 and int(array_buffer_data_consumed_after.get("copper_ingot", 0)) == int(array_buffer_data_consumed_before.get("copper_ingot", 0)) + array_buffer_data_target_cycles and int(array_buffer_data_produced_after.get("data_core", 0)) == int(array_buffer_data_produced_before.get("data_core", 0)) + array_buffer_data_target_cycles, "twenty real High-Energy cycles consume the remaining retained electronics buffer into explicit data-core custody while retaining fifty copper plus the exact three titanium units for the Energy Array bus manifest; machine=%s bulk=%s statistics=%s events=%s" % [JSON.stringify(array_after_data_buffer), JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {})), JSON.stringify(array_buffer_data_statistics_after), JSON.stringify(array_buffer_data_events)])
	if failures.size() > 0:
		return
	for array_power_bus_power_link_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var array_power_bus_power_link := array_power_bus_power_link_value as Dictionary
		if str(array_power_bus_power_link.get("kind", "")) == "POWER" and str(array_power_bus_power_link.get("target_id", "")) == prototype_high_energy_id:
			var array_power_bus_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(array_power_bus_power_link.get("id", ""))})
			_check(bool(array_power_bus_power_removed.get("accepted", false)), "Factory protocol makes the retained High-Energy bus manifest cold before electronics staging")
	_clear_competing_cargo_outputs(prototype_high_energy_id, "radiation_hardened_electronics", "")
	_clear_competing_cargo_outputs(prototype_high_energy_id, "data_core", "")
	var array_power_bus_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("power_bus_component", 0))
	var array_power_bus_recipe := _factory_command("SET_RECIPE", {"entity_id":prototype_high_energy_id, "recipe_id":"grid_fabricate_power_bus_component"})
	_check(bool(array_power_bus_recipe.get("accepted", false)), "Factory protocol selects the exact three-cycle Energy Array power-bus recipe")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "copper_ingot", "")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "titanium_alloy", "")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "electronics", cruiser_bulk_depot_id)
	_clear_competing_cargo_outputs(prototype_high_energy_id, "power_bus_component", cruiser_bulk_depot_id)
	_clear_competing_cargo_inputs(cruiser_bulk_depot_id, "power_bus_component", prototype_high_energy_id)
	_ensure_connection("CARGO", cruiser_bulk_depot_id, prototype_high_energy_id, "electronics")
	_ensure_connection("CARGO", prototype_high_energy_id, cruiser_bulk_depot_id, "power_bus_component")
	var array_power_bus_machine_before := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	var array_power_bus_electronics_before := int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("electronics", 0))
	var array_power_bus_cold_events := _advance(1500.0, "J10 Energy Array retained-buffer power-bus electronics staging")
	_clear_competing_cargo_inputs(prototype_high_energy_id, "electronics", "")
	var array_power_bus_staged := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	_check(not _events_have_recipe(array_power_bus_cold_events, "grid_fabricate_power_bus_component") and int(array_power_bus_machine_before.get("inputs", {}).get("copper_ingot", 0)) == 50 and int(array_power_bus_machine_before.get("inputs", {}).get("titanium_alloy", 0)) == 3 and int(array_power_bus_staged.get("inputs", {}).get("electronics", 0)) == 6 and int(_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}).get("electronics", 0)) == array_power_bus_electronics_before - 6, "the cold public boundary combines six external electronics with the exact resident copper/titanium bus manifest; before=%s staged=%s" % [JSON.stringify(array_power_bus_machine_before), JSON.stringify(array_power_bus_staged)])
	_isolate_all_machine_power_for_target(prototype_high_energy_id)
	_ensure_connection("POWER", jovian_research_power_id, prototype_high_energy_id, "")
	var array_power_bus_events := _advance(66000.0, "J10 exact three-cycle Energy Array retained-buffer power-bus fabrication")
	_advance(1000.0, "J10 Energy Array retained-buffer power-bus cargo settlement")
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
	var array_power_bus_machine_after := _entity(_snapshot(EARTH_WORLD_ID), prototype_high_energy_id)
	_check(array_power_bus_cycles == 3 and array_power_bus_produced == 3 and int(array_power_bus_bulk.get("inventory", {}).get("power_bus_component", 0)) == array_power_bus_before + 3 and int(array_power_bus_machine_after.get("inputs", {}).get("copper_ingot", 0)) == 41 and int(array_power_bus_machine_after.get("inputs", {}).get("electronics", 0)) == 0 and int(array_power_bus_machine_after.get("inputs", {}).get("titanium_alloy", 0)) == 0, "High-Energy Electronics Works consumes the exact resident copper/titanium plus staged electronics and fabricates three Energy Array power buses into explicit Bulk custody; machine=%s bulk=%s events=%s" % [JSON.stringify(array_power_bus_machine_after), JSON.stringify(array_power_bus_bulk.get("inventory", {})), JSON.stringify(array_power_bus_events)])
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
		return str(blocker.get("domain", "")) == "research" and str((blocker.get("source_entity", {}) as Dictionary).get("id", "")) == "research_jovian_operations" and str(blocker.get("primary_reason", "")) == "RESEARCH_CAPACITY_SHORTAGE"
	)
	var array_unpowered_blocker: Dictionary = array_unpowered_runtime.get("blocker", {})
	_check(array_unpowered_links.is_empty() and str(array_unpowered_runtime.get("status", "")) == "BLOCKED" and str(array_unpowered_blocker.get("primary_reason", "")) == "RESEARCH_CAPACITY_SHORTAGE" and float(array_unpowered_blocker.get("available", -1.0)) == 0.0 and float(array_unpowered_blocker.get("required", 0.0)) >= 1.0 and not array_unpowered_capacity_blockers.is_empty(), "without any incoming Research Complex POWER edge, the Energy Array field test is visibly capacity-blocked in both public research projections before causal reconnection; links=%s runtime=%s blockers=%s" % [JSON.stringify(array_unpowered_links), JSON.stringify(array_unpowered_runtime), JSON.stringify(array_unpowered_capacity_blockers)])
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
		return str(blocker.get("domain", "")) == "research" and str((blocker.get("source_entity", {}) as Dictionary).get("id", "")) == "research_jovian_operations" and str(blocker.get("primary_reason", "")) == "RESEARCH_CAPACITY_SHORTAGE"
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
	# Settle the original Engineering Works' conserved iron output before reusing
	# the machine for this new package.  Changing its public recipe exposes the
	# matching output port; the machine stays cold, so the exact delta is historic
	# player-produced custody rather than new background production.
	for gas_survey_legacy_iron_power_value in _snapshot(EARTH_WORLD_ID).get("links", []):
		var gas_survey_legacy_iron_power := gas_survey_legacy_iron_power_value as Dictionary
		if str(gas_survey_legacy_iron_power.get("kind", "")) == "POWER" and str(gas_survey_legacy_iron_power.get("target_id", "")) == cruiser_electronics_id:
			var gas_survey_legacy_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(gas_survey_legacy_iron_power.get("id", ""))})
			_check(bool(gas_survey_legacy_power_removed.get("accepted", false)), "Factory protocol freezes the legacy Engineering Works before iron-output settlement")
	var gas_survey_legacy_iron_recipe := _factory_command("SET_RECIPE", {"entity_id":cruiser_electronics_id, "recipe_id":"grid_refine_iron"})
	_check(bool(gas_survey_legacy_iron_recipe.get("accepted", false)), "Factory protocol exposes the legacy Engineering Works iron output port for conserved settlement")
	var gas_survey_legacy_iron_output := int((_entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id).get("outputs", {}) as Dictionary).get("iron_ingot", 0))
	_check(gas_survey_legacy_iron_output == 44, "the public Engineering Works retains the exact forty-four historic iron output before Jovian survey-package reuse")
	if failures.size() > 0:
		return
	_clear_competing_cargo_outputs(cruiser_electronics_id, "iron_ingot", STARTER_DEPOT_ID)
	_clear_competing_cargo_inputs(STARTER_DEPOT_ID, "iron_ingot", cruiser_electronics_id)
	_ensure_connection("CARGO", cruiser_electronics_id, STARTER_DEPOT_ID, "iron_ingot")
	var gas_survey_legacy_starter_iron_before := int((_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}) as Dictionary).get("iron_ingot", 0))
	var gas_survey_legacy_iron_events := _advance(float(gas_survey_legacy_iron_output) / 4.0 * 1000.0, "J10 legacy Engineering Works iron-output settlement")
	var gas_survey_legacy_starter_iron_after := int((_entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {}) as Dictionary).get("iron_ingot", 0))
	var gas_survey_legacy_machine_iron_after := int((_entity(_snapshot(EARTH_WORLD_ID), cruiser_electronics_id).get("outputs", {}) as Dictionary).get("iron_ingot", 0))
	_check(gas_survey_legacy_starter_iron_after == gas_survey_legacy_starter_iron_before + gas_survey_legacy_iron_output and gas_survey_legacy_machine_iron_after == 0, "the cold public CARGO edge conserves and settles all forty-four legacy iron units into Starter custody; events=%s" % JSON.stringify(gas_survey_legacy_iron_events))
	_clear_competing_cargo_outputs(cruiser_electronics_id, "iron_ingot", "")
	if failures.size() > 0:
		return
	# The Energy Array chain consumes its own exact component lots, so manufacture
	# this distinct survey package from the still-buffered renewable refineries.
	# Dependency targets include what propellant and tool production consumes,
	# leaving the canonical survey quantities in storage at the final boundary.
	var gas_survey_factory_before: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})
	var gas_survey_propellant_shortfall := maxi(0, int(gas_survey_manifest.get("chemical_propellant", 0)) - int(gas_survey_factory_before.get("chemical_propellant", 0)))
	var gas_survey_repair_shortfall := maxi(0, int(gas_survey_manifest.get("repair_material", 0)) - int(gas_survey_factory_before.get("repair_material", 0)))
	var gas_survey_tool_shortfall := maxi(0, int(gas_survey_manifest.get("industrial_machine_tools", 0)) - int(gas_survey_factory_before.get("industrial_machine_tools", 0)))
	var gas_survey_propellant_cycles := ceili(float(gas_survey_propellant_shortfall) / 2.0)
	var gas_survey_frame_target := int(gas_survey_manifest.get("structural_frame", 0)) + gas_survey_tool_shortfall
	var gas_survey_frame_cycles := maxi(0, gas_survey_frame_target - int(gas_survey_factory_before.get("structural_frame", 0)))
	var gas_survey_electronics_target := int(gas_survey_manifest.get("electronics", 0)) + gas_survey_propellant_cycles + gas_survey_tool_shortfall * 2
	var gas_survey_electronics_shortfall := maxi(0, gas_survey_electronics_target - int(gas_survey_factory_before.get("electronics", 0)))
	var gas_survey_electronics_cycles := ceili(float(gas_survey_electronics_shortfall) / 2.0)
	var gas_survey_copper_target := gas_survey_repair_shortfall + gas_survey_frame_cycles + gas_survey_electronics_cycles
	var gas_survey_copper_shortfall := maxi(0, gas_survey_copper_target - int(gas_survey_factory_before.get("copper_ingot", 0)))
	var gas_survey_iron_target := gas_survey_repair_shortfall * 2 + gas_survey_frame_cycles * 2 + gas_survey_electronics_cycles + gas_survey_propellant_cycles * 2 + gas_survey_tool_shortfall * 4
	var gas_survey_iron_shortfall := maxi(0, gas_survey_iron_target - int(gas_survey_factory_before.get("iron_ingot", 0)))
	if gas_survey_iron_shortfall > 0:
		_run_buffered_recipe_minimum(array_iron_recovery_refinery_id, "grid_refine_iron", array_entity_id, STARTER_DEPOT_ID, "iron_ingot", gas_survey_iron_shortfall, float(gas_survey_iron_shortfall) * 2000.0 + 2000.0, "J10 Jovian survey-package iron precursor")
	if gas_survey_copper_shortfall > 0:
		_run_buffered_recipe_minimum(cruiser_copper_id, "grid_refine_copper", array_entity_id, STARTER_DEPOT_ID, "copper_ingot", gas_survey_copper_shortfall, float(gas_survey_copper_shortfall) * 6000.0 + 2000.0, "J10 Jovian survey-package copper precursor", STARTER_DEPOT_ID)
	if gas_survey_electronics_cycles > 0:
		_run_exact_recipe_batches(cruiser_electronics_id, "grid_fabricate_electronics", array_entity_id, STARTER_DEPOT_ID, "electronics", gas_survey_electronics_cycles, gas_survey_electronics_cycles, "J10 Jovian survey-package electronics")
	if gas_survey_frame_cycles > 0:
		_run_exact_recipe_batches(cruiser_electronics_id, "grid_assemble_frame", array_entity_id, STARTER_DEPOT_ID, "structural_frame", gas_survey_frame_cycles, gas_survey_frame_cycles, "J10 Jovian survey-package structural frames")
	if gas_survey_propellant_cycles > 0:
		_run_exact_recipe_batches(cruiser_electronics_id, "grid_manufacture_emergency_propellant", array_entity_id, STARTER_DEPOT_ID, "chemical_propellant", gas_survey_propellant_cycles, gas_survey_propellant_cycles, "J10 Jovian survey-package propellant")
	if gas_survey_repair_shortfall > 0:
		_run_exact_recipe_batches(cruiser_electronics_id, "grid_fabricate_repair_material", array_entity_id, STARTER_DEPOT_ID, "repair_material", gas_survey_repair_shortfall, gas_survey_repair_shortfall, "J10 Jovian survey-package repair material")
	if gas_survey_tool_shortfall > 0:
		_run_exact_recipe_batches(cruiser_electronics_id, "grid_fabricate_basic_machine_tools", array_entity_id, STARTER_DEPOT_ID, "industrial_machine_tools", gas_survey_tool_shortfall, gas_survey_tool_shortfall, "J10 Jovian survey-package industrial tools")
	var gas_survey_factory_after: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})
	var gas_survey_factory_complete := true
	for gas_survey_factory_item_value in gas_survey_manifest:
		var gas_survey_factory_item := str(gas_survey_factory_item_value)
		gas_survey_factory_complete = gas_survey_factory_complete and int(gas_survey_factory_after.get(gas_survey_factory_item, 0)) >= int(gas_survey_manifest.get(gas_survey_factory_item, 0))
	_check(gas_survey_factory_complete, "Earth Factory physically closes the complete finite Jovian survey package before Location staging; inventory=%s" % JSON.stringify(gas_survey_factory_after))
	var gas_survey_staging := {}
	for gas_survey_manifest_item_value in gas_survey_manifest:
		var gas_survey_manifest_item := str(gas_survey_manifest_item_value)
		gas_survey_staging[gas_survey_manifest_item] = _stage_location_shortfall_from_factory(gas_survey_manifest_item, int(gas_survey_manifest.get(gas_survey_manifest_item, 0)), "J10 Jovian DETECTED-to-SURVEYED mission package")
	if failures.size() > 0:
		return
	var gas_survey_availability: Dictionary = game.survey_mission_availability("gas_giant_region", "SURVEYED", [pathfinder_ship_id], EARTH_LOCATION_ID)
	_check(bool(gas_survey_availability.get("allowed", false)) and (gas_survey_availability.get("costs", {}) as Dictionary) == gas_survey_manifest, "public Survey availability exposes the exact canonical Jovian mission manifest before consuming its Factory-backed Location custody; availability=%s staging=%s" % [JSON.stringify(gas_survey_availability), JSON.stringify(gas_survey_staging)])
	if not bool(gas_survey_availability.get("allowed", false)) or failures.size() > 0:
		return
	var gas_survey_events_start := observed_events.size()
	var gas_survey_location_before_start: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(bool(game.start_survey_mission("gas_giant_region", "SURVEYED", [pathfinder_ship_id], EARTH_LOCATION_ID)), "public Survey command starts the canonical Jovian DETECTED-to-SURVEYED mission with the constructed Pathfinder")
	var gas_survey_location_after_start: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var gas_survey_started := _events_after(gas_survey_events_start).filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "SurveyMissionStarted" and str(event.get("target", "")) == "gas_giant_region" and str(event.get("target_state", "")) == "SURVEYED" and str(event.get("origin", "")) == EARTH_LOCATION_ID and (event.get("ship_ids", []) as Array) == [pathfinder_ship_id]
	)
	var gas_survey_debits_exact := true
	for gas_survey_cost_item_value in gas_survey_manifest:
		var gas_survey_cost_item := str(gas_survey_cost_item_value)
		var gas_survey_cost := int(gas_survey_manifest.get(gas_survey_cost_item, 0))
		gas_survey_debits_exact = gas_survey_debits_exact and int(gas_survey_location_after_start.get(gas_survey_cost_item, 0)) == int(gas_survey_location_before_start.get(gas_survey_cost_item, 0)) - gas_survey_cost
	_check(gas_survey_started.size() == 1 and gas_survey_debits_exact, "the public Jovian survey start consumes exactly its canonical Location manifest and names the target, state, origin, and Pathfinder; started=%s before=%s after=%s" % [JSON.stringify(gas_survey_started), JSON.stringify(gas_survey_location_before_start), JSON.stringify(gas_survey_location_after_start)])
	if failures.size() > 0:
		return
	var gas_survey_events := _advance(60000.0, "J10 Jovian gas-giant industrial survey")
	var gas_survey_completion := _first_event(gas_survey_events, "SurveyMissionCompleted")
	_check(str(gas_survey_completion.get("target", "")) == "gas_giant_region" and str(gas_survey_completion.get("survey_state", "")) == "SURVEYED" and _ordered_types(["SurveyMissionStarted", "SurveyMissionCompleted"], _events_after(gas_survey_events_start)), "J10 completes the exact Jovian DETECTED-to-SURVEYED mission through public time advancement; completion=%s events=%s" % [JSON.stringify(gas_survey_completion), JSON.stringify(gas_survey_events)])
	if failures.size() > 0:
		return
	var gas_factory_init_events_start := observed_events.size()
	_check(bool(game.initialize_surveyed_factory_world("gas_giant_region")), "public Survey completion initializes the Jovian Factory workspace for physical methane and superalloy industry")
	var jovian_world_ids: Array[String] = game.factory_world_ids_for_location("gas_giant_region")
	var jovian_world_id := str(jovian_world_ids[0] if jovian_world_ids.size() == 1 else "")
	var jovian_factory_snapshot := _snapshot(jovian_world_id)
	var gas_factory_init_events := _events_after(gas_factory_init_events_start).filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryWorldInitialized" and str(event.get("location_id", "")) == "gas_giant_region" and str(event.get("world_id", "")) == jovian_world_id
	)
	var jovian_resource_ids: Array[String] = []
	for jovian_field_value in jovian_factory_snapshot.get("resource_fields", []):
		jovian_resource_ids.append(str((jovian_field_value as Dictionary).get("resource_id", "")))
	jovian_resource_ids.sort()
	var gas_factory_init_event := gas_factory_init_events[0] as Dictionary if gas_factory_init_events.size() == 1 else {}
	var jovian_location_available: Dictionary = jovian_factory_snapshot.get("location_available_inventory", {})
	_check(jovian_world_ids.size() == 1 and bool(jovian_factory_snapshot.get("valid", false)) and jovian_resource_ids == ["methane", "water_ice"] and (gas_factory_init_event.get("resource_ids", []) as Array) == jovian_resource_ids and (jovian_factory_snapshot.get("entities", []) as Array).is_empty() and (jovian_factory_snapshot.get("construction_orders", []) as Array).is_empty() and (jovian_factory_snapshot.get("links", []) as Array).is_empty() and jovian_location_available.is_empty() and gas_factory_init_events.size() == 1, "the public Factory-world query exposes a sparse exact Jovian methane/water-ice workspace with no hidden Location resource stock after the FactoryWorldInitialized event; world_ids=%s resources=%s location_available=%s snapshot=%s init_events=%s" % [JSON.stringify(jovian_world_ids), JSON.stringify(jovian_factory_snapshot.get("resource_fields", [])), JSON.stringify(jovian_location_available), JSON.stringify(jovian_factory_snapshot), JSON.stringify(gas_factory_init_events)])
	if failures.size() > 0:
		return

	# Bring the minimal, explicitly finite physical base to the surveyed Jovian
	# world.  The three-hop public freight path has separate chemical and repair
	# costs for each cargo shipment, so stage those operating supplies before the
	# two construction manifests and retire every policy immediately on arrival.
	_check(bool(game.configure_logistics_service("belt_jovian_freight", "general_cargo")), "public Logistics configures the Belt-Jovian freight corridor for the renewable methane industry")
	for gas_bootstrap_policy_item in ["scrap_metal", "iron_ingot", "chemical_propellant", "repair_material"]:
		game.clear_location_logistics_policy(EARTH_LOCATION_ID, str(gas_bootstrap_policy_item))
		game.clear_location_logistics_policy("gas_giant_region", str(gas_bootstrap_policy_item))
	var gas_bootstrap_manifest := {"scrap_metal":2, "iron_ingot":10}
	var gas_bootstrap_operating_manifest := {"chemical_propellant":10, "repair_material":6}
	var gas_bootstrap_factory_before: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})
	var gas_bootstrap_propellant_shortfall := maxi(0, int(gas_bootstrap_operating_manifest.get("chemical_propellant", 0)) - int(gas_bootstrap_factory_before.get("chemical_propellant", 0)))
	var gas_bootstrap_repair_shortfall_plan := maxi(0, int(gas_bootstrap_operating_manifest.get("repair_material", 0)) - int(gas_bootstrap_factory_before.get("repair_material", 0)))
	var gas_bootstrap_propellant_cycles := ceili(float(gas_bootstrap_propellant_shortfall) / 2.0)
	var gas_bootstrap_electronics_cycles := ceili(float(maxi(0, gas_bootstrap_propellant_cycles - int(gas_bootstrap_factory_before.get("electronics", 0)))) / 2.0)
	var gas_bootstrap_required_iron := int(gas_bootstrap_manifest.get("iron_ingot", 0)) + gas_bootstrap_repair_shortfall_plan * 2 + gas_bootstrap_propellant_cycles * 2 + gas_bootstrap_electronics_cycles
	var gas_bootstrap_iron_shortfall_plan := maxi(0, gas_bootstrap_required_iron - int(gas_bootstrap_factory_before.get("iron_ingot", 0)))
	if gas_bootstrap_iron_shortfall_plan > 0:
		_run_buffered_recipe_minimum(array_iron_recovery_refinery_id, "grid_refine_iron", array_entity_id, STARTER_DEPOT_ID, "iron_ingot", gas_bootstrap_iron_shortfall_plan, float(gas_bootstrap_iron_shortfall_plan) * 2000.0 + 2000.0, "J10 Jovian bootstrap manifest and operating iron reserve")
	_manufacture_earth_operating_shortfall(int(gas_bootstrap_operating_manifest.get("chemical_propellant", 0)), int(gas_bootstrap_operating_manifest.get("repair_material", 0)), cruiser_copper_id, cruiser_electronics_id, array_entity_id, STARTER_DEPOT_ID, "J10 Jovian bootstrap operating reserve")
	if failures.size() > 0:
		return
	var gas_bootstrap_staging := {}
	for gas_bootstrap_item_value in gas_bootstrap_manifest:
		var gas_bootstrap_item := str(gas_bootstrap_item_value)
		gas_bootstrap_staging[gas_bootstrap_item] = _stage_location_shortfall_from_factory(gas_bootstrap_item, int(gas_bootstrap_manifest.get(gas_bootstrap_item, 0)), "J10 Jovian solar-and-bulk-depot bootstrap")
	# The maintenance projection is a read-only settlement estimate, not an item
	# grant.  Re-evaluate it after any finite repair production: the production
	# window itself can advance fractional Earth maintenance consumption.
	var gas_bootstrap_iron_refinery := _entity_with_recipe(_snapshot(EARTH_WORLD_ID), "grid_refine_iron")
	_check(not gas_bootstrap_iron_refinery.is_empty(), "Earth Factory retains the public iron-refinery endpoint needed to replenish a Jovian freight repair shortfall")
	if gas_bootstrap_iron_refinery.is_empty() or failures.size() > 0:
		return
	var gas_bootstrap_iron_refinery_id := str(gas_bootstrap_iron_refinery.get("id", ""))
	var gas_bootstrap_operating_targets := {}
	var gas_bootstrap_operating_projections := {}
	var gas_bootstrap_repair_works_id := cruiser_electronics_id
	for gas_bootstrap_recovery_pass in range(2):
		gas_bootstrap_operating_targets.clear()
		gas_bootstrap_operating_projections.clear()
		for gas_bootstrap_operating_item_value in gas_bootstrap_operating_manifest:
			var gas_bootstrap_operating_item := str(gas_bootstrap_operating_item_value)
			var gas_bootstrap_spendable_target := int(gas_bootstrap_operating_manifest.get(gas_bootstrap_operating_item, 0))
			var gas_bootstrap_recovery: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, gas_bootstrap_operating_item, gas_bootstrap_spendable_target, 5000.0)
			gas_bootstrap_operating_projections[gas_bootstrap_operating_item] = gas_bootstrap_recovery
			gas_bootstrap_operating_targets[gas_bootstrap_operating_item] = maxi(gas_bootstrap_spendable_target, int(gas_bootstrap_recovery.get("gross_production_target", gas_bootstrap_spendable_target)))
		var gas_bootstrap_repair_snapshot := _snapshot(EARTH_WORLD_ID)
		var gas_bootstrap_repair_factory_available := 0
		for gas_bootstrap_repair_entity_value in gas_bootstrap_repair_snapshot.get("entities", []):
			gas_bootstrap_repair_factory_available += int(((gas_bootstrap_repair_entity_value as Dictionary).get("inventory", {}) as Dictionary).get("repair_material", 0))
		var gas_bootstrap_repair_location_available := int((gas_bootstrap_repair_snapshot.get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
		var gas_bootstrap_repair_shortfall := maxi(0, int(gas_bootstrap_operating_targets.get("repair_material", 0)) - gas_bootstrap_repair_location_available - gas_bootstrap_repair_factory_available)
		if gas_bootstrap_repair_shortfall > 0:
			gas_bootstrap_repair_works_id = _fabricate_earth_repair_shortfall(gas_bootstrap_repair_shortfall, cruiser_copper_id, gas_bootstrap_repair_works_id, gas_bootstrap_iron_refinery_id, array_entity_id, cruiser_bulk_depot_id, "J10 Jovian freight repair-shortfall pass %d" % (gas_bootstrap_recovery_pass + 1))
			if gas_bootstrap_repair_works_id.is_empty() or failures.size() > 0:
				return
	# Compute the dispatch horizon one final time immediately before public exports
	# and fail closed if the two bounded production passes still cannot fund it.
	gas_bootstrap_operating_targets.clear()
	gas_bootstrap_operating_projections.clear()
	for gas_bootstrap_operating_item_value in gas_bootstrap_operating_manifest:
		var gas_bootstrap_final_item := str(gas_bootstrap_operating_item_value)
		var gas_bootstrap_final_spendable_target := int(gas_bootstrap_operating_manifest.get(gas_bootstrap_final_item, 0))
		var gas_bootstrap_final_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, gas_bootstrap_final_item, gas_bootstrap_final_spendable_target, 5000.0)
		gas_bootstrap_operating_projections[gas_bootstrap_final_item] = gas_bootstrap_final_projection
		gas_bootstrap_operating_targets[gas_bootstrap_final_item] = maxi(gas_bootstrap_final_spendable_target, int(gas_bootstrap_final_projection.get("gross_production_target", gas_bootstrap_final_spendable_target)))
	var gas_bootstrap_final_repair_snapshot := _snapshot(EARTH_WORLD_ID)
	var gas_bootstrap_final_repair_available := int((gas_bootstrap_final_repair_snapshot.get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
	for gas_bootstrap_final_repair_entity_value in gas_bootstrap_final_repair_snapshot.get("entities", []):
		gas_bootstrap_final_repair_available += int(((gas_bootstrap_final_repair_entity_value as Dictionary).get("inventory", {}) as Dictionary).get("repair_material", 0))
	_check(gas_bootstrap_final_repair_available >= int(gas_bootstrap_operating_targets.get("repair_material", 0)), "two bounded public repair-production passes cover the fresh Jovian-bootstrap maintenance projection across existing Earth Location plus exportable Factory custody; available=%d targets=%s projections=%s" % [gas_bootstrap_final_repair_available, JSON.stringify(gas_bootstrap_operating_targets), JSON.stringify(gas_bootstrap_operating_projections)])
	if failures.size() > 0:
		return
	for gas_bootstrap_operating_item_value in gas_bootstrap_operating_targets:
		var gas_bootstrap_operating_item := str(gas_bootstrap_operating_item_value)
		gas_bootstrap_staging[gas_bootstrap_operating_item] = _stage_location_shortfall_from_factory(gas_bootstrap_operating_item, int(gas_bootstrap_operating_targets.get(gas_bootstrap_operating_item, 0)), "J10 Jovian solar-and-bulk-depot freight operating reserve")
	if failures.size() > 0:
		return
	var gas_bootstrap_location_before: Dictionary = _snapshot(jovian_world_id).get("location_available_inventory", {})
	_check(bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "scrap_metal", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("gas_giant_region", "scrap_metal", "DEMAND", 0, int(gas_bootstrap_location_before.get("scrap_metal", 0)) + 2, 100, 1)) and bool(game.set_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot", "SUPPLY", 0, 0, 100, 1)) and bool(game.set_location_logistics_policy("gas_giant_region", "iron_ingot", "DEMAND", 0, int(gas_bootstrap_location_before.get("iron_ingot", 0)) + 10, 100, 1)), "public Logistics publishes the exact finite Jovian solar and Bulk-depot construction manifest")
	var gas_bootstrap_earth_before_dispatch: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var gas_bootstrap_dispatch_events := _advance(5000.0, "J10 Earth-Jovian solar-and-bulk-depot bootstrap dispatch")
	var gas_bootstrap_dispatches: Array = gas_bootstrap_dispatch_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "ShipmentDispatched" and str(event.get("origin", "")) == EARTH_LOCATION_ID and str(event.get("destination", "")) == "gas_giant_region"
	)
	var gas_bootstrap_shipment_ids := {}
	var gas_bootstrap_dispatch_cargo_by_id := {}
	var gas_bootstrap_dispatched := {"scrap_metal":0, "iron_ingot":0}
	var gas_bootstrap_singleton_dispatch := true
	var gas_bootstrap_dispatch_items := {}
	var gas_bootstrap_max_eta_ms := 0.0
	for gas_bootstrap_dispatch_value in gas_bootstrap_dispatches:
		var gas_bootstrap_dispatch := gas_bootstrap_dispatch_value as Dictionary
		var gas_bootstrap_shipment_id := str(gas_bootstrap_dispatch.get("shipment_id", ""))
		gas_bootstrap_shipment_ids[gas_bootstrap_shipment_id] = true
		gas_bootstrap_max_eta_ms = maxf(gas_bootstrap_max_eta_ms, float(gas_bootstrap_dispatch.get("eta_ms", 0.0)))
		var gas_bootstrap_dispatch_cargo: Dictionary = gas_bootstrap_dispatch.get("cargo", {})
		gas_bootstrap_dispatch_cargo_by_id[gas_bootstrap_shipment_id] = gas_bootstrap_dispatch_cargo.duplicate(true)
		if gas_bootstrap_dispatch_cargo.size() != 1:
			gas_bootstrap_singleton_dispatch = false
		else:
			var gas_bootstrap_dispatch_item := str(gas_bootstrap_dispatch_cargo.keys()[0])
			if not gas_bootstrap_manifest.has(gas_bootstrap_dispatch_item) or gas_bootstrap_dispatch_items.has(gas_bootstrap_dispatch_item) or int(gas_bootstrap_dispatch_cargo.get(gas_bootstrap_dispatch_item, 0)) != int(gas_bootstrap_manifest.get(gas_bootstrap_dispatch_item, 0)):
				gas_bootstrap_singleton_dispatch = false
			else:
				gas_bootstrap_dispatch_items[gas_bootstrap_dispatch_item] = true
		for gas_bootstrap_item_value in gas_bootstrap_dispatched:
			var gas_bootstrap_item := str(gas_bootstrap_item_value)
			gas_bootstrap_dispatched[gas_bootstrap_item] = int(gas_bootstrap_dispatched.get(gas_bootstrap_item, 0)) + int(gas_bootstrap_dispatch_cargo.get(gas_bootstrap_item, 0))
	var gas_bootstrap_earth_after_dispatch: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var gas_bootstrap_cp_projection: Dictionary = gas_bootstrap_operating_projections.get("chemical_propellant", {}) as Dictionary
	var gas_bootstrap_repair_projection: Dictionary = gas_bootstrap_operating_projections.get("repair_material", {}) as Dictionary
	var gas_bootstrap_expected_cp_after := int(gas_bootstrap_earth_before_dispatch.get("chemical_propellant", 0)) - int(gas_bootstrap_operating_manifest.get("chemical_propellant", 0)) - int(gas_bootstrap_cp_projection.get("recovery_quantity", 0))
	var gas_bootstrap_expected_repair_after := int(gas_bootstrap_earth_before_dispatch.get("repair_material", 0)) - int(gas_bootstrap_operating_manifest.get("repair_material", 0)) - int(gas_bootstrap_repair_projection.get("recovery_quantity", 0))
	_check(gas_bootstrap_dispatches.size() == gas_bootstrap_manifest.size() and gas_bootstrap_shipment_ids.size() == gas_bootstrap_manifest.size() and gas_bootstrap_dispatch_cargo_by_id.size() == gas_bootstrap_manifest.size() and gas_bootstrap_dispatch_items.size() == gas_bootstrap_manifest.size() and gas_bootstrap_singleton_dispatch and not gas_bootstrap_dispatch_cargo_by_id.has("") and int(gas_bootstrap_dispatched.get("scrap_metal", 0)) == 2 and int(gas_bootstrap_dispatched.get("iron_ingot", 0)) == 10 and gas_bootstrap_max_eta_ms > 0.0 and int(gas_bootstrap_earth_after_dispatch.get("scrap_metal", 0)) == int(gas_bootstrap_earth_before_dispatch.get("scrap_metal", 0)) - 2 and int(gas_bootstrap_earth_after_dispatch.get("iron_ingot", 0)) == int(gas_bootstrap_earth_before_dispatch.get("iron_ingot", 0)) - 10 and int(gas_bootstrap_earth_after_dispatch.get("chemical_propellant", 0)) == gas_bootstrap_expected_cp_after and int(gas_bootstrap_earth_after_dispatch.get("repair_material", 0)) == gas_bootstrap_expected_repair_after, "public Logistics dispatches exactly two singleton correlated Earth-Jovian bootstrap cargos covering each finite manifest item once and debits their exact construction cargo plus the full two-shipment three-hop operating cost and fresh public maintenance projection at the Earth origin; dispatched=%s ids=%s cargo_by_id=%s before=%s after=%s projections=%s" % [JSON.stringify(gas_bootstrap_dispatches), JSON.stringify(gas_bootstrap_shipment_ids), JSON.stringify(gas_bootstrap_dispatch_cargo_by_id), JSON.stringify(gas_bootstrap_earth_before_dispatch), JSON.stringify(gas_bootstrap_earth_after_dispatch), JSON.stringify(gas_bootstrap_operating_projections)])
	if failures.size() > 0:
		return
	var gas_bootstrap_freight_events := _advance(gas_bootstrap_max_eta_ms + 1000.0, "J10 Earth-Jovian solar-and-bulk-depot bootstrap arrival")
	var gas_bootstrap_arrivals: Array = gas_bootstrap_freight_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "ShipmentArrived" and str(event.get("origin", "")) == EARTH_LOCATION_ID and str(event.get("destination", "")) == "gas_giant_region" and gas_bootstrap_shipment_ids.has(str(event.get("shipment_id", "")))
	)
	var gas_bootstrap_arrived := {"scrap_metal":0, "iron_ingot":0}
	var gas_bootstrap_arrival_cargo_by_id := {}
	var gas_bootstrap_singleton_arrival := true
	for gas_bootstrap_arrival_value in gas_bootstrap_arrivals:
		var gas_bootstrap_arrival := gas_bootstrap_arrival_value as Dictionary
		var gas_bootstrap_arrival_id := str(gas_bootstrap_arrival.get("shipment_id", ""))
		var gas_bootstrap_cargo: Dictionary = gas_bootstrap_arrival.get("cargo", {})
		gas_bootstrap_arrival_cargo_by_id[gas_bootstrap_arrival_id] = gas_bootstrap_cargo.duplicate(true)
		gas_bootstrap_singleton_arrival = gas_bootstrap_singleton_arrival and gas_bootstrap_cargo.size() == 1
		for gas_bootstrap_item_value in gas_bootstrap_arrived:
			var gas_bootstrap_item := str(gas_bootstrap_item_value)
			gas_bootstrap_arrived[gas_bootstrap_item] = int(gas_bootstrap_arrived.get(gas_bootstrap_item, 0)) + int(gas_bootstrap_cargo.get(gas_bootstrap_item, 0))
	var gas_bootstrap_location_after: Dictionary = _snapshot(jovian_world_id).get("location_available_inventory", {})
	var gas_bootstrap_repair_production_during_freight := (gas_bootstrap_dispatch_events + gas_bootstrap_freight_events).any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == EARTH_WORLD_ID and str(event.get("recipe_id", "")) == "grid_fabricate_repair_material"
	)
	_check(gas_bootstrap_arrivals.size() == gas_bootstrap_shipment_ids.size() and gas_bootstrap_arrival_cargo_by_id.size() == gas_bootstrap_manifest.size() and gas_bootstrap_singleton_arrival and gas_bootstrap_arrival_cargo_by_id == gas_bootstrap_dispatch_cargo_by_id and int(gas_bootstrap_arrived.get("scrap_metal", 0)) == 2 and int(gas_bootstrap_arrived.get("iron_ingot", 0)) == 10 and not gas_bootstrap_repair_production_during_freight and int(gas_bootstrap_location_after.get("scrap_metal", 0)) == int(gas_bootstrap_location_before.get("scrap_metal", 0)) + 2 and int(gas_bootstrap_location_after.get("iron_ingot", 0)) == int(gas_bootstrap_location_before.get("iron_ingot", 0)) + 10, "public three-hop freight delivers the exact Jovian solar-and-Bulk bootstrap with one singleton cargo per ID, exact manifest coverage, ID-correlated arrival equality, and no continued repair production during dispatch/arrival; arrivals=%s dispatch_cargo=%s arrival_cargo=%s staged=%s before=%s after=%s" % [JSON.stringify(gas_bootstrap_arrivals), JSON.stringify(gas_bootstrap_dispatch_cargo_by_id), JSON.stringify(gas_bootstrap_arrival_cargo_by_id), JSON.stringify(gas_bootstrap_staging), JSON.stringify(gas_bootstrap_location_before), JSON.stringify(gas_bootstrap_location_after)])
	if failures.size() > 0:
		return
	_check(bool(game.clear_location_logistics_policy(EARTH_LOCATION_ID, "scrap_metal")) and bool(game.clear_location_logistics_policy("gas_giant_region", "scrap_metal")) and bool(game.clear_location_logistics_policy(EARTH_LOCATION_ID, "iron_ingot")) and bool(game.clear_location_logistics_policy("gas_giant_region", "iron_ingot")), "public Logistics retires the completed Jovian bootstrap manifests before construction advances")
	var jovian_solar_order := _queue_and_fund("grid_solar_array", "", {"x":192, "y":32}, "J10 Jovian methane-industry solar array", true, jovian_world_id, "")
	var jovian_bulk_order := _queue_and_fund("grid_bulk_depot", "", {"x":224, "y":32}, "J10 Jovian methane-industry Bulk depot", true, jovian_world_id, "")
	var jovian_solar_id := str(jovian_solar_order.get("entity_id", ""))
	var jovian_bulk_depot_id := str(jovian_bulk_order.get("entity_id", ""))
	if jovian_solar_id.is_empty() or jovian_bulk_depot_id.is_empty() or failures.size() > 0:
		return
	var jovian_location_after_funding: Dictionary = _snapshot(jovian_world_id).get("location_available_inventory", {})
	_check(int(jovian_location_after_funding.get("scrap_metal", 0)) == int(gas_bootstrap_location_before.get("scrap_metal", 0)) and int(jovian_location_after_funding.get("iron_ingot", 0)) == int(gas_bootstrap_location_before.get("iron_ingot", 0)), "the public same-location construction funding drains the exact Jovian solar-and-Bulk manifest without hidden inventory; before=%s after_funding=%s" % [JSON.stringify(gas_bootstrap_location_before), JSON.stringify(jovian_location_after_funding)])
	if failures.size() > 0:
		return
	var jovian_bootstrap_construction_events := _advance(90000.0, "J10 Jovian solar-and-Bulk-depot construction")
	var jovian_solar_runtime := _entity(_snapshot(jovian_world_id), jovian_solar_id)
	var jovian_bulk_runtime := _entity(_snapshot(jovian_world_id), jovian_bulk_depot_id)
	_check(jovian_bootstrap_construction_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("entity_id", "")) == jovian_solar_id and str(event.get("definition_id", "")) == "grid_solar_array"
	) and jovian_bootstrap_construction_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("entity_id", "")) == jovian_bulk_depot_id and str(event.get("definition_id", "")) == "grid_bulk_depot"
	) and float(jovian_solar_runtime.get("power_generation_kw", 0.0)) == 100.0 and str(jovian_bulk_runtime.get("definition_id", "")) == "grid_bulk_depot" and str(jovian_bulk_runtime.get("node_kind", "")) == "STORAGE" and int(jovian_bulk_runtime.get("inventory_capacity", 0)) == 1000 and (jovian_bulk_runtime.get("inventory", {}) as Dictionary).is_empty(), "Factory physically completes the finite Jovian solar provider and empty canonical BULK custody required before methane extraction; solar=%s bulk=%s events=%s" % [JSON.stringify(jovian_solar_runtime), JSON.stringify(jovian_bulk_runtime), JSON.stringify(jovian_bootstrap_construction_events)])
	if failures.size() > 0:
		return

	# The surveyed gas world begins empty by contract.  Build the gas-extraction
	# line in two capacity-safe public freight waves: first the extractor, then
	# its explicit FLUID custody, second power source, and clean alloy machine.
	# Methane is never inferred from a generic Bulk inventory even though the
	# current storage-class rule is descriptive rather than rejecting that path.
	var jovian_methane_field := _resource_field(_snapshot(jovian_world_id), "methane")
	_check(not jovian_methane_field.is_empty(), "the surveyed Jovian Factory exposes the canonical methane field for renewable superalloy production")
	if failures.size() > 0:
		return
	var jovian_path_costs := {"chemical_propellant":5, "repair_material":3}
	var jovian_extractor_manifest := {"electronics":3, "industrial_machine_tools":2}
	var jovian_extractor_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", jovian_extractor_manifest.size() * int(jovian_path_costs.get("repair_material", 0)), 5000.0)
	var jovian_extractor_repair_target := int(jovian_extractor_repair_projection.get("gross_production_target", 0))
	var jovian_extractor_propellant_target := jovian_extractor_manifest.size() * int(jovian_path_costs.get("chemical_propellant", 0))
	_manufacture_earth_operating_shortfall(jovian_extractor_propellant_target, jovian_extractor_repair_target, cruiser_copper_id, gas_bootstrap_repair_works_id, array_entity_id, STARTER_DEPOT_ID, "J10 Jovian extractor freight operating reserve")
	if failures.size() > 0:
		return
	# Close the two-tool/three-electronics payload after its operating reserve so
	# the tool recipe's frame/electronics consumption cannot borrow from cargo.
	var jovian_extractor_payload_before: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})
	var jovian_extractor_tool_shortfall := maxi(0, int(jovian_extractor_manifest.get("industrial_machine_tools", 0)) - int(jovian_extractor_payload_before.get("industrial_machine_tools", 0)))
	var jovian_extractor_frame_cycles := maxi(0, jovian_extractor_tool_shortfall - int(jovian_extractor_payload_before.get("structural_frame", 0)))
	var jovian_extractor_electronics_target := int(jovian_extractor_manifest.get("electronics", 0)) + jovian_extractor_tool_shortfall * 2
	var jovian_extractor_electronics_cycles := ceili(float(maxi(0, jovian_extractor_electronics_target - int(jovian_extractor_payload_before.get("electronics", 0)))) / 2.0)
	var jovian_extractor_iron_target := jovian_extractor_frame_cycles * 2 + jovian_extractor_electronics_cycles + jovian_extractor_tool_shortfall * 4
	var jovian_extractor_copper_target := jovian_extractor_frame_cycles + jovian_extractor_electronics_cycles
	_ensure_earth_ingot_minimum("iron_ingot", jovian_extractor_iron_target, gas_bootstrap_iron_refinery_id, array_entity_id, STARTER_DEPOT_ID, "J10 Jovian extractor payload iron precursor")
	_ensure_earth_ingot_minimum("copper_ingot", jovian_extractor_copper_target, cruiser_copper_id, array_entity_id, STARTER_DEPOT_ID, "J10 Jovian extractor payload copper precursor")
	if jovian_extractor_electronics_cycles > 0:
		_run_exact_recipe_batches(gas_bootstrap_repair_works_id, "grid_fabricate_electronics", array_entity_id, STARTER_DEPOT_ID, "electronics", jovian_extractor_electronics_cycles, jovian_extractor_electronics_cycles, "J10 Jovian extractor payload electronics")
	if jovian_extractor_frame_cycles > 0:
		_run_exact_recipe_batches(gas_bootstrap_repair_works_id, "grid_assemble_frame", array_entity_id, STARTER_DEPOT_ID, "structural_frame", jovian_extractor_frame_cycles, jovian_extractor_frame_cycles, "J10 Jovian extractor payload frames")
	if jovian_extractor_tool_shortfall > 0:
		_run_exact_recipe_batches(gas_bootstrap_repair_works_id, "grid_fabricate_basic_machine_tools", array_entity_id, STARTER_DEPOT_ID, "industrial_machine_tools", jovian_extractor_tool_shortfall, jovian_extractor_tool_shortfall, "J10 Jovian extractor payload industrial tools")
	var jovian_extractor_payload_after: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), STARTER_DEPOT_ID).get("inventory", {})
	_check(int(jovian_extractor_payload_after.get("electronics", 0)) >= int(jovian_extractor_manifest.get("electronics", 0)) and int(jovian_extractor_payload_after.get("industrial_machine_tools", 0)) >= int(jovian_extractor_manifest.get("industrial_machine_tools", 0)), "Earth Factory physically closes the exact Jovian extractor freight payload; inventory=%s" % JSON.stringify(jovian_extractor_payload_after))
	if failures.size() > 0:
		return
	var jovian_extractor_repair_total := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
	for repair_entity_value in _snapshot(EARTH_WORLD_ID).get("entities", []):
		jovian_extractor_repair_total += int((((repair_entity_value as Dictionary).get("inventory", {}) as Dictionary).get("repair_material", 0)))
	var jovian_extractor_repair_shortfall := maxi(0, jovian_extractor_repair_target - jovian_extractor_repair_total)
	if jovian_extractor_repair_shortfall > 0:
		gas_bootstrap_repair_works_id = _fabricate_earth_repair_shortfall(jovian_extractor_repair_shortfall, cruiser_copper_id, gas_bootstrap_repair_works_id, gas_bootstrap_iron_refinery_id, array_entity_id, cruiser_bulk_depot_id, "J10 Jovian extractor freight repair recovery")
		_check(not gas_bootstrap_repair_works_id.is_empty(), "the exact public repair-recovery line remains addressable for the Jovian extractor freight manifest")
		if failures.size() > 0:
			return
	var jovian_extractor_freight := _freight_earth_manifest_to_remote("gas_giant_region", jovian_world_id, jovian_extractor_manifest, "J10 Jovian cryogenic methane-extractor construction", jovian_path_costs, {"copper_refinery_id":cruiser_copper_id, "engineering_works_id":gas_bootstrap_repair_works_id, "iron_refinery_id":gas_bootstrap_iron_refinery_id, "power_source_id":array_entity_id, "bulk_storage_id":cruiser_bulk_depot_id})
	gas_bootstrap_repair_works_id = str(jovian_extractor_freight.get("repair_works_id", gas_bootstrap_repair_works_id))
	if failures.size() > 0:
		return
	var jovian_extractor_order := _queue_and_fund("grid_cryogenic_extractor", "", jovian_methane_field.get("footprint", {}).get("origin", {}), "J10 Jovian renewable methane cryogenic extractor", true, jovian_world_id, "")
	var jovian_extractor_id := str(jovian_extractor_order.get("entity_id", ""))
	if jovian_extractor_id.is_empty() or failures.size() > 0:
		return
	var jovian_extractor_construction_events := _advance(90000.0, "J10 Jovian methane-extractor construction")
	var jovian_extractor_runtime := _entity(_snapshot(jovian_world_id), jovian_extractor_id)
	_check(jovian_extractor_construction_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("entity_id", "")) == jovian_extractor_id and str(event.get("definition_id", "")) == "grid_cryogenic_extractor"
	) and str(jovian_extractor_runtime.get("resource_id", "")) == "methane", "Factory physically completes the canonical Jovian methane extractor over its exact public resource field; extractor=%s events=%s" % [JSON.stringify(jovian_extractor_runtime), JSON.stringify(jovian_extractor_construction_events)])
	if failures.size() > 0:
		return
	var jovian_alloy_base_manifest := {"electronics":6, "iron_ingot":4, "scrap_metal":2, "structural_frame":1, "titanium_alloy":4}
	# The next five independent Jovian cargo policies each pay the real multi-hop
	# route cost.  Replenish propellant and payload first, then converge repair
	# material against a fresh projection after those time-advancing recipes;
	# otherwise maintenance can consume an older reserve while it is fabricated.
	# The earlier operating chains may exhaust either legacy ore buffer.  Close the
	# same forty-iron/twenty-copper targets through the public buffered-then-
	# renewable boundary instead of assuming a fixed inherited quantity.
	_ensure_earth_ingot_minimum("iron_ingot", 40, gas_bootstrap_iron_refinery_id, array_entity_id, cruiser_bulk_depot_id, "J10 exact renewable pre-Jovian iron closure")
	_ensure_earth_ingot_minimum("copper_ingot", 20, cruiser_copper_id, array_entity_id, cruiser_bulk_depot_id, "J10 exact renewable pre-Jovian copper closure")
	if failures.size() > 0:
		return
	_cold_stage_recipe_batch(gas_bootstrap_repair_works_id, "grid_fabricate_electronics", array_entity_id, [
		{"item_id":"iron_ingot", "source_id":cruiser_bulk_depot_id, "quantity":9},
		{"item_id":"copper_ingot", "source_id":cruiser_bulk_depot_id, "quantity":9}
	], cruiser_bulk_depot_id, "electronics", 109000.0, "J10 exact eighteen-unit pre-Jovian electronics reserve")
	_cold_stage_recipe_batch(gas_bootstrap_repair_works_id, "grid_manufacture_emergency_propellant", array_entity_id, [
		{"item_id":"iron_ingot", "source_id":cruiser_bulk_depot_id, "quantity":26},
		{"item_id":"electronics", "source_id":cruiser_bulk_depot_id, "quantity":13}
	], cruiser_bulk_depot_id, "chemical_propellant", 235000.0, "J10 exact twenty-six-unit pre-Jovian five-dispatch propellant reserve")
	_run_exact_recipe_batches(gas_bootstrap_repair_works_id, "grid_assemble_frame", array_entity_id, cruiser_bulk_depot_id, "structural_frame", 1, 1, "J10 exact Jovian alloy-base structural frame")
	var jovian_alloy_base_repair_target := 0
	for jovian_alloy_repair_pass in range(2):
		var jovian_alloy_base_repair_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", jovian_alloy_base_manifest.size() * int(jovian_path_costs.get("repair_material", 0)), 5000.0)
		jovian_alloy_base_repair_target = int(jovian_alloy_base_repair_projection.get("gross_production_target", 0))
		var jovian_alloy_base_repair_total := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
		for alloy_repair_entity_value in _snapshot(EARTH_WORLD_ID).get("entities", []):
			jovian_alloy_base_repair_total += int((((alloy_repair_entity_value as Dictionary).get("inventory", {}) as Dictionary).get("repair_material", 0)))
		var jovian_alloy_base_repair_shortfall := maxi(0, jovian_alloy_base_repair_target - jovian_alloy_base_repair_total)
		if jovian_alloy_base_repair_shortfall <= 0:
			break
		# Repair fabrication consumes two iron per unit.  Preserve the four-ingot
		# construction payload in the same public Bulk depot while closing the
		# dynamically projected operating reserve.
		_ensure_earth_ingot_minimum("iron_ingot", 4 + jovian_alloy_base_repair_shortfall * 2, gas_bootstrap_iron_refinery_id, array_entity_id, cruiser_bulk_depot_id, "J10 Jovian alloy-base repair plus construction-iron closure pass %d" % [jovian_alloy_repair_pass + 1])
		if failures.size() > 0:
			return
		var jovian_alloy_bulk_repair_before := int((_entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {}) as Dictionary).get("repair_material", 0))
		_manufacture_earth_operating_shortfall(0, jovian_alloy_bulk_repair_before + jovian_alloy_base_repair_shortfall, cruiser_copper_id, gas_bootstrap_repair_works_id, array_entity_id, cruiser_bulk_depot_id, "J10 Jovian alloy-base freight repair recovery pass %d" % [jovian_alloy_repair_pass + 1])
		_check(not gas_bootstrap_repair_works_id.is_empty(), "the exact public renewable repair-production line remains addressable for the Jovian alloy-base freight manifest")
		if failures.size() > 0:
			return
	var jovian_alloy_base_factory_ready: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), cruiser_bulk_depot_id).get("inventory", {})
	var jovian_alloy_base_factory_repair_total := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
	for alloy_base_ready_entity_value in _snapshot(EARTH_WORLD_ID).get("entities", []):
		jovian_alloy_base_factory_repair_total += int((((alloy_base_ready_entity_value as Dictionary).get("inventory", {}) as Dictionary).get("repair_material", 0)))
	_check(int(jovian_alloy_base_factory_ready.get("chemical_propellant", 0)) >= 26 and jovian_alloy_base_factory_repair_total >= jovian_alloy_base_repair_target and int(jovian_alloy_base_factory_ready.get("electronics", 0)) >= 6 and int(jovian_alloy_base_factory_ready.get("iron_ingot", 0)) >= 4 and int(jovian_alloy_base_factory_ready.get("structural_frame", 0)) >= 1, "Earth Factory closes the non-titanium Jovian alloy-base freight manifest and operating reserve before Lunar support; inventory=%s repair_total=%d" % [JSON.stringify(jovian_alloy_base_factory_ready), jovian_alloy_base_factory_repair_total])
	if failures.size() > 0:
		return

	# The Energy Array build retained three titanium alloys at Earth, one short of
	# the canonical Jovian FLUID tank.  Produce the missing unit at the already
	# surveyed Lunar mine and return it through the public route before the larger
	# nineteen-unit Outer batch begins.
	var alloy_base_lunar_repair_projection: Dictionary = game.maintenance_recovery_snapshot("lunar_space", "repair_material", 1, 120000.0)
	var alloy_base_lunar_repair_target := maxi(1, int(alloy_base_lunar_repair_projection.get("gross_production_target", 1)))
	var alloy_base_lunar_support := _freight_earth_manifest_to_remote("lunar_space", lunar_world_id, {"iron_ingot":1, "chemical_propellant":1, "repair_material":alloy_base_lunar_repair_target}, "J10 one-unit Lunar titanium recovery support", {"chemical_propellant":1, "repair_material":1}, {"copper_refinery_id":cruiser_copper_id, "engineering_works_id":gas_bootstrap_repair_works_id, "iron_refinery_id":gas_bootstrap_iron_refinery_id, "power_source_id":array_entity_id, "bulk_storage_id":cruiser_bulk_depot_id})
	gas_bootstrap_repair_works_id = str(alloy_base_lunar_support.get("repair_works_id", gas_bootstrap_repair_works_id))
	if failures.size() > 0:
		return
	_import_from_location("iron_ingot", 1, array_titanium_depot_id, "J10 one-unit Lunar titanium recovery iron", lunar_world_id)
	var alloy_base_lunar_snapshot := _snapshot(lunar_world_id)
	var alloy_base_titanium_foundry_id := ""
	for link_value in alloy_base_lunar_snapshot.get("links", []):
		var link := link_value as Dictionary
		if str(link.get("kind", "")) == "CARGO" and str(link.get("target_id", "")) == array_titanium_depot_id and str(link.get("item_id", "")) == "titanium_alloy":
			alloy_base_titanium_foundry_id = str(link.get("source_id", ""))
			break
	var alloy_base_titanium_mine := _entity_with_resource(alloy_base_lunar_snapshot, "titanium_ore")
	var alloy_base_lunar_power_sources := _entities_with_definition(alloy_base_lunar_snapshot, "grid_solar_array")
	_check(not alloy_base_titanium_foundry_id.is_empty() and not alloy_base_titanium_mine.is_empty() and not alloy_base_lunar_power_sources.is_empty(), "J10 resolves the public Lunar titanium mine, clean foundry, and power provider for the one-unit construction shortfall")
	if failures.size() > 0:
		return
	var alloy_base_titanium_mine_id := str(alloy_base_titanium_mine.get("id", ""))
	var alloy_base_lunar_power_id := str((alloy_base_lunar_power_sources[0] as Dictionary).get("id", ""))
	for link_value in _snapshot(lunar_world_id).get("links", []):
		var link := link_value as Dictionary
		if str(link.get("kind", "")) == "POWER" and str(link.get("target_id", "")) in [alloy_base_titanium_foundry_id, alloy_base_titanium_mine_id]:
			var removed := _factory_command("REMOVE_LINK", {"link_id":str(link.get("id", ""))}, lunar_world_id)
			_check(bool(removed.get("accepted", false)), "J10 freezes Lunar titanium extraction and refinement before one-unit exact staging")
	var alloy_base_recipe := _factory_command("SET_RECIPE", {"entity_id":alloy_base_titanium_foundry_id, "recipe_id":"grid_refine_titanium"}, lunar_world_id)
	_check(bool(alloy_base_recipe.get("accepted", false)), "J10 selects the canonical Lunar titanium recipe for the one-unit construction shortfall")
	_clear_competing_cargo_inputs(alloy_base_titanium_foundry_id, "iron_ingot", array_titanium_depot_id, lunar_world_id)
	_ensure_connection("CARGO", array_titanium_depot_id, alloy_base_titanium_foundry_id, "iron_ingot", lunar_world_id)
	var alloy_base_iron_events := _advance(250.0, "J10 one-unit Lunar titanium iron staging")
	_clear_competing_cargo_inputs(alloy_base_titanium_foundry_id, "iron_ingot", "", lunar_world_id)
	var alloy_base_mine_before := int((_entity(_snapshot(lunar_world_id), alloy_base_titanium_mine_id).get("outputs", {}) as Dictionary).get("titanium_ore", 0))
	var alloy_base_machine_ore_before := int((_entity(_snapshot(lunar_world_id), alloy_base_titanium_foundry_id).get("inputs", {}) as Dictionary).get("titanium_ore", 0))
	var alloy_base_ore_shortfall := maxi(0, 2 - alloy_base_machine_ore_before)
	_check(not _events_have_recipe(alloy_base_iron_events, "grid_refine_titanium") and alloy_base_mine_before >= alloy_base_ore_shortfall and alloy_base_machine_ore_before <= 2, "J10 cold-stages one iron and proves the exact visible Lunar ore shortfall for one titanium cycle; mine=%d retained=%d shortfall=%d" % [alloy_base_mine_before, alloy_base_machine_ore_before, alloy_base_ore_shortfall])
	_ensure_connection("CARGO", alloy_base_titanium_mine_id, alloy_base_titanium_foundry_id, "titanium_ore", lunar_world_id)
	var alloy_base_ore_events := _advance(float(alloy_base_ore_shortfall) / 4.0 * 1000.0, "J10 one-unit Lunar titanium ore staging")
	_clear_competing_cargo_inputs(alloy_base_titanium_foundry_id, "titanium_ore", "", lunar_world_id)
	var alloy_base_ore_snapshot := _snapshot(lunar_world_id)
	var alloy_base_mine_after := int((_entity(alloy_base_ore_snapshot, alloy_base_titanium_mine_id).get("outputs", {}) as Dictionary).get("titanium_ore", 0))
	var alloy_base_machine_ore_after := int((_entity(alloy_base_ore_snapshot, alloy_base_titanium_foundry_id).get("inputs", {}) as Dictionary).get("titanium_ore", 0))
	_check(not _events_have_recipe(alloy_base_ore_events, "grid_refine_titanium") and alloy_base_mine_after == alloy_base_mine_before - alloy_base_ore_shortfall and alloy_base_machine_ore_after == 2, "J10 cold-stages exactly the missing Lunar ore for one titanium cycle without discarding retained input; mine_before=%d mine_after=%d retained_before=%d retained_after=%d" % [alloy_base_mine_before, alloy_base_mine_after, alloy_base_machine_ore_before, alloy_base_machine_ore_after])
	_isolate_all_machine_power_for_target(alloy_base_titanium_foundry_id, lunar_world_id)
	_ensure_connection("POWER", alloy_base_lunar_power_id, alloy_base_titanium_foundry_id, "", lunar_world_id)
	var alloy_base_titanium_before := int((_entity(_snapshot(lunar_world_id), array_titanium_depot_id).get("inventory", {}) as Dictionary).get("titanium_alloy", 0))
	var alloy_base_titanium_events := _advance(15000.0, "J10 one-unit Lunar titanium fabrication")
	var alloy_base_titanium_cycles := _events_with_activity(alloy_base_titanium_events, "FactoryRecipeCompleted", "refine_titanium").size()
	_check(alloy_base_titanium_cycles == 1 and int((_entity(_snapshot(lunar_world_id), array_titanium_depot_id).get("inventory", {}) as Dictionary).get("titanium_alloy", 0)) == alloy_base_titanium_before + 1, "J10 fabricates exactly one physical Lunar titanium alloy for the Jovian FLUID tank")
	for link_value in _snapshot(lunar_world_id).get("links", []):
		var link := link_value as Dictionary
		if str(link.get("kind", "")) == "POWER" and str(link.get("target_id", "")) == alloy_base_titanium_foundry_id:
			_factory_command("REMOVE_LINK", {"link_id":str(link.get("id", ""))}, lunar_world_id)
	if failures.size() > 0:
		return
	_export_to_location("titanium_alloy", 1, "J10 one-unit Lunar titanium construction return", lunar_world_id, array_titanium_depot_id)
	var alloy_base_titanium_return := _freight_location_cargo("lunar_space", lunar_world_id, EARTH_LOCATION_ID, EARTH_WORLD_ID, "titanium_alloy", 1, {"chemical_propellant":1, "repair_material":1}, "J10 one-unit Lunar-Earth titanium construction return")
	_check(not alloy_base_titanium_return.is_empty(), "J10 returns the one physical titanium shortfall to Earth before the five-item Jovian construction manifest")
	if failures.size() > 0:
		return
	var jovian_alloy_base_freight := _freight_earth_manifest_to_remote("gas_giant_region", jovian_world_id, jovian_alloy_base_manifest, "J10 Jovian FLUID-tank, alloy-smelter, and second-solar construction", jovian_path_costs, {"copper_refinery_id":cruiser_copper_id, "engineering_works_id":gas_bootstrap_repair_works_id, "iron_refinery_id":gas_bootstrap_iron_refinery_id, "power_source_id":array_entity_id, "bulk_storage_id":cruiser_bulk_depot_id})
	gas_bootstrap_repair_works_id = str(jovian_alloy_base_freight.get("repair_works_id", gas_bootstrap_repair_works_id))
	if failures.size() > 0:
		return
	var jovian_second_solar_order := _queue_and_fund("grid_solar_array", "", {"x":256, "y":32}, "J10 Jovian methane-industry second solar array", true, jovian_world_id, "")
	var jovian_fluid_tank_order := _queue_and_fund("grid_fluid_tank", "", {"x":272, "y":32}, "J10 Jovian canonical methane FLUID tank", true, jovian_world_id, "")
	var jovian_superalloy_smelter_order := _queue_and_fund("grid_arc_smelter", "grid_refine_superalloy", {"x":304, "y":32}, "J10 Jovian renewable superalloy Arc Smelter", true, jovian_world_id, "")
	var jovian_second_solar_id := str(jovian_second_solar_order.get("entity_id", ""))
	var jovian_fluid_tank_id := str(jovian_fluid_tank_order.get("entity_id", ""))
	var jovian_superalloy_smelter_id := str(jovian_superalloy_smelter_order.get("entity_id", ""))
	if jovian_second_solar_id.is_empty() or jovian_fluid_tank_id.is_empty() or jovian_superalloy_smelter_id.is_empty() or failures.size() > 0:
		return
	var jovian_alloy_base_events := _advance(120000.0, "J10 Jovian FLUID-tank and renewable-superalloy base construction")
	var jovian_fluid_tank_runtime := _entity(_snapshot(jovian_world_id), jovian_fluid_tank_id)
	var jovian_superalloy_smelter_runtime := _entity(_snapshot(jovian_world_id), jovian_superalloy_smelter_id)
	_check(jovian_alloy_base_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("entity_id", "")) == jovian_second_solar_id and str(event.get("definition_id", "")) == "grid_solar_array"
	) and jovian_alloy_base_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("entity_id", "")) == jovian_fluid_tank_id and str(event.get("definition_id", "")) == "grid_fluid_tank"
	) and jovian_alloy_base_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("entity_id", "")) == jovian_superalloy_smelter_id and str(event.get("definition_id", "")) == "grid_arc_smelter"
	) and str(jovian_fluid_tank_runtime.get("definition_id", "")) == "grid_fluid_tank" and str(jovian_superalloy_smelter_runtime.get("recipe_id", "")) == "grid_refine_superalloy", "Factory completes the canonical explicit FLUID methane tank, second solar, and renewable-superalloy machine through public same-location funding; tank=%s smelter=%s events=%s" % [JSON.stringify(jovian_fluid_tank_runtime), JSON.stringify(jovian_superalloy_smelter_runtime), JSON.stringify(jovian_alloy_base_events)])
	if failures.size() > 0:
		return
	_ensure_connection("POWER", jovian_solar_id, jovian_extractor_id, "", jovian_world_id)
	_ensure_connection("CARGO", jovian_extractor_id, jovian_fluid_tank_id, "methane", jovian_world_id)
	var jovian_methane_extraction_events := _advance(3000.0, "J10 Jovian renewable methane extraction into exact FLUID custody")
	jovian_fluid_tank_runtime = _entity(_snapshot(jovian_world_id), jovian_fluid_tank_id)
	_check(jovian_methane_extraction_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryResourceExtracted" and str(event.get("world_id", "")) == jovian_world_id and str(event.get("entity_id", "")) == jovian_extractor_id and str(event.get("resource_id", "")) == "methane" and str(event.get("activity_id", "")) == "separate_methane"
	) and int((jovian_fluid_tank_runtime.get("inventory", {}) as Dictionary).get("methane", 0)) > 0, "the powered Jovian cryogenic extractor physically produces methane and routes it into the exact canonical FLUID tank; tank=%s events=%s" % [JSON.stringify(jovian_fluid_tank_runtime), JSON.stringify(jovian_methane_extraction_events)])
	if failures.size() > 0:
		return

	# Capital Combat and the canonical Jovian Battleship require nineteen new
	# titanium alloys (five are converted into its superalloy research reserve,
	# fourteen into the exact Shipyard manifest).  Reuse only the proven *third*
	# Lunar Arc Smelter: its output edge identifies the empty Bulk depot built for
	# the Array, while the two historic full-buffer smelters remain untouched.
	var outer_lunar_snapshot := _snapshot(lunar_world_id)
	var outer_titanium_foundry_id := ""
	for outer_titanium_link_value in outer_lunar_snapshot.get("links", []):
		var outer_titanium_link := outer_titanium_link_value as Dictionary
		if str(outer_titanium_link.get("kind", "")) == "CARGO" and str(outer_titanium_link.get("target_id", "")) == array_titanium_depot_id and str(outer_titanium_link.get("item_id", "")) == "titanium_alloy":
			outer_titanium_foundry_id = str(outer_titanium_link.get("source_id", ""))
			break
	var outer_titanium_foundry := _entity(outer_lunar_snapshot, outer_titanium_foundry_id)
	var outer_titanium_mine := _entity_with_resource(outer_lunar_snapshot, "titanium_ore")
	_check(not outer_titanium_foundry_id.is_empty() and str(outer_titanium_foundry.get("definition_id", "")) == "grid_arc_smelter" and not outer_titanium_mine.is_empty() and str(array_titanium_depot_id) != lunar_depot_id, "J10 identifies the empty third Lunar titanium Arc Smelter solely from its public output-to-new-Bulk edge before the finite Outer manifest; foundry=%s mine=%s depot=%s" % [JSON.stringify(outer_titanium_foundry), JSON.stringify(outer_titanium_mine), array_titanium_depot_id])
	if failures.size() > 0:
		return
	var outer_titanium_mine_id := str(outer_titanium_mine.get("id", ""))
	var outer_titanium_power_sources: Array[String] = []
	for outer_titanium_solar_value in _entities_with_definition(outer_lunar_snapshot, "grid_solar_array"):
		outer_titanium_power_sources.append(str((outer_titanium_solar_value as Dictionary).get("id", "")))
	_check(not outer_titanium_power_sources.is_empty(), "the public Lunar Factory snapshot retains solar providers for the bounded Outer titanium renewal")
	if failures.size() > 0:
		return
	var outer_titanium_total := 19
	var outer_titanium_fabricated := 0
	for outer_titanium_batch in [11, 8]:
		var outer_batch := int(outer_titanium_batch)
		# Residual Lunar rewards leave eleven free BULK units at this point.  Import
		# each wave into the Factory before the next dispatch, so both batches remain
		# capacity-safe without discarding any existing Location custody.
		var outer_titanium_iron_freight := _freight_earth_manifest_to_remote("lunar_space", lunar_world_id, {"iron_ingot":outer_batch}, "J10 Outer Lunar titanium iron batch %d" % outer_batch, {"chemical_propellant":1, "repair_material":1}, {"copper_refinery_id":cruiser_copper_id, "engineering_works_id":gas_bootstrap_repair_works_id, "iron_refinery_id":gas_bootstrap_iron_refinery_id, "power_source_id":array_entity_id, "bulk_storage_id":cruiser_bulk_depot_id})
		gas_bootstrap_repair_works_id = str(outer_titanium_iron_freight.get("repair_works_id", gas_bootstrap_repair_works_id))
		if failures.size() > 0:
			return
		_import_from_location("iron_ingot", outer_batch, array_titanium_depot_id, "J10 Outer Lunar titanium batch %d Factory iron custody" % outer_batch, lunar_world_id)
		# Force a cold recipe boundary on the known empty smelter; never reconfigure
		# or empty the two saturated legacy machines.
		for outer_titanium_power_link_value in _snapshot(lunar_world_id).get("links", []):
			var outer_titanium_power_link := outer_titanium_power_link_value as Dictionary
			if str(outer_titanium_power_link.get("kind", "")) == "POWER" and str(outer_titanium_power_link.get("target_id", "")) == outer_titanium_foundry_id:
				var outer_titanium_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(outer_titanium_power_link.get("id", ""))}, lunar_world_id)
				_check(bool(outer_titanium_power_removed.get("accepted", false)), "J10 retires the clean Lunar foundry POWER edge before exact Outer titanium staging; result=%s" % JSON.stringify(outer_titanium_power_removed))
		if failures.size() > 0:
			return
		var outer_titanium_recipe_result := _factory_command("SET_RECIPE", {"entity_id":outer_titanium_foundry_id, "recipe_id":"grid_refine_titanium"}, lunar_world_id)
		_check(bool(outer_titanium_recipe_result.get("accepted", false)), "J10 selects the public canonical titanium recipe on the isolated third Lunar smelter")
		_clear_competing_cargo_inputs(outer_titanium_foundry_id, "iron_ingot", array_titanium_depot_id, lunar_world_id)
		_clear_competing_cargo_inputs(outer_titanium_foundry_id, "titanium_ore", outer_titanium_mine_id, lunar_world_id)
		_clear_competing_cargo_outputs(outer_titanium_foundry_id, "titanium_alloy", array_titanium_depot_id, lunar_world_id)
		_clear_competing_cargo_inputs(array_titanium_depot_id, "titanium_alloy", outer_titanium_foundry_id, lunar_world_id)
		var outer_iron_stage := _factory_command("CONNECT_ENTITIES", {"link_kind":"CARGO", "source_id":array_titanium_depot_id, "target_id":outer_titanium_foundry_id, "item_id":"iron_ingot", "capacity_per_second":float(outer_batch)}, lunar_world_id)
		_check(bool(outer_iron_stage.get("accepted", false)), "J10 connects the finite %d-iron Outer titanium manifest into the isolated Lunar smelter; result=%s" % [outer_batch, JSON.stringify(outer_iron_stage)])
		var outer_iron_stage_events := _advance(1000.0, "J10 Outer Lunar titanium batch %d exact iron staging" % outer_batch)
		_clear_competing_cargo_inputs(outer_titanium_foundry_id, "iron_ingot", "", lunar_world_id)
		var outer_after_iron_stage := _entity(_snapshot(lunar_world_id), outer_titanium_foundry_id)
		_check(not _events_have_recipe(outer_iron_stage_events, "grid_refine_titanium") and int(outer_after_iron_stage.get("inputs", {}).get("iron_ingot", 0)) == outer_batch and int(_entity(_snapshot(lunar_world_id), array_titanium_depot_id).get("inventory", {}).get("iron_ingot", 0)) == 0, "J10 stages exactly the cold Outer titanium iron batch and leaves no iron hidden in the Lunar Bulk source; foundry=%s events=%s" % [JSON.stringify(outer_after_iron_stage), JSON.stringify(outer_iron_stage_events)])
		if failures.size() > 0:
			return
		# Freeze the already-extracted mine buffer before transferring it.  This
		# makes the physical ore debit auditable rather than allowing a powered
		# extractor to replenish the source during the cold staging boundary.
		for outer_titanium_mine_power_link_value in _snapshot(lunar_world_id).get("links", []):
			var outer_titanium_mine_power_link := outer_titanium_mine_power_link_value as Dictionary
			if str(outer_titanium_mine_power_link.get("kind", "")) == "POWER" and str(outer_titanium_mine_power_link.get("target_id", "")) == outer_titanium_mine_id:
				var outer_titanium_mine_power_removed := _factory_command("REMOVE_LINK", {"link_id":str(outer_titanium_mine_power_link.get("id", ""))}, lunar_world_id)
				_check(bool(outer_titanium_mine_power_removed.get("accepted", false)), "J10 freezes the pre-extracted Lunar titanium buffer before bounded source-custody transfer; result=%s" % JSON.stringify(outer_titanium_mine_power_removed))
		var outer_mine_before_ore_stage := _entity(_snapshot(lunar_world_id), outer_titanium_mine_id)
		var outer_mine_ore_before := int((outer_mine_before_ore_stage.get("outputs", {}) as Dictionary).get("titanium_ore", 0))
		_check(float(outer_mine_before_ore_stage.get("power_factor", 0.0)) == 0.0 and outer_mine_ore_before >= outer_batch * 2, "J10 proves the frozen Lunar mine already holds the exact finite Outer titanium-ore source manifest before CARGO transfer; mine=%s batch=%d" % [JSON.stringify(outer_mine_before_ore_stage), outer_batch])
		if failures.size() > 0:
			return
		# The mine's public CARGO edge is deliberately throttled to the exact
		# two-ore-per-alloy manifest, then removed before smelting begins.
		var outer_ore_stage := _factory_command("CONNECT_ENTITIES", {"link_kind":"CARGO", "source_id":outer_titanium_mine_id, "target_id":outer_titanium_foundry_id, "item_id":"titanium_ore", "capacity_per_second":float(outer_batch)}, lunar_world_id)
		_check(bool(outer_ore_stage.get("accepted", false)), "J10 connects the bounded Lunar titanium-ore source at the exact Outer batch rate; result=%s" % JSON.stringify(outer_ore_stage))
		var outer_ore_stage_events := _advance(2000.0, "J10 Outer Lunar titanium batch %d exact ore staging" % outer_batch)
		_clear_competing_cargo_inputs(outer_titanium_foundry_id, "titanium_ore", "", lunar_world_id)
		var outer_after_ore_stage := _entity(_snapshot(lunar_world_id), outer_titanium_foundry_id)
		var outer_mine_after_ore_stage := _entity(_snapshot(lunar_world_id), outer_titanium_mine_id)
		_check(not _events_have_recipe(outer_ore_stage_events, "grid_refine_titanium") and int(outer_after_ore_stage.get("inputs", {}).get("iron_ingot", 0)) == outer_batch and int(outer_after_ore_stage.get("inputs", {}).get("titanium_ore", 0)) == outer_batch * 2 and int((outer_mine_after_ore_stage.get("outputs", {}) as Dictionary).get("titanium_ore", 0)) == outer_mine_ore_before - outer_batch * 2, "J10 stages the exact two-ore-per-alloy Outer titanium manifest in the cold Lunar smelter and debits the frozen mine custody before production; foundry=%s mine_before=%s mine_after=%s events=%s" % [JSON.stringify(outer_after_ore_stage), JSON.stringify(outer_mine_before_ore_stage), JSON.stringify(outer_mine_after_ore_stage), JSON.stringify(outer_ore_stage_events)])
		if failures.size() > 0:
			return
		_isolate_all_machine_power_for_target(outer_titanium_foundry_id, lunar_world_id)
		for outer_titanium_power_source_id in outer_titanium_power_sources:
			_ensure_connection("POWER", outer_titanium_power_source_id, outer_titanium_foundry_id, "", lunar_world_id)
		_ensure_connection("CARGO", outer_titanium_foundry_id, array_titanium_depot_id, "titanium_alloy", lunar_world_id)
		var outer_titanium_powered := _entity(_snapshot(lunar_world_id), outer_titanium_foundry_id)
		_check(float(outer_titanium_powered.get("power_factor", 0.0)) == 1.0, "J10 gives the isolated third Lunar titanium smelter full public power before its exact bounded fabrication duration; foundry=%s" % JSON.stringify(outer_titanium_powered))
		if failures.size() > 0:
			return
		var outer_titanium_batch_events := _advance(float(outer_batch) * 14000.0 + 1000.0, "J10 Outer Lunar titanium batch %d exact fabrication" % outer_batch)
		var outer_titanium_completed := 0
		var outer_titanium_produced := 0
		for outer_titanium_event_value in outer_titanium_batch_events:
			var outer_titanium_event := outer_titanium_event_value as Dictionary
			if str(outer_titanium_event.get("type", "")) == "FactoryRecipeCompleted" and str(outer_titanium_event.get("world_id", "")) == lunar_world_id and str(outer_titanium_event.get("entity_id", "")) == outer_titanium_foundry_id and str(outer_titanium_event.get("recipe_id", "")) == "grid_refine_titanium":
				outer_titanium_completed += int(outer_titanium_event.get("completed_cycles", 0))
				outer_titanium_produced += int((outer_titanium_event.get("produced", {}) as Dictionary).get("titanium_alloy", 0))
		outer_titanium_fabricated += outer_titanium_produced
		_check(outer_titanium_completed == outer_batch and outer_titanium_produced == outer_batch and int(_entity(_snapshot(lunar_world_id), outer_titanium_foundry_id).get("inputs", {}).get("iron_ingot", 0)) == 0 and int(_entity(_snapshot(lunar_world_id), outer_titanium_foundry_id).get("inputs", {}).get("titanium_ore", 0)) == 0, "J10 completes exactly the bounded Outer titanium recipe batch from physical Lunar custody; batch=%d cycles=%d produced=%d foundry=%s events=%s" % [outer_batch, outer_titanium_completed, outer_titanium_produced, JSON.stringify(_entity(_snapshot(lunar_world_id), outer_titanium_foundry_id)), JSON.stringify(outer_titanium_batch_events)])
		if failures.size() > 0:
			return
	_check(outer_titanium_fabricated == outer_titanium_total and int(_entity(_snapshot(lunar_world_id), array_titanium_depot_id).get("inventory", {}).get("titanium_alloy", 0)) == outer_titanium_total, "J10 retains all nineteen new physical Lunar titanium alloys in the explicit second Bulk depot for the Outer closure; fabricated=%d depot=%s" % [outer_titanium_fabricated, JSON.stringify(_entity(_snapshot(lunar_world_id), array_titanium_depot_id).get("inventory", {}))])
	if failures.size() > 0:
		return
	# Titanium alloy is BULK custody at 1.25 units per item, so the surveyed
	# Location's twenty-unit capacity admits exactly sixteen at once.  Fund the
	# two direct Lunar-to-Jovian shipments for the complete 16+3 manifest, with a
	# public long-horizon maintenance projection covering both transit windows.
	var outer_lunar_repair_reserve_projection: Dictionary = game.maintenance_recovery_snapshot("lunar_space", "repair_material", 4, 500000.0)
	var outer_lunar_repair_reserve_target := maxi(4, int(outer_lunar_repair_reserve_projection.get("gross_production_target", 4)))
	# The two-item reserve itself incurs two Earth dispatch debits.  Earlier J10
	# freight intentionally consumes the pre-Jovian fuel batch, so close this
	# later ten-unit source target through the same public Factory protocol rather
	# than assuming the starter depot still contains it.
	var outer_lunar_source_fuel_target := 8 + 2
	var outer_lunar_source_fuel_packet := {
		"storage_id":cruiser_bulk_depot_id,
		"waste_storage_id":cruiser_bulk_depot_id,
		"power_source_id":array_entity_id,
		"iron_extractor_id":str(_entity_with_resource(_snapshot(EARTH_WORLD_ID), "iron_ore").get("id", "")),
		"copper_extractor_id":str(_entity_with_resource(_snapshot(EARTH_WORLD_ID), "copper_ore").get("id", "")),
		"iron_refinery_id":gas_bootstrap_iron_refinery_id,
		"copper_refinery_id":cruiser_copper_id,
		"engineering_machine_id":gas_bootstrap_repair_works_id
	}
	_ensure_local_factory_item("chemical_propellant", outer_lunar_source_fuel_target, outer_lunar_source_fuel_packet, "J10 Outer Lunar-to-Jovian titanium public Earth fuel closure")
	gas_bootstrap_repair_works_id = str(outer_lunar_source_fuel_packet.get("engineering_machine_id", gas_bootstrap_repair_works_id))
	if failures.size() > 0:
		return
	var outer_lunar_titanium_reserve := _freight_earth_manifest_to_remote("lunar_space", lunar_world_id, {"chemical_propellant":8, "repair_material":outer_lunar_repair_reserve_target}, "J10 Outer Lunar-to-Jovian titanium operating reserve", {"chemical_propellant":1, "repair_material":1}, {"copper_refinery_id":cruiser_copper_id, "engineering_works_id":gas_bootstrap_repair_works_id, "iron_refinery_id":gas_bootstrap_iron_refinery_id, "power_source_id":array_entity_id, "bulk_storage_id":cruiser_bulk_depot_id})
	gas_bootstrap_repair_works_id = str(outer_lunar_titanium_reserve.get("repair_works_id", gas_bootstrap_repair_works_id))
	_check(not outer_lunar_titanium_reserve.is_empty(), "J10 physically stages the complete Lunar-origin titanium freight reserve through Earth logistics; projection=%s reserve_target=%d" % [JSON.stringify(outer_lunar_repair_reserve_projection), outer_lunar_repair_reserve_target])
	if failures.size() > 0:
		return
	var outer_lunar_titanium_transferred := 0
	for outer_titanium_shipment_value in [11, 8]:
		var outer_titanium_shipment := int(outer_titanium_shipment_value)
		_export_to_location("titanium_alloy", outer_titanium_shipment, "J10 Outer capacity-safe Lunar titanium shipment", lunar_world_id, array_titanium_depot_id)
		if failures.size() > 0:
			return
		var outer_titanium_route := _freight_location_cargo("lunar_space", lunar_world_id, "gas_giant_region", jovian_world_id, "titanium_alloy", outer_titanium_shipment, {"chemical_propellant":4, "repair_material":2}, "J10 Outer Lunar-Jovian titanium %d-unit shipment" % outer_titanium_shipment)
		if outer_titanium_route.is_empty() or failures.size() > 0:
			return
		_import_from_location("titanium_alloy", outer_titanium_shipment, jovian_bulk_depot_id, "J10 Outer Jovian titanium Bulk custody", jovian_world_id)
		outer_lunar_titanium_transferred += outer_titanium_shipment
	_check(outer_lunar_titanium_transferred == outer_titanium_total and int(_entity(_snapshot(jovian_world_id), jovian_bulk_depot_id).get("inventory", {}).get("titanium_alloy", 0)) == outer_titanium_total, "J10 transfers all nineteen newly refined Lunar titanium alloys through finite capacity-safe public freight into explicit Jovian Bulk custody; transferred=%d bulk=%s" % [outer_lunar_titanium_transferred, JSON.stringify(_entity(_snapshot(jovian_world_id), jovian_bulk_depot_id).get("inventory", {}))])
	if failures.size() > 0:
		return

	# Renewable cobalt begins at the surveyed Asteroid mine.  The prior Repair
	# Dock redirected its one solar provider, so retarget it publicly to cobalt,
	# extract the finite raw manifest into the canonical Asteroid Bulk store, and
	# carry that ore directly to Jovian rather than inventing an Earth detour.
	var outer_asteroid_cobalt_before := int(_entity(_snapshot(asteroid_world_id), asteroid_steel_depot_id).get("inventory", {}).get("cobalt_ore", 0))
	var outer_asteroid_cobalt_required_gain := maxi(0, 76 - outer_asteroid_cobalt_before)
	var outer_asteroid_cobalt_events: Array = []
	var outer_asteroid_cobalt_powered_rate := 0.0
	if outer_asteroid_cobalt_required_gain > 0:
		_isolate_all_machine_power_for_target(rig_asteroid_cobalt_mine_id, asteroid_world_id)
		_ensure_connection("POWER", rig_asteroid_solar_id, rig_asteroid_cobalt_mine_id, "", asteroid_world_id)
		_clear_competing_cargo_outputs(rig_asteroid_cobalt_mine_id, "cobalt_ore", asteroid_steel_depot_id, asteroid_world_id)
		_clear_competing_cargo_inputs(asteroid_steel_depot_id, "cobalt_ore", rig_asteroid_cobalt_mine_id, asteroid_world_id)
		_ensure_connection("CARGO", rig_asteroid_cobalt_mine_id, asteroid_steel_depot_id, "cobalt_ore", asteroid_world_id)
		outer_asteroid_cobalt_powered_rate = float(_entity(_snapshot(asteroid_world_id), rig_asteroid_cobalt_mine_id).get("actual_rate", 0.0))
		_check(outer_asteroid_cobalt_powered_rate > 0.0, "J10 exposes a positive public Asteroid cobalt rate when a physical shortfall remains")
		if failures.size() > 0:
			return
		outer_asteroid_cobalt_events = _advance(float(ceili(float(outer_asteroid_cobalt_required_gain) / minf(4.0, outer_asteroid_cobalt_powered_rate))) * 1000.0, "J10 Outer Asteroid renewable cobalt shortfall extraction")
	# Freeze this source after the bounded decision.  Existing cobalt is valid
	# player-produced custody, and a full Bulk depot must not be forced to emit a
	# fictitious extraction event when the physical shortfall is already zero.
	_isolate_all_machine_power_for_target(rig_asteroid_cobalt_mine_id, asteroid_world_id)
	_clear_competing_cargo_outputs(rig_asteroid_cobalt_mine_id, "cobalt_ore", "", asteroid_world_id)
	var outer_asteroid_cobalt_after := int(_entity(_snapshot(asteroid_world_id), asteroid_steel_depot_id).get("inventory", {}).get("cobalt_ore", 0))
	var outer_asteroid_cobalt_scoped_gain := 0
	for event_value in outer_asteroid_cobalt_events:
		var event := event_value as Dictionary
		if str(event.get("type", "")) == "FactoryResourceExtracted" and str(event.get("world_id", "")) == asteroid_world_id and str(event.get("entity_id", "")) == rig_asteroid_cobalt_mine_id and str(event.get("resource_id", "")) == "cobalt_ore" and str(event.get("activity_id", "")) == "separate_cobalt_ore":
			outer_asteroid_cobalt_scoped_gain += int(event.get("quantity", 0))
	var outer_asteroid_cobalt_event_proof := outer_asteroid_cobalt_required_gain == 0 or outer_asteroid_cobalt_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryResourceExtracted" and str(event.get("world_id", "")) == asteroid_world_id and str(event.get("entity_id", "")) == rig_asteroid_cobalt_mine_id and str(event.get("resource_id", "")) == "cobalt_ore" and str(event.get("activity_id", "")) == "separate_cobalt_ore"
	)
	_check(outer_asteroid_cobalt_event_proof and (outer_asteroid_cobalt_required_gain == 0 or outer_asteroid_cobalt_powered_rate > 0.0) and outer_asteroid_cobalt_scoped_gain >= outer_asteroid_cobalt_required_gain and outer_asteroid_cobalt_after == outer_asteroid_cobalt_before + outer_asteroid_cobalt_scoped_gain and outer_asteroid_cobalt_after >= 76, "J10 closes the complete finite Asteroid cobalt shortfall from existing or newly extracted physical custody with matching event and inventory deltas; before=%d required_gain=%d scoped_gain=%d powered_rate=%.3f after=%d depot=%s events=%s" % [outer_asteroid_cobalt_before, outer_asteroid_cobalt_required_gain, outer_asteroid_cobalt_scoped_gain, outer_asteroid_cobalt_powered_rate, outer_asteroid_cobalt_after, JSON.stringify(_entity(_snapshot(asteroid_world_id), asteroid_steel_depot_id)), JSON.stringify(outer_asteroid_cobalt_events)])
	if failures.size() > 0:
		return
	var outer_cobalt_transferred := 0
	# Ten raw-ore shipments need twenty propellant, which cannot coexist in the
	# surveyed Asteroid FLUID capacity (20 * 1.5 > 24).  Fund two five-shipment
	# windows and import every arrival before opening the next public policy.
	for outer_cobalt_group_value in [[8, 8, 8, 8, 8], [8, 8, 8, 8, 4]]:
		var outer_cobalt_group := outer_cobalt_group_value as Array
		var outer_cobalt_group_horizon_ms := float(outer_cobalt_group.size()) * 126000.0 + 10000.0
		var outer_asteroid_repair_projection: Dictionary = game.maintenance_recovery_snapshot("asteroid_belt", "repair_material", outer_cobalt_group.size(), outer_cobalt_group_horizon_ms)
		var outer_asteroid_repair_target := maxi(outer_cobalt_group.size(), int(outer_asteroid_repair_projection.get("gross_production_target", outer_cobalt_group.size())))
		# This two-item reserve carries ten propellant as payload and spends three
		# more per independent Earth dispatch.  Re-close the sixteen-unit source
		# target for each finite window after the preceding freight consumed it.
		outer_lunar_source_fuel_packet["engineering_machine_id"] = gas_bootstrap_repair_works_id
		_ensure_local_factory_item("chemical_propellant", outer_cobalt_group.size() * 2 + 2 * 3, outer_lunar_source_fuel_packet, "J10 Outer Asteroid-to-Jovian cobalt operating-window Earth fuel closure")
		gas_bootstrap_repair_works_id = str(outer_lunar_source_fuel_packet.get("engineering_machine_id", gas_bootstrap_repair_works_id))
		if failures.size() > 0:
			return
		var outer_asteroid_operating_reserve := _freight_earth_manifest_to_remote("asteroid_belt", asteroid_world_id, {"chemical_propellant":outer_cobalt_group.size() * 2, "repair_material":outer_asteroid_repair_target}, "J10 Outer Asteroid-to-Jovian cobalt operating reserve window", {"chemical_propellant":3, "repair_material":2}, {"copper_refinery_id":cruiser_copper_id, "engineering_works_id":gas_bootstrap_repair_works_id, "iron_refinery_id":gas_bootstrap_iron_refinery_id, "power_source_id":array_entity_id, "bulk_storage_id":cruiser_bulk_depot_id})
		gas_bootstrap_repair_works_id = str(outer_asteroid_operating_reserve.get("repair_works_id", gas_bootstrap_repair_works_id))
		_check(not outer_asteroid_operating_reserve.is_empty(), "J10 physically stages one capacity-safe Asteroid-origin cobalt freight reserve window; projection=%s reserve_target=%d" % [JSON.stringify(outer_asteroid_repair_projection), outer_asteroid_repair_target])
		if failures.size() > 0:
			return
		for outer_cobalt_chunk_value in outer_cobalt_group:
			var outer_cobalt_chunk := int(outer_cobalt_chunk_value)
			_export_to_location("cobalt_ore", outer_cobalt_chunk, "J10 Outer capacity-safe Asteroid cobalt ore shipment", asteroid_world_id, asteroid_steel_depot_id)
			if failures.size() > 0:
				return
			var outer_cobalt_route := _freight_location_cargo("asteroid_belt", asteroid_world_id, "gas_giant_region", jovian_world_id, "cobalt_ore", outer_cobalt_chunk, {"chemical_propellant":2, "repair_material":1}, "J10 Outer Asteroid-Jovian cobalt %d-unit shipment" % outer_cobalt_chunk)
			if outer_cobalt_route.is_empty() or failures.size() > 0:
				return
			_import_from_location("cobalt_ore", outer_cobalt_chunk, jovian_bulk_depot_id, "J10 Outer Jovian cobalt-ore Bulk custody", jovian_world_id)
			outer_cobalt_transferred += outer_cobalt_chunk
	_check(outer_cobalt_transferred == 76 and int(_entity(_snapshot(jovian_world_id), jovian_bulk_depot_id).get("inventory", {}).get("cobalt_ore", 0)) == 76, "J10 transfers the exact seventy-six physically extracted Asteroid cobalt ore through ten capacity-safe public Jovian freight shipments; transferred=%d bulk=%s" % [outer_cobalt_transferred, JSON.stringify(_entity(_snapshot(jovian_world_id), jovian_bulk_depot_id).get("inventory", {}))])
	if failures.size() > 0:
		return
	# Refine raw cobalt locally in cold batches that fit the Jovian Arc Smelter
	# input capacity.  Waste uses explicit Bulk custody before the next recipe
	# reconfiguration, preserving every physical by-product.
	var outer_cobalt_ingot_before := int(_entity(_snapshot(jovian_world_id), jovian_bulk_depot_id).get("inventory", {}).get("cobalt_ingot", 0))
	var outer_cobalt_waste_before := int(_entity(_snapshot(jovian_world_id), jovian_bulk_depot_id).get("inventory", {}).get("industrial_waste", 0))
	var outer_cobalt_scoped_waste := 0
	# Cargo compatibility is evaluated against the source machine's currently
	# selected recipe.  Select cobalt refinement before publishing its explicit
	# waste-output edge; each cold batch reaffirms the same public recipe.
	var outer_cobalt_recipe_selection := _factory_command("SET_RECIPE", {"entity_id":jovian_superalloy_smelter_id, "recipe_id":"grid_refine_cobalt"}, jovian_world_id)
	_check(bool(outer_cobalt_recipe_selection.get("accepted", false)), "J10 selects Jovian cobalt refinement before connecting its industrial-waste output")
	if failures.size() > 0:
		return
	for outer_cobalt_cycles_value in [16, 16, 6]:
		var outer_cobalt_cycles := int(outer_cobalt_cycles_value)
		_clear_competing_cargo_outputs(jovian_superalloy_smelter_id, "industrial_waste", jovian_bulk_depot_id, jovian_world_id)
		_clear_competing_cargo_inputs(jovian_bulk_depot_id, "industrial_waste", jovian_superalloy_smelter_id, jovian_world_id)
		_ensure_connection("CARGO", jovian_superalloy_smelter_id, jovian_bulk_depot_id, "industrial_waste", jovian_world_id)
		var outer_cobalt_batch_events := _cold_stage_recipe_batch(jovian_superalloy_smelter_id, "grid_refine_cobalt", jovian_second_solar_id, [{"item_id":"cobalt_ore", "source_id":jovian_bulk_depot_id, "quantity":outer_cobalt_cycles * 2}], jovian_bulk_depot_id, "cobalt_ingot", float(outer_cobalt_cycles) * 15000.0 + 1000.0, "J10 Outer Jovian cold cobalt refinement batch %d" % outer_cobalt_cycles, jovian_world_id)
		for event_value in outer_cobalt_batch_events:
			var event := event_value as Dictionary
			if str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == jovian_world_id and str(event.get("entity_id", "")) == jovian_superalloy_smelter_id and str(event.get("recipe_id", "")) == "grid_refine_cobalt":
				outer_cobalt_scoped_waste += int((event.get("produced", {}) as Dictionary).get("industrial_waste", 0))
		if failures.size() > 0:
			return
	var outer_cobalt_bulk := _entity(_snapshot(jovian_world_id), jovian_bulk_depot_id)
	var outer_cobalt_smelter := _entity(_snapshot(jovian_world_id), jovian_superalloy_smelter_id)
	_check(int(outer_cobalt_bulk.get("inventory", {}).get("cobalt_ore", 0)) == 0 and int(outer_cobalt_bulk.get("inventory", {}).get("cobalt_ingot", 0)) == outer_cobalt_ingot_before + 38 and outer_cobalt_scoped_waste == 38 and int(outer_cobalt_bulk.get("inventory", {}).get("industrial_waste", 0)) == outer_cobalt_waste_before + 38 and int(outer_cobalt_smelter.get("outputs", {}).get("industrial_waste", 0)) == 0, "J10 refines the exact physical Outer cobalt manifest locally, conserves the exact thirty-eight-event waste delta in Bulk custody, and leaves no raw cobalt ore; waste_before=%d scoped_waste=%d bulk=%s smelter=%s" % [outer_cobalt_waste_before, outer_cobalt_scoped_waste, JSON.stringify(outer_cobalt_bulk), JSON.stringify(outer_cobalt_smelter)])
	if failures.size() > 0:
		return

	# Accumulate a finite methane manifest in the explicit FLUID tank, then cold
	# stage the three-input alloy recipe in two capacity-safe 12+7 batches.  The
	# cobalt by-product line is retired by SET_RECIPE; all nineteen superalloys
	# end in the canonical Jovian BULK depot with exact statistics/event evidence.
	var outer_methane_before := int(_entity(_snapshot(jovian_world_id), jovian_fluid_tank_id).get("inventory", {}).get("methane", 0))
	if outer_methane_before < 19:
		_isolate_all_machine_power_for_target(jovian_extractor_id, jovian_world_id)
		_ensure_connection("POWER", jovian_solar_id, jovian_extractor_id, "", jovian_world_id)
		_clear_competing_cargo_outputs(jovian_extractor_id, "methane", jovian_fluid_tank_id, jovian_world_id)
		_clear_competing_cargo_inputs(jovian_fluid_tank_id, "methane", jovian_extractor_id, jovian_world_id)
		_ensure_connection("CARGO", jovian_extractor_id, jovian_fluid_tank_id, "methane", jovian_world_id)
		var outer_methane_events := _advance(60000.0, "J10 Outer renewable Jovian methane accumulation")
		_check(outer_methane_events.any(func(event_value):
			var event := event_value as Dictionary
			return str(event.get("type", "")) == "FactoryResourceExtracted" and str(event.get("world_id", "")) == jovian_world_id and str(event.get("entity_id", "")) == jovian_extractor_id and str(event.get("resource_id", "")) == "methane" and str(event.get("activity_id", "")) == "separate_methane"
		), "J10 physically extends the renewable methane stream before exact superalloy conversion; events=%s" % JSON.stringify(outer_methane_events))
	# Freeze the renewable source before measuring and cold-staging the finite
	# alloy manifest.  Otherwise the extractor can refill the FLUID tank during
	# its debit window and obscure the exact twelve-plus-seven custody transfer.
	_isolate_all_machine_power_for_target(jovian_extractor_id, jovian_world_id)
	_clear_competing_cargo_outputs(jovian_extractor_id, "methane", "", jovian_world_id)
	var outer_methane_ready := int(_entity(_snapshot(jovian_world_id), jovian_fluid_tank_id).get("inventory", {}).get("methane", 0))
	_check(outer_methane_ready >= 19, "J10 retains at least nineteen physically extracted methane units in canonical FLUID custody; before=%d ready=%d tank=%s" % [outer_methane_before, outer_methane_ready, JSON.stringify(_entity(_snapshot(jovian_world_id), jovian_fluid_tank_id))])
	if failures.size() > 0:
		return
	var outer_superalloy_before := int(_entity(_snapshot(jovian_world_id), jovian_bulk_depot_id).get("inventory", {}).get("superalloy", 0))
	var outer_superalloy_cycles := 0
	for outer_superalloy_batch_value in [12, 7]:
		var outer_superalloy_batch := int(outer_superalloy_batch_value)
		var outer_superalloy_events := _cold_stage_recipe_batch(jovian_superalloy_smelter_id, "grid_refine_superalloy", jovian_second_solar_id, [
			{"item_id":"titanium_alloy", "source_id":jovian_bulk_depot_id, "quantity":outer_superalloy_batch},
			{"item_id":"cobalt_ingot", "source_id":jovian_bulk_depot_id, "quantity":outer_superalloy_batch * 2},
			{"item_id":"methane", "source_id":jovian_fluid_tank_id, "quantity":outer_superalloy_batch}
		], jovian_bulk_depot_id, "superalloy", float(outer_superalloy_batch) * 30000.0 + 1000.0, "J10 Outer Jovian exact superalloy batch %d" % outer_superalloy_batch, jovian_world_id)
		for outer_superalloy_event_value in outer_superalloy_events:
			var outer_superalloy_event := outer_superalloy_event_value as Dictionary
			if str(outer_superalloy_event.get("type", "")) == "FactoryRecipeCompleted" and str(outer_superalloy_event.get("world_id", "")) == jovian_world_id and str(outer_superalloy_event.get("entity_id", "")) == jovian_superalloy_smelter_id and str(outer_superalloy_event.get("recipe_id", "")) == "grid_refine_superalloy":
				outer_superalloy_cycles += int(outer_superalloy_event.get("completed_cycles", 0))
		if failures.size() > 0:
			return
	var outer_superalloy_bulk := _entity(_snapshot(jovian_world_id), jovian_bulk_depot_id)
	_check(outer_superalloy_cycles == 19 and int(outer_superalloy_bulk.get("inventory", {}).get("titanium_alloy", 0)) == 0 and int(outer_superalloy_bulk.get("inventory", {}).get("cobalt_ingot", 0)) == outer_cobalt_ingot_before and int(outer_superalloy_bulk.get("inventory", {}).get("superalloy", 0)) == outer_superalloy_before + 19 and int(_entity(_snapshot(jovian_world_id), jovian_fluid_tank_id).get("inventory", {}).get("methane", 0)) == outer_methane_ready - 19, "J10 converts the exact Ti19/Co38/methane19 manifest into nineteen physical Jovian superalloys without residual alloy inputs; cycles=%d bulk=%s tank=%s" % [outer_superalloy_cycles, JSON.stringify(outer_superalloy_bulk), JSON.stringify(_entity(_snapshot(jovian_world_id), jovian_fluid_tank_id))])
	if failures.size() > 0:
		return

	# Two capacity-safe Jovian-to-Earth superalloy shipments fund Capital Combat
	# first and leave the later fourteen-unit Battleship manifest distinct.  Fund
	# both source dispatches once, including maintenance recovery across transit
	# and research time, through the same public Earth logistics boundary.
	var outer_jovian_repair_projection: Dictionary = game.maintenance_recovery_snapshot("gas_giant_region", "repair_material", 6, 900000.0)
	var outer_jovian_repair_target := maxi(6, int(outer_jovian_repair_projection.get("gross_production_target", 6)))
	outer_lunar_source_fuel_packet["engineering_machine_id"] = gas_bootstrap_repair_works_id
	_ensure_local_factory_item("chemical_propellant", 10 + 2 * int(jovian_path_costs.get("chemical_propellant", 0)), outer_lunar_source_fuel_packet, "J10 Outer Jovian-to-Earth superalloy Earth fuel closure")
	gas_bootstrap_repair_works_id = str(outer_lunar_source_fuel_packet.get("engineering_machine_id", gas_bootstrap_repair_works_id))
	if failures.size() > 0:
		return
	var outer_jovian_return_reserve := _freight_earth_manifest_to_remote("gas_giant_region", jovian_world_id, {"chemical_propellant":10, "repair_material":outer_jovian_repair_target}, "J10 Outer Jovian-to-Earth superalloy operating reserve", jovian_path_costs, {"copper_refinery_id":cruiser_copper_id, "engineering_works_id":gas_bootstrap_repair_works_id, "iron_refinery_id":gas_bootstrap_iron_refinery_id, "power_source_id":array_entity_id, "bulk_storage_id":cruiser_bulk_depot_id})
	gas_bootstrap_repair_works_id = str(outer_jovian_return_reserve.get("repair_works_id", gas_bootstrap_repair_works_id))
	_check(not outer_jovian_return_reserve.is_empty(), "J10 physically stages the finite Jovian-origin superalloy return reserve; projection=%s reserve_target=%d" % [JSON.stringify(outer_jovian_repair_projection), outer_jovian_repair_target])
	if failures.size() > 0:
		return
	var outer_earth_superalloy_before := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("superalloy", 0))
	_export_to_location("superalloy", 5, "J10 Capital Combat superalloy research batch", jovian_world_id, jovian_bulk_depot_id)
	var outer_research_alloy_route := _freight_location_cargo("gas_giant_region", jovian_world_id, EARTH_LOCATION_ID, EARTH_WORLD_ID, "superalloy", 5, jovian_path_costs, "J10 Jovian-Earth Capital Combat superalloy shipment")
	_check(not outer_research_alloy_route.is_empty() and int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("superalloy", 0)) == outer_earth_superalloy_before + 5, "J10 returns the exact five-unit Capital Combat superalloy batch to Earth Location custody")
	if failures.size() > 0:
		return
	_stage_location_shortfall_from_factory("data_core", 5, "J10 Capital Combat data-core research manifest")
	if failures.size() > 0:
		return
	var outer_capital_inventory_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	var outer_capital_events_start := observed_events.size()
	_check(bool(game.start_research_project("research_capital_combat")), "public Research command starts Capital Combat from the physical Jovian superalloy return")
	var outer_capital_events := _advance(70000.0, "J10 Capital Combat research")
	var outer_capital_completion := _first_event(_events_after(outer_capital_events_start), "ResearchCompleted")
	var outer_capital_inventory_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(str(outer_capital_completion.get("project_id", "")) == "research_capital_combat" and str(outer_capital_completion.get("technology_id", "")) == "capital_combat" and int(outer_capital_inventory_after.get("superalloy", 0)) == int(outer_capital_inventory_before.get("superalloy", 0)) - 5 and int(outer_capital_inventory_after.get("data_core", 0)) == int(outer_capital_inventory_before.get("data_core", 0)) - 5, "J10 completes Capital Combat with exact project/technology identity and physical five-alloy/five-data debit; completion=%s events=%s" % [JSON.stringify(outer_capital_completion), JSON.stringify(outer_capital_events)])
	if failures.size() > 0:
		return
	_export_to_location("superalloy", 14, "J10 canonical Jovian Battleship superalloy Shipyard batch", jovian_world_id, jovian_bulk_depot_id)
	var outer_ship_alloy_route := _freight_location_cargo("gas_giant_region", jovian_world_id, EARTH_LOCATION_ID, EARTH_WORLD_ID, "superalloy", 14, jovian_path_costs, "J10 Jovian-Earth Battleship superalloy shipment")
	_check(not outer_ship_alloy_route.is_empty() and int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("superalloy", 0)) == 14, "J10 returns exactly fourteen remaining Jovian superalloys for the canonical Battleship manifest")
	if failures.size() > 0:
		return
	# Install the conserved Jovian waste lane before the Battleship's recursive
	# capital-goods closure requests fresh cobalt.  This keeps every additional
	# cobalt-refining by-product in a public two-waste-to-one-iron path instead of
	# waiting until after the ship that consumes those materials already exists.
	var post_outer_snapshot := _snapshot(EARTH_WORLD_ID)
	var post_outer_packet := {
		"storage_id":cruiser_bulk_depot_id,
		"waste_storage_id":cruiser_bulk_depot_id,
		"power_source_id":array_entity_id,
		"iron_extractor_id":str(_entity_with_resource(post_outer_snapshot, "iron_ore").get("id", "")),
		"copper_extractor_id":str(_entity_with_resource(post_outer_snapshot, "copper_ore").get("id", "")),
		"iron_refinery_id":gas_bootstrap_iron_refinery_id,
		"copper_refinery_id":cruiser_copper_id,
		"engineering_machine_id":gas_bootstrap_repair_works_id,
		"arc_smelter_id":cruiser_foundry_id,
		"electronics_works_id":prototype_high_energy_id,
		"assembly_array_id":quantum_assembly_id,
		"lunar_world_id":lunar_world_id,
		"lunar_storage_id":array_titanium_depot_id,
		"lunar_power_id":alloy_base_lunar_power_id,
		"lunar_titanium_extractor_id":alloy_base_titanium_mine_id,
		"lunar_titanium_foundry_id":alloy_base_titanium_foundry_id,
		"lunar_rare_extractor_id":rare_earth_mine_id,
		"lunar_helium_extractor_id":lunar_cryo_id,
		"lunar_helium_storage_id":lunar_tank_id,
		"lunar_thorium_extractor_id":thorium_mine_id,
		"asteroid_world_id":asteroid_world_id,
		"asteroid_storage_id":asteroid_steel_depot_id,
		"asteroid_power_id":rig_asteroid_solar_id,
		"asteroid_cobalt_extractor_id":rig_asteroid_cobalt_mine_id,
		"jovian_world_id":jovian_world_id,
		"jovian_storage_id":jovian_bulk_depot_id,
		"jovian_fluid_storage_id":jovian_fluid_tank_id,
		"jovian_power_id":jovian_second_solar_id,
		"jovian_methane_extractor_id":jovian_extractor_id,
		"jovian_smelter_id":jovian_superalloy_smelter_id
	}
	var jovian_waste_recovery := _build_jovian_waste_recovery(post_outer_packet)
	post_outer_packet["jovian_waste_processor_id"] = str(jovian_waste_recovery.get("processor_id", ""))
	post_outer_packet["jovian_recycle_storage_ids"] = jovian_waste_recovery.get("storage_ids", [])
	if failures.size() > 0:
		return
	_recycle_jovian_cobalt_waste(post_outer_packet, "J10 pre-Battleship accumulated Jovian cobalt waste")
	if failures.size() > 0:
		return
	# The prototype Assembly Array legitimately retains inputs from earlier J10
	# work.  Build a clean second array for exact endgame lots instead of deleting
	# that player-produced buffer or misattributing it to the Battleship manifest.
	var clean_outer_array_costs := {"steel_composite":8, "titanium_alloy":6, "electronics":6}
	_prepare_external_for_manifest(clean_outer_array_costs, post_outer_packet, "J10 clean endgame Assembly Array external closure")
	if failures.size() > 0:
		return
	quantum_assembly_id = _construct_earth_adapter("grid_assembly_array", clean_outer_array_costs, post_outer_packet, "J10 clean endgame Assembly Array", "grid_fabricate_quantum_component")
	post_outer_packet["assembly_array_id"] = quantum_assembly_id
	_check(not quantum_assembly_id.is_empty() and (_entity(_snapshot(EARTH_WORLD_ID), quantum_assembly_id).get("inputs", {}) as Dictionary).is_empty(), "J10 exposes a physically constructed clean Assembly Array for exact Battleship and endgame production")
	if failures.size() > 0:
		return
	# The prototype high-energy works also retains the lawful copper buffer used by
	# earlier J10 research.  Preserve it and build a clean endgame electronics
	# adapter so exact power-bus and later module lots start from empty inputs.
	var clean_outer_electronics_costs := {"iron_ingot":8, "electronics":5, "structural_frame":2}
	_prepare_external_for_manifest(clean_outer_electronics_costs, post_outer_packet, "J10 clean endgame Electronics Works external closure")
	if failures.size() > 0:
		return
	var clean_outer_electronics_id := _construct_earth_adapter("grid_electronics_works", clean_outer_electronics_costs, post_outer_packet, "J10 clean endgame Electronics Works", "grid_fabricate_power_bus_component")
	post_outer_packet["electronics_works_id"] = clean_outer_electronics_id
	_check(not clean_outer_electronics_id.is_empty() and (_entity(_snapshot(EARTH_WORLD_ID), clean_outer_electronics_id).get("inputs", {}) as Dictionary).is_empty(), "J10 exposes a physically constructed clean Electronics Works while preserving the prototype machine's lawful input buffer")
	if failures.size() > 0:
		return

	# Reserve the full Starport III, development, hull, and five-module manifest
	# at Earth through visible Factory exports.  Any missing physical precursor
	# fails closed here and is repaired by a focused production slice, never by a
	# hidden state grant.
	var outer_earth_manifest := {
		"steel_composite":12,
		"titanium_alloy":6,
		"quantum_component":12,
		"heavy_structural_section":2,
		"precision_actuator":2,
		"power_bus_component":1,
		"data_core":2,
		"helium_3":2,
		"electronics":7,
		"reactor_part":1,
		"iron_ingot":2,
		"copper_ingot":1
	}
	_prepare_external_for_manifest(outer_earth_manifest, post_outer_packet, "J10 Starport III development and canonical Battleship external closure")
	_stage_earth_manifest(outer_earth_manifest, post_outer_packet, "J10 Starport III development and canonical Battleship manifest")
	gas_bootstrap_repair_works_id = str(post_outer_packet.get("engineering_machine_id", gas_bootstrap_repair_works_id))
	if failures.size() > 0:
		return
	var outer_location_manifest: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var outer_manifest_complete := int(outer_location_manifest.get("superalloy", 0)) == 14
	for outer_manifest_item_value in outer_earth_manifest:
		var outer_manifest_item := str(outer_manifest_item_value)
		outer_manifest_complete = outer_manifest_complete and int(outer_location_manifest.get(outer_manifest_item, 0)) >= int(outer_earth_manifest.get(outer_manifest_item, 0))
	_check(outer_manifest_complete, "J10 exposes the complete physical Starport/development/Battleship manifest at Earth before any consumer reserves it; available=%s" % JSON.stringify(outer_location_manifest))
	if failures.size() > 0:
		return
	var outer_starport_bom := {"steel_composite":6, "titanium_alloy":4, "quantum_component":3, "heavy_structural_section":2, "precision_actuator":2, "power_bus_component":1}
	var outer_starport_inventory_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	var outer_starport := _queue_and_fund("grid_starport_expansion_iii", "", {"x":300, "y":0}, "J10 canonical Starport III", true, EARTH_WORLD_ID, "")
	var outer_starport_id := str(outer_starport.get("entity_id", ""))
	if outer_starport_id.is_empty() or failures.size() > 0:
		return
	var outer_starport_funding: Dictionary = outer_starport.get("location_funding", {})
	var outer_starport_funding_events: Array = outer_starport_funding.get("events", [])
	var outer_starport_inventory_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	var outer_starport_order := {}
	for order_value in _snapshot(EARTH_WORLD_ID).get("construction_orders", []):
		var order := order_value as Dictionary
		if str(order.get("id", "")) == str(outer_starport.get("order_id", "")):
			outer_starport_order = order
			break
	var outer_starport_exact_debit := true
	for item_value in outer_starport_bom:
		var item_id := str(item_value)
		outer_starport_exact_debit = outer_starport_exact_debit and int(outer_starport_inventory_after.get(item_id, 0)) == int(outer_starport_inventory_before.get(item_id, 0)) - int(outer_starport_bom.get(item_id, 0))
	_check(bool(outer_starport_funding.get("result", {}).get("fully_funded", false)) and outer_starport_funding_events.size() == 1 and (outer_starport_funding_events[0] as Dictionary).get("moved", {}) == outer_starport_bom and outer_starport_exact_debit and (outer_starport_order.get("required_items", {}) as Dictionary) == outer_starport_bom and (outer_starport_order.get("delivered_items", {}) as Dictionary) == outer_starport_bom, "J10 Starport III zero-time public funding records the exact canonical BOM, Location debit, and fully delivered order before background production can alter custody; funding=%s order=%s before=%s after=%s" % [JSON.stringify(outer_starport_funding), JSON.stringify(outer_starport_order), JSON.stringify(outer_starport_inventory_before), JSON.stringify(outer_starport_inventory_after)])
	if failures.size() > 0:
		return
	var outer_starport_events := _advance(120000.0, "J10 Starport III construction")
	var outer_starport_runtime := _entity(_snapshot(EARTH_WORLD_ID), outer_starport_id)
	_check(outer_starport_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("world_id", "")) == EARTH_WORLD_ID and str(event.get("entity_id", "")) == outer_starport_id and str(event.get("definition_id", "")) == "grid_starport_expansion_iii"
	) and str(outer_starport_runtime.get("definition_id", "")) == "grid_starport_expansion_iii", "J10 physically completes canonical Starport III before capital-ship development; entity=%s events=%s" % [JSON.stringify(outer_starport_runtime), JSON.stringify(outer_starport_events)])
	if failures.size() > 0:
		return
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "quantum_component")
	game.clear_location_logistics_policy(EARTH_LOCATION_ID, "data_core")
	var outer_development_inventory_before: Dictionary = (_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).duplicate(true)
	var outer_development_events_start := observed_events.size()
	_check(bool(game.start_research_project("develop_jovian_battleship")), "public Research command starts the canonical Jovian Battleship development")
	var outer_development_events := _advance(40000.0, "J10 Jovian Battleship development")
	var outer_development_completion := _first_event(_events_after(outer_development_events_start), "ResearchCompleted")
	var outer_development_inventory_after: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_available_inventory", {})
	_check(str(outer_development_completion.get("project_id", "")) == "develop_jovian_battleship" and str(outer_development_completion.get("ship_plan_id", "")) == "construct_jovian_battleship" and int(outer_development_inventory_after.get("quantum_component", 0)) == int(outer_development_inventory_before.get("quantum_component", 0)) - 3 and int(outer_development_inventory_after.get("data_core", 0)) == int(outer_development_inventory_before.get("data_core", 0)) - 2, "J10 completes the exact canonical Battleship development project with its three-quantum/two-data Location debit and unlocks its plan; completion=%s before=%s after=%s events=%s" % [JSON.stringify(outer_development_completion), JSON.stringify(outer_development_inventory_before), JSON.stringify(outer_development_inventory_after), JSON.stringify(outer_development_events)])
	if failures.size() > 0:
		return
	var outer_design_nodes := [
		{"node_id":"hull", "kind":"hull", "definition_id":"jovian_battleship", "position":{"x":0.0, "y":0.0}},
		{"node_id":"weapon", "kind":"module", "definition_id":"plasma_cannon", "position":{"x":120.0, "y":0.0}},
		{"node_id":"shield", "kind":"module", "definition_id":"capital_shield", "position":{"x":120.0, "y":50.0}},
		{"node_id":"drive", "kind":"module", "definition_id":"advanced_drive", "position":{"x":120.0, "y":100.0}},
		{"node_id":"targeting", "kind":"module", "definition_id":"targeting_computer", "position":{"x":120.0, "y":150.0}},
		{"node_id":"core", "kind":"module", "definition_id":"civilian_reactor_core", "position":{"x":120.0, "y":200.0}}
	]
	var outer_design_connections := [
		{"module_node_id":"weapon", "socket_id":"socket_weapon_0"},
		{"module_node_id":"shield", "socket_id":"socket_shield_0"},
		{"module_node_id":"drive", "socket_id":"socket_drive_0"},
		{"module_node_id":"targeting", "socket_id":"socket_utility_0"},
		{"module_node_id":"core", "socket_id":"socket_core_0"}
	]
	var outer_design_validation: Dictionary = game.ship_design_validation("construct_jovian_battleship", outer_design_nodes, outer_design_connections)
	var outer_expected_modules := ["plasma_cannon", "capital_shield", "advanced_drive", "targeting_computer", "civilian_reactor_core"]
	_check(bool(outer_design_validation.get("allowed", false)) and (outer_design_validation.get("modules", []) as Array) == outer_expected_modules, "public Ship Design validation accepts the exact canonical Jovian Battleship graph; validation=%s" % JSON.stringify(outer_design_validation))
	if failures.size() > 0:
		return
	var outer_engineering_summary: Dictionary = game.ship_design_engineering_summary("construct_jovian_battleship", outer_design_nodes, outer_design_connections)
	var outer_expected_costs := {"superalloy":14, "steel_composite":6, "quantum_component":6, "helium_3":2, "titanium_alloy":2, "electronics":7, "reactor_part":1, "iron_ingot":2, "copper_ingot":1}
	var outer_engineering: Dictionary = outer_engineering_summary.get("engineering", {})
	_check((outer_engineering_summary.get("construction_costs", {}) as Dictionary) == outer_expected_costs and (outer_engineering.get("totals", {}) as Dictionary) == {"mass":127.0, "power":228.0, "thermal":164.0} and (outer_engineering.get("capacities", {}) as Dictionary) == {"mass":400.0, "power":480.0, "thermal":380.0}, "J10 engineering summary exposes the exact canonical Battleship BOM and fitting totals; summary=%s" % JSON.stringify(outer_engineering_summary))
	if failures.size() > 0:
		return
	var outer_design_events_start := observed_events.size()
	_check(bool(game.save_ship_design("", "Runtime Jovian Battleship", "construct_jovian_battleship", outer_design_nodes, outer_design_connections)), "public Ship Design command saves the canonical Jovian Battleship graph")
	var outer_design_event := _first_event(_events_after(outer_design_events_start), "ShipDesignSaved")
	var outer_design_id := str(outer_design_event.get("design_id", ""))
	_check(not outer_design_id.is_empty() and str(outer_design_event.get("plan_id", "")) == "construct_jovian_battleship", "ShipDesignSaved publishes the exact Battleship design and plan identities; event=%s" % JSON.stringify(outer_design_event))
	if failures.size() > 0:
		return
	var outer_queue_events_start := observed_events.size()
	_check(bool(game.enqueue_saved_ship_design(outer_design_id)), "public Shipyard command queues the physically funded Jovian Battleship saved design")
	var outer_queue_event := _first_event(_events_after(outer_queue_events_start), "ShipDesignQueued")
	_check(str(outer_queue_event.get("design_id", "")) == outer_design_id and str(outer_queue_event.get("plan_id", "")) == "construct_jovian_battleship" and int(outer_queue_event.get("quantity", 0)) == 1, "ShipDesignQueued identifies the exact Battleship design, plan, and one physical unit")
	if failures.size() > 0:
		return
	var outer_shipyard_events := _advance(120000.0, "J10 exact one-hundred-segment Jovian Battleship construction")
	var outer_construction_event := _first_event(outer_shipyard_events, "ShipConstructionCompleted")
	var outer_build_cycles: Array = outer_shipyard_events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "ShipbuildingCycleCompleted" and str(event.get("plan_id", "")) == "construct_jovian_battleship"
	)
	var outer_exact_cycle_sequence := outer_build_cycles.size() == 100
	for outer_cycle_index in outer_build_cycles.size():
		if int((outer_build_cycles[outer_cycle_index] as Dictionary).get("segments", 0)) != outer_cycle_index + 1:
			outer_exact_cycle_sequence = false
			break
	_check(outer_exact_cycle_sequence and str(outer_construction_event.get("plan_id", "")) == "construct_jovian_battleship" and str(outer_construction_event.get("design_id", "")) == outer_design_id and (outer_construction_event.get("module_ids", []) as Array) == outer_expected_modules and (outer_construction_event.get("consumed", {}) as Dictionary) == outer_expected_costs and int(outer_construction_event.get("segments", 0)) == 100 and int(outer_construction_event.get("quantity_completed", 0)) == 1 and bool(outer_construction_event.get("created", false)), "J10 Shipyard completes and publishes the exact rich one-hundred-segment Battleship event; event=%s cycles=%d" % [JSON.stringify(outer_construction_event), outer_build_cycles.size()])
	var outer_candidates: Array = game.ship_design_refit_candidates(outer_design_id)
	_check(outer_candidates.size() == 1, "public design-refit candidate query exposes exactly one constructed Jovian Battleship instance")
	if outer_candidates.size() != 1 or failures.size() > 0:
		return
	var outer_battleship_id := str(outer_candidates[0])
	var outer_formation_events_start := observed_events.size()
	_check(bool(game.create_fleet_formation("Outer Battleship Group")), "public Fleet command creates the dedicated Outer Battleship formation")
	var outer_formation_event := _first_event(_events_after(outer_formation_events_start), "FleetFormationCreated")
	var outer_formation_id := str(outer_formation_event.get("formation_id", ""))
	_check(not outer_formation_id.is_empty() and bool(game.set_ship_formation_assignment(outer_battleship_id, outer_formation_id)), "public Fleet command assigns the exact constructed Battleship to its dedicated formation")
	if failures.size() > 0:
		return
	var outer_exotic_before := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("exotic_crystal", 0))
	_check(bool(game.start_expedition_route("outer_route", [outer_battleship_id], outer_formation_id)), "public Expedition command launches the exact canonical Battleship on the Outer route")
	var outer_route_events := _advance(120000.0, "J10 Outer Battleship route and boss combat")
	var outer_boss_started := outer_route_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "CombatStarted" and str(event.get("enemy_id", "")) == "outer_dreadnought" and bool(event.get("boss", false))
	)
	var outer_boss_defeated := outer_route_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "EnemyDefeated" and str(event.get("enemy_id", "")) == "outer_dreadnought" and bool(event.get("boss", false)) and bool((event.get("combat", {}) as Dictionary).get("victory", false))
	)
	var outer_node_events: Array = outer_route_events.filter(func(event_value): return str((event_value as Dictionary).get("type", "")) == "ExpeditionNodeCompleted")
	var outer_exact_nodes := outer_node_events.size() == 3
	if outer_exact_nodes:
		for outer_node_index in range(3):
			var outer_node_event := outer_node_events[outer_node_index] as Dictionary
			var expected_phase: String = ["TRAVEL", "HAZARD", "BOSS"][outer_node_index]
			outer_exact_nodes = outer_exact_nodes and int(outer_node_event.get("node_index", -1)) == outer_node_index and str(outer_node_event.get("phase", "")) == expected_phase and str(outer_node_event.get("route_id", "")) == "outer_route"
	var outer_route_completed := outer_route_events.any(func(event_value): return str((event_value as Dictionary).get("type", "")) == "ExpeditionRouteCompleted" and str((event_value as Dictionary).get("route_id", "")) == "outer_route")
	var outer_exotic_after := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("exotic_crystal", 0))
	_check(outer_exact_nodes, "J10 completes the exact indexed Outer TRAVEL, HAZARD, and BOSS nodes; nodes=%s" % JSON.stringify(outer_node_events))
	_check(outer_boss_started, "J10 starts the canonical outer_dreadnought boss encounter")
	_check(outer_boss_defeated, "J10 defeats the canonical outer_dreadnought with a public combat victory")
	_check(outer_route_completed, "J10 publishes the canonical Outer route completion checkpoint")
	_check(outer_exotic_after == outer_exotic_before + 11, "J10 receives exactly eleven physical exotic crystals from the completed Outer route; before=%d after=%d" % [outer_exotic_before, outer_exotic_after])
	if failures.size() > 0:
		return
	_recycle_jovian_cobalt_waste(post_outer_packet, "J10 post-Outer accumulated Jovian cobalt waste")
	if failures.size() > 0:
		return
	_complete_deep_system(post_outer_packet, outer_battleship_id)


## Add a finite public recycling lane before endgame production begins.  The
## bounded Deep bootstrap, staged research, and seven Megastructure lots request
## fewer than 4,000 cobalt-refining cycles; immediate two-for-one reprocessing
## therefore fits two 1,000-unit canonical BULK iron depots with explicit margin,
## without deleting by-products or relying on an unenforced storage-class rule.
func _build_jovian_waste_recovery(packet: Dictionary) -> Dictionary:
	var jovian_world_id := str(packet.get("jovian_world_id", ""))
	var first_wave := {"electronics":2, "iron_ingot":10, "scrap_metal":4}
	_stage_earth_manifest(first_wave, packet, "J10 Jovian waste-recovery first construction wave")
	if failures.size() > 0:
		return {}
	_transfer_earth_manifest_to_remote_factory("gas_giant_region", jovian_world_id, first_wave, {"chemical_propellant":5, "repair_material":3}, packet, "J10 Jovian waste processor and first recovery depot", "")
	if failures.size() > 0:
		return {}
	var processor_order := _queue_and_fund("grid_engineering_works", "grid_reprocess_industrial_waste", _find_clear_factory_origin("grid_engineering_works", jovian_world_id), "J10 Jovian industrial-waste processor", true, jovian_world_id, "")
	var first_storage_order := _queue_and_fund("grid_bulk_depot", "", _find_clear_factory_origin("grid_bulk_depot", jovian_world_id), "J10 Jovian first recovered-iron Bulk depot", true, jovian_world_id, "")
	var processor_id := str(processor_order.get("entity_id", ""))
	var first_storage_id := str(first_storage_order.get("entity_id", ""))
	var first_events := _advance(120000.0, "J10 Jovian waste processor and first recovery-depot construction")
	var first_snapshot := _snapshot(jovian_world_id)
	var first_orders_retired := not (first_snapshot.get("construction_orders", []) as Array).any(func(order_value):
		var order := order_value as Dictionary
		return str(order.get("id", "")) in [str(processor_order.get("order_id", "")), str(first_storage_order.get("order_id", ""))]
	)
	var processor_completed := first_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("world_id", "")) == jovian_world_id and str(event.get("entity_id", "")) == processor_id and str(event.get("definition_id", "")) == "grid_engineering_works"
	)
	var first_storage_completed := first_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("world_id", "")) == jovian_world_id and str(event.get("entity_id", "")) == first_storage_id and str(event.get("definition_id", "")) == "grid_bulk_depot"
	)
	_check(not processor_id.is_empty() and not first_storage_id.is_empty() and processor_completed and first_storage_completed and first_orders_retired and str(_entity(first_snapshot, processor_id).get("status", "")) != "UNDER_CONSTRUCTION" and int(_entity(first_snapshot, first_storage_id).get("inventory_capacity", 0)) == 1000, "Factory fully funds and completes the exact Jovian waste processor plus first empty recovered-iron depot; events=%s" % JSON.stringify(first_events))
	if failures.size() > 0:
		return {}

	var second_wave := {"iron_ingot":10}
	_stage_earth_manifest(second_wave, packet, "J10 Jovian second recovery-depot construction wave")
	if failures.size() > 0:
		return {}
	_transfer_earth_manifest_to_remote_factory("gas_giant_region", jovian_world_id, second_wave, {"chemical_propellant":5, "repair_material":3}, packet, "J10 Jovian second recovered-iron Bulk depot", "")
	if failures.size() > 0:
		return {}
	var second_storage_order := _queue_and_fund("grid_bulk_depot", "", _find_clear_factory_origin("grid_bulk_depot", jovian_world_id), "J10 Jovian second recovered-iron Bulk depot", true, jovian_world_id, "")
	var second_storage_id := str(second_storage_order.get("entity_id", ""))
	var second_events := _advance(90000.0, "J10 Jovian second recovery-depot construction")
	var second_snapshot := _snapshot(jovian_world_id)
	var second_order_retired := not (second_snapshot.get("construction_orders", []) as Array).any(func(order_value): return str((order_value as Dictionary).get("id", "")) == str(second_storage_order.get("order_id", "")))
	var second_storage_completed := second_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("world_id", "")) == jovian_world_id and str(event.get("entity_id", "")) == second_storage_id and str(event.get("definition_id", "")) == "grid_bulk_depot"
	)
	_check(not second_storage_id.is_empty() and second_storage_completed and second_order_retired and str(_entity(second_snapshot, second_storage_id).get("status", "")) != "UNDER_CONSTRUCTION" and int(_entity(second_snapshot, second_storage_id).get("inventory_capacity", 0)) == 1000, "Factory fully funds and completes the exact second empty Jovian recovered-iron depot; events=%s" % JSON.stringify(second_events))
	return {"processor_id":processor_id, "storage_ids":[first_storage_id, second_storage_id]}


## Reprocess all even cobalt-waste custody after every bounded cobalt lot.  The
## odd remainder, if any, stays visible for the next call; recovered iron is
## spread over the two explicitly constructed depots by public capacity.
func _recycle_jovian_cobalt_waste(packet: Dictionary, label: String) -> void:
	var jovian_world_id := str(packet.get("jovian_world_id", ""))
	var waste_storage_id := str(packet.get("jovian_storage_id", ""))
	var processor_id := str(packet.get("jovian_waste_processor_id", ""))
	var power_id := str(packet.get("jovian_power_id", ""))
	var recovery_storage_ids: Array = packet.get("jovian_recycle_storage_ids", [])
	var waste_before := int((_entity(_snapshot(jovian_world_id), waste_storage_id).get("inventory", {}) as Dictionary).get("industrial_waste", 0))
	var recycle_cycles := waste_before / 2
	_check(not processor_id.is_empty() and not power_id.is_empty() and recovery_storage_ids.size() == 2, "%s resolves the physical Jovian processor, power, and two-depot recovery lane" % label)
	if failures.size() > 0 or recycle_cycles <= 0:
		return
	var iron_before := 0
	for storage_id_value in recovery_storage_ids:
		iron_before += int((_entity(_snapshot(jovian_world_id), str(storage_id_value)).get("inventory", {}) as Dictionary).get("iron_ingot", 0))
	var remaining := recycle_cycles
	for storage_id_value in recovery_storage_ids:
		if remaining <= 0:
			break
		var storage_id := str(storage_id_value)
		var storage := _entity(_snapshot(jovian_world_id), storage_id)
		var used_capacity := 0
		for inventory_value in (storage.get("inventory", {}) as Dictionary).values():
			used_capacity += int(inventory_value)
		var available_capacity := maxi(0, int(storage.get("inventory_capacity", 0)) - used_capacity)
		var assigned_cycles := mini(remaining, available_capacity)
		if assigned_cycles <= 0:
			continue
		_run_exact_recipe_batches(processor_id, "grid_reprocess_industrial_waste", power_id, storage_id, "iron_ingot", assigned_cycles, mini(32, assigned_cycles), "%s recovered-iron depot %s" % [label, storage_id], "", jovian_world_id, {"industrial_waste":waste_storage_id})
		remaining -= assigned_cycles
		if failures.size() > 0:
			return
	var waste_after := int((_entity(_snapshot(jovian_world_id), waste_storage_id).get("inventory", {}) as Dictionary).get("industrial_waste", 0))
	var iron_after := 0
	for storage_id_value in recovery_storage_ids:
		iron_after += int((_entity(_snapshot(jovian_world_id), str(storage_id_value)).get("inventory", {}) as Dictionary).get("iron_ingot", 0))
	_check(remaining == 0 and waste_after == waste_before - recycle_cycles * 2 and waste_after <= 1 and iron_after == iron_before + recycle_cycles, "%s conserves the exact two-waste-to-one-iron public recipe across bounded explicit custody; waste_before=%d cycles=%d waste_after=%d iron_before=%d iron_after=%d" % [label, waste_before, recycle_cycles, waste_after, iron_before, iron_after])


func _complete_deep_system(packet: Dictionary, _outer_battleship_id: String) -> void:
	# The route unlock is only DETECTED.  Investment-grade Factory access still
	# requires the normal survey package and the already-built Pathfinder.
	# Stage time-advancing manufactured cargo first and the maintenance-sensitive
	# operating items last, so no later recipe window consumes the survey reserve.
	_stage_earth_manifest({"industrial_machine_tools":1, "structural_frame":2, "electronics":2, "chemical_propellant":2, "repair_material":1}, packet, "J10 Outer SURVEYED mission")
	if failures.size() > 0:
		return
	_complete_public_survey("outer_system", "SURVEYED", pathfinder_ship_id, 60000.0, "J10 Outer industrial survey")
	_check(bool(game.initialize_surveyed_factory_world("outer_system")), "public Survey completion initializes the sparse Outer Factory workspace")
	var outer_world_ids: Array[String] = game.factory_world_ids_for_location("outer_system")
	var outer_world_id := str(outer_world_ids[0] if outer_world_ids.size() == 1 else "")
	var outer_snapshot := _snapshot(outer_world_id)
	var outer_exotic_field := _resource_field(outer_snapshot, "exotic_crystal")
	_check(outer_world_ids.size() == 1 and bool(outer_snapshot.get("valid", false)) and not outer_exotic_field.is_empty(), "the public Factory-world query exposes exactly one surveyed Outer exotic field")
	if failures.size() > 0:
		return

	# Establish explicit Outer custody.  Separate freight waves keep the surveyed
	# Location's finite BULK staging below its declared capacity.
	_check(bool(game.configure_logistics_service("jovian_outer_freight", "general_cargo")), "public Logistics configures the Jovian-Outer corridor")
	_transfer_earth_manifest_to_remote_factory("outer_system", outer_world_id, {"iron_ingot":10}, {"chemical_propellant":8, "repair_material":4}, packet, "J10 Outer Bulk-depot iron wave", "")
	var outer_bulk := _queue_and_fund("grid_bulk_depot", "", _find_clear_factory_origin("grid_bulk_depot", outer_world_id), "J10 Outer Bulk depot", true, outer_world_id, "")
	var outer_bulk_id := str(outer_bulk.get("entity_id", ""))
	_advance(120000.0, "J10 Outer Bulk-depot construction")
	_check(str(_entity(_snapshot(outer_world_id), outer_bulk_id).get("definition_id", "")) == "grid_bulk_depot", "Factory physically completes the Outer Bulk depot")
	if failures.size() > 0:
		return
	_transfer_earth_manifest_to_remote_factory("outer_system", outer_world_id, {"scrap_metal":4}, {"chemical_propellant":8, "repair_material":4}, packet, "J10 Outer two-solar power wave", outer_bulk_id)
	var outer_solar := _queue_and_fund("grid_solar_array", "", _find_clear_factory_origin("grid_solar_array", outer_world_id), "J10 Outer solar array one", false, outer_world_id, outer_bulk_id)
	var outer_second_solar := _queue_and_fund("grid_solar_array", "", _find_clear_factory_origin("grid_solar_array", outer_world_id), "J10 Outer solar array two", false, outer_world_id, outer_bulk_id)
	var outer_solar_id := str(outer_solar.get("entity_id", ""))
	var outer_second_solar_id := str(outer_second_solar.get("entity_id", ""))
	var outer_power_events := _advance(120000.0, "J10 Outer two-solar power-base construction")
	_check(str(_entity(_snapshot(outer_world_id), outer_solar_id).get("definition_id", "")) == "grid_solar_array" and str(_entity(_snapshot(outer_world_id), outer_second_solar_id).get("definition_id", "")) == "grid_solar_array" and _events_have_type(outer_power_events, "FactoryConstructionCompleted"), "Factory completes two explicit Outer solar providers before the exotic extractor")
	if failures.size() > 0:
		return

	# Close every regional input needed by the Deep-system bootstrap through its
	# real extraction, processing and freight chain before local recursive builds.
	_return_remote_resource_to_earth("rare_earth_concentrate", 66, 2, "lunar_space", str(packet.get("lunar_world_id", "")), str(packet.get("lunar_rare_extractor_id", "")), str(packet.get("lunar_power_id", "")), str(packet.get("lunar_storage_id", "")), {"chemical_propellant":1, "repair_material":1}, packet, "J10 Deep quantum rare-earth closure")
	_return_remote_resource_to_earth("helium_3", 33, 5, "lunar_space", str(packet.get("lunar_world_id", "")), str(packet.get("lunar_helium_extractor_id", "")), str(packet.get("lunar_power_id", "")), str(packet.get("lunar_helium_storage_id", "")), {"chemical_propellant":1, "repair_material":1}, packet, "J10 Deep antimatter helium closure")
	_return_lunar_titanium_to_earth(6, packet, "J10 Deep direct titanium closure")
	_produce_jovian_superalloy_to_earth(60, packet, "J10 Deep superalloy closure")
	if failures.size() > 0:
		return
	_ensure_local_factory_item("quantum_component", 66, packet, "J10 Deep quantum-component closure")
	if failures.size() > 0:
		return

	_complete_exact_research("research_exotic_materials", {"exotic_crystal":4, "quantum_component":4}, 80000.0, packet, "exotic_materials")
	var construction_yard_costs := {"steel_composite":6, "quantum_component":4, "titanium_alloy":4, "heavy_structural_section":2, "precision_actuator":1}
	_prepare_external_for_manifest(construction_yard_costs, packet, "J10 Construction Yard III external closure")
	if failures.size() > 0:
		return
	_construct_earth_adapter("grid_construction_yard_iii", construction_yard_costs, packet, "J10 Construction Yard III")
	_construct_earth_adapter("grid_field_engineering_complex", {"superalloy":8, "quantum_component":6, "electronics":8}, packet, "J10 Field Engineering Complex")
	_complete_exact_research("research_antimatter", {"exotic_crystal":5, "helium_3":5}, 90000.0, packet, "antimatter_engineering")
	if failures.size() > 0:
		return
	# The route leaves exactly the two crystals required by the first cell.  That
	# cell is the physical bootstrap input of the canonical exotic extractor.
	var exotic_in_location := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("exotic_crystal", 0))
	_check(exotic_in_location == 2, "both research programs leave exactly the route-reward exotic pair for the first antimatter cell")
	_import_from_location("exotic_crystal", 2, str(packet.get("storage_id", "")), "J10 first antimatter-cell route-reward custody")
	_run_exact_recipe_batches(str(packet.get("electronics_works_id", "")), "grid_build_antimatter_cell", str(packet.get("power_source_id", "")), str(packet.get("storage_id", "")), "antimatter_cell", 1, 1, "J10 first physical antimatter cell")
	_transfer_earth_manifest_to_remote_factory("outer_system", outer_world_id, {"superalloy":4, "quantum_component":3, "antimatter_cell":1}, {"chemical_propellant":8, "repair_material":4}, packet, "J10 canonical Outer exotic-extractor wave", outer_bulk_id)
	var outer_mine := _queue_and_fund("grid_exotic_extractor", "", outer_exotic_field.get("footprint", {}).get("origin", {}), "J10 Outer exotic extractor", false, outer_world_id, outer_bulk_id)
	var outer_mine_id := str(outer_mine.get("entity_id", ""))
	var outer_extractor_events := _advance(120000.0, "J10 Outer exotic-extractor construction")
	_check(str(_entity(_snapshot(outer_world_id), outer_mine_id).get("definition_id", "")) == "grid_exotic_extractor" and str(_entity(_snapshot(outer_world_id), outer_mine_id).get("resource_id", "")) == "exotic_crystal" and _events_have_type(outer_extractor_events, "FactoryConstructionCompleted"), "Factory physically completes the canonical two-solar Outer exotic extractor")
	_return_remote_resource_to_earth("exotic_crystal", 26, 8, "outer_system", outer_world_id, outer_mine_id, outer_solar_id, outer_bulk_id, {"chemical_propellant":8, "repair_material":4}, packet, "J10 Deep exotic closure", [outer_second_solar_id])
	_run_exact_recipe_batches(str(packet.get("electronics_works_id", "")), "grid_build_antimatter_cell", str(packet.get("power_source_id", "")), str(packet.get("storage_id", "")), "antimatter_cell", 13, 13, "J10 remaining thirteen-cell antimatter program")
	if failures.size() > 0:
		return
	_complete_exact_research("research_exotic_containment", {"antimatter_cell":3, "quantum_component":5}, 95000.0, packet, "exotic_containment_tech")
	_transfer_earth_manifest_to_remote_factory("outer_system", outer_world_id, {"superalloy":8, "quantum_component":6, "antimatter_cell":2}, {"chemical_propellant":8, "repair_material":4}, packet, "J10 Outer Command Array wave", outer_bulk_id)
	var outer_command := _queue_and_fund("grid_command_array", "", _find_clear_factory_origin("grid_command_array", outer_world_id), "J10 Outer Deep-space Command Array", false, outer_world_id, outer_bulk_id)
	var outer_command_id := str(outer_command.get("entity_id", ""))
	var outer_command_events := _advance(180000.0, "J10 Outer Command Array construction")
	_check(str(_entity(_snapshot(outer_world_id), outer_command_id).get("definition_id", "")) == "grid_command_array" and _events_have_type(outer_command_events, "FactoryConstructionCompleted"), "Factory physically completes the canonical Command Array at the Outer worksite")
	_construct_earth_adapter("grid_starport_expansion_iv", {"superalloy":8, "quantum_component":5, "antimatter_cell":2}, packet, "J10 Starport IV")
	_complete_exact_research("develop_outer_titan", {"quantum_component":4, "data_core":3}, 55000.0, packet, "")
	if failures.size() > 0:
		return

	var titan_nodes := [
		{"node_id":"hull", "kind":"hull", "definition_id":"outer_titan", "position":{"x":0.0, "y":0.0}},
		{"node_id":"weapon", "kind":"module", "definition_id":"plasma_cannon", "position":{"x":120.0, "y":0.0}},
		{"node_id":"shield", "kind":"module", "definition_id":"capital_shield", "position":{"x":120.0, "y":50.0}},
		{"node_id":"drive", "kind":"module", "definition_id":"advanced_drive", "position":{"x":120.0, "y":100.0}},
		{"node_id":"targeting", "kind":"module", "definition_id":"targeting_computer", "position":{"x":120.0, "y":150.0}},
		{"node_id":"survey", "kind":"module", "definition_id":"deep_survey_system", "position":{"x":120.0, "y":200.0}},
		{"node_id":"core", "kind":"module", "definition_id":"civilian_reactor_core", "position":{"x":120.0, "y":250.0}}
	]
	var titan_connections := [
		{"module_node_id":"weapon", "socket_id":"socket_weapon_0"},
		{"module_node_id":"shield", "socket_id":"socket_shield_0"},
		{"module_node_id":"drive", "socket_id":"socket_drive_0"},
		{"module_node_id":"targeting", "socket_id":"socket_utility_0"},
		{"module_node_id":"survey", "socket_id":"socket_utility_1"},
		{"module_node_id":"core", "socket_id":"socket_core_0"}
	]
	var titan_expected_modules := ["plasma_cannon", "capital_shield", "advanced_drive", "targeting_computer", "deep_survey_system", "civilian_reactor_core"]
	var titan_expected_costs := {"superalloy":18, "steel_composite":10, "antimatter_cell":3, "quantum_component":8, "titanium_alloy":2, "electronics":9, "data_core":2, "reactor_part":1, "iron_ingot":2, "copper_ingot":1}
	var titan_validation: Dictionary = game.ship_design_validation("construct_outer_titan", titan_nodes, titan_connections)
	var titan_summary: Dictionary = game.ship_design_engineering_summary("construct_outer_titan", titan_nodes, titan_connections)
	_check(bool(titan_validation.get("allowed", false)) and (titan_validation.get("modules", []) as Array) == titan_expected_modules and (titan_summary.get("construction_costs", {}) as Dictionary) == titan_expected_costs, "public Ship Design accepts the exact Deep Survey Titan graph and physical BOM; validation=%s summary=%s" % [JSON.stringify(titan_validation), JSON.stringify(titan_summary)])
	_stage_earth_manifest(titan_expected_costs, packet, "J10 canonical Deep Survey Titan Shipyard manifest")
	if failures.size() > 0:
		return
	var titan_save_start := observed_events.size()
	_check(bool(game.save_ship_design("", "Runtime Deep Survey Titan", "construct_outer_titan", titan_nodes, titan_connections)), "public Ship Design saves the exact Deep Survey Titan graph")
	var titan_save_event := _first_event(_events_after(titan_save_start), "ShipDesignSaved")
	var titan_design_id := str(titan_save_event.get("design_id", ""))
	_check(not titan_design_id.is_empty() and bool(game.enqueue_saved_ship_design(titan_design_id)), "public Shipyard queues the physically funded Deep Survey Titan")
	var titan_build_events := _advance(120000.0, "J10 exact one-hundred-segment Deep Survey Titan construction")
	var titan_completion := _first_event(titan_build_events, "ShipConstructionCompleted")
	var titan_cycles: Array = titan_build_events.filter(func(event_value): return str((event_value as Dictionary).get("type", "")) == "ShipbuildingCycleCompleted" and str((event_value as Dictionary).get("plan_id", "")) == "construct_outer_titan")
	_check(titan_cycles.size() == 100 and str(titan_completion.get("design_id", "")) == titan_design_id and (titan_completion.get("consumed", {}) as Dictionary) == titan_expected_costs and (titan_completion.get("module_ids", []) as Array) == titan_expected_modules, "Shipyard publishes the exact physical one-hundred-segment Deep Survey Titan completion; event=%s cycles=%d" % [JSON.stringify(titan_completion), titan_cycles.size()])
	var titan_candidates: Array = game.ship_design_refit_candidates(titan_design_id)
	if titan_candidates.size() != 1 or failures.size() > 0:
		_check(false, "public design query exposes exactly one constructed Deep Survey Titan; candidates=%s" % JSON.stringify(titan_candidates))
		return
	var titan_id := str(titan_candidates[0])
	var titan_formation_start := observed_events.size()
	_check(bool(game.create_fleet_formation("Deep Survey Titan Group")), "public Fleet command creates the Deep Survey Titan formation")
	var titan_formation_id := str(_first_event(_events_after(titan_formation_start), "FleetFormationCreated").get("formation_id", ""))
	_check(not titan_formation_id.is_empty() and bool(game.set_ship_formation_assignment(titan_id, titan_formation_id)), "public Fleet command assigns the exact Titan instance")
	if failures.size() > 0:
		return
	var deep_route_start := observed_events.size()
	var deep_dark_before := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("dark_matter", 0))
	_check(bool(game.start_expedition_route("deep_system_route", [titan_id], titan_formation_id)), "public Expedition command launches the exact Deep Survey Titan")
	var deep_route_events := _advance(180000.0, "J10 Deep-system route and final crisis")
	var deep_scoped := _events_after(deep_route_start)
	var deep_dark_after := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("dark_matter", 0))
	var deep_crisis_started := deep_scoped.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "CombatStarted" and str(event.get("enemy_id", "")) == "deep_crisis" and bool(event.get("boss", false))
	)
	var deep_crisis_defeated := deep_scoped.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "EnemyDefeated" and str(event.get("enemy_id", "")) == "deep_crisis" and bool(event.get("boss", false)) and bool((event.get("combat", {}) as Dictionary).get("victory", false))
	)
	_check(deep_crisis_started and deep_crisis_defeated and _ordered_types(["ExpeditionNodeCompleted", "ExpeditionNodeCompleted", "CombatStarted", "EnemyDefeated", "ExpeditionNodeCompleted", "ExpeditionRouteCompleted"], deep_route_events) and deep_scoped.any(func(event_value): return str((event_value as Dictionary).get("type", "")) == "ExpeditionRouteCompleted" and str((event_value as Dictionary).get("route_id", "")) == "deep_system_route") and deep_dark_after == deep_dark_before + 5, "J10 completes the exact victorious Deep crisis route and receives five physical dark matter; before=%d after=%d events=%s" % [deep_dark_before, deep_dark_after, JSON.stringify(deep_route_events)])
	if failures.size() > 0:
		return
	_stage_earth_manifest({"chemical_propellant":2, "repair_material":1, "industrial_machine_tools":1, "structural_frame":2, "electronics":2}, packet, "J10 Deep SURVEYED mission")
	var deep_availability: Dictionary = game.survey_mission_availability("deep_system", "SURVEYED", [titan_id], EARTH_LOCATION_ID)
	if not bool(deep_availability.get("allowed", false)):
		var only_repair_blocked := not (deep_availability.get("blockers", []) as Array).is_empty() and (deep_availability.get("blockers", []) as Array).all(func(blocker_value): return str((blocker_value as Dictionary).get("code", "")) == "SURVEY_VESSEL_UNAVAILABLE")
		_check(only_repair_blocked, "the fully staged Deep survey is blocked only by the exact post-crisis Titan readiness contract; availability=%s" % JSON.stringify(deep_availability))
		var repair_events := _advance(200000.0, "J10 bounded post-crisis Titan repair")
		var repaired_availability: Dictionary = game.survey_mission_availability("deep_system", "SURVEYED", [titan_id], EARTH_LOCATION_ID)
		_check(_events_have_type(repair_events, "ShipRepaired") and bool(repaired_availability.get("allowed", false)), "the public repair stream restores the Deep Survey Titan and reopens the already-funded industrial survey; before=%s after=%s" % [JSON.stringify(deep_availability), JSON.stringify(repaired_availability)])
	if failures.size() > 0:
		return
	_complete_public_survey("deep_system", "SURVEYED", titan_id, 60000.0, "J10 Deep industrial survey")
	_check(bool(game.initialize_surveyed_factory_world("deep_system")), "public Survey completion initializes the sparse Deep Factory workspace")
	var deep_world_ids: Array[String] = game.factory_world_ids_for_location("deep_system")
	var deep_world_id := str(deep_world_ids[0] if deep_world_ids.size() == 1 else "")
	var deep_snapshot := _snapshot(deep_world_id)
	var dark_field := _resource_field(deep_snapshot, "dark_matter")
	_check(deep_world_ids.size() == 1 and bool(deep_snapshot.get("valid", false)) and not dark_field.is_empty(), "the public Deep Factory snapshot exposes exactly the surveyed dark-matter field")
	if failures.size() > 0:
		return

	_check(bool(game.configure_logistics_service("outer_deep_freight", "general_cargo")), "public Logistics configures the Outer-Deep corridor")
	_transfer_earth_manifest_to_remote_factory("deep_system", deep_world_id, {"scrap_metal":8}, {"chemical_propellant":12, "repair_material":5}, packet, "J10 Deep four-solar power-base wave", "")
	var deep_solars: Array[String] = []
	for deep_solar_index in 4:
		var deep_solar := _queue_and_fund("grid_solar_array", "", _find_clear_factory_origin("grid_solar_array", deep_world_id), "J10 Deep solar array %d" % (deep_solar_index + 1), true, deep_world_id, "")
		deep_solars.append(str(deep_solar.get("entity_id", "")))
	var deep_power_events := _advance(120000.0, "J10 Deep four-solar power-base construction")
	_check(deep_solars.all(func(entity_id): return str(_entity(_snapshot(deep_world_id), str(entity_id)).get("definition_id", "")) == "grid_solar_array") and _events_have_type(deep_power_events, "FactoryConstructionCompleted"), "Factory physically completes all four Deep solar providers")
	_transfer_earth_manifest_to_remote_factory("deep_system", deep_world_id, {"superalloy":4, "quantum_component":3, "antimatter_cell":1}, {"chemical_propellant":12, "repair_material":5}, packet, "J10 Deep exotic-extractor wave", "")
	var dark_mine := _queue_and_fund("grid_exotic_extractor", "", dark_field.get("footprint", {}).get("origin", {}), "J10 Deep dark-matter extractor", true, deep_world_id, "")
	var dark_mine_id := str(dark_mine.get("entity_id", ""))
	var dark_extractor_events := _advance(120000.0, "J10 Deep dark-matter extractor construction")
	_check(str(_entity(_snapshot(deep_world_id), dark_mine_id).get("definition_id", "")) == "grid_exotic_extractor" and str(_entity(_snapshot(deep_world_id), dark_mine_id).get("resource_id", "")) == "dark_matter" and _events_have_type(dark_extractor_events, "FactoryConstructionCompleted"), "Factory physically completes the canonical two-solar Deep dark-matter extractor")
	_transfer_earth_manifest_to_remote_factory("deep_system", deep_world_id, {"superalloy":10, "quantum_component":8, "antimatter_cell":2}, {"chemical_propellant":12, "repair_material":5}, packet, "J10 Frontier Matterworks wave", "")
	var matterworks := _queue_and_fund("grid_frontier_matterworks", "", _find_clear_factory_origin("grid_frontier_matterworks", deep_world_id), "J10 Frontier Matterworks", true, deep_world_id, "")
	var matterworks_id := str(matterworks.get("entity_id", ""))
	var matterworks_events := _advance(180000.0, "J10 Frontier Matterworks construction")
	_check(str(_entity(_snapshot(deep_world_id), matterworks_id).get("definition_id", "")) == "grid_frontier_matterworks" and _events_have_type(matterworks_events, "FactoryConstructionCompleted"), "Factory physically completes the Frontier Matterworks")
	if failures.size() > 0:
		return
	_ensure_connection("POWER", deep_solars[2], matterworks_id, "", deep_world_id)
	_ensure_connection("POWER", deep_solars[3], matterworks_id, "", deep_world_id)
	var dark_before_snapshot := _snapshot(deep_world_id)
	var dark_storage_before := int((_entity(dark_before_snapshot, matterworks_id).get("inventory", {}) as Dictionary).get("dark_matter", 0))
	var dark_output_before := int((_entity(dark_before_snapshot, dark_mine_id).get("outputs", {}) as Dictionary).get("dark_matter", 0))
	var dark_event_start := observed_events.size()
	_extract_resource_batch(dark_mine_id, "dark_matter", deep_solars[0], matterworks_id, 2, "J10 exact Deep dark-matter separation", deep_world_id, [deep_solars[1]])
	var dark_events: Array = _events_after(dark_event_start).filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryResourceExtracted" and str(event.get("world_id", "")) == deep_world_id and str(event.get("entity_id", "")) == dark_mine_id and str(event.get("resource_id", "")) == "dark_matter" and str(event.get("activity_id", "")) == "separate_dark_matter"
	)
	var dark_scoped_quantity := 0
	for dark_event_value in dark_events:
		dark_scoped_quantity += int((dark_event_value as Dictionary).get("quantity", 0))
	var dark_after_snapshot := _snapshot(deep_world_id)
	var dark_storage_after := int((_entity(dark_after_snapshot, matterworks_id).get("inventory", {}) as Dictionary).get("dark_matter", 0))
	var dark_output_after := int((_entity(dark_after_snapshot, dark_mine_id).get("outputs", {}) as Dictionary).get("dark_matter", 0))
	_check(dark_scoped_quantity == 2 and dark_storage_after == dark_storage_before + 2 and dark_output_after == 0 and dark_storage_after + dark_output_after == dark_storage_before + dark_output_before + dark_scoped_quantity, "J10 proves exactly two units of public Deep separation activity and SPECIAL custody with no extractor residue; before_storage=%d before_output=%d scoped=%d after_storage=%d after_output=%d events=%s" % [dark_storage_before, dark_output_before, dark_scoped_quantity, dark_storage_after, dark_output_after, JSON.stringify(dark_events)])
	if failures.size() > 0:
		return
	_complete_stellar_energy_program(packet, titan_id)


func _stage_earth_manifest(manifest: Dictionary, packet: Dictionary, label: String) -> void:
	for item_value in manifest:
		var item_id := str(item_value)
		var target := int(manifest.get(item_id, 0))
		var location_quantity := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get(item_id, 0))
		var shortfall := maxi(0, target - location_quantity)
		if shortfall > 0:
			_ensure_local_factory_item(item_id, shortfall, packet, "%s %s" % [label, item_id])
		if failures.size() > 0:
			return
		_stage_location_shortfall_from_factory(item_id, target, label)


func _complete_exact_research(project_id: String, costs: Dictionary, duration_ms: float, packet: Dictionary, technology_id: String) -> void:
	_stage_earth_manifest(costs, packet, "J10 %s research manifest" % project_id)
	if failures.size() > 0:
		return
	var before_snapshot := _snapshot(EARTH_WORLD_ID)
	var before: Dictionary = (before_snapshot.get("location_available_inventory", {}) as Dictionary).duplicate(true)
	var before_physical: Dictionary = (before_snapshot.get("location_inventory", {}) as Dictionary).duplicate(true)
	var event_start := observed_events.size()
	_check(bool(game.start_research_project(project_id)), "public Research starts %s from exact Factory-backed Location custody" % project_id)
	var after_start_snapshot := _snapshot(EARTH_WORLD_ID)
	var after_start: Dictionary = after_start_snapshot.get("location_available_inventory", {})
	var after_start_physical: Dictionary = after_start_snapshot.get("location_inventory", {})
	var exact_reservation := true
	for item_value in costs:
		var item_id := str(item_value)
		exact_reservation = exact_reservation and int(after_start.get(item_id, 0)) == int(before.get(item_id, 0)) - int(costs.get(item_id, 0)) and int(after_start_physical.get(item_id, 0)) == int(before_physical.get(item_id, 0))
	var events := _advance(duration_ms, "J10 %s research" % project_id)
	var completion := _first_event(_events_after(event_start), "ResearchCompleted")
	var after_completion_physical: Dictionary = _snapshot(EARTH_WORLD_ID).get("location_inventory", {})
	var physical_costs_settled := true
	for item_value in costs:
		var item_id := str(item_value)
		physical_costs_settled = physical_costs_settled and int(after_completion_physical.get(item_id, 0)) <= int(before_physical.get(item_id, 0)) - int(costs.get(item_id, 0))
	var technology_matches := technology_id.is_empty() or str(completion.get("technology_id", "")) == technology_id
	_check(exact_reservation and physical_costs_settled and str(completion.get("project_id", "")) == project_id and technology_matches and _events_have_type(events, "ResearchCompleted"), "J10 reserves %s exactly at start, settles at least its full physical costs during progress, and publishes canonical completion; completion=%s before_available=%s after_start_available=%s before_physical=%s after_start_physical=%s after_completion_physical=%s" % [project_id, JSON.stringify(completion), JSON.stringify(before), JSON.stringify(after_start), JSON.stringify(before_physical), JSON.stringify(after_start_physical), JSON.stringify(after_completion_physical)])


func _construct_earth_adapter(definition_id: String, costs: Dictionary, packet: Dictionary, label: String, initial_recipe_id: String = "") -> String:
	_stage_earth_manifest(costs, packet, "%s construction manifest" % label)
	if failures.size() > 0:
		return ""
	var construction := _queue_and_fund(definition_id, initial_recipe_id, _find_clear_factory_origin(definition_id, EARTH_WORLD_ID), label, true, EARTH_WORLD_ID, "")
	var entity_id := str(construction.get("entity_id", ""))
	var events := _advance(180000.0, "%s physical construction" % label)
	_check(not entity_id.is_empty() and str(_entity(_snapshot(EARTH_WORLD_ID), entity_id).get("definition_id", "")) == definition_id and events.any(func(event_value): return str((event_value as Dictionary).get("type", "")) == "FactoryConstructionCompleted" and str((event_value as Dictionary).get("entity_id", "")) == entity_id), "%s completes through exact public funding and time advancement; events=%s" % [label, JSON.stringify(events)])
	return entity_id


func _complete_public_survey(location_id: String, target_state: String, ship_id: String, duration_ms: float, label: String) -> void:
	var availability: Dictionary = game.survey_mission_availability(location_id, target_state, [ship_id], EARTH_LOCATION_ID)
	_check(bool(availability.get("allowed", false)), "%s is publicly available with its staged physical package; blockers=%s" % [label, JSON.stringify(availability.get("blockers", []))])
	if failures.size() > 0:
		return
	var event_start := observed_events.size()
	_check(bool(game.start_survey_mission(location_id, target_state, [ship_id], EARTH_LOCATION_ID)), "public Survey starts %s" % label)
	var events := _advance(duration_ms, label)
	var completion := _first_event(_events_after(event_start), "SurveyMissionCompleted")
	_check(str(completion.get("target", "")) == location_id and str(completion.get("survey_state", "")) == target_state and _ordered_types(["SurveyMissionStarted", "SurveyMissionCompleted"], _events_after(event_start)), "%s reaches the exact target state; completion=%s events=%s" % [label, JSON.stringify(completion), JSON.stringify(events)])


func _transfer_earth_manifest_to_remote_factory(remote_location_id: String, remote_world_id: String, manifest: Dictionary, path_costs: Dictionary, packet: Dictionary, label: String, remote_storage_id: String) -> void:
	var shipment_count := manifest.keys().filter(func(item_value): return int(manifest.get(str(item_value), 0)) > 0).size()
	var source_targets: Dictionary = manifest.duplicate(true)
	source_targets["chemical_propellant"] = int(source_targets.get("chemical_propellant", 0)) + shipment_count * int(path_costs.get("chemical_propellant", 0))
	for item_value in source_targets:
		var item_id := str(item_value)
		if item_id == "repair_material":
			continue
		var required_at_location := int(source_targets.get(item_id, 0))
		var available_at_location := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get(item_id, 0))
		_ensure_local_factory_item(item_id, maxi(0, required_at_location - available_at_location), packet, "%s Earth source reserve" % label)
		if failures.size() > 0:
			return
	# Repair fabrication consumes two iron and one copper per cycle.  Close those
	# physical precursors before the freight helper evaluates its fresh recovery
	# projection, retaining a small rolling buffer for the next bounded shipment.
	var repair_operating_spend := shipment_count * int(path_costs.get("repair_material", 0))
	var repair_payload := int(manifest.get("repair_material", 0))
	var repair_target := repair_payload + int((game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", repair_operating_spend, 5000.0) as Dictionary).get("gross_production_target", 0))
	var repair_total := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
	for repair_entity_value in _snapshot(EARTH_WORLD_ID).get("entities", []):
		repair_total += int((((repair_entity_value as Dictionary).get("inventory", {}) as Dictionary).get("repair_material", 0)))
	var repair_shortfall := maxi(0, repair_target - repair_total)
	if repair_shortfall > 0:
		var rolling_repair_cycles := repair_shortfall + 8
		_ensure_local_factory_item("iron_ingot", rolling_repair_cycles * 2, packet, "%s rolling repair iron precursor" % label)
		_ensure_local_factory_item("copper_ingot", rolling_repair_cycles, packet, "%s rolling repair copper precursor" % label)
		if failures.size() > 0:
			return
	var result := _freight_earth_manifest_to_remote(remote_location_id, remote_world_id, manifest, label, path_costs, _earth_freight_recovery_packet(packet))
	packet["engineering_machine_id"] = str(result.get("repair_works_id", packet.get("engineering_machine_id", "")))
	if result.is_empty() or failures.size() > 0:
		return
	if remote_storage_id.is_empty():
		return
	for item_value in manifest:
		var item_id := str(item_value)
		_import_from_location(item_id, int(manifest.get(item_id, 0)), remote_storage_id, "%s Factory custody" % label, remote_world_id)


func _return_lunar_titanium_to_earth(quantity: int, packet: Dictionary, label: String) -> void:
	var lunar_world_id := str(packet.get("lunar_world_id", ""))
	var lunar_storage_id := str(packet.get("lunar_storage_id", ""))
	var chunk_count := ceili(float(quantity) / 8.0)
	for chunk_index in range(chunk_count):
		var chunk := mini(8, quantity - chunk_index * 8)
		_transfer_earth_manifest_to_remote_factory("lunar_space", lunar_world_id, {"iron_ingot":chunk}, {"chemical_propellant":1, "repair_material":1}, packet, "%s iron batch %d/%d" % [label, chunk_index + 1, chunk_count], lunar_storage_id)
		_extract_resource_batch(str(packet.get("lunar_titanium_extractor_id", "")), "titanium_ore", str(packet.get("lunar_power_id", "")), lunar_storage_id, chunk * 2, "%s ore batch %d/%d" % [label, chunk_index + 1, chunk_count], lunar_world_id)
		_run_exact_recipe_batches(str(packet.get("lunar_titanium_foundry_id", "")), "grid_refine_titanium", str(packet.get("lunar_power_id", "")), lunar_storage_id, "titanium_alloy", chunk, chunk, "%s alloy batch %d/%d" % [label, chunk_index + 1, chunk_count], "", lunar_world_id)
		_transfer_earth_manifest_to_remote_factory("lunar_space", lunar_world_id, {"chemical_propellant":1, "repair_material":1}, {"chemical_propellant":1, "repair_material":1}, packet, "%s return reserve %d/%d" % [label, chunk_index + 1, chunk_count], "")
		_export_to_location("titanium_alloy", chunk, "%s source cargo %d/%d" % [label, chunk_index + 1, chunk_count], lunar_world_id, lunar_storage_id)
		var returned := _freight_location_cargo("lunar_space", lunar_world_id, EARTH_LOCATION_ID, EARTH_WORLD_ID, "titanium_alloy", chunk, {"chemical_propellant":1, "repair_material":1}, "%s public return %d/%d" % [label, chunk_index + 1, chunk_count])
		if returned.is_empty() or failures.size() > 0:
			return
		_import_from_location("titanium_alloy", chunk, str(packet.get("storage_id", "")), "%s Earth Factory custody %d/%d" % [label, chunk_index + 1, chunk_count])


func _move_lunar_titanium_to_jovian(quantity: int, packet: Dictionary, label: String) -> void:
	var lunar_world_id := str(packet.get("lunar_world_id", ""))
	var lunar_storage_id := str(packet.get("lunar_storage_id", ""))
	var jovian_world_id := str(packet.get("jovian_world_id", ""))
	var jovian_storage_id := str(packet.get("jovian_storage_id", ""))
	var chunk_count := ceili(float(quantity) / 8.0)
	for chunk_index in range(chunk_count):
		var chunk := mini(8, quantity - chunk_index * 8)
		_transfer_earth_manifest_to_remote_factory("lunar_space", lunar_world_id, {"iron_ingot":chunk}, {"chemical_propellant":1, "repair_material":1}, packet, "%s iron batch %d/%d" % [label, chunk_index + 1, chunk_count], lunar_storage_id)
		_extract_resource_batch(str(packet.get("lunar_titanium_extractor_id", "")), "titanium_ore", str(packet.get("lunar_power_id", "")), lunar_storage_id, chunk * 2, "%s ore batch %d/%d" % [label, chunk_index + 1, chunk_count], lunar_world_id)
		_run_exact_recipe_batches(str(packet.get("lunar_titanium_foundry_id", "")), "grid_refine_titanium", str(packet.get("lunar_power_id", "")), lunar_storage_id, "titanium_alloy", chunk, chunk, "%s alloy batch %d/%d" % [label, chunk_index + 1, chunk_count], "", lunar_world_id)
		_transfer_earth_manifest_to_remote_factory("lunar_space", lunar_world_id, {"chemical_propellant":4, "repair_material":2}, {"chemical_propellant":1, "repair_material":1}, packet, "%s Jovian reserve %d/%d" % [label, chunk_index + 1, chunk_count], "")
		_export_to_location("titanium_alloy", chunk, "%s source cargo %d/%d" % [label, chunk_index + 1, chunk_count], lunar_world_id, lunar_storage_id)
		var moved := _freight_location_cargo("lunar_space", lunar_world_id, "gas_giant_region", jovian_world_id, "titanium_alloy", chunk, {"chemical_propellant":4, "repair_material":2}, "%s public Jovian transfer %d/%d" % [label, chunk_index + 1, chunk_count])
		if moved.is_empty() or failures.size() > 0:
			return
		_import_from_location("titanium_alloy", chunk, jovian_storage_id, "%s Jovian Factory custody %d/%d" % [label, chunk_index + 1, chunk_count], jovian_world_id)


func _move_asteroid_cobalt_ore_to_jovian(quantity: int, packet: Dictionary, label: String) -> void:
	var asteroid_world_id := str(packet.get("asteroid_world_id", ""))
	var asteroid_storage_id := str(packet.get("asteroid_storage_id", ""))
	var jovian_world_id := str(packet.get("jovian_world_id", ""))
	var jovian_storage_id := str(packet.get("jovian_storage_id", ""))
	var chunk_count := ceili(float(quantity) / 8.0)
	for chunk_index in range(chunk_count):
		var chunk := mini(8, quantity - chunk_index * 8)
		_extract_resource_batch(str(packet.get("asteroid_cobalt_extractor_id", "")), "cobalt_ore", str(packet.get("asteroid_power_id", "")), asteroid_storage_id, chunk, "%s extraction %d/%d" % [label, chunk_index + 1, chunk_count], asteroid_world_id)
		_transfer_earth_manifest_to_remote_factory("asteroid_belt", asteroid_world_id, {"chemical_propellant":2, "repair_material":1}, {"chemical_propellant":3, "repair_material":2}, packet, "%s Jovian reserve %d/%d" % [label, chunk_index + 1, chunk_count], "")
		_export_to_location("cobalt_ore", chunk, "%s source cargo %d/%d" % [label, chunk_index + 1, chunk_count], asteroid_world_id, asteroid_storage_id)
		var moved := _freight_location_cargo("asteroid_belt", asteroid_world_id, "gas_giant_region", jovian_world_id, "cobalt_ore", chunk, {"chemical_propellant":2, "repair_material":1}, "%s public Jovian transfer %d/%d" % [label, chunk_index + 1, chunk_count])
		if moved.is_empty() or failures.size() > 0:
			return
		_import_from_location("cobalt_ore", chunk, jovian_storage_id, "%s Jovian Factory custody %d/%d" % [label, chunk_index + 1, chunk_count], jovian_world_id)


func _produce_jovian_superalloy_to_earth(quantity: int, packet: Dictionary, label: String) -> void:
	var jovian_world_id := str(packet.get("jovian_world_id", ""))
	var jovian_storage_id := str(packet.get("jovian_storage_id", ""))
	var chunk_count := ceili(float(quantity) / 8.0)
	for chunk_index in range(chunk_count):
		var chunk := mini(8, quantity - chunk_index * 8)
		_move_lunar_titanium_to_jovian(chunk, packet, "%s titanium %d/%d" % [label, chunk_index + 1, chunk_count])
		_move_asteroid_cobalt_ore_to_jovian(chunk * 4, packet, "%s cobalt %d/%d" % [label, chunk_index + 1, chunk_count])
		_run_exact_recipe_batches(str(packet.get("jovian_smelter_id", "")), "grid_refine_cobalt", str(packet.get("jovian_power_id", "")), jovian_storage_id, "cobalt_ingot", chunk * 2, mini(16, chunk * 2), "%s cobalt refinement %d/%d" % [label, chunk_index + 1, chunk_count], jovian_storage_id, jovian_world_id)
		_recycle_jovian_cobalt_waste(packet, "%s cobalt-waste recovery %d/%d" % [label, chunk_index + 1, chunk_count])
		_extract_resource_batch(str(packet.get("jovian_methane_extractor_id", "")), "methane", str(packet.get("jovian_power_id", "")), str(packet.get("jovian_fluid_storage_id", "")), chunk, "%s methane extraction %d/%d" % [label, chunk_index + 1, chunk_count], jovian_world_id)
		_run_exact_recipe_batches(str(packet.get("jovian_smelter_id", "")), "grid_refine_superalloy", str(packet.get("jovian_power_id", "")), jovian_storage_id, "superalloy", chunk, chunk, "%s superalloy refinement %d/%d" % [label, chunk_index + 1, chunk_count], "", jovian_world_id, {"methane":str(packet.get("jovian_fluid_storage_id", ""))})
		_transfer_earth_manifest_to_remote_factory("gas_giant_region", jovian_world_id, {"chemical_propellant":5, "repair_material":3}, {"chemical_propellant":5, "repair_material":3}, packet, "%s return reserve %d/%d" % [label, chunk_index + 1, chunk_count], "")
		_export_to_location("superalloy", chunk, "%s source cargo %d/%d" % [label, chunk_index + 1, chunk_count], jovian_world_id, jovian_storage_id)
		var returned := _freight_location_cargo("gas_giant_region", jovian_world_id, EARTH_LOCATION_ID, EARTH_WORLD_ID, "superalloy", chunk, {"chemical_propellant":5, "repair_material":3}, "%s public Earth return %d/%d" % [label, chunk_index + 1, chunk_count])
		if returned.is_empty() or failures.size() > 0:
			return
		_import_from_location("superalloy", chunk, str(packet.get("storage_id", "")), "%s Earth Factory custody %d/%d" % [label, chunk_index + 1, chunk_count])


func _find_clear_factory_origin(definition_id: String, world_id: String) -> Dictionary:
	var snapshot := _snapshot(world_id)
	var definition := {}
	for definition_value in (snapshot.get("palette", {}) as Dictionary).get("buildings", []):
		var candidate := definition_value as Dictionary
		if str(candidate.get("id", "")) == definition_id:
			definition = candidate
			break
	var width := int((definition.get("footprint", {}) as Dictionary).get("width", 1))
	var height := int((definition.get("footprint", {}) as Dictionary).get("height", 1))
	var bounds_size: Dictionary = (snapshot.get("bounds", {}) as Dictionary).get("size", {})
	var maximum_x := int(bounds_size.get("x", 512)) - width
	var maximum_y := int(bounds_size.get("y", 512)) - height
	for y in range(0, maximum_y + 1, 4):
		for x in range(0, maximum_x + 1, 4):
			var clear := true
			for collection_id in ["entities", "construction_orders", "resource_fields"]:
				for occupant_value in snapshot.get(collection_id, []):
					var occupant := occupant_value as Dictionary
					var footprint: Dictionary = occupant.get("footprint", {})
					var origin: Dictionary = footprint.get("origin", {})
					var size: Dictionary = footprint.get("size", {})
					if x < int(origin.get("x", 0)) + int(size.get("x", 0)) and int(origin.get("x", 0)) < x + width and y < int(origin.get("y", 0)) + int(size.get("y", 0)) and int(origin.get("y", 0)) < y + height:
						clear = false
						break
				if not clear:
					break
			if clear:
				return {"x":x, "y":y}
	_check(false, "public Factory snapshot exposes a clear footprint for %s in %s" % [definition_id, world_id])
	return {}


func _complete_stellar_energy_program(packet: Dictionary, titan_id: String) -> void:
	# Lagrange is a normal three-step survey target.  The Titan's explicit Deep
	# Survey module is the public capability source for the terminal step.
	_stage_earth_manifest({"chemical_propellant":1}, packet, "J10 Lagrange DETECTED mission")
	_complete_public_survey("earth_sun_lagrange", "DETECTED", titan_id, 20000.0, "J10 Lagrange detection survey")
	_stage_earth_manifest({"chemical_propellant":2, "repair_material":1, "industrial_machine_tools":1, "structural_frame":2, "electronics":2}, packet, "J10 Lagrange SURVEYED mission")
	_complete_public_survey("earth_sun_lagrange", "SURVEYED", titan_id, 40000.0, "J10 Lagrange industrial survey")
	_stage_earth_manifest({"chemical_propellant":4, "repair_material":2, "electronics":1}, packet, "J10 Lagrange DEEP_SURVEYED mission")
	_complete_public_survey("earth_sun_lagrange", "DEEP_SURVEYED", titan_id, 60000.0, "J10 Lagrange deep survey")
	if failures.size() > 0:
		return
	_check(bool(game.initialize_surveyed_factory_world("earth_sun_lagrange")), "public deep survey initializes the sparse Lagrange Factory workspace")
	var lagrange_world_ids: Array[String] = game.factory_world_ids_for_location("earth_sun_lagrange")
	var lagrange_world_id := str(lagrange_world_ids[0] if lagrange_world_ids.size() == 1 else "")
	_check(lagrange_world_ids.size() == 1 and bool(_snapshot(lagrange_world_id).get("valid", false)), "the public Factory-world query exposes exactly one Lagrange workspace")
	_check(bool(game.configure_logistics_service("earth_lagrange_freight", "general_cargo")), "public Logistics configures the Earth-Lagrange construction corridor")
	if failures.size() > 0:
		return

	# Research Complex II is a physical application adapter, not a synthetic
	# capacity flag.  Keep the Energy Array connected throughout the staged
	# program so capacity, advanced power and cooling remain observable.
	var research_complex_costs := {"steel_composite":5, "quantum_component":4, "data_core":4}
	_prepare_external_for_manifest(research_complex_costs, packet, "J10 Research Complex II external closure")
	var research_complex_ii_id := _construct_earth_adapter("grid_research_complex_ii", research_complex_costs, packet, "J10 Research Complex II")
	_ensure_connection("POWER", str(packet.get("power_source_id", "")), research_complex_ii_id, "")
	_ensure_connection("POWER", str(packet.get("power_source_id", "")), str(packet.get("assembly_array_id", "")), "")
	if failures.size() > 0:
		return

	var research_stages := [
		{"id":"theory_site", "costs":{"data_core":2, "electronics":4}, "work_required":18000},
		{"id":"materials", "costs":{"superalloy":8, "superconducting_coil":6, "radiation_hardened_electronics":4}, "work_required":22000},
		{"id":"thermal_routing", "costs":{"dark_matter":2, "power_bus_component":6, "fusion_service_component":4}, "work_required":24000},
		{"id":"collector_prototype", "costs":{"project_core":2, "quantum_component":8, "precision_actuator":6}, "work_required":18000},
		{"id":"industrial_release", "costs":{"data_core":4, "industrial_machine_tools":4}, "work_required":18000}
	]
	for research_stage_index in research_stages.size():
		var stage := research_stages[research_stage_index] as Dictionary
		var stage_costs: Dictionary = stage.get("costs", {})
		if research_stage_index == 2:
			var route_dark_custody := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("dark_matter", 0))
			_check(route_dark_custody >= 2, "the thermal-routing stage consumes the Deep-route dark-matter reward from explicit Earth Location custody rather than assuming remote Factory output was recovered; available=%d" % route_dark_custody)
		_prepare_external_for_manifest(stage_costs, packet, "J10 Megastructure research stage %s" % str(stage.get("id", "")))
		_stage_earth_manifest(stage_costs, packet, "J10 Megastructure research stage %s" % str(stage.get("id", "")))
		if failures.size() > 0:
			return
		var stage_event_start := observed_events.size()
		if research_stage_index == 0:
			_check(bool(game.start_research_project("research_megastructures")), "public Research starts the staged Stellar Energy program")
		var runtime_before: Dictionary = game.research_runtime_snapshot()
		_check(str(runtime_before.get("project_id", "")) == "research_megastructures" and str(runtime_before.get("stage_id", "")) == str(stage.get("id", "")) and int(stage.get("work_required", 0)) > 0, "public research runtime exposes exact active Megastructure stage %s and its canonical finite work; runtime=%s" % [str(stage.get("id", "")), JSON.stringify(runtime_before)])
		var stage_events: Array = []
		var stage_boundary_seen := false
		# Public research throughput changes with powered capacity.  Poll in at most
		# 120 one-second slices instead of assuming a stale wall-clock duration.
		for research_slice in range(120):
			var slice_events := _advance(1000.0, "J10 Megastructure research stage %s slice %d/120" % [str(stage.get("id", "")), research_slice + 1])
			stage_events.append_array(slice_events)
			if research_stage_index < research_stages.size() - 1:
				stage_boundary_seen = stage_events.any(func(event_value): return str((event_value as Dictionary).get("type", "")) == "ResearchStageCompleted" and str((event_value as Dictionary).get("stage_id", "")) == str(stage.get("id", "")))
			else:
				stage_boundary_seen = stage_events.any(func(event_value): return str((event_value as Dictionary).get("type", "")) == "ResearchCompleted" and str((event_value as Dictionary).get("project_id", "")) == "research_megastructures")
			if stage_boundary_seen:
				break
		var scoped := _events_after(stage_event_start)
		if research_stage_index < research_stages.size() - 1:
			_check(stage_boundary_seen and scoped.any(func(event_value): return str((event_value as Dictionary).get("type", "")) == "ResearchStageCompleted" and str((event_value as Dictionary).get("stage_id", "")) == str(stage.get("id", ""))), "Megastructure research completes exact stage %s within its bounded public polling window; events=%s" % [str(stage.get("id", "")), JSON.stringify(stage_events)])
		else:
			var completion := _first_event(scoped, "ResearchCompleted")
			_check(stage_boundary_seen and str(completion.get("project_id", "")) == "research_megastructures" and str(completion.get("technology_id", "")) == "megastructure_engineering", "Megastructure research publishes its exact terminal technology within the bounded public polling window; completion=%s events=%s" % [JSON.stringify(completion), JSON.stringify(stage_events)])
		if failures.size() > 0:
			return

	# The first physical depot is funded directly from finite Location staging;
	# later phase manifests are imported immediately into class-specific Factory
	# custody so no surveyed Location capacity is bypassed.
	_transfer_earth_manifest_to_remote_factory("earth_sun_lagrange", lagrange_world_id, {"iron_ingot":10}, {"chemical_propellant":1, "repair_material":1}, packet, "J10 Lagrange Bulk-depot wave", "")
	var lagrange_bulk := _queue_and_fund("grid_bulk_depot", "", _find_clear_factory_origin("grid_bulk_depot", lagrange_world_id), "J10 Lagrange Bulk depot", true, lagrange_world_id, "")
	var lagrange_bulk_id := str(lagrange_bulk.get("entity_id", ""))
	_advance(90000.0, "J10 Lagrange Bulk-depot construction")
	_transfer_earth_manifest_to_remote_factory("earth_sun_lagrange", lagrange_world_id, {"steel_composite":4, "electronics":4}, {"chemical_propellant":1, "repair_material":1}, packet, "J10 Lagrange Component-depot wave", "")
	var lagrange_component := _queue_and_fund("grid_component_depot", "", _find_clear_factory_origin("grid_component_depot", lagrange_world_id), "J10 Lagrange Component depot", true, lagrange_world_id, "")
	var lagrange_component_id := str(lagrange_component.get("entity_id", ""))
	_advance(90000.0, "J10 Lagrange Component-depot construction")
	_prepare_external_for_manifest({"superalloy":4, "quantum_component":4}, packet, "J10 Lagrange Special-vault external closure")
	_transfer_earth_manifest_to_remote_factory("earth_sun_lagrange", lagrange_world_id, {"superalloy":4, "quantum_component":4}, {"chemical_propellant":1, "repair_material":1}, packet, "J10 Lagrange Special-vault wave", "")
	var lagrange_special := _queue_and_fund("grid_special_vault", "", _find_clear_factory_origin("grid_special_vault", lagrange_world_id), "J10 Lagrange Special vault", true, lagrange_world_id, "")
	var lagrange_special_id := str(lagrange_special.get("entity_id", ""))
	var lagrange_depot_events := _advance(120000.0, "J10 Lagrange Special-vault construction")
	_check(str(_entity(_snapshot(lagrange_world_id), lagrange_bulk_id).get("definition_id", "")) == "grid_bulk_depot" and str(_entity(_snapshot(lagrange_world_id), lagrange_component_id).get("definition_id", "")) == "grid_component_depot" and str(_entity(_snapshot(lagrange_world_id), lagrange_special_id).get("definition_id", "")) == "grid_special_vault" and _events_have_type(lagrange_depot_events, "FactoryConstructionCompleted"), "Factory completes all three explicit Lagrange material-custody depots")
	if failures.size() > 0:
		return

	var selection_start := observed_events.size()
	_check(bool(game.select_megastructure_site("stellar_energy", "earth_sun_lagrange")), "public Megastructure command commits the deeply surveyed Lagrange site")
	var selected: Dictionary = game.megastructure_runtime_snapshot("stellar_energy")
	_check(bool(selected.get("selected", false)) and str(selected.get("site_location_id", "")) == "earth_sun_lagrange" and int(selected.get("phase_index", 0)) == 1 and str(selected.get("phase_id", "")) == "stellar_forward_base" and int(selected.get("phase_history_count", 0)) == 1 and _events_after(selection_start).any(func(event_value): return str((event_value as Dictionary).get("type", "")) == "MegastructureSiteSelected"), "public Megastructure snapshot records the exact Phase-one Lagrange selection state; snapshot=%s" % JSON.stringify(selected))
	if failures.size() > 0:
		return

	var phases := [
		{"id":"stellar_forward_base", "activity_id":"construct_stellar_forward_base", "duration_ms":180000.0, "costs":{"industrial_machine_tools":20, "heavy_structural_section":20, "logistics_handling_equipment":12, "power_bus_component":8, "electronics":20}},
		{"id":"stellar_anchorage", "activity_id":"construct_stellar_anchorage", "duration_ms":220000.0, "costs":{"steel_composite":80, "heavy_structural_section":40, "construction_robotics":10, "industrial_machine_tools":16}},
		{"id":"stellar_primary_frame", "activity_id":"construct_stellar_primary_frame", "duration_ms":260000.0, "costs":{"steel_composite":240, "superalloy":60, "heavy_structural_section":120, "logistics_handling_equipment":20, "construction_robotics":20}},
		{"id":"stellar_energy_backbone", "activity_id":"construct_stellar_energy_backbone", "duration_ms":280000.0, "costs":{"superalloy":120, "superconducting_coil":80, "power_bus_component":60, "thermal_exchange_unit":30}},
		{"id":"stellar_collector_systems", "activity_id":"install_stellar_collector_systems", "duration_ms":300000.0, "costs":{"project_core":12, "precision_actuator":30, "automated_control_core":24, "quantum_component":50, "antimatter_cell":20}},
		{"id":"stellar_grid_integration", "activity_id":"integrate_stellar_grid", "duration_ms":320000.0, "costs":{"electronics":100, "radiation_hardened_electronics":50, "thermal_exchange_unit":20, "repair_material":80, "project_core":5}},
		{"id":"stellar_commissioning", "activity_id":"commission_stellar_energy", "duration_ms":360000.0, "costs":{"project_core":5, "automated_control_core":10, "power_bus_component":20, "fusion_service_component":30, "repair_material":100}}
	]
	var service_ids := {}
	for phase_offset in phases.size():
		var phase := phases[phase_offset] as Dictionary
		var phase_index := phase_offset + 1
		var phase_costs: Dictionary = phase.get("costs", {})
		var factory_stage_costs: Dictionary = phase_costs.duplicate(true)
		if phase_index == 1:
			# Deliberately leave the first phase one electronics short.  The rejected
			# public command must not consume any Location or Factory custody.  The
			# final unit then remains at Location, proving mixed-source settlement.
			factory_stage_costs["electronics"] = int(phase_costs.get("electronics", 0)) - 1
		elif phase_index == 7:
			# Commissioning repair cargo must remain in Location custody so the same
			# physical stock can cover continuous O&M after the phase starts.
			factory_stage_costs.erase("repair_material")
		_stage_lagrange_manifest(factory_stage_costs, packet, lagrange_world_id, lagrange_bulk_id, lagrange_component_id, lagrange_special_id, "J10 %s" % str(phase.get("id", "")))
		if failures.size() > 0:
			return
		if phase_index == 1:
			var rejection_before := _snapshot(lagrange_world_id)
			var rejection_event_count := observed_events.size()
			var rejected_for_shortfall: bool = game.start_megastructure_phase("stellar_energy", 100)
			var rejection_after := _snapshot(lagrange_world_id)
			var shortfall_blocker: Dictionary = game.megastructure_runtime_snapshot("stellar_energy").get("phase_start_blocker", {})
			var rejection_no_loss := observed_events.size() == rejection_event_count
			for cost_item_value in phase_costs:
				var cost_item_id := str(cost_item_value)
				rejection_no_loss = rejection_no_loss and _site_item_custody_quantity(rejection_before, cost_item_id) == _site_item_custody_quantity(rejection_after, cost_item_id)
			_check(not rejected_for_shortfall and str(shortfall_blocker.get("primary_reason", "")) == "INPUT_SHORTAGE" and str(shortfall_blocker.get("item_id", "")) == "electronics" and int(shortfall_blocker.get("required", 0)) == 20 and int(shortfall_blocker.get("available", 0)) == 19 and rejection_no_loss, "Phase one rejects an exact one-unit electronics shortfall without cargo loss or domain events; blocker=%s" % JSON.stringify(shortfall_blocker))
			_stage_lagrange_location_manifest({"electronics":1}, packet, lagrange_world_id, "J10 Phase-one mixed-custody electronics remainder")
		if phase_index == 4:
			var rejected: bool = game.start_megastructure_phase("stellar_energy", 100)
			var service_runtime: Dictionary = game.megastructure_runtime_snapshot("stellar_energy")
			var service_blocker: Dictionary = service_runtime.get("phase_start_blocker", {})
			_check(not rejected and str(service_runtime.get("gameplay_state", "")) == "WAITING_SITE_SERVICE" and str(service_runtime.get("phase_id", "")) == "stellar_energy_backbone" and not service_blocker.is_empty() and str(service_blocker.get("primary_reason", "")) in ["POWER_SHORTAGE", "COOLING_SHORTAGE"], "Phase four fails closed in the exact public WAITING_SITE_SERVICE state before physical power/cooling adapters are linked; runtime=%s" % JSON.stringify(service_runtime))
			service_ids = _build_lagrange_services(packet, lagrange_world_id)
		if phase_index == 7:
			var rejected_for_maintenance: bool = game.start_megastructure_phase("stellar_energy", 100)
			var maintenance_runtime: Dictionary = game.megastructure_runtime_snapshot("stellar_energy")
			var maintenance_blocker: Dictionary = maintenance_runtime.get("phase_start_blocker", {})
			_check(not rejected_for_maintenance and str(maintenance_runtime.get("gameplay_state", "")) == "WAITING_SITE_SERVICE" and str(maintenance_runtime.get("phase_id", "")) == "stellar_commissioning" and str(maintenance_blocker.get("primary_reason", "")) == "MAINTENANCE_SHORTAGE", "Commissioning fails closed in the exact public WAITING_SITE_SERVICE state before a Repair Dock exists; runtime=%s" % JSON.stringify(maintenance_runtime))
			var repair_id := _build_lagrange_repair_service(packet, lagrange_world_id, str(service_ids.get("power_id", "")))
			service_ids["repair_id"] = repair_id
			# Include bounded fabrication/freight lead time as well as the 360-second
			# commissioning window.  One projected hour is finite and comfortably
			# covers the five capacity-safe repair shipments below.
			var repair_recovery: Dictionary = game.maintenance_recovery_snapshot("earth_sun_lagrange", "repair_material", int(phase_costs.get("repair_material", 0)), 3600000.0)
			var electronics_recovery: Dictionary = game.maintenance_recovery_snapshot("earth_sun_lagrange", "electronics", 1, 3600000.0)
			_stage_lagrange_location_manifest({"repair_material":maxi(101, int(repair_recovery.get("gross_production_target", phase_costs.get("repair_material", 0)))), "electronics":maxi(1, int(electronics_recovery.get("gross_production_target", 1)))}, packet, lagrange_world_id, "J10 commissioning Location O&M reserve")
			# The first reserve covers a deliberately conservative hour.  Re-project in
			# two finite passes after its own shipment window so a future O&M-rate change
			# cannot consume the hundred phase units before the start boundary.
			for commissioning_recovery_pass in range(2):
				var current_location: Dictionary = _snapshot(lagrange_world_id).get("location_available_inventory", {})
				var fresh_repair: Dictionary = game.maintenance_recovery_snapshot("earth_sun_lagrange", "repair_material", int(phase_costs.get("repair_material", 0)), 360000.0)
				var fresh_electronics: Dictionary = game.maintenance_recovery_snapshot("earth_sun_lagrange", "electronics", 1, 360000.0)
				var top_up := {}
				var fresh_repair_target := maxi(101, int(fresh_repair.get("gross_production_target", phase_costs.get("repair_material", 0))))
				var fresh_electronics_target := maxi(1, int(fresh_electronics.get("gross_production_target", 1)))
				if int(current_location.get("repair_material", 0)) < fresh_repair_target:
					top_up["repair_material"] = fresh_repair_target - int(current_location.get("repair_material", 0))
				if int(current_location.get("electronics", 0)) < fresh_electronics_target:
					top_up["electronics"] = fresh_electronics_target - int(current_location.get("electronics", 0))
				if top_up.is_empty():
					break
				_stage_lagrange_location_manifest(top_up, packet, lagrange_world_id, "J10 commissioning post-staging O&M top-up pass %d" % [commissioning_recovery_pass + 1])
				if failures.size() > 0:
					return
			_advance(1000.0, "J10 commissioning service-readiness refresh")
			var restored_service_blocker: Dictionary = game.megastructure_runtime_snapshot("stellar_energy").get("phase_start_blocker", {})
			var final_location: Dictionary = _snapshot(lagrange_world_id).get("location_available_inventory", {})
			var final_repair_projection: Dictionary = game.maintenance_recovery_snapshot("earth_sun_lagrange", "repair_material", int(phase_costs.get("repair_material", 0)), 360000.0)
			var final_electronics_projection: Dictionary = game.maintenance_recovery_snapshot("earth_sun_lagrange", "electronics", 1, 360000.0)
			_check(not repair_id.is_empty() and not service_ids.is_empty() and restored_service_blocker.is_empty() and int(final_location.get("repair_material", 0)) > 100 and int(final_location.get("repair_material", 0)) >= maxi(101, int(final_repair_projection.get("gross_production_target", 100))) and int(final_location.get("electronics", 0)) >= maxi(1, int(final_electronics_projection.get("gross_production_target", 1))), "J10 commissioning adds the physical powered Repair Dock, retains more than the hundred consumed phase units after staging, and restores the public service gate; initial_repair=%s initial_electronics=%s final_repair=%s final_electronics=%s available=%s blocker=%s" % [JSON.stringify(repair_recovery), JSON.stringify(electronics_recovery), JSON.stringify(final_repair_projection), JSON.stringify(final_electronics_projection), JSON.stringify(final_location), JSON.stringify(restored_service_blocker)])
		if failures.size() > 0:
			return
		var phase_custody_before := _snapshot(lagrange_world_id)
		var phase_start_event := observed_events.size()
		_check(bool(game.start_megastructure_phase("stellar_energy", 100)), "public Megastructure command starts exact phase %d / %s" % [phase_index, str(phase.get("id", ""))])
		var started := _first_event(_events_after(phase_start_event), "MegastructurePhaseStarted")
		var runtime: Dictionary = game.megastructure_runtime_snapshot("stellar_energy")
		var phase_custody_after := _snapshot(lagrange_world_id)
		var source_breakdown: Dictionary = started.get("source_breakdown", {})
		var exact_source_accounting := true
		for cost_item_value in phase_costs:
			var cost_item_id := str(cost_item_value)
			var source_rows: Array = source_breakdown.get(cost_item_id, [])
			var source_total := 0
			for source_value in source_rows:
				var source := source_value as Dictionary
				source_total += int(source.get("quantity", 0))
				exact_source_accounting = exact_source_accounting and str(source.get("location_id", "")) == "earth_sun_lagrange" and str(source.get("custody", "")) in ["LOCATION", "FACTORY_STORAGE"]
			exact_source_accounting = exact_source_accounting and source_total == int(phase_costs.get(cost_item_id, 0)) and _site_item_custody_quantity(phase_custody_before, cost_item_id) - _site_item_custody_quantity(phase_custody_after, cost_item_id) == int(phase_costs.get(cost_item_id, 0))
		var phase_one_electronics_sources: Array = source_breakdown.get("electronics", [])
		var phase_one_mixed := phase_index != 1 or (phase_one_electronics_sources.any(func(source_value): return str((source_value as Dictionary).get("custody", "")) == "LOCATION") and phase_one_electronics_sources.any(func(source_value): return str((source_value as Dictionary).get("custody", "")) == "FACTORY_STORAGE"))
		_check(str(started.get("phase_id", "")) == str(phase.get("id", "")) and int(started.get("phase_index", -1)) == phase_index and str(started.get("location_id", "")) == "earth_sun_lagrange" and (started.get("consumed", {}) as Dictionary) == phase_costs and exact_source_accounting and phase_one_mixed and str(runtime.get("phase_id", "")) == str(phase.get("id", "")) and int((runtime.get("phase_runtime", {}) as Dictionary).get("phase_index", -1)) == phase_index, "Megastructure starts phase %d with exact identity, same-site custody debit, source accounting, and public runtime; event=%s runtime=%s" % [phase_index, JSON.stringify(started), JSON.stringify(runtime)])
		if failures.size() > 0:
			return
		var phase_events: Array = []
		var phase_slices := ceili(float(phase.get("duration_ms", 0.0)) / 120000.0)
		for slice_index in range(phase_slices):
			var remaining := float(phase.get("duration_ms", 0.0)) - float(slice_index) * 120000.0
			phase_events.append_array(_advance(minf(120000.0, remaining) + (1000.0 if slice_index == phase_slices - 1 else 0.0), "J10 Megastructure phase %d slice %d/%d" % [phase_index, slice_index + 1, phase_slices]))
		var after: Dictionary = game.megastructure_runtime_snapshot("stellar_energy")
		var changed := _first_event(phase_events, "MegastructureStageChanged")
		_check(int(after.get("phase_index", 0)) == phase_index + 1 and int(after.get("phase_history_count", 0)) == phase_index + 1 and int(changed.get("stage_index", -1)) == phase_index + 1, "Megastructure completes phase %d exactly once and advances its public history; changed=%s after=%s" % [phase_index, JSON.stringify(changed), JSON.stringify(after)])
		if phase_index == 7:
			var game_completed_count := phase_events.filter(func(event_value): return str((event_value as Dictionary).get("type", "")) == "GameCompleted").size()
			_check(game_completed_count == 1 and _ordered_types(["GameCompleted", "MegastructureStageChanged"], phase_events) and bool(after.get("completed", false)) and bool(after.get("game_complete", false)) and str(after.get("status", "")) == "COMPLETE" and str(after.get("gameplay_state", "")) == "COMPLETED" and int(after.get("phase_history_count", 0)) == 8 and (after.get("phase_runtime", {}) as Dictionary).is_empty(), "final commissioning publishes exactly one GameCompleted before the terminal stage and leaves the exact completed public snapshot; events=%s after=%s" % [JSON.stringify(phase_events), JSON.stringify(after)])
		if failures.size() > 0:
			return
	_journey_pass("J10", "MEGASTRUCTURE")


func _prepare_external_for_manifest(manifest: Dictionary, packet: Dictionary, label: String) -> void:
	var external := {}
	for item_value in manifest:
		_accumulate_external_requirements(str(item_value), int(manifest.get(str(item_value), 0)), external)
	var storage_id := str(packet.get("storage_id", ""))
	for item_value in external:
		var item_id := str(item_value)
		var required := int(external.get(item_id, 0))
		var earth_snapshot := _snapshot(EARTH_WORLD_ID)
		var storage_inventory: Dictionary = _entity(earth_snapshot, storage_id).get("inventory", {})
		var location_inventory: Dictionary = earth_snapshot.get("location_available_inventory", {})
		var shortfall := maxi(0, required - int(storage_inventory.get(item_id, 0)) - int(location_inventory.get(item_id, 0)))
		if shortfall <= 0 or item_id == "dark_matter":
			continue
		match item_id:
			"rare_earth_concentrate":
				_return_remote_resource_to_earth(item_id, shortfall, 2, "lunar_space", str(packet.get("lunar_world_id", "")), str(packet.get("lunar_rare_extractor_id", "")), str(packet.get("lunar_power_id", "")), str(packet.get("lunar_storage_id", "")), {"chemical_propellant":1, "repair_material":1}, packet, "%s rare-earth" % label)
			"helium_3":
				_return_remote_resource_to_earth(item_id, shortfall, 5, "lunar_space", str(packet.get("lunar_world_id", "")), str(packet.get("lunar_helium_extractor_id", "")), str(packet.get("lunar_power_id", "")), str(packet.get("lunar_helium_storage_id", "")), {"chemical_propellant":1, "repair_material":1}, packet, "%s helium" % label)
			"thorium_ore":
				_return_remote_resource_to_earth(item_id, shortfall, 2, "lunar_space", str(packet.get("lunar_world_id", "")), str(packet.get("lunar_thorium_extractor_id", "")), str(packet.get("lunar_power_id", "")), str(packet.get("lunar_storage_id", "")), {"chemical_propellant":1, "repair_material":1}, packet, "%s thorium" % label)
			"titanium_alloy":
				_return_lunar_titanium_to_earth(shortfall, packet, "%s titanium" % label)
			"cobalt_ingot":
				_return_jovian_cobalt_ingot_to_earth(shortfall, packet, "%s cobalt" % label)
			"superalloy":
				_produce_jovian_superalloy_to_earth(shortfall, packet, "%s superalloy" % label)
			"exotic_crystal":
				var outer_world_ids: Array[String] = game.factory_world_ids_for_location("outer_system")
				var outer_world_id := str(outer_world_ids[0] if outer_world_ids.size() == 1 else "")
				var outer_snapshot := _snapshot(outer_world_id)
				var outer_mine := _entity_with_resource(outer_snapshot, "exotic_crystal")
				var outer_power := _entity_with_definition(outer_snapshot, "grid_command_array")
				var outer_storage := _entity_with_definition(outer_snapshot, "grid_bulk_depot")
				_return_remote_resource_to_earth(item_id, shortfall, 8, "outer_system", outer_world_id, str(outer_mine.get("id", "")), str(outer_power.get("id", "")), str(outer_storage.get("id", "")), {"chemical_propellant":8, "repair_material":4}, packet, "%s exotic" % label)
			_:
				_check(false, "%s has no public regional supply lane for %s x%d" % [label, item_id, shortfall])
		if failures.size() > 0:
			return


func _accumulate_external_requirements(item_id: String, quantity: int, result: Dictionary) -> void:
	if quantity <= 0:
		return
	if item_id in ["rare_earth_concentrate", "helium_3", "thorium_ore", "titanium_alloy", "cobalt_ingot", "superalloy", "exotic_crystal", "dark_matter"]:
		result[item_id] = int(result.get(item_id, 0)) + quantity
		return
	var recipe_ids := {
		"electronics":"grid_fabricate_electronics", "structural_frame":"grid_assemble_frame", "repair_material":"grid_fabricate_repair_material", "chemical_propellant":"grid_manufacture_emergency_propellant",
		"steel_composite":"grid_refine_steel_electric", "precision_actuator":"grid_fabricate_precision_actuator", "heavy_structural_section":"grid_fabricate_heavy_structural_section_robotic", "industrial_machine_tools":"grid_fabricate_basic_machine_tools",
		"reactor_part":"grid_fabricate_reactor_part", "power_bus_component":"grid_fabricate_power_bus_component", "data_core":"grid_fabricate_data_core", "superconducting_composite":"grid_fabricate_superconducting_composite",
		"superconducting_coil":"grid_wind_superconducting_coil", "radiation_hardened_electronics":"grid_fabricate_radiation_hardened_electronics", "thermal_exchange_unit":"grid_fabricate_thermal_exchange_unit", "thorium_fuel":"grid_prepare_thorium_fuel",
		"antimatter_cell":"grid_build_antimatter_cell", "fusion_service_component":"grid_fabricate_fusion_service_component", "quantum_component":"grid_fabricate_quantum_component", "logistics_handling_equipment":"grid_fabricate_logistics_handling_equipment",
		"automated_control_core":"grid_fabricate_automated_control_core", "construction_robotics":"grid_fabricate_construction_robotics", "project_core":"grid_assemble_project_core"
	}
	if item_id in ["iron_ingot", "copper_ingot"]:
		return
	var recipe_id := str(recipe_ids.get(item_id, ""))
	_check(not recipe_id.is_empty(), "external-requirement planner resolves a physical recipe for %s" % item_id)
	if failures.size() > 0:
		return
	var recipe := {}
	for recipe_value in (_snapshot(EARTH_WORLD_ID).get("palette", {}) as Dictionary).get("recipes", []):
		var candidate := recipe_value as Dictionary
		if str(candidate.get("id", "")) == recipe_id:
			recipe = candidate
			break
	# Project cores are planned before their stage-two spillover makes the recipe
	# visible.  Its stable canonical contract is still explicit here; production
	# itself remains gated and occurs only after the spillover event.
	if recipe.is_empty() and recipe_id == "grid_assemble_project_core":
		recipe = {"inputs":[{"item":"superalloy", "quantity":4}, {"item":"quantum_component", "quantity":3}, {"item":"antimatter_cell", "quantity":1}], "outputs":[{"item":"project_core", "quantity":1}]}
	_check(not recipe.is_empty(), "external-requirement planner sees the canonical recipe for %s" % item_id)
	if failures.size() > 0:
		return
	var output_quantity := 0
	for output_value in recipe.get("outputs", []):
		if str((output_value as Dictionary).get("item", "")) == item_id:
			output_quantity = int((output_value as Dictionary).get("quantity", 0))
	var cycles := ceili(float(quantity) / float(output_quantity)) if output_quantity > 0 else 0
	_check(cycles > 0, "external-requirement planner derives a positive cycle count for %s" % item_id)
	for input_value in recipe.get("inputs", []):
		var input := input_value as Dictionary
		_accumulate_external_requirements(str(input.get("item", "")), int(input.get("quantity", 0)) * cycles, result)


func _return_jovian_cobalt_ingot_to_earth(quantity: int, packet: Dictionary, label: String) -> void:
	var jovian_world_id := str(packet.get("jovian_world_id", ""))
	var jovian_storage_id := str(packet.get("jovian_storage_id", ""))
	var chunk_count := ceili(float(quantity) / 8.0)
	for chunk_index in range(chunk_count):
		var chunk := mini(8, quantity - chunk_index * 8)
		_move_asteroid_cobalt_ore_to_jovian(chunk * 2, packet, "%s ore %d/%d" % [label, chunk_index + 1, chunk_count])
		_run_exact_recipe_batches(str(packet.get("jovian_smelter_id", "")), "grid_refine_cobalt", str(packet.get("jovian_power_id", "")), jovian_storage_id, "cobalt_ingot", chunk, chunk, "%s refinement %d/%d" % [label, chunk_index + 1, chunk_count], jovian_storage_id, jovian_world_id)
		_recycle_jovian_cobalt_waste(packet, "%s cobalt-waste recovery %d/%d" % [label, chunk_index + 1, chunk_count])
		_transfer_earth_manifest_to_remote_factory("gas_giant_region", jovian_world_id, {"chemical_propellant":5, "repair_material":3}, {"chemical_propellant":5, "repair_material":3}, packet, "%s return reserve %d/%d" % [label, chunk_index + 1, chunk_count], "")
		_export_to_location("cobalt_ingot", chunk, "%s source cargo %d/%d" % [label, chunk_index + 1, chunk_count], jovian_world_id, jovian_storage_id)
		var returned := _freight_location_cargo("gas_giant_region", jovian_world_id, EARTH_LOCATION_ID, EARTH_WORLD_ID, "cobalt_ingot", chunk, {"chemical_propellant":5, "repair_material":3}, "%s public return %d/%d" % [label, chunk_index + 1, chunk_count])
		if returned.is_empty() or failures.size() > 0:
			return
		_import_from_location("cobalt_ingot", chunk, str(packet.get("storage_id", "")), "%s Earth Factory custody %d/%d" % [label, chunk_index + 1, chunk_count])


func _lagrange_manifest_maximum_chunk(item_id: String) -> int:
	# These conservative public-lane limits fit the original SURVEYED site's
	# per-class Location staging (BULK 20 / COMPONENT 20 / SPECIAL 5) as well as
	# the 90-unit general-cargo route.  Later phase effects only add headroom.
	if item_id in ["iron_ingot", "copper_ingot", "steel_composite", "superalloy"]:
		return 16
	if item_id == "project_core":
		return 1
	if item_id == "antimatter_cell":
		return 2
	if item_id == "dark_matter":
		return 1
	if item_id in ["industrial_machine_tools", "heavy_structural_section", "logistics_handling_equipment", "power_bus_component", "construction_robotics", "precision_actuator", "thermal_exchange_unit", "automated_control_core"]:
		return 5
	return 20


func _stage_lagrange_location_manifest(manifest: Dictionary, packet: Dictionary, lagrange_world_id: String, label: String) -> void:
	for item_value in manifest:
		var item_id := str(item_value)
		var quantity := int(manifest.get(item_id, 0))
		if quantity <= 0:
			continue
		var maximum_chunk := _lagrange_manifest_maximum_chunk(item_id)
		var chunk_count := ceili(float(quantity) / float(maximum_chunk))
		for chunk_index in range(chunk_count):
			var chunk := mini(maximum_chunk, quantity - chunk_index * maximum_chunk)
			_prepare_external_for_manifest({item_id:chunk}, packet, "%s %s Location batch %d/%d external closure" % [label, item_id, chunk_index + 1, chunk_count])
			if failures.size() > 0:
				return
			_transfer_earth_manifest_to_remote_factory("earth_sun_lagrange", lagrange_world_id, {item_id:chunk}, {"chemical_propellant":1, "repair_material":1}, packet, "%s %s Location batch %d/%d" % [label, item_id, chunk_index + 1, chunk_count], "")
			if failures.size() > 0:
				return


func _stage_lagrange_manifest(manifest: Dictionary, packet: Dictionary, lagrange_world_id: String, bulk_storage_id: String, component_storage_id: String, special_storage_id: String, label: String) -> void:
	var bulk_items := ["iron_ingot", "copper_ingot", "steel_composite", "superalloy"]
	var special_items := ["project_core", "antimatter_cell", "dark_matter"]
	for item_value in manifest:
		var item_id := str(item_value)
		var quantity := int(manifest.get(item_id, 0))
		if quantity <= 0:
			continue
		var maximum_chunk := _lagrange_manifest_maximum_chunk(item_id)
		var target_storage_id := bulk_storage_id if item_id in bulk_items else (special_storage_id if item_id in special_items else component_storage_id)
		var chunk_count := ceili(float(quantity) / float(maximum_chunk))
		for chunk_index in range(chunk_count):
			var chunk := mini(maximum_chunk, quantity - chunk_index * maximum_chunk)
			_prepare_external_for_manifest({item_id:chunk}, packet, "%s %s batch %d/%d external closure" % [label, item_id, chunk_index + 1, chunk_count])
			if failures.size() > 0:
				return
			_transfer_earth_manifest_to_remote_factory("earth_sun_lagrange", lagrange_world_id, {item_id:chunk}, {"chemical_propellant":1, "repair_material":1}, packet, "%s %s batch %d/%d" % [label, item_id, chunk_index + 1, chunk_count], target_storage_id)
			if failures.size() > 0:
				return


func _build_lagrange_services(packet: Dictionary, lagrange_world_id: String) -> Dictionary:
	var service_costs := {"iron_ingot":16, "electronics":8, "structural_frame":4}
	_stage_lagrange_location_manifest(service_costs, packet, lagrange_world_id, "J10 Lagrange power/cooling adapters")
	if failures.size() > 0:
		return {}
	var power := _queue_and_fund("grid_power_substation_ii", "", _find_clear_factory_origin("grid_power_substation_ii", lagrange_world_id), "J10 Lagrange Power II", true, lagrange_world_id, "")
	var cooling := _queue_and_fund("grid_cooling_service", "", _find_clear_factory_origin("grid_cooling_service", lagrange_world_id), "J10 Lagrange Cooling Service", true, lagrange_world_id, "")
	var power_id := str(power.get("entity_id", ""))
	var cooling_id := str(cooling.get("entity_id", ""))
	var events := _advance(180000.0, "J10 Lagrange power/cooling-adapter construction")
	_ensure_connection("POWER", power_id, cooling_id, "", lagrange_world_id)
	var snapshot := _snapshot(lagrange_world_id)
	var exact_completions := events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("world_id", "")) == lagrange_world_id and str(event.get("entity_id", "")) in [power_id, cooling_id]
	)
	var orders_retired := not (snapshot.get("construction_orders", []) as Array).any(func(order_value):
		var order_id := str((order_value as Dictionary).get("id", ""))
		return order_id in [str(power.get("order_id", "")), str(cooling.get("order_id", ""))]
	)
	var power_runtime := _entity(snapshot, power_id)
	var cooling_runtime := _entity(snapshot, cooling_id)
	_check(exact_completions.size() == 2 and orders_retired and str(power_runtime.get("definition_id", "")) == "grid_power_substation_ii" and str(power_runtime.get("status", "")) != "UNDER_CONSTRUCTION" and str(cooling_runtime.get("definition_id", "")) == "grid_cooling_service" and str(cooling_runtime.get("status", "")) != "UNDER_CONSTRUCTION" and float(cooling_runtime.get("power_factor", 0.0)) > 0.0, "Factory fully funds, completes, and powers only the exact Phase-four Lagrange power/cooling service pair; events=%s cooling=%s" % [JSON.stringify(events), JSON.stringify(cooling_runtime)])
	return {"power_id":power_id, "cooling_id":cooling_id}


func _build_lagrange_repair_service(packet: Dictionary, lagrange_world_id: String, power_id: String) -> String:
	var repair_costs := {"steel_composite":4, "electronics":3}
	_stage_lagrange_location_manifest(repair_costs, packet, lagrange_world_id, "J10 Lagrange commissioning Repair Dock")
	if failures.size() > 0:
		return ""
	var repair := _queue_and_fund("grid_repair_dock", "", _find_clear_factory_origin("grid_repair_dock", lagrange_world_id), "J10 Lagrange Repair Dock", true, lagrange_world_id, "")
	var repair_id := str(repair.get("entity_id", ""))
	var events := _advance(180000.0, "J10 Lagrange commissioning Repair-Dock construction")
	_ensure_connection("POWER", power_id, repair_id, "", lagrange_world_id)
	var snapshot := _snapshot(lagrange_world_id)
	var repair_runtime := _entity(snapshot, repair_id)
	var exact_completion := events.filter(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryConstructionCompleted" and str(event.get("world_id", "")) == lagrange_world_id and str(event.get("entity_id", "")) == repair_id and str(event.get("definition_id", "")) == "grid_repair_dock"
	).size() == 1
	var order_retired := not (snapshot.get("construction_orders", []) as Array).any(func(order_value): return str((order_value as Dictionary).get("id", "")) == str(repair.get("order_id", "")))
	_check(exact_completion and order_retired and str(repair_runtime.get("definition_id", "")) == "grid_repair_dock" and str(repair_runtime.get("status", "")) != "UNDER_CONSTRUCTION" and float(repair_runtime.get("power_factor", 0.0)) > 0.0, "Factory fully funds, completes, and powers the commissioning-only Lagrange Repair Dock; events=%s repair=%s" % [JSON.stringify(events), JSON.stringify(repair_runtime)])
	return repair_id


func _site_item_custody_quantity(snapshot: Dictionary, item_id: String) -> int:
	var total := int((snapshot.get("location_available_inventory", {}) as Dictionary).get(item_id, 0))
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("node_kind", "")) == "STORAGE" and str(entity.get("status", "")) != "UNDER_CONSTRUCTION":
			total += int((entity.get("inventory", {}) as Dictionary).get(item_id, 0))
	return total


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


## Add one bounded missing input to a cold machine while preserving every other
## visible legacy buffer.  This supports sequential recipes whose shared machine
## honestly contains more of another input than one exact batch would require.
func _cold_stage_single_input_minimum(machine_id: String, recipe_id: String, source_id: String, item_id: String, target_quantity: int, label: String, world_id: String = EARTH_WORLD_ID) -> void:
	for power_link_value in _snapshot(world_id).get("links", []):
		var power_link := power_link_value as Dictionary
		if str(power_link.get("kind", "")) == "POWER" and str(power_link.get("target_id", "")) == machine_id:
			var removed := _factory_command("REMOVE_LINK", {"link_id":str(power_link.get("id", ""))}, world_id)
			_check(bool(removed.get("accepted", false)), "%s freezes its target machine before bounded single-input staging" % label)
	var recipe_result := _factory_command("SET_RECIPE", {"entity_id":machine_id, "recipe_id":recipe_id}, world_id)
	_check(bool(recipe_result.get("accepted", false)), "%s selects its canonical recipe before bounded single-input staging" % label)
	if failures.size() > 0:
		return
	var before_snapshot := _snapshot(world_id)
	var source_before := int(_entity(before_snapshot, source_id).get("inventory", {}).get(item_id, 0))
	var machine_before := int(_entity(before_snapshot, machine_id).get("inputs", {}).get(item_id, 0))
	var deficit := maxi(0, target_quantity - machine_before)
	_check(machine_before <= target_quantity and source_before >= deficit, "%s exposes a finite capacity-safe %s staging deficit; machine=%d source=%d target=%d" % [label, item_id, machine_before, source_before, target_quantity])
	if failures.size() > 0:
		return
	var staging_events: Array = []
	if deficit > 0:
		_clear_competing_cargo_inputs(machine_id, item_id, source_id, world_id)
		_ensure_connection("CARGO", source_id, machine_id, item_id, world_id)
		staging_events = _advance(float(deficit) / 4.0 * 1000.0, "%s public CARGO staging" % label)
	var cold_cycle_seen := staging_events.any(func(event_value):
		var event := event_value as Dictionary
		return str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == world_id and str(event.get("entity_id", "")) == machine_id and str(event.get("recipe_id", "")) == recipe_id
	)
	var after_snapshot := _snapshot(world_id)
	var source_after := int(_entity(after_snapshot, source_id).get("inventory", {}).get(item_id, 0))
	var machine_after := int(_entity(after_snapshot, machine_id).get("inputs", {}).get(item_id, 0))
	_check(not cold_cycle_seen and source_after == source_before - deficit and machine_after == target_quantity, "%s stages only its requested %s deficit while cold; source_before=%d source_after=%d machine_before=%d machine_after=%d" % [label, item_id, source_before, source_after, machine_before, machine_after])
	_clear_competing_cargo_inputs(machine_id, item_id, "", world_id)


## Drain an already player-filled machine buffer through one bounded public
## production window.  This is used only for renewable base-metal recovery: the
## historical ore buffer is visible in the Factory snapshot, every output has a
## named storage destination, and POWER is removed again before returning.
## Refill one refined Earth ingot through the same public buffered-then-renewable
## path used by the player-facing production chains.
func _ensure_earth_ingot_minimum(item_id: String, target_quantity: int, refinery_id: String, power_source_id: String, storage_id: String, label: String) -> void:
	_check(item_id in ["iron_ingot", "copper_ingot"] and target_quantity >= 0 and not refinery_id.is_empty(), "%s declares a supported finite refined-ingot target" % label)
	if failures.size() > 0:
		return
	var current := int((_entity(_snapshot(EARTH_WORLD_ID), storage_id).get("inventory", {}) as Dictionary).get(item_id, 0))
	var shortfall := maxi(0, target_quantity - current)
	if shortfall <= 0:
		return
	var raw_item_id := "iron_ore" if item_id == "iron_ingot" else "copper_ore"
	var recipe_id := "grid_refine_iron" if item_id == "iron_ingot" else "grid_refine_copper"
	var duration_ms := 2000.0 if item_id == "iron_ingot" else 6000.0
	var refinery := _entity(_snapshot(EARTH_WORLD_ID), refinery_id)
	var buffered_cycles := mini(shortfall, floori(float((refinery.get("inputs", {}) as Dictionary).get(raw_item_id, 0)) / 2.0))
	if buffered_cycles > 0:
		_run_buffered_recipe_minimum(refinery_id, recipe_id, power_source_id, storage_id, item_id, buffered_cycles, float(buffered_cycles) * duration_ms + 2000.0, "%s buffered refinement" % label, storage_id if item_id == "copper_ingot" else "")
	var renewable_cycles := maxi(0, target_quantity - int((_entity(_snapshot(EARTH_WORLD_ID), storage_id).get("inventory", {}) as Dictionary).get(item_id, 0)))
	if renewable_cycles > 0:
		var extractor := _entity_with_resource(_snapshot(EARTH_WORLD_ID), raw_item_id)
		var extractor_id := str(extractor.get("id", ""))
		_check(not extractor_id.is_empty(), "%s resolves its public renewable %s field" % [label, raw_item_id])
		if failures.size() > 0:
			return
		_extract_resource_batch(extractor_id, raw_item_id, power_source_id, storage_id, renewable_cycles * 2, "%s renewable extraction" % label)
		_run_exact_recipe_batches(refinery_id, recipe_id, power_source_id, storage_id, item_id, renewable_cycles, mini(32, renewable_cycles), "%s renewable refinement" % label, storage_id if item_id == "copper_ingot" else "")
	var final_quantity := int((_entity(_snapshot(EARTH_WORLD_ID), storage_id).get("inventory", {}) as Dictionary).get(item_id, 0))
	_check(final_quantity >= target_quantity, "%s closes its refined-ingot target in public storage; target=%d final=%d" % [label, target_quantity, final_quantity])


## Close a bounded Earth operating-cost lot entirely through visible Factory
## custody.  Emergency propellant and repair material share iron plus renewable
## copper/electronics precursors; every dependency is produced before the final
## exact recipe batches and no Location inventory is mutated here.
func _manufacture_earth_operating_shortfall(chemical_propellant_target: int, repair_material_target: int, copper_refinery_id: String, engineering_works_id: String, power_source_id: String, storage_id: String, label: String, retained_inventory: Dictionary = {}) -> void:
	_check(chemical_propellant_target >= 0 and repair_material_target >= 0 and not copper_refinery_id.is_empty() and not engineering_works_id.is_empty() and not power_source_id.is_empty() and not storage_id.is_empty(), "%s declares finite operating targets and concrete public Factory actors" % label)
	if failures.size() > 0:
		return
	var storage_before: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), storage_id).get("inventory", {})
	var propellant_shortfall := maxi(0, chemical_propellant_target - int(storage_before.get("chemical_propellant", 0)))
	var repair_shortfall := maxi(0, repair_material_target - int(storage_before.get("repair_material", 0)))
	var propellant_cycles := ceili(float(propellant_shortfall) / 2.0)
	var retained_electronics := int(retained_inventory.get("electronics", 0))
	var electronics_shortfall := maxi(0, propellant_cycles + retained_electronics - int(storage_before.get("electronics", 0)))
	var electronics_cycles := ceili(float(electronics_shortfall) / 2.0)
	var copper_target := repair_shortfall + electronics_cycles + int(retained_inventory.get("copper_ingot", 0))
	var copper_shortfall := maxi(0, copper_target - int(storage_before.get("copper_ingot", 0)))
	var iron_target := repair_shortfall * 2 + propellant_cycles * 2 + electronics_cycles + int(retained_inventory.get("iron_ingot", 0))
	var iron_shortfall := maxi(0, iron_target - int(storage_before.get("iron_ingot", 0)))
	if iron_shortfall > 0:
		var iron_refinery := _entity_with_recipe(_snapshot(EARTH_WORLD_ID), "grid_refine_iron")
		var iron_refinery_id := str(iron_refinery.get("id", ""))
		_check(not iron_refinery_id.is_empty(), "%s resolves the public iron refinery for renewable operating-cost closure" % label)
		if failures.size() > 0:
			return
		var buffered_iron_cycles := mini(iron_shortfall, floori(float((iron_refinery.get("inputs", {}) as Dictionary).get("iron_ore", 0)) / 2.0))
		if buffered_iron_cycles > 0:
			_run_buffered_recipe_minimum(iron_refinery_id, "grid_refine_iron", power_source_id, storage_id, "iron_ingot", buffered_iron_cycles, float(buffered_iron_cycles) * 2000.0 + 2000.0, "%s buffered iron precursor" % label)
		var renewable_iron_cycles := maxi(0, iron_target - int((_entity(_snapshot(EARTH_WORLD_ID), storage_id).get("inventory", {}) as Dictionary).get("iron_ingot", 0)))
		if renewable_iron_cycles > 0:
			var iron_extractor := _entity_with_resource(_snapshot(EARTH_WORLD_ID), "iron_ore")
			var iron_extractor_id := str(iron_extractor.get("id", ""))
			_check(not iron_extractor_id.is_empty(), "%s resolves the public renewable iron field after the historic refinery buffer is exhausted" % label)
			if failures.size() > 0:
				return
			_extract_resource_batch(iron_extractor_id, "iron_ore", power_source_id, storage_id, renewable_iron_cycles * 2, "%s renewable iron ore" % label)
			_run_exact_recipe_batches(iron_refinery_id, "grid_refine_iron", power_source_id, storage_id, "iron_ingot", renewable_iron_cycles, mini(32, renewable_iron_cycles), "%s renewable iron precursor" % label)
	_check(int((_entity(_snapshot(EARTH_WORLD_ID), storage_id).get("inventory", {}) as Dictionary).get("iron_ingot", 0)) >= iron_target, "%s retains the exact finite iron precursor for operating-cost closure; target=%d inventory=%s" % [label, iron_target, JSON.stringify(_entity(_snapshot(EARTH_WORLD_ID), storage_id).get("inventory", {}))])
	if failures.size() > 0:
		return
	if copper_shortfall > 0:
		var copper_refinery_before := _entity(_snapshot(EARTH_WORLD_ID), copper_refinery_id)
		var buffered_copper_cycles := mini(copper_shortfall, floori(float((copper_refinery_before.get("inputs", {}) as Dictionary).get("copper_ore", 0)) / 2.0))
		if buffered_copper_cycles > 0:
			_run_buffered_recipe_minimum(copper_refinery_id, "grid_refine_copper", power_source_id, storage_id, "copper_ingot", buffered_copper_cycles, float(buffered_copper_cycles) * 6000.0 + 2000.0, "%s buffered copper precursor" % label, storage_id)
		var renewable_copper_cycles := maxi(0, copper_target - int((_entity(_snapshot(EARTH_WORLD_ID), storage_id).get("inventory", {}) as Dictionary).get("copper_ingot", 0)))
		if renewable_copper_cycles > 0:
			var copper_extractor := _entity_with_resource(_snapshot(EARTH_WORLD_ID), "copper_ore")
			var copper_extractor_id := str(copper_extractor.get("id", ""))
			_check(not copper_extractor_id.is_empty(), "%s resolves the public renewable copper field after the historic refinery buffer is exhausted" % label)
			if failures.size() > 0:
				return
			_extract_resource_batch(copper_extractor_id, "copper_ore", power_source_id, storage_id, renewable_copper_cycles * 2, "%s renewable copper ore" % label)
			_run_exact_recipe_batches(copper_refinery_id, "grid_refine_copper", power_source_id, storage_id, "copper_ingot", renewable_copper_cycles, mini(32, renewable_copper_cycles), "%s renewable copper precursor" % label, storage_id)
	if electronics_cycles > 0:
		_run_exact_recipe_batches(engineering_works_id, "grid_fabricate_electronics", power_source_id, storage_id, "electronics", electronics_cycles, mini(32, electronics_cycles), "%s electronics precursor" % label)
	if propellant_cycles > 0:
		_run_exact_recipe_batches(engineering_works_id, "grid_manufacture_emergency_propellant", power_source_id, storage_id, "chemical_propellant", propellant_cycles, mini(32, propellant_cycles), "%s chemical propellant" % label)
	if repair_shortfall > 0:
		_run_exact_recipe_batches(engineering_works_id, "grid_fabricate_repair_material", power_source_id, storage_id, "repair_material", repair_shortfall, mini(32, repair_shortfall), "%s repair material" % label)
	var storage_after: Dictionary = _entity(_snapshot(EARTH_WORLD_ID), storage_id).get("inventory", {})
	_check(int(storage_after.get("chemical_propellant", 0)) >= chemical_propellant_target and int(storage_after.get("repair_material", 0)) >= repair_material_target, "%s physically closes both operating-cost targets in public Factory custody; propellant_target=%d repair_target=%d inventory=%s" % [label, chemical_propellant_target, repair_material_target, JSON.stringify(storage_after)])


func _run_buffered_recipe_minimum(machine_id: String, recipe_id: String, power_source_id: String, output_target_id: String, output_item_id: String, minimum_gain: int, production_ms: float, label: String, waste_target_id: String = "", world_id: String = EARTH_WORLD_ID) -> Array:
	var before_machine := _entity(_snapshot(world_id), machine_id)
	_check(not before_machine.is_empty() and not (before_machine.get("inputs", {}) as Dictionary).is_empty() and minimum_gain > 0, "%s starts from a visible finite machine input buffer; machine=%s" % [label, JSON.stringify(before_machine)])
	if failures.size() > 0:
		return []
	var recipe_result := _factory_command("SET_RECIPE", {"entity_id":machine_id, "recipe_id":recipe_id}, world_id)
	_check(bool(recipe_result.get("accepted", false)), "%s selects its canonical buffered recipe through protocol v1; result=%s" % [label, JSON.stringify(recipe_result)])
	_clear_competing_cargo_inputs(output_target_id, output_item_id, machine_id, world_id)
	_clear_competing_cargo_outputs(output_target_id, output_item_id, "", world_id)
	_clear_competing_cargo_outputs(machine_id, output_item_id, output_target_id, world_id)
	_ensure_connection("CARGO", machine_id, output_target_id, output_item_id, world_id)
	if not waste_target_id.is_empty():
		_clear_competing_cargo_inputs(waste_target_id, "industrial_waste", machine_id, world_id)
		_clear_competing_cargo_outputs(machine_id, "industrial_waste", waste_target_id, world_id)
		_ensure_connection("CARGO", machine_id, waste_target_id, "industrial_waste", world_id)
	_isolate_all_machine_power_for_target(machine_id, world_id)
	_ensure_connection("POWER", power_source_id, machine_id, "", world_id)
	var output_before := int(_entity(_snapshot(world_id), output_target_id).get("inventory", {}).get(output_item_id, 0))
	var production_events := _advance(production_ms, label)
	var scoped_produced := 0
	for event_value in production_events:
		var event := event_value as Dictionary
		if str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == world_id and str(event.get("entity_id", "")) == machine_id and str(event.get("recipe_id", "")) == recipe_id:
			scoped_produced += int((event.get("produced", {}) as Dictionary).get(output_item_id, 0))
	var output_after := int(_entity(_snapshot(world_id), output_target_id).get("inventory", {}).get(output_item_id, 0))
	for power_link_value in _snapshot(world_id).get("links", []):
		var power_link := power_link_value as Dictionary
		if str(power_link.get("kind", "")) == "POWER" and str(power_link.get("target_id", "")) == machine_id:
			var removed := _factory_command("REMOVE_LINK", {"link_id":str(power_link.get("id", ""))}, world_id)
			_check(bool(removed.get("accepted", false)), "%s retires its bounded buffered-production POWER edge; result=%s" % [label, JSON.stringify(removed)])
	_check(scoped_produced >= minimum_gain and output_after == output_before + scoped_produced, "%s converts its visible buffered feed into at least the required public-storage gain; minimum=%d produced=%d before=%d after=%d events=%s" % [label, minimum_gain, scoped_produced, output_before, output_after, JSON.stringify(production_events)])
	return production_events


## Run an arbitrarily large but explicitly bounded recipe lot as a sequence of
## cold manifests that each fit the selected machine.  Inputs and the primary
## output share one caller-owned depot; an optional waste depot preserves the
## physical secondary output instead of allowing it to fill a hidden buffer.
func _run_exact_recipe_batches(machine_id: String, recipe_id: String, power_source_id: String, storage_id: String, output_item_id: String, total_cycles: int, maximum_cycles_per_batch: int, label: String, waste_storage_id: String = "", world_id: String = EARTH_WORLD_ID, input_source_overrides: Dictionary = {}) -> Array:
	_check(total_cycles > 0 and maximum_cycles_per_batch > 0, "%s declares a finite positive recipe lot" % label)
	if failures.size() > 0:
		return []
	var recipe_definition := {}
	for recipe_value in (_snapshot(world_id).get("palette", {}) as Dictionary).get("recipes", []):
		var palette_recipe := recipe_value as Dictionary
		if str(palette_recipe.get("id", "")) == recipe_id:
			recipe_definition = palette_recipe
			break
	_check(not recipe_definition.is_empty(), "%s resolves its canonical recipe before bounded batching" % label)
	if failures.size() > 0:
		return []
	var duration_ms := float(recipe_definition.get("duration_seconds", 0.0)) * 1000.0
	var has_waste := (recipe_definition.get("outputs", []) as Array).any(func(output_value): return str((output_value as Dictionary).get("item", "")) == "industrial_waste")
	_check(duration_ms > 0.0 and (not has_waste or not waste_storage_id.is_empty()), "%s supplies a duration and explicit waste custody for every secondary waste stream" % label)
	if failures.size() > 0:
		return []
	var events: Array = []
	var batch_count := ceili(float(total_cycles) / float(maximum_cycles_per_batch))
	for batch_index in range(batch_count):
		var completed_before := batch_index * maximum_cycles_per_batch
		var batch_cycles := mini(maximum_cycles_per_batch, total_cycles - completed_before)
		var input_specs: Array = []
		for input_value in recipe_definition.get("inputs", []):
			var recipe_input := input_value as Dictionary
			var input_item_id := str(recipe_input.get("item", ""))
			input_specs.append({"item_id":input_item_id, "source_id":str(input_source_overrides.get(input_item_id, storage_id)), "quantity":int(recipe_input.get("quantity", 0)) * batch_cycles})
		var waste_before := 0
		if has_waste:
			# Endpoint compatibility is recipe-scoped, so publish the canonical
			# recipe before its secondary industrial-waste edge.  The cold helper
			# below repeats this idempotent public selection before staging inputs.
			var waste_recipe_selection := _factory_command("SET_RECIPE", {"entity_id":machine_id, "recipe_id":recipe_id}, world_id)
			_check(bool(waste_recipe_selection.get("accepted", false)), "%s selects its waste-producing recipe before publishing the explicit by-product edge" % label)
			if failures.size() > 0:
				return events
			_clear_competing_cargo_inputs(waste_storage_id, "industrial_waste", machine_id, world_id)
			_clear_competing_cargo_outputs(machine_id, "industrial_waste", waste_storage_id, world_id)
			_ensure_connection("CARGO", machine_id, waste_storage_id, "industrial_waste", world_id)
			waste_before = int((_entity(_snapshot(world_id), waste_storage_id).get("inventory", {}) as Dictionary).get("industrial_waste", 0))
		var batch_events := _cold_stage_recipe_batch(machine_id, recipe_id, power_source_id, input_specs, storage_id, output_item_id, duration_ms * float(batch_cycles) + 1000.0, "%s batch %d/%d" % [label, batch_index + 1, batch_count], world_id)
		events.append_array(batch_events)
		if has_waste:
			var waste_produced := 0
			for event_value in batch_events:
				var event := event_value as Dictionary
				if str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == world_id and str(event.get("entity_id", "")) == machine_id and str(event.get("recipe_id", "")) == recipe_id:
					waste_produced += int((event.get("produced", {}) as Dictionary).get("industrial_waste", 0))
			var waste_after := int((_entity(_snapshot(world_id), waste_storage_id).get("inventory", {}) as Dictionary).get("industrial_waste", 0))
			_check(waste_after == waste_before + waste_produced, "%s batch %d conserves its exact industrial-waste by-product in explicit Factory custody" % [label, batch_index + 1])
		if failures.size() > 0:
			return events
	for power_link_value in _snapshot(world_id).get("links", []):
		var power_link := power_link_value as Dictionary
		if str(power_link.get("kind", "")) == "POWER" and str(power_link.get("target_id", "")) == machine_id:
			var removed := _factory_command("REMOVE_LINK", {"link_id":str(power_link.get("id", ""))}, world_id)
			_check(bool(removed.get("accepted", false)), "%s retires its final bounded production POWER edge" % label)
	var completed_cycles := 0
	for event_value in events:
		var event := event_value as Dictionary
		if str(event.get("type", "")) == "FactoryRecipeCompleted" and str(event.get("world_id", "")) == world_id and str(event.get("entity_id", "")) == machine_id and str(event.get("recipe_id", "")) == recipe_id:
			completed_cycles += int(event.get("completed_cycles", 0))
	_check(completed_cycles == total_cycles, "%s completes exactly %d public Factory recipe cycles; completed=%d" % [label, total_cycles, completed_cycles])
	return events


## Extract a finite raw-resource batch through one public extractor-to-storage
## edge.  Existing extractor output is legitimate player-produced custody; the
## powered window replenishes it at the same canonical four-unit transfer rate.
func _extract_resource_batch(extractor_id: String, resource_id: String, power_source_id: String, storage_id: String, quantity: int, label: String, world_id: String = EARTH_WORLD_ID, additional_power_source_ids: Array = []) -> Array:
	_check(quantity > 0 and not extractor_id.is_empty() and not power_source_id.is_empty() and not storage_id.is_empty(), "%s declares a finite physical extraction batch" % label)
	if failures.size() > 0:
		return []
	var extractor_before := _entity(_snapshot(world_id), extractor_id)
	_check(str(extractor_before.get("resource_id", "")) == resource_id, "%s addresses the exact public renewable resource field" % label)
	for power_link_value in _snapshot(world_id).get("links", []):
		var power_link := power_link_value as Dictionary
		if str(power_link.get("kind", "")) == "POWER" and str(power_link.get("target_id", "")) == extractor_id:
			var removed := _factory_command("REMOVE_LINK", {"link_id":str(power_link.get("id", ""))}, world_id)
			_check(bool(removed.get("accepted", false)), "%s freezes its extractor before the bounded output transfer" % label)
	_clear_competing_cargo_inputs(storage_id, resource_id, extractor_id, world_id)
	_clear_competing_cargo_outputs(extractor_id, resource_id, storage_id, world_id)
	_ensure_connection("CARGO", extractor_id, storage_id, resource_id, world_id)
	var storage_before := int((_entity(_snapshot(world_id), storage_id).get("inventory", {}) as Dictionary).get(resource_id, 0))
	var extractor_output_before := int((_entity(_snapshot(world_id), extractor_id).get("outputs", {}) as Dictionary).get(resource_id, 0))
	# Drain only the requested share of already-produced extractor output while
	# the source is cold.  A full output buffer is legitimate custody, not a
	# reason to demand a positive live extraction rate before cargo can move.
	var buffered_quantity := mini(quantity, extractor_output_before)
	var batch_events: Array = []
	if buffered_quantity > 0:
		var buffered_events := _advance(float(buffered_quantity) / 4.0 * 1000.0, "%s existing output custody" % label)
		batch_events.append_array(buffered_events)
	var storage_after_buffer := int((_entity(_snapshot(world_id), storage_id).get("inventory", {}) as Dictionary).get(resource_id, 0))
	var extractor_output_after_buffer := int((_entity(_snapshot(world_id), extractor_id).get("outputs", {}) as Dictionary).get(resource_id, 0))
	_check(storage_after_buffer == storage_before + buffered_quantity and extractor_output_after_buffer == extractor_output_before - buffered_quantity, "%s first transfers exactly %d already-produced units from frozen extractor custody; storage_before=%d storage_after=%d output_before=%d output_after=%d" % [label, buffered_quantity, storage_before, storage_after_buffer, extractor_output_before, extractor_output_after_buffer])
	_clear_competing_cargo_outputs(extractor_id, resource_id, "", world_id)
	if failures.size() > 0:
		return batch_events
	var remaining_quantity := quantity - buffered_quantity
	var physical_rate := 0.0
	var extraction_events: Array = []
	if remaining_quantity > 0:
		_clear_competing_cargo_inputs(storage_id, resource_id, extractor_id, world_id)
		_ensure_connection("CARGO", extractor_id, storage_id, resource_id, world_id)
		_ensure_connection("POWER", power_source_id, extractor_id, "", world_id)
		for additional_power_source_id_value in additional_power_source_ids:
			var additional_power_source_id := str(additional_power_source_id_value)
			_check(not additional_power_source_id.is_empty() and additional_power_source_id != power_source_id, "%s declares a distinct nonempty supplemental power provider" % label)
			_ensure_connection("POWER", additional_power_source_id, extractor_id, "", world_id)
		var powered_extractor := _entity(_snapshot(world_id), extractor_id)
		physical_rate = minf(4.0, float(powered_extractor.get("actual_rate", 0.0)))
		_check(physical_rate > 0.0, "%s exposes a positive public powered extraction rate for its remaining %d-unit shortfall; extractor=%s" % [label, remaining_quantity, JSON.stringify(powered_extractor)])
		if failures.size() > 0:
			return batch_events
		var extraction_seconds := ceili(float(remaining_quantity) / physical_rate)
		extraction_events = _advance(float(maxi(1, extraction_seconds)) * 1000.0, label)
		batch_events.append_array(extraction_events)
	for power_link_value in _snapshot(world_id).get("links", []):
		var power_link := power_link_value as Dictionary
		if str(power_link.get("kind", "")) == "POWER" and str(power_link.get("target_id", "")) == extractor_id:
			var removed := _factory_command("REMOVE_LINK", {"link_id":str(power_link.get("id", ""))}, world_id)
			_check(bool(removed.get("accepted", false)), "%s retires its extractor POWER edge after the finite batch" % label)
	_clear_competing_cargo_outputs(extractor_id, resource_id, "", world_id)
	var storage_after := int((_entity(_snapshot(world_id), storage_id).get("inventory", {}) as Dictionary).get(resource_id, 0))
	var extractor_output_after := int((_entity(_snapshot(world_id), extractor_id).get("outputs", {}) as Dictionary).get(resource_id, 0))
	var scoped_extracted := 0
	for event_value in extraction_events:
		var event := event_value as Dictionary
		if str(event.get("type", "")) == "FactoryResourceExtracted" and str(event.get("world_id", "")) == world_id and str(event.get("entity_id", "")) == extractor_id and str(event.get("resource_id", "")) == resource_id:
			scoped_extracted += int(event.get("quantity", 0))
	_check(storage_after >= storage_before + quantity and (remaining_quantity == 0 or scoped_extracted > 0) and storage_after + extractor_output_after == storage_before + extractor_output_before + scoped_extracted, "%s deposits at least the requested %d units from existing plus renewable custody and conserves the exact scoped extraction delta; buffered=%d remaining=%d rate=%.3f before_storage=%d after_storage=%d before_output=%d after_output=%d scoped=%d events=%s" % [label, quantity, buffered_quantity, remaining_quantity, physical_rate, storage_before, storage_after, extractor_output_before, extractor_output_after, scoped_extracted, JSON.stringify(batch_events)])
	return batch_events


## Consolidate already-produced storage custody through explicit CARGO edges.
## This never counts machine inputs/outputs as freely movable inventory.
func _consolidate_factory_item(item_id: String, target_quantity: int, storage_id: String, label: String, world_id: String = EARTH_WORLD_ID) -> void:
	var target_before := int((_entity(_snapshot(world_id), storage_id).get("inventory", {}) as Dictionary).get(item_id, 0))
	var remaining := maxi(0, target_quantity - target_before)
	for source_value in _snapshot(world_id).get("entities", []):
		if remaining <= 0:
			break
		var source := source_value as Dictionary
		var source_id := str(source.get("id", ""))
		if source_id.is_empty() or source_id == storage_id:
			continue
		var available := int((source.get("inventory", {}) as Dictionary).get(item_id, 0))
		if available <= 0:
			continue
		var moved := mini(remaining, available)
		_clear_competing_cargo_inputs(storage_id, item_id, source_id, world_id)
		_clear_competing_cargo_outputs(source_id, item_id, storage_id, world_id)
		_ensure_connection("CARGO", source_id, storage_id, item_id, world_id)
		var source_before := int((_entity(_snapshot(world_id), source_id).get("inventory", {}) as Dictionary).get(item_id, 0))
		var destination_before := int((_entity(_snapshot(world_id), storage_id).get("inventory", {}) as Dictionary).get(item_id, 0))
		var movement_events := _advance(float(moved) / 4.0 * 1000.0, "%s %s Factory consolidation" % [label, item_id])
		_clear_competing_cargo_outputs(source_id, item_id, "", world_id)
		var source_after := int((_entity(_snapshot(world_id), source_id).get("inventory", {}) as Dictionary).get(item_id, 0))
		var destination_after := int((_entity(_snapshot(world_id), storage_id).get("inventory", {}) as Dictionary).get(item_id, 0))
		_check(source_after == source_before - moved and destination_after == destination_before + moved, "%s moves exactly %d %s between visible Factory stores; events=%s" % [label, moved, item_id, JSON.stringify(movement_events)])
		remaining -= moved
		if failures.size() > 0:
			return


## Recursive, bounded local production used by the post-Outer endgame closure.
## Region-specific feedstocks remain explicit external inputs: callers must
## deliver them through public freight before requesting a dependent product.
func _ensure_local_factory_item(item_id: String, target_quantity: int, packet: Dictionary, label: String, world_id: String = EARTH_WORLD_ID) -> void:
	var storage_id := str(packet.get("storage_id", ""))
	var power_source_id := str(packet.get("power_source_id", ""))
	_check(not storage_id.is_empty() and not power_source_id.is_empty() and target_quantity >= 0, "%s supplies a concrete storage, power provider, and finite target for %s" % [label, item_id])
	if failures.size() > 0:
		return
	_consolidate_factory_item(item_id, target_quantity, storage_id, label, world_id)
	var current := int((_entity(_snapshot(world_id), storage_id).get("inventory", {}) as Dictionary).get(item_id, 0))
	if current >= target_quantity:
		return
	if item_id in ["iron_ingot", "copper_ingot"]:
		var raw_item_id := "iron_ore" if item_id == "iron_ingot" else "copper_ore"
		var recipe_id := "grid_refine_iron" if item_id == "iron_ingot" else "grid_refine_copper"
		var extractor_id := str(packet.get("iron_extractor_id" if item_id == "iron_ingot" else "copper_extractor_id", ""))
		var refinery_id := str(packet.get("iron_refinery_id" if item_id == "iron_ingot" else "copper_refinery_id", ""))
		var required_cycles := target_quantity - current
		var batch_count := ceili(float(required_cycles) / 32.0)
		for batch_index in range(batch_count):
			var batch_cycles := mini(32, required_cycles - batch_index * 32)
			# The original ore refineries can legitimately retain a larger raw
			# manifest from an earlier journey.  Reuse another already-built empty
			# Engineering Works when that custody cannot belong to this exact lot;
			# never delete or silently attribute the retained material.
			var refinery_key := "iron_refinery_id" if item_id == "iron_ingot" else "copper_refinery_id"
			refinery_id = _select_exact_recipe_machine(refinery_id, "grid_engineering_works", recipe_id, {raw_item_id:batch_cycles * 2}, "%s exact %s batch %d/%d" % [label, item_id, batch_index + 1, batch_count], world_id)
			packet[refinery_key] = refinery_id
			if failures.size() > 0:
				return
			_extract_resource_batch(extractor_id, raw_item_id, power_source_id, storage_id, batch_cycles * 2, "%s renewable %s batch %d/%d" % [label, raw_item_id, batch_index + 1, batch_count], world_id)
			_run_exact_recipe_batches(refinery_id, recipe_id, power_source_id, storage_id, item_id, batch_cycles, batch_cycles, "%s exact %s batch %d/%d" % [label, item_id, batch_index + 1, batch_count], str(packet.get("waste_storage_id", "")) if item_id == "copper_ingot" else "", world_id)
			if item_id == "copper_ingot":
				var waste_storage_id := str(packet.get("waste_storage_id", ""))
				var waste_quantity := int((_entity(_snapshot(world_id), waste_storage_id).get("inventory", {}) as Dictionary).get("industrial_waste", 0))
				var recycle_cycles := waste_quantity / 2
				if recycle_cycles > 0:
					_run_exact_recipe_batches(str(packet.get("engineering_machine_id", "")), "grid_reprocess_industrial_waste", power_source_id, storage_id, "iron_ingot", recycle_cycles, mini(48, recycle_cycles), "%s conserved copper-waste recovery" % label, "", world_id, {"industrial_waste":waste_storage_id})
			if failures.size() > 0:
				return
	else:
		var plans := {
			"electronics":{"recipe_id":"grid_fabricate_electronics", "machine_key":"engineering_machine_id", "maximum_cycles":32},
			"structural_frame":{"recipe_id":"grid_assemble_frame", "machine_key":"engineering_machine_id", "maximum_cycles":32},
			"repair_material":{"recipe_id":"grid_fabricate_repair_material", "machine_key":"engineering_machine_id", "maximum_cycles":32},
			"chemical_propellant":{"recipe_id":"grid_manufacture_emergency_propellant", "machine_key":"engineering_machine_id", "maximum_cycles":32},
			"steel_composite":{"recipe_id":"grid_refine_steel_electric", "machine_key":"arc_smelter_id", "maximum_cycles":16},
			"precision_actuator":{"recipe_id":"grid_fabricate_precision_actuator", "machine_key":"arc_smelter_id", "maximum_cycles":9},
			"heavy_structural_section":{"recipe_id":"grid_fabricate_heavy_structural_section_robotic", "machine_key":"arc_smelter_id", "maximum_cycles":8},
			"industrial_machine_tools":{"recipe_id":"grid_fabricate_basic_machine_tools", "machine_key":"engineering_machine_id", "maximum_cycles":12},
			"reactor_part":{"recipe_id":"grid_fabricate_reactor_part", "machine_key":"arc_smelter_id", "maximum_cycles":12},
			"power_bus_component":{"recipe_id":"grid_fabricate_power_bus_component", "machine_key":"electronics_works_id", "maximum_cycles":21},
			"data_core":{"recipe_id":"grid_fabricate_data_core", "machine_key":"electronics_works_id", "maximum_cycles":42},
			"superconducting_composite":{"recipe_id":"grid_fabricate_superconducting_composite", "machine_key":"electronics_works_id", "maximum_cycles":42},
			"superconducting_coil":{"recipe_id":"grid_wind_superconducting_coil", "machine_key":"electronics_works_id", "maximum_cycles":42},
			"radiation_hardened_electronics":{"recipe_id":"grid_fabricate_radiation_hardened_electronics", "machine_key":"electronics_works_id", "maximum_cycles":42},
			"thermal_exchange_unit":{"recipe_id":"grid_fabricate_thermal_exchange_unit", "machine_key":"electronics_works_id", "maximum_cycles":42},
			"thorium_fuel":{"recipe_id":"grid_prepare_thorium_fuel", "machine_key":"electronics_works_id", "maximum_cycles":48},
			"antimatter_cell":{"recipe_id":"grid_build_antimatter_cell", "machine_key":"electronics_works_id", "maximum_cycles":25},
			"fusion_service_component":{"recipe_id":"grid_fabricate_fusion_service_component", "machine_key":"electronics_works_id", "maximum_cycles":42},
			"quantum_component":{"recipe_id":"grid_fabricate_quantum_component", "machine_key":"assembly_array_id", "maximum_cycles":38},
			"logistics_handling_equipment":{"recipe_id":"grid_fabricate_logistics_handling_equipment", "machine_key":"assembly_array_id", "maximum_cycles":38},
			"automated_control_core":{"recipe_id":"grid_fabricate_automated_control_core", "machine_key":"assembly_array_id", "maximum_cycles":48},
			"construction_robotics":{"recipe_id":"grid_fabricate_construction_robotics", "machine_key":"assembly_array_id", "maximum_cycles":38},
			"project_core":{"recipe_id":"grid_assemble_project_core", "machine_key":"assembly_array_id", "maximum_cycles":24}
		}
		var plan: Dictionary = plans.get(item_id, {})
		_check(not plan.is_empty(), "%s requires externally freighted physical custody for non-local item %s; storage=%s" % [label, item_id, JSON.stringify(_entity(_snapshot(world_id), storage_id).get("inventory", {}))])
		if failures.size() > 0:
			return
		var recipe_id := str(plan.get("recipe_id", ""))
		var recipe_definition := {}
		for recipe_value in (_snapshot(world_id).get("palette", {}) as Dictionary).get("recipes", []):
			var palette_recipe := recipe_value as Dictionary
			if str(palette_recipe.get("id", "")) == recipe_id:
				recipe_definition = palette_recipe
				break
		_check(not recipe_definition.is_empty(), "%s sees the unlocked canonical recipe for %s" % [label, item_id])
		if failures.size() > 0:
			return
		var output_per_cycle := 0
		for output_value in recipe_definition.get("outputs", []):
			var recipe_output := output_value as Dictionary
			if str(recipe_output.get("item", "")) == item_id:
				output_per_cycle = int(recipe_output.get("quantity", 0))
		var required_cycles := ceili(float(target_quantity - current) / float(output_per_cycle)) if output_per_cycle > 0 else 0
		var maximum_cycles := int(plan.get("maximum_cycles", 1))
		var batch_count := ceili(float(required_cycles) / float(maximum_cycles))
		for batch_index in range(batch_count):
			var batch_cycles := mini(maximum_cycles, required_cycles - batch_index * maximum_cycles)
			# A later sibling dependency may consume an earlier one (for example a
			# precision actuator consumes steel needed by its parent structural
			# section).  Two bounded closure passes restore the final parent manifest;
			# the explicit check below fails closed if future content needs a planner.
			for dependency_pass in range(2):
				for input_value in recipe_definition.get("inputs", []):
					var recipe_input := input_value as Dictionary
					var input_item_id := str(recipe_input.get("item", ""))
					_ensure_local_factory_item(input_item_id, int(recipe_input.get("quantity", 0)) * batch_cycles, packet, "%s dependency pass %d for %s" % [label, dependency_pass + 1, item_id], world_id)
					if failures.size() > 0:
						return
			var parent_manifest_ready := true
			var parent_inventory: Dictionary = _entity(_snapshot(world_id), storage_id).get("inventory", {})
			for input_value in recipe_definition.get("inputs", []):
				var recipe_input := input_value as Dictionary
				parent_manifest_ready = parent_manifest_ready and int(parent_inventory.get(str(recipe_input.get("item", "")), 0)) >= int(recipe_input.get("quantity", 0)) * batch_cycles
			_check(parent_manifest_ready, "%s closes the exact bounded parent manifest for %s after dependency production; inventory=%s" % [label, item_id, JSON.stringify(parent_inventory)])
			if failures.size() > 0:
				return
			_run_exact_recipe_batches(str(packet.get(str(plan.get("machine_key", "")), "")), recipe_id, power_source_id, storage_id, item_id, batch_cycles, batch_cycles, "%s %s batch %d/%d" % [label, item_id, batch_index + 1, batch_count], str(packet.get("waste_storage_id", "")) if recipe_id == "grid_prepare_thorium_fuel" else "", world_id)
			if failures.size() > 0:
				return
	var final_quantity := int((_entity(_snapshot(world_id), storage_id).get("inventory", {}) as Dictionary).get(item_id, 0))
	_check(final_quantity >= target_quantity, "%s physically closes local %s at or above the finite target; target=%d final=%d" % [label, item_id, target_quantity, final_quantity])


## Select an already-built machine whose visible buffers can belong wholly to
## one exact recipe lot.  A different clean sibling is preferred over deleting
## an oversized legacy input or allowing stale output to inflate the lot's
## public-storage delta.
func _select_exact_recipe_machine(preferred_id: String, definition_id: String, recipe_id: String, required_inputs: Dictionary, label: String, world_id: String = EARTH_WORLD_ID) -> String:
	var snapshot := _snapshot(world_id)
	var candidates: Array = _entities_with_definition(snapshot, definition_id)
	candidates.sort_custom(func(left_value, right_value):
		var left_id := str((left_value as Dictionary).get("id", ""))
		var right_id := str((right_value as Dictionary).get("id", ""))
		if left_id == preferred_id:
			return true
		if right_id == preferred_id:
			return false
		return left_id < right_id
	)
	var selected_id := ""
	var rejected: Array = []
	for candidate_value in candidates:
		var candidate := candidate_value as Dictionary
		var candidate_id := str(candidate.get("id", ""))
		var inputs: Dictionary = candidate.get("inputs", {})
		var outputs: Dictionary = candidate.get("outputs", {})
		var compatible := str(candidate.get("status", "")) != "UNDER_CONSTRUCTION"
		for input_item_value in inputs:
			var input_item_id := str(input_item_value)
			var retained := int(inputs.get(input_item_id, 0))
			if retained > int(required_inputs.get(input_item_id, 0)):
				compatible = false
				break
		var retained_output := 0
		for output_item_value in outputs:
			retained_output += int(outputs.get(str(output_item_value), 0))
		if retained_output > 0:
			compatible = false
		if compatible:
			selected_id = candidate_id
			break
		rejected.append({"id":candidate_id, "recipe_id":str(candidate.get("recipe_id", "")), "inputs":inputs, "outputs":outputs})
	_check(not selected_id.is_empty(), "%s finds an already-built %s with no stale output and no input beyond the exact %s manifest; required=%s rejected=%s" % [label, definition_id, recipe_id, JSON.stringify(required_inputs), JSON.stringify(rejected)])
	if not selected_id.is_empty() and selected_id != preferred_id:
		_check(true, "%s selects clean sibling %s instead of retained-buffer machine %s for %s" % [label, selected_id, preferred_id, recipe_id])
	return selected_id


func _earth_freight_recovery_packet(packet: Dictionary) -> Dictionary:
	return {
		"copper_refinery_id":str(packet.get("copper_refinery_id", "")),
		"engineering_works_id":str(packet.get("engineering_machine_id", "")),
		"iron_refinery_id":str(packet.get("iron_refinery_id", "")),
		"power_source_id":str(packet.get("power_source_id", "")),
		"bulk_storage_id":str(packet.get("storage_id", ""))
	}


## Bring one renewable remote resource into the Earth Factory in capacity-safe
## chunks.  Every return receives a freshly projected public operating reserve;
## no remote stock or route service is assumed to be free between batches.
func _return_remote_resource_to_earth(resource_id: String, quantity: int, maximum_chunk: int, remote_location_id: String, remote_world_id: String, extractor_id: String, remote_power_id: String, remote_storage_id: String, path_costs: Dictionary, packet: Dictionary, label: String, additional_power_source_ids: Array = []) -> void:
	_check(quantity > 0 and maximum_chunk > 0, "%s declares a finite capacity-safe remote return" % label)
	if failures.size() > 0:
		return
	var chunk_count := ceili(float(quantity) / float(maximum_chunk))
	for chunk_index in range(chunk_count):
		var chunk := mini(maximum_chunk, quantity - chunk_index * maximum_chunk)
		var remote_storage := _entity(_snapshot(remote_world_id), remote_storage_id)
		var stored := int((remote_storage.get("inventory", {}) as Dictionary).get(resource_id, 0))
		if stored < chunk:
			_extract_resource_batch(extractor_id, resource_id, remote_power_id, remote_storage_id, chunk - stored, "%s renewable source batch %d/%d" % [label, chunk_index + 1, chunk_count], remote_world_id, additional_power_source_ids)
		if failures.size() > 0:
			return
		var repair_projection: Dictionary = game.maintenance_recovery_snapshot(remote_location_id, "repair_material", int(path_costs.get("repair_material", 0)), 600000.0)
		var remote_repair_target := maxi(int(path_costs.get("repair_material", 0)), int(repair_projection.get("gross_production_target", 0)))
		var support_manifest := {"chemical_propellant":int(path_costs.get("chemical_propellant", 0)), "repair_material":remote_repair_target}
		# The support manifest itself has two shipments.  Produce only the exact
		# payload plus their projected Earth dispatch debit; the freight helper
		# independently converges repair stock.  A fixed surplus per raw-resource
		# chunk would accumulate hundreds of stranded units during Megastructure
		# streaming and eventually fill the single Earth staging depot.
		var earth_cp_spendable := int(path_costs.get("chemical_propellant", 0)) * support_manifest.size()
		var earth_cp_projection: Dictionary = game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "chemical_propellant", earth_cp_spendable, 5000.0)
		var earth_cp_required := int(support_manifest.get("chemical_propellant", 0)) + maxi(earth_cp_spendable, int(earth_cp_projection.get("gross_production_target", earth_cp_spendable)))
		var earth_cp_available := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("chemical_propellant", 0))
		_ensure_local_factory_item("chemical_propellant", maxi(0, earth_cp_required - earth_cp_available), packet, "%s exact Earth support fuel" % label)
		if failures.size() > 0:
			return
		var support_shipment_count := support_manifest.keys().filter(func(item_value): return int(support_manifest.get(str(item_value), 0)) > 0).size()
		var support_repair_spend := support_shipment_count * int(path_costs.get("repair_material", 0))
		var support_repair_target := int(support_manifest.get("repair_material", 0)) + int((game.maintenance_recovery_snapshot(EARTH_LOCATION_ID, "repair_material", support_repair_spend, 5000.0) as Dictionary).get("gross_production_target", 0))
		var support_repair_total := int((_snapshot(EARTH_WORLD_ID).get("location_available_inventory", {}) as Dictionary).get("repair_material", 0))
		for repair_entity_value in _snapshot(EARTH_WORLD_ID).get("entities", []):
			support_repair_total += int((((repair_entity_value as Dictionary).get("inventory", {}) as Dictionary).get("repair_material", 0)))
		var support_repair_shortfall := maxi(0, support_repair_target - support_repair_total)
		if support_repair_shortfall > 0:
			var rolling_repair_cycles := support_repair_shortfall + 8
			_ensure_local_factory_item("iron_ingot", rolling_repair_cycles * 2, packet, "%s rolling return-support repair iron" % label)
			_ensure_local_factory_item("copper_ingot", rolling_repair_cycles, packet, "%s rolling return-support repair copper" % label)
			if failures.size() > 0:
				return
		var support_result := _freight_earth_manifest_to_remote(remote_location_id, remote_world_id, support_manifest, "%s source operating reserve %d/%d" % [label, chunk_index + 1, chunk_count], path_costs, _earth_freight_recovery_packet(packet))
		packet["engineering_machine_id"] = str(support_result.get("repair_works_id", packet.get("engineering_machine_id", "")))
		if support_result.is_empty() or failures.size() > 0:
			return
		_export_to_location(resource_id, chunk, "%s source cargo %d/%d" % [label, chunk_index + 1, chunk_count], remote_world_id, remote_storage_id)
		var returned := _freight_location_cargo(remote_location_id, remote_world_id, EARTH_LOCATION_ID, EARTH_WORLD_ID, resource_id, chunk, path_costs, "%s public return %d/%d" % [label, chunk_index + 1, chunk_count])
		if returned.is_empty() or failures.size() > 0:
			return
		_import_from_location(resource_id, chunk, str(packet.get("storage_id", "")), "%s Earth Factory custody %d/%d" % [label, chunk_index + 1, chunk_count])
	var final_quantity := int((_entity(_snapshot(EARTH_WORLD_ID), str(packet.get("storage_id", ""))).get("inventory", {}) as Dictionary).get(resource_id, 0))
	_check(final_quantity >= quantity, "%s returns at least its finite %d-unit target into explicit Earth Factory custody; final=%d" % [label, quantity, final_quantity])


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
