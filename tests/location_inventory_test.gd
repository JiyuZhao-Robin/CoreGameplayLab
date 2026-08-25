extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "Lab content loads")
	if not failures.is_empty():
		_finish()
		return
	_test_version_authority(database)
	_test_location_creation(database)
	_test_legacy_inventory_migration(database)
	_test_inventory_conservation(database)
	_test_reserve_and_commitment_ownership(database)
	_test_save_load_round_trip(database)
	_test_offline_round_trip(database)
	_finish()


func _test_version_authority(database: ContentDatabase) -> void:
	_check(str(ProjectSettings.get_setting("application/config/version", "")) == GameVersion.PRODUCT_VERSION, "project version matches GameVersion")
	_check(database.version == GameVersion.PRODUCT_VERSION, "content version matches GameVersion")
	_check(SpaceGameState.SAVE_VERSION == GameVersion.SAVE_SCHEMA_VERSION, "save schema comes from GameVersion")


func _test_location_creation(database: ContentDatabase) -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	_check(state.locations.size() == database.regions.size(), "one Location exists for every Lab system-map region")
	var main_base := state.location_state(SpaceGameState.MAIN_BASE_LOCATION_ID)
	_check(str(main_base.get("type", "")) == LocationState.ARTIFICIAL and str(main_base.get("system_id", "")) == "sol", "Main Base is an Artificial Location in Sol")
	for field in ["id", "type", "system_id", "discovery_state", "survey_state", "inventory", "power", "industry_summary", "logistics_summary", "projects_summary", "fleet_presence"]:
		_check(main_base.has(field), "Location exposes required field '%s'" % field)


func _test_legacy_inventory_migration(database: ContentDatabase) -> void:
	var legacy := SpaceGameState.create_new(database.domains.keys(), database.regions).to_dictionary()
	legacy["save_version"] = 24
	legacy.erase("locations")
	legacy["inventory"] = {"iron_ore":17, "electronics":4}
	legacy["inventory_reserves"] = {"iron_ore":3}
	legacy["research"]["reserved_costs"] = {"electronics":2}
	legacy["research"].erase("location_id")
	legacy["industrial_operations"][0]["location_id"] = ""
	legacy["industrial_operations"][0]["status"] = "RUNNING"
	legacy["industrial_operations"][0]["reserved_costs"] = {"iron_ore":1}
	var migrated := SpaceGameState.from_dictionary(legacy, database.domains.keys(), database.regions)
	_check(migrated.item_quantity("iron_ore", SpaceGameState.MAIN_BASE_LOCATION_ID) == 17 and migrated.aggregate_item_quantity("iron_ore") == 17, "legacy stock migrates once to Main Base")
	_check(int(migrated.location_reserves().get("iron_ore", 0)) == 3, "legacy reserve migrates to Main Base")
	_check(str(migrated.research.get("location_id", "")) == SpaceGameState.MAIN_BASE_LOCATION_ID, "legacy research commitment receives a Location owner")
	_check(str(migrated.industrial_operations[0].get("location_id", "")) == SpaceGameState.MAIN_BASE_LOCATION_ID, "empty legacy operation owner migrates to Main Base")
	var migrated_payload := migrated.to_dictionary()
	_check(not migrated_payload.has("inventory") and not migrated_payload.has("inventory_reserves"), "migrated save does not serialize legacy inventory authorities")


func _test_inventory_conservation(database: ContentDatabase) -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	state.location_inventory().clear()
	state.add_item("iron_ore", 40, "earth_orbit")
	state.add_item("iron_ore", 25, "lunar_space")
	_check(state.aggregate_item_quantity("iron_ore") == 65, "aggregate inventory is a sum read model")
	_check(state.remove_item("iron_ore", 9, "lunar_space"), "location removal succeeds against its owner")
	_check(state.item_quantity("iron_ore", "earth_orbit") == 40 and state.item_quantity("iron_ore", "lunar_space") == 16 and state.aggregate_item_quantity("iron_ore") == 56, "location arithmetic conserves authoritative stock")


func _test_reserve_and_commitment_ownership(database: ContentDatabase) -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	state.location_inventory().clear()
	state.add_item("iron_ore", 20, "earth_orbit")
	state.add_item("iron_ore", 30, "lunar_space")
	state.set_item_reserve("iron_ore", 4, "earth_orbit")
	state.set_item_reserve("iron_ore", 3, "lunar_space")
	state.research.merge({"status":"RUNNING", "location_id":"earth_orbit", "reserved_costs":{"iron_ore":2}}, true)
	state.industrial_operations[0].merge({"status":"RUNNING", "location_id":"earth_orbit", "reserved_costs":{"iron_ore":5}}, true)
	state.industrial_operations[1].merge({"status":"RUNNING", "location_id":"lunar_space", "reserved_costs":{"iron_ore":7}}, true)
	_check(state.available_item_quantity("iron_ore", "earth_orbit") == 9, "Main Base availability subtracts only Main Base reserve and commitments")
	_check(state.available_item_quantity("iron_ore", "lunar_space") == 20, "Lunar availability subtracts only Lunar reserve and commitments")
	_check(state.aggregate_reserved_quantity("iron_ore") == 7 and state.aggregate_committed_quantity("iron_ore") == 14, "aggregate reserve and commitment views sum explicit Location owners")


func _test_save_load_round_trip(database: ContentDatabase) -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	state.add_item("copper_ore", 11, "lunar_space")
	state.set_item_reserve("copper_ore", 2, "lunar_space")
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(restored.locations.keys().size() == state.locations.keys().size(), "save/load restores all Locations")
	_check(restored.location_inventory("lunar_space") == state.location_inventory("lunar_space") and restored.location_reserves("lunar_space") == state.location_reserves("lunar_space"), "save/load preserves Location stock and reserves")
	_check(restored.aggregate_inventory() == state.aggregate_inventory(), "save/load conserves aggregate resources")


func _test_offline_round_trip(database: ContentDatabase) -> void:
	var simulation := SimulationEngine.new(database)
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	state.add_item("iron_ore", 77, "earth_orbit")
	state.add_item("iron_ore", 21, "lunar_space")
	simulation.ensure_frontier_state(state)
	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	var before := restored.aggregate_inventory().duplicate(true)
	var repair_before := restored.aggregate_item_quantity("repair_material")
	simulation.advance(restored, 6.0 * 60.0 * 60.0 * 1000.0)
	var second_restore := SpaceGameState.from_dictionary(restored.to_dictionary(), database.domains.keys(), database.regions)
	var after := restored.aggregate_inventory().duplicate(true)
	before.erase("repair_material")
	after.erase("repair_material")
	_check(after == before and repair_before - restored.aggregate_item_quantity("repair_material") == 1, "idle offline advance changes only the explicit Active-fleet maintenance sink")
	_check(second_restore.aggregate_inventory() == restored.aggregate_inventory(), "offline save/load does not duplicate Location resources")


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: Lab Location and per-Location inventory foundation")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
