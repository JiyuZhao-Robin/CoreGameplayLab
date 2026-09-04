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
	return Vector2i(int(footprint.get("x", footprint.get("origin_x", 0))), int(footprint.get("y", footprint.get("origin_y", 0))))


func footprint_size(footprint: Dictionary) -> Vector2i:
	return Vector2i(maxi(1, int(footprint.get("width", 1))), maxi(1, int(footprint.get("height", 1))))
