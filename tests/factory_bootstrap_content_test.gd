extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	root.get_node("Game").set_process(false)
	_test_live_factory_starter_snapshot()
	_test_missing_landing_core_is_rejected()
	_test_missing_starter_miner_is_rejected()
	_test_missing_starter_resources_is_rejected()
	_test_unselectable_starter_miner_recipe_is_rejected()
	_finish()


func _database() -> ContentDatabase:
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "content loads before Factory starter audit: %s" % str(database.errors))
	return database


func _test_live_factory_starter_snapshot() -> void:
	var database := _database()
	if not database.errors.is_empty():
		return
	var snapshot := database.factory_bootstrap_reachability_snapshot()
	_check(str(snapshot.get("mode", "")) == "FACTORY_STARTER_QUALITATIVE", "Factory starter snapshot identifies its qualitative Factory contract")
	_check(bool(snapshot.get("qualitative", false)), "Factory starter snapshot explicitly declares qualitative scope")
	_check(bool(snapshot.get("valid", false)), "current core landing, deployment package, fields and manufacturing closure are reachable: %s" % str(snapshot.get("issues", [])))
	_check(snapshot.get("reachable_resource_ids", []).has("iron_ore") and snapshot.get("reachable_resource_ids", []).has("copper_ore"), "starter resource fields seed the iron and copper Factory closure")
	_check(snapshot.get("reachable_recipe_ids", []).has("manufacture_grid_surface_mine"), "starter assembler can select the replacement mining-building recipe")
	_check(snapshot.get("manufacture_recipe_ids", []).has("manufacture_grid_surface_mine"), "finished mining building has an explicit manufacture recipe")
	_check(snapshot.get("not_simulated", []).has("roads_and_power_topology") and snapshot.get("not_simulated", []).has("inventory_quantities"), "static audit does not misrepresent road topology or quantities as simulated")


func _test_missing_landing_core_is_rejected() -> void:
	var database := _database()
	if not database.errors.is_empty():
		return
	var starter: Dictionary = database.factory_grid_rules.get("starter_world", {})
	var inventory: Dictionary = starter.get("inventory", {})
	inventory.erase("building_grid_planetary_core")
	var snapshot := database.factory_bootstrap_reachability_snapshot()
	_check(_has_issue(snapshot, "LANDING_CORE_ITEM_MISSING"), "starter audit rejects a landing core definition without a finished core item in starter inventory")


func _test_missing_starter_miner_is_rejected() -> void:
	var database := _database()
	if not database.errors.is_empty():
		return
	var starter: Dictionary = database.factory_grid_rules.get("starter_world", {})
	var package: Dictionary = starter.get("deployment_package", {})
	package.erase("building_grid_surface_mine")
	var snapshot := database.factory_bootstrap_reachability_snapshot()
	_check(_has_issue(snapshot, "STARTER_RESOURCE_UNHARVESTABLE"), "starter audit rejects resource fields when the supplied starter mine is absent")


func _test_unselectable_starter_miner_recipe_is_rejected() -> void:
	var database := _database()
	if not database.errors.is_empty():
		return
	var assembler: Dictionary = database.factory_buildings.get("grid_engineering_works", {})
	var recipe_ids: Array = assembler.get("recipe_ids", [])
	recipe_ids.erase("manufacture_grid_surface_mine")
	var snapshot := database.factory_bootstrap_reachability_snapshot()
	_check(_has_issue(snapshot, "FINISHED_BUILDING_MANUFACTURER_MISSING"), "starter audit rejects a finished building recipe that no Factory machine can select")
	_check(_has_issue(snapshot, "STARTER_EXTRACTOR_MANUFACTURE_UNREACHABLE"), "starter audit rejects a mine replacement recipe outside the starter machine closure")


func _test_missing_starter_resources_is_rejected() -> void:
	var database := _database()
	database.factory_grid_rules["starter_world"]["resource_fields"] = []
	_check(_has_issue(database.factory_bootstrap_reachability_snapshot(), "STARTER_RESOURCES_MISSING"), "empty starter resource fields cannot produce a vacuous reachability PASS")


func _has_issue(snapshot: Dictionary, code: String) -> bool:
	return (snapshot.get("issues", []) as Array).any(func(issue_value): return str((issue_value as Dictionary).get("code", "")) == code)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: Factory bootstrap content tests")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
