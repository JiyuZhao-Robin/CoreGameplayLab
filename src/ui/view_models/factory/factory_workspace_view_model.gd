class_name FactoryWorkspaceViewModel
extends RefCounted

## Presentation-only adapter for the Factory v1 contract.  It deliberately
## copies all input data so controls cannot accidentally retain mutable state.

const PROTOCOL_VERSION := 1


func build(snapshot: Dictionary) -> Dictionary:
	var result := snapshot.duplicate(true)
	if int(result.get("protocol_version", 0)) != PROTOCOL_VERSION:
		return {"valid":false, "protocol_version":PROTOCOL_VERSION, "reason_code":"UNSUPPORTED_PROTOCOL"}
	if not bool(result.get("valid", true)):
		return result
	for array_key in ["resource_fields", "entities", "links", "construction_orders"]:
		var rows: Array = result.get(array_key, []) if result.get(array_key, []) is Array else []
		rows.sort_custom(func(a, b): return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")))
		result[array_key] = rows
	var palette: Dictionary = result.get("palette", {}) if result.get("palette", {}) is Dictionary else {}
	for array_key in ["buildings", "recipes"]:
		var rows: Array = palette.get(array_key, []) if palette.get(array_key, []) is Array else []
		rows.sort_custom(func(a, b): return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")))
		palette[array_key] = rows
	result["palette"] = palette
	return result


## Intent construction lives here so the workspace is a presentation client of
## the application boundary, rather than a second owner of Factory state.
func command_intent(snapshot: Dictionary, command_id: String, kind: String, payload: Dictionary) -> Dictionary:
	return {
		"protocol_version":PROTOCOL_VERSION,
		"command_id":command_id,
		"kind":kind.to_upper(),
		"world_id":str(snapshot.get("world_id", "")),
		"base_topology_revision":maxi(0, int(snapshot.get("topology_revision", 0))),
		"base_runtime_revision":maxi(0, int(snapshot.get("runtime_revision", 0))),
		"payload":payload.duplicate(true)
	}


func building_by_id(snapshot: Dictionary, building_id: String) -> Dictionary:
	var palette: Dictionary = snapshot.get("palette", {}) if snapshot.get("palette", {}) is Dictionary else {}
	for building_value in palette.get("buildings", []):
		var building := building_value as Dictionary
		if str(building.get("id", "")) == building_id:
			return building.duplicate(true)
	return {}


func recipe_by_id(snapshot: Dictionary, recipe_id: String) -> Dictionary:
	var palette: Dictionary = snapshot.get("palette", {}) if snapshot.get("palette", {}) is Dictionary else {}
	for recipe_value in palette.get("recipes", []):
		var recipe := recipe_value as Dictionary
		if str(recipe.get("id", "")) == recipe_id:
			return recipe.duplicate(true)
	return {}


## This is intentionally a local, conservative preview. The authoritative
## terrain/resource check remains in execute_factory_command(), whose reason
## code is shown verbatim by the UI after a rejection.
func placement_preview(snapshot: Dictionary, building: Dictionary, origin: Vector2i) -> Dictionary:
	if building.is_empty():
		return {"valid":false, "reason_code":"NO_BUILDING_SELECTED", "footprint":{}}
	var size := footprint_size(building.get("footprint", {}))
	var footprint := {
		"origin":{"x":origin.x, "y":origin.y},
		"size":{"x":size.x, "y":size.y}
	}
	var bounds: Dictionary = snapshot.get("bounds", {}) if snapshot.get("bounds", {}) is Dictionary else {}
	var bounds_origin := footprint_origin(bounds)
	var bounds_size := footprint_size(bounds)
	if origin.x < bounds_origin.x or origin.y < bounds_origin.y or origin.x + size.x > bounds_origin.x + bounds_size.x or origin.y + size.y > bounds_origin.y + bounds_size.y:
		return {"valid":false, "reason_code":"OUT_OF_BOUNDS", "footprint":footprint}
	for entity_value in snapshot.get("entities", []):
		if footprints_overlap(footprint, (entity_value as Dictionary).get("footprint", {})):
			return {"valid":false, "reason_code":"FOOTPRINT_OCCUPIED", "footprint":footprint}
	for order_value in snapshot.get("construction_orders", []):
		if footprints_overlap(footprint, (order_value as Dictionary).get("footprint", {})):
			return {"valid":false, "reason_code":"CONSTRUCTION_OCCUPIED", "footprint":footprint}
	return {"valid":true, "reason_code":"", "footprint":footprint}


func compatible_cargo_items(source: Dictionary, target: Dictionary) -> Array:
	var source_ports: Dictionary = source.get("ports", {}) if source.get("ports", {}) is Dictionary else {}
	var target_ports: Dictionary = target.get("ports", {}) if target.get("ports", {}) is Dictionary else {}
	var outputs: Array = source_ports.get("outputs", []) if source_ports.get("outputs", []) is Array else []
	var inputs: Array = target_ports.get("inputs", []) if target_ports.get("inputs", []) is Array else []
	var result: Array = []
	var source_provides_any := outputs.has("*")
	var target_accepts_any := inputs.has("*")
	if source_provides_any and not target_accepts_any:
		for item_value in inputs:
			var target_item_id := str(item_value)
			if not target_item_id.is_empty() and target_item_id != "*" and not result.has(target_item_id):
				result.append(target_item_id)
	else:
		for item_value in outputs:
			var item_id := str(item_value)
			if not item_id.is_empty() and item_id != "*" and (target_accepts_any or inputs.has(item_id)) and not result.has(item_id):
				result.append(item_id)
		if source_provides_any and target_accepts_any:
			for item_collection_key in ["outputs", "inventory"]:
				var quantities: Dictionary = source.get(item_collection_key, {}) if source.get(item_collection_key, {}) is Dictionary else {}
				for item_id_value in quantities.keys():
					var stored_item_id := str(item_id_value)
					if not stored_item_id.is_empty() and not result.has(stored_item_id):
						result.append(stored_item_id)
	result.sort()
	return result


func is_power_connection_valid(source: Dictionary, target: Dictionary) -> bool:
	var source_ports: Dictionary = source.get("ports", {}) if source.get("ports", {}) is Dictionary else {}
	var target_ports: Dictionary = target.get("ports", {}) if target.get("ports", {}) is Dictionary else {}
	return bool(source_ports.get("provides_power", false)) and bool(target_ports.get("accepts_power", false))


func footprints_overlap(a_value: Variant, b_value: Variant) -> bool:
	var a: Dictionary = a_value as Dictionary if a_value is Dictionary else {}
	var b: Dictionary = b_value as Dictionary if b_value is Dictionary else {}
	var a_origin := footprint_origin(a)
	var b_origin := footprint_origin(b)
	var a_size := footprint_size(a)
	var b_size := footprint_size(b)
	return a_origin.x < b_origin.x + b_size.x and a_origin.x + a_size.x > b_origin.x and a_origin.y < b_origin.y + b_size.y and a_origin.y + a_size.y > b_origin.y


func node_rows(snapshot: Dictionary) -> Array:
	var result: Array = []
	for field_value in snapshot.get("resource_fields", []):
		var field := field_value as Dictionary
		result.append({"id":str(field.get("id", "")), "kind":"RESOURCE_FIELD", "is_entity":false, "data":field.duplicate(true)})
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		result.append({"id":str(entity.get("id", "")), "kind":str(entity.get("node_kind", "UNKNOWN")), "is_entity":true, "data":entity.duplicate(true)})
	return result


func storage_entities(snapshot: Dictionary) -> Array:
	var storages: Array = []
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("node_kind", "")) == "STORAGE":
			storages.append(entity.duplicate(true))
	return storages



func footprint_origin(footprint: Dictionary) -> Vector2i:
	var origin: Dictionary = footprint.get("origin", {}) if footprint.get("origin", {}) is Dictionary else {}
	return Vector2i(
		int(origin.get("x", footprint.get("x", footprint.get("origin_x", 0)))),
		int(origin.get("y", footprint.get("y", footprint.get("origin_y", 0))))
	)


func footprint_size(footprint: Dictionary) -> Vector2i:
	var size: Dictionary = footprint.get("size", {}) if footprint.get("size", {}) is Dictionary else {}
	return Vector2i(
		maxi(1, int(size.get("x", footprint.get("width", footprint.get("size_x", 1))))),
		maxi(1, int(size.get("y", footprint.get("height", footprint.get("size_y", 1)))))
	)
