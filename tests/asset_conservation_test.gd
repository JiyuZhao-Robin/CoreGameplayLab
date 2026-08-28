extends SceneTree

const MAIN_LOCATION := SpaceGameState.MAIN_BASE_LOCATION_ID

var failures: Array[String] = []
var database: ContentDatabase


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	database = ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "core content loads for asset-conservation tests")
	if failures.is_empty():
		_test_survey_ship_claim_survives_transaction_and_roundtrip()
		_test_fleet_resupply_is_reserve_safe_and_movement_neutral()
		_test_shipment_roundtrip_arrives_exactly_once()
		_test_nonproduction_ingress_respects_storage_capacity()
	_finish()


func _test_survey_ship_claim_survives_transaction_and_roundtrip() -> void:
	var simulation := SimulationEngine.new(database)
	simulation.set_simulation_profile("TEST_PROFILE")
	var state := _new_state(simulation)
	state.regions["asteroid_belt"] = true
	simulation.ensure_frontier_state(state)
	var survey_ship := state._create_ship_instance("deep_survey_vessel", ["deep_survey_system"], "ISS Conservation Survey")
	var ship_id := str(survey_ship.get("instance_id", ""))
	for item_id_value in simulation.survey_mission_costs(LocationState.SURVEYED):
		var item_id := str(item_id_value)
		state.add_item(item_id, int(simulation.survey_mission_costs(LocationState.SURVEYED).get(item_id, 0)), MAIN_LOCATION)
	state.regions["asteroid_belt"] = true
	simulation.ensure_frontier_state(state)

	_check(simulation.start_survey_mission(state, "asteroid_belt", LocationState.SURVEYED, [ship_id], MAIN_LOCATION), "a Survey Mission starts through normal Simulation validation")
	_assert_running_survey_owns_ship(state, ship_id, "immediately after mission start")

	var transaction := GameStateTransaction.new(state, database.domains.keys())
	var transaction_clone := transaction.commit()
	_assert_running_survey_owns_ship(transaction_clone, ship_id, "after a normal transaction clone")

	var save_roundtrip := SpaceGameState.from_dictionary(transaction_clone.to_dictionary(), database.domains.keys(), database.regions)
	_assert_running_survey_owns_ship(save_roundtrip, ship_id, "after save/load roundtrip")
	_check(not save_roundtrip.ship_can_refit(ship_id), "a running Survey vessel cannot be double-spent by refit")
	_check(not save_roundtrip.ship_is_unassigned_docked(ship_id), "a running Survey vessel cannot re-enter the unassigned docked pool")


func _assert_running_survey_owns_ship(state: SpaceGameState, ship_id: String, context: String) -> void:
	var mission: Dictionary = state.survey_mission
	var ship := state.ship_by_id(ship_id)
	_check(str(mission.get("status", "")) == "RUNNING" and mission.get("assigned_ship_ids", []).count(ship_id) == 1, "Survey Mission retains exactly one physical ship claim %s" % context)
	_check(str(ship.get("status", "")) == "EXPEDITION", "Survey vessel remains active %s" % context)
	_check(str(ship.get("assignment", {}).get("type", "")) == "SURVEY_MISSION" and str(ship.get("assignment", {}).get("mission_id", "")) == str(mission.get("mission_id", "")), "Survey vessel assignment matches its authoritative mission %s" % context)


func _test_fleet_resupply_is_reserve_safe_and_movement_neutral() -> void:
	var simulation := SimulationEngine.new(database)
	simulation.set_simulation_profile("TEST_PROFILE")
	var state := _new_state(simulation)
	var item_id := "chemical_propellant"
	state.add_item(item_id, 20, MAIN_LOCATION)
	var on_hand := state.item_quantity(item_id, MAIN_LOCATION)
	state.set_item_reserve(item_id, on_hand, MAIN_LOCATION)
	_check(state.has_method("transfer_inventory_to_fleet_supply"), "Fleet resupply uses the shared reserve-safe Domain transfer")
	if not state.has_method("transfer_inventory_to_fleet_supply"):
		return
	var consumed_before := _consumed_quantity(state, item_id)
	var transferred := int(state.call("transfer_inventory_to_fleet_supply", item_id, 10, "expedition", MAIN_LOCATION))
	_check(transferred == 0, "fleet resupply cannot take strategically Reserved inventory")
	_check(state.item_quantity(item_id, MAIN_LOCATION) == on_hand, "a fully Reserved source retains all physical inventory")
	_check(state.fleet_supply_quantity(item_id, "expedition") == 0, "a fully Reserved source produces no live Fleet supply")
	_check(_consumed_quantity(state, item_id) == consumed_before, "a rejected/zero Fleet transfer does not create consumption")

	state.set_item_reserve(item_id, 0, MAIN_LOCATION)
	var live_before := state.item_quantity(item_id, MAIN_LOCATION) + state.fleet_supply_quantity(item_id, "expedition")
	consumed_before = _consumed_quantity(state, item_id)
	transferred = int(state.call("transfer_inventory_to_fleet_supply", item_id, 10, "expedition", MAIN_LOCATION))
	var loaded := state.fleet_supply_quantity(item_id, "expedition")
	var live_after := state.item_quantity(item_id, MAIN_LOCATION) + loaded
	_check(transferred == 10 and loaded == 10, "Available inventory loads the requested quantity into live Fleet cargo")
	_check(live_after == live_before, "Inventory to Fleet resupply is a movement-neutral ownership transfer")
	_check(_consumed_quantity(state, item_id) == consumed_before, "Inventory to Fleet transfer is not misclassified as Consumed")

	var roundtrip := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(roundtrip.item_quantity(item_id, MAIN_LOCATION) + roundtrip.fleet_supply_quantity(item_id, "expedition") == live_before, "Inventory plus Fleet supply survives save/load without duplication or loss")
	var actual_consumption := mini(3, roundtrip.fleet_supply_quantity(item_id, "expedition"))
	consumed_before = _consumed_quantity(roundtrip, item_id)
	_check(actual_consumption > 0 and roundtrip.consume_fleet_supply(item_id, actual_consumption, "expedition"), "Fleet propellant is consumed through its Domain operation")
	_check(roundtrip.fleet_supply_quantity(item_id, "expedition") == loaded - actual_consumption, "real Fleet consumption removes the exact live quantity")
	_check(_consumed_quantity(roundtrip, item_id) == consumed_before + actual_consumption, "real Fleet consumption enters the per-item Consumed ledger exactly once")


func _test_shipment_roundtrip_arrives_exactly_once() -> void:
	var simulation := SimulationEngine.new(database)
	simulation.set_simulation_profile("TEST_PROFILE")
	var state := _new_state(simulation)
	var destination := "lunar_space"
	state.regions[destination] = true
	state.region_states[destination].merge({"discovered":true, "exploration_state":LocationState.SURVEYED}, true)
	simulation.ensure_frontier_state(state)
	state.location_state(destination)["survey_state"] = LocationState.SURVEYED
	state.location_state(destination)["logistics"]["storage_capacities"] = {"BULK":1000, "COMPONENT":1000, "FLUID":1000, "SPECIAL":1000}
	state.location_state(destination)["logistics"]["hub_throughput"] = 100
	state.location_state(destination)["logistics"]["local_throughput_capacity"] = 100.0
	state.add_item("electronics", 12, MAIN_LOCATION)
	state.add_item("chemical_propellant", 20, MAIN_LOCATION)
	state.add_item("repair_material", 20, MAIN_LOCATION)
	_check(simulation.logistics.configure_policy(state, MAIN_LOCATION, "electronics", {"mode":"SUPPLY", "reserve":0, "dispatch_threshold":1}), "Shipment source policy is accepted")
	_check(simulation.logistics.configure_policy(state, destination, "electronics", {"mode":"DEMAND", "target":5, "priority":100, "source_lock":MAIN_LOCATION, "route_lock":"earth_lunar_freight"}), "Shipment demand policy is accepted")
	var dispatch_events: Array[Dictionary] = simulation.logistics._dispatch(state)
	_check(not dispatch_events.is_empty() and state.logistics_network.get("shipments", []).size() == 1, "normal Logistics dispatch creates one persistent in-transit Shipment")
	if state.logistics_network.get("shipments", []).is_empty():
		return
	var shipment: Dictionary = state.logistics_network.get("shipments", [])[0]
	var shipment_id := str(shipment.get("id", ""))
	var dispatched_quantity := int(shipment.get("cargo", {}).get("electronics", 0))
	_check(dispatched_quantity == 5, "the real Shipment carries the requested bounded cargo")
	simulation.logistics.clear_policy(state, MAIN_LOCATION, "electronics")
	simulation.logistics.clear_policy(state, destination, "electronics")

	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(restored.logistics_network.get("shipments", []).any(func(row): return str((row as Dictionary).get("id", "")) == shipment_id), "the in-transit Shipment identity survives save/load")
	var destination_before := restored.item_quantity("electronics", destination)
	simulation.advance(restored, float(shipment.get("remaining_ms", shipment.get("total_ms", 0.0))) + 1.0)
	_check(restored.item_quantity("electronics", destination) == destination_before + dispatched_quantity, "the restored Shipment arrives with its exact cargo once")
	_check(not restored.logistics_network.get("shipments", []).any(func(row): return str((row as Dictionary).get("id", "")) == shipment_id), "the delivered Shipment leaves InTransit ownership")

	var delivered_roundtrip := SpaceGameState.from_dictionary(restored.to_dictionary(), database.domains.keys(), database.regions)
	var delivered_quantity := delivered_roundtrip.item_quantity("electronics", destination)
	simulation.advance(delivered_roundtrip, 10000.0)
	_check(delivered_roundtrip.item_quantity("electronics", destination) == delivered_quantity, "save/load after arrival cannot deliver the same Shipment twice")
	_check(not delivered_roundtrip.logistics_network.get("shipments", []).any(func(row): return str((row as Dictionary).get("id", "")) == shipment_id), "a completed Shipment cannot reappear after another roundtrip")


func _test_nonproduction_ingress_respects_storage_capacity() -> void:
	_test_full_storage_retains_recovered_fleet_cargo()


func _test_full_storage_retains_recovered_fleet_cargo() -> void:
	var simulation := SimulationEngine.new(database)
	simulation.set_simulation_profile("TEST_PROFILE")
	var state := _new_state(simulation)
	var item_id := "dark_matter"
	var quantity := 2
	state.add_recovered_cargo(item_id, quantity, "expedition")
	var storage_class := simulation.storage_class_for_item(item_id)
	var used: Dictionary = simulation.location_storage_used(state, MAIN_LOCATION)
	state.location_state(MAIN_LOCATION)["logistics"]["storage_capacities"][storage_class] = int(ceil(float(used.get(storage_class, 0.0))))
	var inventory_before := state.item_quantity(item_id, MAIN_LOCATION)
	_check(simulation.has_method("unload_fleet_cargo"), "Fleet unloading uses the capacity-aware Simulation transaction")
	if not simulation.has_method("unload_fleet_cargo"):
		return
	var unloaded := bool(simulation.call("unload_fleet_cargo", state, "expedition", MAIN_LOCATION, false))
	_check(not unloaded, "Fleet unload reports a blocked transfer when destination storage is full")
	_check(state.item_quantity(item_id, MAIN_LOCATION) == inventory_before, "full storage does not accept recovered Fleet cargo")
	_check(int(state.fleet_logistics_runtime("expedition").get("recovered", {}).get(item_id, 0)) == quantity, "blocked Fleet unload retains cargo under Fleet ownership")
	_check(_storage_within_capacity(state, simulation, MAIN_LOCATION), "Fleet unloading never drives a storage class beyond capacity")


func _new_state(simulation: SimulationEngine) -> SpaceGameState:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	simulation.ensure_frontier_state(state)
	return state


func _consumed_quantity(state: SpaceGameState, item_id: String) -> int:
	return int(state.statistics.get("item_consumed_totals", {}).get(item_id, 0))


func _storage_within_capacity(state: SpaceGameState, simulation: SimulationEngine, location_id: String) -> bool:
	for row_value in simulation.location_storage_snapshot(state, location_id).get("classes", {}).values():
		var row := row_value as Dictionary
		if float(row.get("used", 0.0)) > float(row.get("capacity", 0.0)) + 0.000001:
			return false
	return true


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: " + message)
	else:
		failures.append("FAIL: " + message)


func _finish() -> void:
	if failures.is_empty():
		print("Asset conservation test passed")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
