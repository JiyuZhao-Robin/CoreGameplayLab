extends SceneTree

## Location Operations is a presentation projection of the one authoritative
## Location inventory. This deliberately starts at the player-facing landing
## state instead of pre-placing a depot or manufacturing private warehouse stock.

const LOCATION := "earth_orbit"
const WORLD := "earth-surface-grid"

var failures: Array[String] = []
var game: Node
var command_serial := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	game = root.get_node("Game")
	game.persistence_enabled = false
	game.set_process(false)
	_test_empty_landing_and_core_capacity()
	_test_legacy_custody_migrates_once()
	_test_actual_location_changes_drive_trends()
	_test_reset_discards_presentation_samples()
	if failures.is_empty():
		print("LOCATION_STOCK_PROJECTION_PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _fresh_blank_start() -> void:
	game.reset_game()
	command_serial = 0


func _test_empty_landing_and_core_capacity() -> void:
	_fresh_blank_start()
	var world: Dictionary = game.state.factory_worlds[WORLD]
	_check(world.get("entities", {}).is_empty(), "new world has no pre-placed warehouse or industry")
	_check(game.state.item_quantity("building_grid_planetary_core", LOCATION) == 1, "empty landing starts with one deployable core in Location inventory")
	var before: Dictionary = _item(game.location_operations_snapshot(LOCATION), "iron_ore")
	_check(not before.is_empty() and int(before.get("quantity", -1)) == 0 and int(before.get("location_quantity", -1)) == 0 and int(before.get("warehouse_quantity", -1)) == 0, "unstocked material is visible without a second warehouse balance")
	var base_capacity := int(before.get("capacity", 0))
	var core_definition: Dictionary = game.content.factory_buildings["grid_planetary_core"]
	var deployment := _deploy_core()
	_check(bool(deployment.get("accepted", false)), "real DEPLOY_BUILDING command lands the core")
	var after: Dictionary = _item(game.location_operations_snapshot(LOCATION), "iron_ore")
	var expected_capacity := base_capacity + int(core_definition.get("inventory_capacity", 0))
	_check(int(after.get("capacity", 0)) == expected_capacity and expected_capacity > base_capacity, "deployed core expands every item slot by its installed storage capacity")
	_check(int(after.get("quantity", -1)) == game.state.item_quantity("iron_ore", LOCATION) and int(after.get("warehouse_quantity", -1)) == 0, "operations stock comes solely from Location inventory after landing")


func _test_legacy_custody_migrates_once() -> void:
	_fresh_blank_start()
	_check(bool(_deploy_core().get("accepted", false)), "core is available for legacy-custody migration fixture")
	var world: Dictionary = game.state.factory_worlds[WORLD]
	var core := _entity_by_definition(world, "grid_planetary_core")
	if core.is_empty():
		_check(false, "deployed core is present for legacy-custody migration")
		return
	# Simulate an old save carrying stock inside a STORAGE entity. Reconciliation
	# transfers custody exactly once and clears that retired private balance.
	core["inventory"] = {"iron_ore":11}
	game.simulation.ensure_frontier_state(game.state)
	var once: Dictionary = _item(game.location_operations_snapshot(LOCATION), "iron_ore")
	_check(int(once.get("quantity", -1)) == 11 and int(once.get("location_quantity", -1)) == 11 and int(once.get("warehouse_quantity", -1)) == 0, "legacy storage stock moves once into the single Location balance")
	_check((core.get("inventory", {}) as Dictionary).is_empty(), "legacy entity inventory is cleared after custody migration")
	game.simulation.ensure_frontier_state(game.state)
	var twice: Dictionary = _item(game.location_operations_snapshot(LOCATION), "iron_ore")
	_check(int(twice.get("quantity", -1)) == 11 and game.state.item_quantity("iron_ore", LOCATION) == 11, "repeating frontier reconciliation never credits legacy stock twice")


func _test_actual_location_changes_drive_trends() -> void:
	_fresh_blank_start()
	_check(bool(_deploy_core().get("accepted", false)), "core deploys before stock trend projection")
	# Establish the first sample from real Location custody, then add and remove
	# stock through the State API. No entity/warehouse mutation participates in
	# the displayed balance or its rate.
	var first: Dictionary = _item(game.location_operations_snapshot(LOCATION), "iron_ore")
	_check(not bool(first.get("trend_known", true)), "first stock render has no invented surplus")
	game.state.add_item("iron_ore", 10, LOCATION)
	game.state.total_elapsed_ms += 1_000
	var growth: Dictionary = _item(game.location_operations_snapshot(LOCATION), "iron_ore")
	_check(bool(growth.get("trend_known", false)) and float(growth.get("net_rate_per_minute", 0.0)) > 0.0, "actual Location inventory growth creates a positive stock trend")
	_check(is_equal_approx(float(growth.get("fill_ratio", 0.0)), 10.0 / float(growth.get("capacity", 1))), "fill projection uses one material quantity over its independent item capacity")
	game.state.total_elapsed_ms += 31_000
	game.location_operations_snapshot(LOCATION)
	_check(game.state.remove_item("iron_ore", 4, LOCATION), "actual Location inventory can be consumed for negative trend fixture")
	game.state.total_elapsed_ms += 31_000
	var loss: Dictionary = _item(game.location_operations_snapshot(LOCATION), "iron_ore")
	_check(bool(loss.get("trend_known", false)) and float(loss.get("net_rate_per_minute", 0.0)) < 0.0, "actual Location inventory loss creates a negative stock trend")


func _test_reset_discards_presentation_samples() -> void:
	# The preceding test created samples and modified stock. A fresh player state
	# must neither retain those quantities nor leak a previous session's arrow.
	_fresh_blank_start()
	var row: Dictionary = _item(game.location_operations_snapshot(LOCATION), "iron_ore")
	_check(game.state.item_quantity("iron_ore", LOCATION) == 0 and not bool(row.get("trend_known", true)), "new game resets Location stock and trend sampling")


func _deploy_core() -> Dictionary:
	command_serial += 1
	var world: Dictionary = game.state.factory_worlds[WORLD]
	return game.execute_factory_command({
		"protocol_version":1,
		"command_id":"location-stock-core-%d" % command_serial,
		"kind":"DEPLOY_BUILDING",
		"world_id":WORLD,
		"base_topology_revision":int(world.get("topology_revision", 0)),
		"payload":{"definition_id":"grid_planetary_core", "origin":{"x":110, "y":32}}
	})


func _entity_by_definition(world: Dictionary, definition_id: String) -> Dictionary:
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		if str(entity.get("definition_id", "")) == definition_id:
			return entity
	return {}


func _item(snapshot: Dictionary, item_id: String) -> Dictionary:
	for row_value in snapshot.get("inventory", []):
		var row := row_value as Dictionary
		if str(row.get("id", "")) == item_id:
			return row
	return {}


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
