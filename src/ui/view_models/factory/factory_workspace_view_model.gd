class_name FactoryWorkspaceViewModel
extends RefCounted

## Presentation-only adapter for the Factory v1 contract. The application
## creates immutable record dictionaries. This adapter detaches and sorts their
## containers without deep-copying every runtime record on each UI refresh.

const PROTOCOL_VERSION := 1
const ChunkIndexScript = preload("res://src/ui/workspaces/factory/factory_canvas_chunk_index.gd")
const Terrain = preload("res://src/core/factory_terrain.gd")

var _buildings_by_id: Dictionary = {}
var _recipes_by_id: Dictionary = {}
var _placement_chunk_index := ChunkIndexScript.new()
var _placement_index_signature := ""
var _placement_entities_by_id: Dictionary = {}
var _placement_orders_by_id: Dictionary = {}


func build(snapshot: Dictionary) -> Dictionary:
	var result := snapshot.duplicate(false)
	if int(result.get("protocol_version", 0)) != PROTOCOL_VERSION:
		return {"valid":false, "protocol_version":PROTOCOL_VERSION, "reason_code":"UNSUPPORTED_PROTOCOL"}
	if not bool(result.get("valid", true)):
		return result
	for array_key in ["resource_fields", "entities", "links", "construction_orders"]:
		var rows: Array = (result.get(array_key, []) as Array).duplicate() if result.get(array_key, []) is Array else []
		rows.sort_custom(func(a, b): return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")))
		result[array_key] = rows
	var palette: Dictionary = (result.get("palette", {}) as Dictionary).duplicate(false) if result.get("palette", {}) is Dictionary else {}
	for array_key in ["buildings", "recipes"]:
		var rows: Array = (palette.get(array_key, []) as Array).duplicate() if palette.get(array_key, []) is Array else []
		rows.sort_custom(func(a, b): return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")))
		palette[array_key] = rows
	result["palette"] = palette
	# Production is an optional v1 extension.  Keep it detached, predictable and
	# non-authoritative so older snapshots remain a fully functional workspace.
	var production: Dictionary = (result.get("production", {}) as Dictionary).duplicate(false) if result.get("production", {}) is Dictionary else {}
	for array_key in ["rows", "production_rows", "groups", "diagnostics"]:
		var rows: Array = (production.get(array_key, []) as Array).duplicate() if production.get(array_key, []) is Array else []
		rows.sort_custom(func(a, b): return str((a as Dictionary).get("id", (a as Dictionary).get("entity_id", ""))) < str((b as Dictionary).get("id", (b as Dictionary).get("entity_id", ""))))
		production[array_key] = rows
	result["production"] = production
	_rebuild_palette_indexes(result)
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
	if _buildings_by_id.is_empty() and not snapshot.is_empty():
		_rebuild_palette_indexes(snapshot)
	var building: Dictionary = _buildings_by_id.get(building_id, {})
	return building.duplicate(false)


func recipe_by_id(snapshot: Dictionary, recipe_id: String) -> Dictionary:
	if _recipes_by_id.is_empty() and not snapshot.is_empty():
		_rebuild_palette_indexes(snapshot)
	var recipe: Dictionary = _recipes_by_id.get(recipe_id, {})
	return recipe.duplicate(false)


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
	_ensure_placement_index(snapshot)
	for y in range(origin.y, origin.y + size.y):
		for x in range(origin.x, origin.x + size.x):
			if not Terrain.is_buildable(snapshot, Vector2i(x, y)):
				return {"valid":false, "reason_code":"TERRAIN_BLOCKED", "footprint":footprint}
	var candidates := _placement_chunk_index.query(Rect2(Vector2(origin), Vector2(size)))
	for entity_id_value in candidates.get("entity_ids", []):
		var entity: Dictionary = _placement_entities_by_id.get(str(entity_id_value), {})
		if footprints_overlap(footprint, entity.get("footprint", {})):
			return {"valid":false, "reason_code":"FOOTPRINT_OCCUPIED", "footprint":footprint}
	for order_id_value in candidates.get("order_ids", []):
		var order: Dictionary = _placement_orders_by_id.get(str(order_id_value), {})
		if footprints_overlap(footprint, order.get("footprint", {})):
			return {"valid":false, "reason_code":"CONSTRUCTION_OCCUPIED", "footprint":footprint}
	return {"valid":true, "reason_code":"", "footprint":footprint}


func _rebuild_palette_indexes(snapshot: Dictionary) -> void:
	_buildings_by_id.clear()
	_recipes_by_id.clear()
	var palette: Dictionary = snapshot.get("palette", {}) if snapshot.get("palette", {}) is Dictionary else {}
	for building_value in palette.get("buildings", []):
		if building_value is Dictionary:
			var building := building_value as Dictionary
			_buildings_by_id[str(building.get("id", ""))] = building
	for recipe_value in palette.get("recipes", []):
		if recipe_value is Dictionary:
			var recipe := recipe_value as Dictionary
			_recipes_by_id[str(recipe.get("id", ""))] = recipe


func _ensure_placement_index(snapshot: Dictionary) -> void:
	var bounds: Dictionary = snapshot.get("bounds", {}) if snapshot.get("bounds", {}) is Dictionary else {}
	var origin := footprint_origin(bounds)
	var extent := footprint_size(bounds)
	var signature := "%s:%d:%d:%d,%d:%d,%d" % [
		str(snapshot.get("world_id", "")),
		int(snapshot.get("topology_revision", 0)),
		int(snapshot.get("chunk_size_tiles", 64)),
		origin.x,
		origin.y,
		extent.x,
		extent.y
	]
	if signature == _placement_index_signature:
		return
	_placement_index_signature = signature
	_placement_entities_by_id.clear()
	_placement_orders_by_id.clear()
	for entity_value in snapshot.get("entities", []):
		if entity_value is Dictionary:
			var entity := entity_value as Dictionary
			_placement_entities_by_id[str(entity.get("id", ""))] = entity
	for order_value in snapshot.get("construction_orders", []):
		if order_value is Dictionary:
			var order := order_value as Dictionary
			_placement_orders_by_id[str(order.get("id", ""))] = order
	_placement_chunk_index.rebuild(snapshot)


func compatible_cargo_items(source: Dictionary, target: Dictionary, catalog_item_ids: Array = []) -> Array:
	var result: Array = []
	for source_port_value in connection_ports(source, "OUTPUT"):
		var source_port: Dictionary = source_port_value as Dictionary
		if str(source_port.get("kind", "")) != "CARGO":
			continue
		for target_port_value in connection_ports(target, "INPUT"):
			var target_port: Dictionary = target_port_value as Dictionary
			if not compatible_port_pair(source, source_port, target, target_port):
				continue
			for item_value in compatible_cargo_items_for_ports(source_port, target_port, source, catalog_item_ids):
				var item_id := str(item_value)
				if not item_id.is_empty() and not result.has(item_id):
					result.append(item_id)
	result.sort()
	return result


func is_power_connection_valid(source: Dictionary, target: Dictionary) -> bool:
	var source_ports: Dictionary = source.get("ports", {}) if source.get("ports", {}) is Dictionary else {}
	var target_ports: Dictionary = target.get("ports", {}) if target.get("ports", {}) is Dictionary else {}
	if bool(source_ports.get("provides_power", false)) and bool(target_ports.get("accepts_power", false)):
		return true
	for source_port_value in connection_ports(source, "OUTPUT"):
		var source_port: Dictionary = source_port_value as Dictionary
		if str(source_port.get("kind", "")) != "POWER":
			continue
		for target_port_value in connection_ports(target, "INPUT"):
			if str((target_port_value as Dictionary).get("kind", "")) == "POWER":
				return true
	return false


## Ports are presentation records, never a second topology model.  Newer
## snapshots can describe individual port ids; old string-array ports are
## expanded into stable synthetic ids so the same canvas gesture works in both.
func connection_ports(entity: Dictionary, direction: String) -> Array:
	var result: Array = []
	var ports_value: Variant = entity.get("ports", {})
	var ports: Dictionary = ports_value as Dictionary if ports_value is Dictionary else {}
	var normalized_direction := direction.to_upper()
	var key := "outputs" if normalized_direction == "OUTPUT" else "inputs"
	var structured_key := "output_ports" if normalized_direction == "OUTPUT" else "input_ports"
	# The factory contract sends input_ports/output_ports when individual port
	# topology is known.  Legacy item arrays are only a compatibility fallback.
	var raw: Array = ports.get(structured_key, []) if ports.get(structured_key, []) is Array else []
	if raw.is_empty():
		raw = ports.get(key, []) if ports.get(key, []) is Array else []
	for index in raw.size():
		var entry_value: Variant = raw[index]
		var entry: Dictionary = {}
		var item_id := ""
		if entry_value is Dictionary:
			entry = (entry_value as Dictionary).duplicate(false)
			item_id = str(entry.get("item_id", entry.get("item", "")))
		else:
			item_id = str(entry_value)
		var port_id := str(entry.get("id", entry.get("port_id", "")))
		if port_id.is_empty():
			port_id = ("out:" if normalized_direction == "OUTPUT" else "in:") + (item_id if not item_id.is_empty() else str(index))
		var channel := str(entry.get("channel", entry.get("kind", "ITEM"))).to_upper()
		result.append({
			"id":port_id,
			"direction":normalized_direction,
			"kind":"POWER" if channel == "POWER" else "CARGO",
			"item_id":item_id,
			"accepts_any":item_id == "*" or bool(entry.get("accepts_any", false)),
			"label":str(entry.get("label", item_id)),
			"index":index
		})
	var has_power_port := false
	for port_value in result:
		if str((port_value as Dictionary).get("kind", "")) == "POWER":
			has_power_port = true
			break
	if normalized_direction == "OUTPUT" and bool(ports.get("provides_power", false)) and not has_power_port:
		result.append({"id":str(ports.get("power_output_id", "power-out")), "direction":"OUTPUT", "kind":"POWER", "item_id":"", "accepts_any":false, "label":"Power", "index":result.size()})
	elif normalized_direction == "INPUT" and bool(ports.get("accepts_power", false)) and not has_power_port:
		result.append({"id":str(ports.get("power_input_id", "power-in")), "direction":"INPUT", "kind":"POWER", "item_id":"", "accepts_any":false, "label":"Power", "index":result.size()})
	return result


func connection_port_by_id(entity: Dictionary, port_id: String, direction: String = "") -> Dictionary:
	for port_value in connection_ports(entity, direction if not direction.is_empty() else "OUTPUT"):
		var port: Dictionary = port_value as Dictionary
		if str(port.get("id", "")) == port_id:
			return port
	if direction.is_empty():
		for port_value in connection_ports(entity, "INPUT"):
			var port: Dictionary = port_value as Dictionary
			if str(port.get("id", "")) == port_id:
				return port
	return {}


func compatible_port_pair(source: Dictionary, source_port: Dictionary, target: Dictionary, target_port: Dictionary) -> bool:
	if source.is_empty() or target.is_empty() or source_port.is_empty() or target_port.is_empty():
		return false
	if str(source_port.get("direction", "")) != "OUTPUT" or str(target_port.get("direction", "")) != "INPUT":
		return false
	var source_kind := str(source_port.get("kind", "CARGO")).to_upper()
	var target_kind := str(target_port.get("kind", "CARGO")).to_upper()
	if source_kind != target_kind:
		return false
	if source_kind == "POWER":
		return is_power_connection_valid(source, target)
	var source_item := str(source_port.get("item_id", ""))
	var target_item := str(target_port.get("item_id", ""))
	return not source_item.is_empty() and (source_item == target_item or source_item == "*" or target_item == "*")


func compatible_cargo_items_for_ports(source_port: Dictionary, target_port: Dictionary, source: Dictionary = {}, catalog_item_ids: Array = []) -> Array:
	if source_port.is_empty() or target_port.is_empty():
		return []
	var source_item := str(source_port.get("item_id", ""))
	var target_item := str(target_port.get("item_id", ""))
	var result: Array = []
	if source_item != "*" and not source_item.is_empty() and (target_item == "*" or target_item == source_item):
		result.append(source_item)
	elif source_item == "*" and target_item != "*" and not target_item.is_empty():
		result.append(target_item)
	elif source_item == "*" and target_item == "*":
		for collection_key in ["outputs", "inventory"]:
			var values: Dictionary = source.get(collection_key, {}) if source.get(collection_key, {}) is Dictionary else {}
			for item_id_value in values.keys():
				var item_id := str(item_id_value)
				if not item_id.is_empty() and not result.has(item_id):
					result.append(item_id)
		if result.is_empty():
			for item_id_value in catalog_item_ids:
				var item_id := str(item_id_value)
				if not item_id.is_empty() and not result.has(item_id):
					result.append(item_id)
	result.sort()
	return result


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
