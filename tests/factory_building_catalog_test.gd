extends SceneTree

const Catalog = preload("res://src/core/factory_building_catalog.gd")
const Database = preload("res://src/core/content_database.gd")
var failures: Array[String] = []


func _init() -> void:
	var database := Database.new()
	_check(database.load_from_file("res://data/content.json"), "consolidated content validates: %s" % [database.errors])
	for alias_value in Catalog.BUILDING_ALIASES:
		var alias_id := str(alias_value)
		var canonical_id := Catalog.canonical_building_id(alias_id)
		_check(not database.factory_buildings.has(alias_id), "retired building removed: %s" % alias_id)
		_check(not database.items.has("building_%s" % alias_id), "retired kit removed: %s" % alias_id)
		_check(database.factory_buildings.has(canonical_id), "replacement exists: %s" % canonical_id)
		var legacy_id := "manufacture_%s" % alias_id
		var legacy: Dictionary = database.factory_recipes.get(legacy_id, {})
		_check(bool(legacy.get("legacy_only", false)), "old manufacture is save-only: %s" % legacy_id)
		_check(legacy.get("outputs", []).any(func(output): return str(output.get("item", "")) == "building_%s" % canonical_id and int(output.get("quantity", 0)) == 1), "old work yields canonical kit: %s" % legacy_id)
		for building in database.factory_buildings.values():
			_check(not building.get("recipe_ids", []).has(legacy_id), "old manufacture absent from active recipes: %s" % legacy_id)
	var assembler: Dictionary = database.factory_buildings.get("grid_engineering_works", {})
	_check(assembler.get("completion_effects", []).has({"type":"unlock_facility", "facility":"electronics_facility"}), "electronics progression survives")
	_check(assembler.get("completion_effects", []).any(func(effect): return str(effect.get("facility", "")) == "assembly_yard" and effect.get("requirements", []).has({"type":"technology", "id":"heavy_industry"})), "assembly progression survives")
	for recipe_id in ["dsp_electromagnetic_matrix", "dsp_energy_matrix", "dsp_structure_matrix", "dsp_information_matrix", "dsp_gravity_matrix", "dsp_universe_matrix"]:
		_check(assembler.get("recipe_ids", []).has(recipe_id), "assembler manufactures matrix: %s" % recipe_id)
		_check(not database.factory_buildings.get("grid_dsp_matrix_lab", {}).get("recipe_ids", []).has(recipe_id), "research lab no longer manufactures: %s" % recipe_id)
	_check(database.factory_buildings.get("grid_dsp_matrix_lab", {}).get("recipe_ids", []).has("dsp_matrix_research"), "matrix research remains independent")
	var chemical: Dictionary = database.factory_buildings.get("grid_dsp_chemical_plant", {})
	for recipe_id in ["dsp_deuterium_fractionation", "dsp_deuterium", "dsp_strange_matter", "dsp_antimatter"]:
		_check(chemical.get("recipe_ids", []).has(recipe_id), "chemical production retained: %s" % recipe_id)
	_check(not database.factory_recipes.get("dsp_sulfuric_acid", {}).get("requirements", []).has({"type":"technology", "id":"advanced_propulsion"}), "removed quantum tier does not gate base chemistry")
	var miner: Dictionary = database.factory_buildings.get("grid_surface_mine", {})
	for category in ["solid", "gas", "exotic", "liquid"]:
		_check(miner.get("resource_categories", []).has(category), "unified miner covers %s" % category)
	var gas_profile := {}
	for profile in miner.get("resource_profiles", []):
		if profile.get("resource_categories", []).has("gas"):
			gas_profile = profile
	_check(gas_profile.get("requirements", []).has({"type":"technology", "id":"heavy_extraction"}), "gas extraction retains technology gate")
	_check(is_equal_approx(float(gas_profile.get("mining_rate_per_second", 0.0)), 2.5), "gas extraction retains rate")
	for special_id in ["grid_planetary_core", "grid_drone_tower", "grid_dsp_orbital_collector", "grid_dsp_artificial_star", "grid_dsp_energy_exchanger", "grid_dsp_ray_receiver", "grid_dsp_space_station_construction_launcher"]:
		_check(database.factory_buildings.has(special_id), "independent function remains: %s" % special_id)
	if failures.is_empty():
		print("Factory building catalog tests: PASS")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
