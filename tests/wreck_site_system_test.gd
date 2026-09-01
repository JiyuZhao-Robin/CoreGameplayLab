extends SceneTree

const WreckSiteSystemScript = preload("res://src/core/wreck_site_system.gd")
var failures: Array[String] = []


func _initialize() -> void:
	var database := ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "content loads with the ship-role contract")
	if not failures.is_empty():
		_finish()
		return
	_test_ship_extraction_is_absent(database)
	_test_combat_and_expedition_recovery_remain(database)
	_test_finite_invasion_aftermath(database)
	_finish()


func _test_ship_extraction_is_absent(database: ContentDatabase) -> void:
	_check(not database.domains.has("mining") and not database.domains.has("salvaging"), "no ship mining or permanent salvage-job domain exists")
	_check(database.activities.values().all(func(activity): return str((activity as Dictionary).get("domain", "")) not in ["mining", "salvaging"]), "no ship mining or permanent salvage-job activity exists")
	var forbidden_fields := ["mining_power", "extraction_power", "extraction_method_efficiency", "salvage_power"]
	var forbidden_capabilities := ["mining", "deep_core_mining", "heavy_mining", "gas_collection", "exotic_containment", "construction_support"]
	for module_value in database.modules.values():
		var module := module_value as Dictionary
		for field in forbidden_fields:
			_check(not module.has(field), "ship module %s has no %s" % [module.get("id", "?"), field])
		for capability_id in forbidden_capabilities:
			_check(not module.get("capabilities", {}).has(capability_id), "ship module %s has no %s capability" % [module.get("id", "?"), capability_id])
	for retired_id in SpaceGameState.RETIRED_SHIP_WORK_MODULE_IDS:
		_check(not database.modules.has(retired_id) and not database.items.has(retired_id), "retired ship work plugin is absent: %s" % retired_id)
	_check(database.ships.has("ultimate_transport") and not database.ships.has("ultimate_miner"), "the former ultimate miner is a logistics hull")


func _test_combat_and_expedition_recovery_remain(database: ContentDatabase) -> void:
	var combat_rewards_remain := false
	for activity_value in database.activities.values():
		var activity := activity_value as Dictionary
		if str(activity.get("domain", "")) == "expedition" and str(activity.get("encounter_type", "")) in ["COMBAT", "BOSS"] and (not activity.get("rewards", []).is_empty() or not activity.get("loot", []).is_empty()):
			combat_rewards_remain = true
			break
	var route_products_remain := false
	for route_value in database.expedition_routes.values():
		for node_value in (route_value as Dictionary).get("nodes", []):
			if not (node_value as Dictionary).get("rewards", []).is_empty():
				route_products_remain = true
				break
	_check(combat_rewards_remain, "combat victories still recover drops and loot")
	_check(route_products_remain, "expedition nodes still return physical products")


func _test_finite_invasion_aftermath(database: ContentDatabase) -> void:
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	var system := WreckSiteSystemScript.new()
	var created := system.create_after_invasion(state, SpaceGameState.MAIN_BASE_LOCATION_ID, "INVASION-000042", 100.0, {"threat":"PIRATE_RAID"})
	_check(bool(created.get("ok", false)), "a resolved invasion can create one finite wreck site")
	var site_id := str(created.get("site_id", ""))
	var site: Dictionary = state.wreck_sites.get(site_id, {})
	_check(not site.is_empty() and not site.has("ship_ids") and not site.has("assigned_ship_ids"), "wreck-site work is not a ship assignment")
	var analyzed := system.apply_work(state, site_id, WreckSiteSystemScript.WORK_KIND_ANALYSIS, 30.0)
	_check(bool(analyzed.get("ok", false)) and float(analyzed.get("remaining_work", -1.0)) == 70.0 and not bool(analyzed.get("exhausted", true)), "analysis consumes the shared finite aftermath budget")

	var restored := SpaceGameState.from_dictionary(state.to_dictionary(), database.domains.keys(), database.regions)
	_check(float(restored.wreck_sites.get(site_id, {}).get("remaining_work", -1.0)) == 70.0, "an active wreck site survives save/load with exact remaining work")
	var exhausted := system.apply_work(restored, site_id, WreckSiteSystemScript.WORK_KIND_SALVAGE, 80.0)
	_check(bool(exhausted.get("ok", false)) and float(exhausted.get("accepted_work", -1.0)) == 70.0 and float(exhausted.get("unaccepted_work", -1.0)) == 10.0, "wreck-site work cannot exceed the remaining finite budget")
	_check(bool(exhausted.get("exhausted", false)) and not restored.wreck_sites.has(site_id) and restored.wreck_site_history.size() == 1, "an exhausted wreck point disappears from the active map")
	_check(not bool(system.apply_work(restored, site_id, WreckSiteSystemScript.WORK_KIND_SALVAGE, 1.0).get("ok", true)), "an exhausted wreck point cannot become a permanent salvage job")


func _check(condition: bool, message: String) -> void:
	if condition:
		return
	if not failures.has(message):
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: ship-role cutover and finite invasion-aftermath interface")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
