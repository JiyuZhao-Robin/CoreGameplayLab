extends SceneTree

## Exercise the actual shared Location adapter and interstellar reservation
## authority with two worlds whose drones already hold more cargo than fits.
const Transport = preload("res://src/core/factory_drone_transport.gd")
const LOCATION := "drone-reservation-location"
const ITEM := "ore"
var failures: Array[String] = []
var database: ContentDatabase
var simulation: SimulationEngine
var state: SpaceGameState


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game: Variant = root.get_node_or_null("Game")
	if game != null:
		game.set_process(false)
		game.persistence_enabled = false
	database = ContentDatabase.new()
	database.items = {ITEM:{"id":ITEM, "storage_class":"BULK", "storage_units":1.0}}
	database.factory_buildings = {"tower":{"id":"tower", "kind":"STORAGE", "inventory_capacity":0, "drone_tower":true, "drone_count":0, "drone_radius_tiles":64}}
	simulation = SimulationEngine.new(database)
	_test_overbooked_returns_and_fifo()
	_test_uncontended_capacity()
	_test_interstellar_claim_survives_drone_overbooking()
	_test_reduced_capacity_preserves_existing_stock()
	if failures.is_empty():
		print("PASS factory_drone_reservation_test")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _fresh(capacity: int) -> void:
	state = SpaceGameState.new()
	state.ensure_location(LOCATION)
	state.locations[LOCATION]["inventory"] = {}
	state.locations[LOCATION]["logistics"]["storage_capacities"] = {"BULK":capacity, "COMPONENT":0, "FLUID":0, "SPECIAL":0}
	state.logistics_network = {"shipments":[], "item_statistics":{}}
	# Deliberately insert the newer world first. Admission must follow persisted
	# waiting age, not Dictionary insertion or the simulation's visit order.
	state.factory_worlds = {"a":_world("a", 100.0), "b":_world("b", 0.0)}


func _world(id: String, created: float) -> Dictionary:
	return {
		"world_id":id, "location_id":LOCATION,
		"entities":{"tower":{"id":"tower", "definition_id":"tower", "kind":"STORAGE", "drone_tower":true, "status":"IDLE", "footprint":{"origin":{"x":0,"y":0}, "size":{"x":1,"y":1}}, "inputs":{}, "outputs":{}}},
		"drone_shipments":{"return":_job("return", created)}
	}


func _job(id: String, created: float) -> Dictionary:
	return {"id":id, "tower_id":"tower", "source_id":"removed-producer", "target_id":"tower", "item_id":ITEM, "cargo":{ITEM:10}, "destination_kind":"WAREHOUSE", "phase":"RETURNING", "status":"IN_TRANSIT", "created_at_ms":created, "remaining_ms":0.0, "travel_ms":1.0, "from_position":{"x":0.5,"y":0.5}, "to_position":{"x":0.5,"y":0.5}}


func _free(world_id: String) -> int:
	return int(simulation.factory_inventory_context(state, state.factory_worlds[world_id])["free_capacity"][ITEM])


func _deliver(world_id: String) -> void:
	var world: Dictionary = state.factory_worlds[world_id]
	Transport.advance(world, 1.0, database.factory_buildings, {}, {}, simulation.factory_inventory_context(state, world))


func _held(world_id: String) -> int:
	var amount := 0
	for job in state.factory_worlds[world_id]["drone_shipments"].values():
		amount += int(job.get("cargo", {}).get(ITEM, 0))
	return amount


func _assets() -> int:
	var amount := state.item_quantity(ITEM, LOCATION) + _held("a") + _held("b")
	for ship in state.logistics_network["shipments"]:
		amount += int(ship.get("cargo", {}).get(ITEM, 0))
	return amount


func _test_overbooked_returns_and_fifo() -> void:
	_fresh(10)
	_check(_free("a") == 0 and _free("b") == 10, "oldest held return owns the ten available slots across two worlds")
	_check(int(simulation.logistics.incoming_storage_reservation(state, LOCATION, ITEM)) == 10, "reservation projection reports admitted slots rather than impossible twenty-slot claims")
	_deliver("a")
	_check(_held("a") == 10 and state.item_quantity(ITEM, LOCATION) == 0, "visiting the newer world first cannot steal the older return's space")
	_deliver("b")
	_check(state.item_quantity(ITEM, LOCATION) == 10 and _held("b") == 0 and _assets() == 20, "one world unloads despite overcommit without loss or overcapacity")
	state.location_inventory(LOCATION)[ITEM] = 0 # Consumer uses the delivered ten.
	state.factory_worlds["b"]["drone_shipments"]["newer"] = _job("newer", 200.0)
	_check(_free("a") == 10 and _free("b") == 0, "previously blocked return precedes newly generated cargo once capacity reopens")
	_deliver("b")
	_deliver("a")
	_check(_held("a") == 0 and _held("b") == 10 and state.item_quantity(ITEM, LOCATION) == 10, "persistent overbooking cannot starve the waiting world")


func _test_uncontended_capacity() -> void:
	_fresh(30)
	state.logistics_network["shipments"] = [{"id":"ship", "destination":LOCATION, "cargo":{ITEM:5}}]
	_check(_free("a") == 15 and _free("b") == 15, "non-overcommitted contexts exclude own ten but honor the other ten plus five interstellar slots")
	_check(int(simulation.logistics.incoming_storage_reservation(state, LOCATION, ITEM)) == 25, "ordinary reservation totals remain unchanged")
	_check(int(simulation.logistics.destination_free_capacity(state, LOCATION, ITEM)) == 5, "unclaimed capacity remains available to new interstellar dispatch")
	_deliver("a")
	_deliver("b")
	_check(state.item_quantity(ITEM, LOCATION) == 20 and _assets() == 25, "both admitted returns deposit while retaining interstellar ownership")


func _test_interstellar_claim_survives_drone_overbooking() -> void:
	_fresh(10)
	var ship := {"id":"ship", "destination":LOCATION, "cargo":{ITEM:6}}
	state.logistics_network["shipments"] = [ship]
	_check(_free("a") == 0 and _free("b") == 4, "existing interstellar shipment keeps six slots and oldest drone receives only the remaining four")
	_check(int(simulation.logistics._destination_free_capacity_excluding_shipment(state, LOCATION, ITEM, "ship")) == 6, "excluding the arriving ship does not reassign its reservation to blocked drones")
	_deliver("b")
	_check(state.item_quantity(ITEM, LOCATION) == 4 and _held("b") == 6 and _held("a") == 10, "drone partially unloads within its admitted capacity and retains the remainder")
	_check(bool(simulation.logistics._deliver_shipment(state, ship)), "the interstellar shipment actually unloads into its protected six slots")
	state.logistics_network["shipments"] = []
	_check(state.item_quantity(ITEM, LOCATION) == 10 and _assets() == 26, "partial drone and interstellar delivery preserve all twenty-six items")
	_deliver("a")
	_deliver("b")
	_check(state.item_quantity(ITEM, LOCATION) == 10 and _held("a") + _held("b") == 16, "full storage cannot be exceeded by retrying retained flights")


func _test_reduced_capacity_preserves_existing_stock() -> void:
	_fresh(10)
	state.location_inventory(LOCATION)[ITEM] = 12
	_check(_free("a") == 0 and _free("b") == 0, "over-capacity saved stock admits no new drone cargo")
	_deliver("a")
	_deliver("b")
	_check(state.item_quantity(ITEM, LOCATION) == 12 and _assets() == 32, "capacity reduction preserves both existing stock and held return cargo")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
