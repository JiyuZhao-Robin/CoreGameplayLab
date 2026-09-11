class_name FactoryBuildingMigration
extends RefCounted

## Pure, repeatable migration shared by save loading and transaction clones.
## Instance identities and occupied rectangles remain stable. Only catalog
## references change; item-key collisions sum physical quantities.
const Catalog = preload("res://src/core/factory_building_catalog.gd")
const ITEM_FIELDS := ["item", "item_id", "product_id", "deployment_item_id", "resource_id", "selected_item_id", "filter_item_id"]
const BUILDING_FIELDS := ["definition_id", "building_definition_id", "landing_definition_id", "selected_building_id", "target_building_id"]
const ITEM_ARRAY_FIELDS := ["pinned_items", "item_ids", "accepted_item_ids", "allowed_item_ids"]

static func migrate_save(source: Dictionary) -> Dictionary:
	return _rewrite(source) as Dictionary

static func _rewrite(value: Variant, field: String = "") -> Variant:
	if value is Dictionary:
		var result := {}
		# Canonical policy/configuration wins on non-quantity collisions.
		for key in value:
			if Catalog.canonical_item_id(str(key)) == str(key):
				result[key] = _child(value[key], str(key))
		for key in value:
			var mapped := Catalog.canonical_item_id(str(key))
			if mapped == str(key):
				continue
			var rewritten: Variant = _child(value[key], str(key))
			if not result.has(mapped):
				result[mapped] = rewritten
			elif (rewritten is int or rewritten is float) and (result[mapped] is int or result[mapped] is float):
				result[mapped] += rewritten
			elif rewritten is Dictionary and result[mapped] is Dictionary:
				result[mapped].merge(rewritten, false)
		# Matrix production moved to the manufacturer; research-only labs remain.
		if str(result.get("definition_id", "")) == "grid_dsp_matrix_lab" and str(result.get("recipe_id", "")) in ["dsp_electromagnetic_matrix", "dsp_energy_matrix", "dsp_structure_matrix", "dsp_information_matrix", "dsp_gravity_matrix", "dsp_universe_matrix"]:
			result["definition_id"] = "grid_engineering_works"
			result["deployment_item_id"] = "building_grid_engineering_works"
			var required: Dictionary = result.get("required_items", {})
			if required.has("building_grid_dsp_matrix_lab"):
				required["building_grid_engineering_works"] = int(required.get("building_grid_engineering_works", 0)) + int(required["building_grid_dsp_matrix_lab"])
				required.erase("building_grid_dsp_matrix_lab")
		# Preserve a running retired manufacturing recipe's original BOM and
		# progress. Its compatibility definition now produces the canonical kit.
		var recipe_id := str(result.get("recipe_id", ""))
		if recipe_id.begins_with("manufacture_") and Catalog.BUILDING_ALIASES.has(recipe_id.trim_prefix("manufacture_")):
			result["legacy_recipe_continuation"] = true
		return result
	if value is Array:
		var result: Array = []
		for entry in value:
			result.append(Catalog.canonical_item_id(str(entry)) if field in ITEM_ARRAY_FIELDS and entry is String else _rewrite(entry))
		return result
	if value is String:
		if field in ITEM_FIELDS:
			return Catalog.canonical_item_id(value)
		if field in BUILDING_FIELDS:
			return Catalog.canonical_building_id(value)
	return value

static func _child(value: Variant, field: String) -> Variant:
	# Historical evidence and idempotency fingerprints are not live inventory.
	if field.contains("archive") or field in ["source_metadata", "command_receipts", "request_fingerprint"]:
		return value.duplicate(true) if value is Dictionary or value is Array else value
	return _rewrite(value, field)
