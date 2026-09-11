class_name FactoryBuildingCatalog
extends RefCounted

## Consolidates the merged source catalog before ContentDatabase indexes it.
## Source metadata remains historical; live references use the approved buildings.
const BUILDING_ALIASES := {
	"grid_cryogenic_extractor":"grid_surface_mine",
	"grid_exotic_extractor":"grid_surface_mine",
	"grid_dsp_mining_machine":"grid_surface_mine",
	"grid_dsp_oil_extractor":"grid_surface_mine",
	"grid_dsp_water_pump":"grid_surface_mine",
	"grid_electronics_works":"grid_engineering_works",
	"grid_assembly_array":"grid_engineering_works",
	"grid_dsp_assembling_machine_mk1":"grid_engineering_works",
	"grid_dsp_assembling_machine_mk2":"grid_engineering_works",
	"grid_dsp_assembling_machine_mk3":"grid_engineering_works",
	"grid_dsp_construction_center":"grid_engineering_works",
	"grid_dsp_arc_smelter":"grid_arc_smelter",
	"grid_dsp_plane_smelter":"grid_arc_smelter",
	"grid_dsp_quantum_chemical_plant":"grid_dsp_chemical_plant",
	"grid_dsp_fractionator":"grid_dsp_chemical_plant",
	"grid_dsp_miniature_particle_collider":"grid_dsp_chemical_plant"
}

const APPROVED_PRODUCTION_IDS := [
	"grid_surface_mine", "grid_arc_smelter", "grid_engineering_works",
	"grid_dsp_oil_refinery", "grid_dsp_chemical_plant", "grid_dsp_thermal_power_plant"
]


static func canonical_building_id(definition_id: String) -> String:
	return str(BUILDING_ALIASES.get(definition_id, definition_id))


static func canonical_item_id(item_id: String) -> String:
	if item_id.begins_with("building_"):
		return "building_%s" % canonical_building_id(item_id.trim_prefix("building_"))
	return item_id


static func apply(parsed: Dictionary) -> void:
	var buildings := _index(parsed.get("factory_buildings", []))
	var recipes := _index(parsed.get("factory_recipes", []))
	_build_resource_profiles(buildings)
	for alias_value in BUILDING_ALIASES:
		var alias_id := str(alias_value)
		var canonical_id := canonical_building_id(alias_id)
		if not buildings.has(alias_id) or not buildings.has(canonical_id):
			continue
		var source: Dictionary = buildings[alias_id]
		var target: Dictionary = buildings[canonical_id]
		_merge_recipes(source, target, recipes)
		for source_effect in source.get("completion_effects", []):
			var effect: Dictionary = source_effect.duplicate(true)
			_merge_unique(effect, "requirements", source.get("requirements", []))
			_merge_unique(target, "completion_effects", [effect])
		# Precision is an existing production capability, not another building tier.
		if source.has("precision_manufacturing"):
			target["precision_manufacturing"] = maxi(int(target.get("precision_manufacturing", 0)), int(source["precision_manufacturing"]))
	_move_matrix_manufacturing(buildings, recipes)
	_retire_duplicate_manufacturing(buildings, recipes)

	var retained_buildings: Array = []
	for building in parsed.get("factory_buildings", []):
		if not BUILDING_ALIASES.has(str(building.get("id", ""))):
			retained_buildings.append(building)
	parsed["factory_buildings"] = retained_buildings
	var retained_items: Array = []
	for item in parsed.get("items", []):
		var item_id := str(item.get("id", ""))
		if canonical_item_id(item_id) == item_id:
			retained_items.append(item)
	parsed["items"] = retained_items
	_remap_references(parsed)


static func _index(rows: Array) -> Dictionary:
	var result := {}
	for row in rows:
		if row is Dictionary:
			result[str(row.get("id", ""))] = row
	return result


static func _merge_unique(target: Dictionary, field: String, values: Array) -> void:
	if values.is_empty():
		return
	var merged: Array = target.get(field, []).duplicate(true)
	for value in values:
		if not merged.has(value):
			merged.append(value.duplicate(true) if value is Dictionary or value is Array else value)
	target[field] = merged


static func _merge_recipes(source: Dictionary, target: Dictionary, recipes: Dictionary) -> void:
	var target_ids: Array = target.get("recipe_ids", []).duplicate()
	for recipe_id_value in source.get("recipe_ids", []):
		var recipe_id := str(recipe_id_value)
		if target_ids.has(recipe_id) or not recipes.has(recipe_id):
			continue
		var recipe: Dictionary = recipes[recipe_id]
		# Shared recipes already available on the approved building must not inherit
		# a removed higher tier's gate. Unique recipes keep their former access gate.
		if not recipe_id.begins_with("manufacture_"):
			_merge_unique(recipe, "requirements", source.get("requirements", []))
			_merge_unique(recipe, "reveal_requirements", source.get("reveal_requirements", []))
		target_ids.append(recipe_id)
	if not target_ids.is_empty():
		target["recipe_ids"] = target_ids


static func _move_matrix_manufacturing(buildings: Dictionary, recipes: Dictionary) -> void:
	if not buildings.has("grid_dsp_matrix_lab") or not buildings.has("grid_engineering_works"):
		return
	var lab: Dictionary = buildings["grid_dsp_matrix_lab"]
	var moved: Array = []
	var research: Array = []
	for recipe_id_value in lab.get("recipe_ids", []):
		var recipe_id := str(recipe_id_value)
		var recipe: Dictionary = recipes.get(recipe_id, {})
		if not recipe.get("outputs", []).is_empty() and not bool(recipe.get("legacy_only", false)):
			moved.append(recipe_id)
			recipe["source_building_id"] = "grid_engineering_works"
		else:
			research.append(recipe_id)
	var source := lab.duplicate(true)
	source["recipe_ids"] = moved
	_merge_recipes(source, buildings["grid_engineering_works"], recipes)
	lab["recipe_ids"] = research


static func _retire_duplicate_manufacturing(buildings: Dictionary, recipes: Dictionary) -> void:
	var retired := {}
	for alias_value in BUILDING_ALIASES:
		var recipe_id := "manufacture_%s" % str(alias_value)
		if recipes.has(recipe_id):
			var recipe: Dictionary = recipes[recipe_id]
			recipe["legacy_only"] = true
			recipe["replacement_building_id"] = canonical_building_id(str(alias_value))
			retired[recipe_id] = true
	for building_value in buildings.values():
		var building: Dictionary = building_value
		var active_ids: Array = []
		var legacy_ids: Array = building.get("legacy_recipe_ids", []).duplicate()
		for recipe_id_value in building.get("recipe_ids", []):
			var recipe_id := str(recipe_id_value)
			if retired.has(recipe_id):
				if not legacy_ids.has(recipe_id):
					legacy_ids.append(recipe_id)
			else:
				active_ids.append(recipe_id)
		if building.has("recipe_ids"):
			building["recipe_ids"] = active_ids
		if not legacy_ids.is_empty():
			building["legacy_recipe_ids"] = legacy_ids


static func _build_resource_profiles(buildings: Dictionary) -> void:
	if not buildings.has("grid_surface_mine"):
		return
	var miner: Dictionary = buildings["grid_surface_mine"]
	if miner.has("resource_profiles"):
		return
	var profiles: Array = []
	var categories: Array = []
	# DSP's slower solid miner is superseded by the approved unrestricted miner.
	for definition_id in ["grid_surface_mine", "grid_cryogenic_extractor", "grid_exotic_extractor", "grid_dsp_oil_extractor", "grid_dsp_water_pump"]:
		if not buildings.has(definition_id):
			continue
		var source: Dictionary = buildings[definition_id]
		var profile := {
			"resource_categories":source.get("resource_categories", []).duplicate(),
			"allowed_resource_ids":source.get("allowed_resource_ids", []).duplicate(),
			"requirements":source.get("requirements", []).duplicate(true),
			"reveal_requirements":source.get("reveal_requirements", []).duplicate(true),
			"mining_rate_per_second":float(source.get("mining_rate_per_second", 1.0)),
			"resource_coverage_loss_per_missing_tile":float(source.get("resource_coverage_loss_per_missing_tile", 0.1)),
			"power_demand_kw":float(source.get("power_demand_kw", 0.0)),
			"output_capacity":int(source.get("output_capacity", 20))
		}
		profiles.append(profile)
		for category in profile["resource_categories"]:
			if not categories.has(category):
				categories.append(category)
	miner["resource_categories"] = categories
	miner["resource_profiles"] = profiles
	miner.erase("allowed_resource_ids")


static func _remap_references(value: Variant) -> Variant:
	if value is Dictionary:
		var record: Dictionary = value
		for key_value in record.keys():
			var key := str(key_value)
			if key in ["source_metadata", "provenance"]:
				continue
			var mapped_key := canonical_item_id(key)
			var mapped_value: Variant = _remap_references(record[key_value])
			if mapped_key != key:
				# Inventory/cost maps may hold both a retired and canonical kit.
				if record.has(mapped_key) and (mapped_value is int or mapped_value is float):
					record[mapped_key] += mapped_value
				else:
					record[mapped_key] = mapped_value
				record.erase(key_value)
			else:
				record[key_value] = mapped_value
		return record
	if value is Array:
		for index in range(value.size()):
			value[index] = _remap_references(value[index])
		return value
	if value is String:
		return canonical_item_id(canonical_building_id(value))
	return value
