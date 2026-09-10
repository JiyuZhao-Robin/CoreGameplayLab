class_name FactoryRoadNetwork
extends RefCounted

## Sparse cardinal-road graph used by the planet-shared Factory logistics mode.
## Roads are persisted as a dictionary keyed by `x,y`; this module never scans
## the complete planet bounds and never owns inventory or transport cargo.

const MAX_EDIT_TILES := 2048
const ROAD_TIERS := [1, 2]
const DIRECTIONS := [Vector2i(0, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, 1)]


static func empty_graph() -> Dictionary:
	return {"tile_to_component":{}, "components":{}, "component_tiles":{}, "path_cache":{}}


static func normalize_roads(value: Variant, world: Dictionary) -> Dictionary:
	var roads := {}
	if value is not Dictionary:
		return roads
	for key_value in value.keys():
		var key := str(key_value)
		var tile: Variant = _parse_key(key)
		var record: Variant = value.get(key_value)
		if tile == null or record is not Dictionary or not _tile_in_world(world, tile):
			continue
		var typed_record := record as Dictionary
		var tier := int(typed_record.get("tier", 1))
		if tier not in ROAD_TIERS or not _live_record(typed_record):
			continue
		# Canonicalize the key and coordinates so malformed/ghost save entries
		# cannot create a second physical road at the same tile.
		roads[_tile_key(tile)] = {"x":tile.x, "y":tile.y, "tier":tier}
	return roads


static func edit_roads(world: Dictionary, tiles: Array, tier: int = 1, remove: bool = false) -> Dictionary:
	if tiles.size() > MAX_EDIT_TILES:
		return _failure("ROAD_BATCH_LIMIT", "A road edit cannot contain more than 2048 tiles")
	if not remove and tier not in ROAD_TIERS:
		return _failure("INVALID_ROAD_TIER", "Road tier must be one or two")
	if remove and tier not in ROAD_TIERS:
		# The tier has no semantic effect while removing, but rejecting malformed
		# input keeps the command contract deterministic.
		return _failure("INVALID_ROAD_TIER", "Road tier must be one or two")
	var parsed: Array[Vector2i] = []
	var seen := {}
	for tile_value in tiles:
		if tile_value is not Dictionary:
			return _failure("INVALID_ROAD_TILE", "Road coordinates must be dictionaries")
		var tile_data := tile_value as Dictionary
		if not _has_integer_coordinate(tile_data, "x") or not _has_integer_coordinate(tile_data, "y"):
			return _failure("INVALID_ROAD_TILE", "Road coordinates require integer x and y")
		var tile := Vector2i(int(tile_data.get("x")), int(tile_data.get("y")))
		var key := _tile_key(tile)
		if seen.has(key):
			return _failure("DUPLICATE_ROAD_TILE", "A road edit cannot contain duplicate coordinates")
		seen[key] = true
		parsed.append(tile)
	# Validate every target before mutating any entry. A disconnected batch is
	# valid; adjacency is a graph property, not a command requirement.
	for tile in parsed:
		if not _tile_in_world(world, tile):
			return _failure("ROAD_OUT_OF_BOUNDS", "Roads must stay inside the Factory world")
		if not remove and _footprint_contains_any(world, tile):
			return _failure("ROAD_OCCUPIED", "Roads cannot overlap a building or construction order")
	# Commit only after the complete validation pass.
	var changed_tiles: Array = []
	var cost := 0
	for tile in parsed:
		var key := _tile_key(tile)
		if remove:
			if world.get("roads", {}).has(key):
				world["roads"].erase(key)
				changed_tiles.append(_tile_record(tile, 0))
			continue
		var previous_tier := int(world.get("roads", {}).get(key, {}).get("tier", 0))
		if previous_tier == tier or (previous_tier == 2 and tier == 1):
			continue
		world["roads"][key] = _tile_record(tile, tier)
		changed_tiles.append(_tile_record(tile, tier))
		# Tier-one starter roads are free. Creating or upgrading to tier two
		# charges one iron ingot per changed tile; the root transaction owns debit.
		if tier == 2 and previous_tier != 2:
			cost += 1
	return {"ok":true, "changed_tiles":changed_tiles, "costs":{"iron_ingot":cost}, "removed":remove}


static func build_graph(world: Dictionary) -> Dictionary:
	var roads: Dictionary = world.get("roads", {}) if world.get("roads", {}) is Dictionary else {}
	var graph := empty_graph()
	var remaining := {}
	for key_value in roads.keys():
		var key := str(key_value)
		var tile: Variant = _parse_key(key)
		var record: Variant = roads.get(key_value)
		if tile == null or record is not Dictionary or not _tile_in_world(world, tile):
			continue
		if int((record as Dictionary).get("tier", 0)) not in ROAD_TIERS or not _live_record(record):
			continue
		remaining[key] = true
	var sorted_keys: Array = remaining.keys()
	sorted_keys.sort()
	for key_value in sorted_keys:
		var start_key := str(key_value)
		if not remaining.has(start_key):
			continue
		var queue: Array[String] = [start_key]
		var queue_head := 0
		remaining.erase(start_key)
		var component_tiles: Array = []
		while queue_head < queue.size():
			var current := str(queue[queue_head])
			queue_head += 1
			component_tiles.append(current)
			for neighbor in _neighbor_keys(current):
				if not remaining.has(neighbor):
					continue
				remaining.erase(neighbor)
				queue.append(neighbor)
		component_tiles.sort()
		var component_id: String = str(component_tiles[0])
		graph["components"][component_id] = {"id":component_id, "tiles":component_tiles.duplicate(true), "size":component_tiles.size()}
		graph["component_tiles"][component_id] = component_tiles.duplicate(true)
		for tile_key in component_tiles:
			graph["tile_to_component"][tile_key] = component_id
	return graph


static func entity_access(world: Dictionary, entity: Dictionary, graph: Dictionary = {}) -> Dictionary:
	var result := {"road_connected":false, "road_component_id":"", "access_tiles":[]}
	if entity.is_empty():
		return result
	var active_graph := graph if not graph.is_empty() else build_graph(world)
	var road_map: Dictionary = world.get("roads", {}) if world.get("roads", {}) is Dictionary else {}
	var footprint: Dictionary = entity.get("footprint", {})
	var origin := _point(footprint.get("origin", {}))
	var size := _point(footprint.get("size", {}))
	var accesses := {}
	var width := maxi(1, size.x)
	var height := maxi(1, size.y)
	for x in range(origin.x, origin.x + width):
		_add_access_tile(accesses, road_map, active_graph, Vector2i(x, origin.y - 1))
		_add_access_tile(accesses, road_map, active_graph, Vector2i(x, origin.y + height))
	for y in range(origin.y, origin.y + height):
		_add_access_tile(accesses, road_map, active_graph, Vector2i(origin.x - 1, y))
		_add_access_tile(accesses, road_map, active_graph, Vector2i(origin.x + width, y))
	var access_keys: Array = accesses.keys()
	access_keys.sort()
	result["access_tiles"] = access_keys.duplicate(true)
	if access_keys.is_empty():
		return result
	var component_ids := {}
	for key_value in access_keys:
		var component_id := str(active_graph.get("tile_to_component", {}).get(str(key_value), ""))
		if not component_id.is_empty():
			component_ids[component_id] = true
	var sorted_components: Array = component_ids.keys()
	sorted_components.sort()
	result["road_connected"] = not sorted_components.is_empty()
	result["road_component_id"] = "" if sorted_components.is_empty() else str(sorted_components[0])
	return result


static func entity_component(world: Dictionary, entity: Dictionary, graph: Dictionary = {}) -> String:
	return str(entity_access(world, entity, graph).get("road_component_id", ""))


static func footprint_overlaps_road(world: Dictionary, footprint: Dictionary) -> bool:
	var roads: Dictionary = world.get("roads", {}) if world.get("roads", {}) is Dictionary else {}
	var origin := _point(footprint.get("origin", {}))
	var size := _point(footprint.get("size", {}))
	for y in range(origin.y, origin.y + maxi(1, size.y)):
		for x in range(origin.x, origin.x + maxi(1, size.x)):
			var record: Variant = roads.get(_tile_key(Vector2i(x, y)), null)
			if record is Dictionary and _live_record(record) and int(record.get("tier", 0)) in ROAD_TIERS:
				return true
	return false


static func path_between(world: Dictionary, source: Dictionary, target: Dictionary, graph: Dictionary = {}) -> Dictionary:
	var active_graph := graph if not graph.is_empty() else build_graph(world)
	var source_id := str(source.get("id", ""))
	var target_id := str(target.get("id", ""))
	var cache_key := "%s@%d>%s@%d" % [source_id, hash(source.get("footprint", {})), target_id, hash(target.get("footprint", {}))]
	if not source_id.is_empty() and not target_id.is_empty() and active_graph.get("path_cache", {}).has(cache_key):
		return active_graph.get("path_cache", {}).get(cache_key, {}).duplicate(true)
	var source_access := entity_access(world, source, active_graph)
	var target_access := entity_access(world, target, active_graph)
	var source_component := str(source_access.get("road_component_id", ""))
	var target_component := str(target_access.get("road_component_id", ""))
	if source_component.is_empty() or target_component.is_empty():
		return _cache_path(active_graph, cache_key, {"ok":false, "reason_code":"ROAD_DISCONNECTED", "path_tiles":[], "distance_tiles":0})
	if source_component != target_component:
		return _cache_path(active_graph, cache_key, {"ok":false, "reason_code":"ROAD_COMPONENT_MISMATCH", "path_tiles":[], "distance_tiles":0})
	var source_keys: Array = source_access.get("access_tiles", []).filter(func(key): return str(active_graph.get("tile_to_component", {}).get(str(key), "")) == source_component)
	var target_keys: Array = target_access.get("access_tiles", []).filter(func(key): return str(active_graph.get("tile_to_component", {}).get(str(key), "")) == target_component)
	source_keys.sort()
	target_keys.sort()
	var best := _nearest_path(active_graph, source_keys, target_keys)
	if best.is_empty():
		return _cache_path(active_graph, cache_key, {"ok":false, "reason_code":"ROAD_PATH_BLOCKED", "path_tiles":[], "distance_tiles":0})
	return _cache_path(active_graph, cache_key, best)


static func path_tiles_valid(world: Dictionary, source: Dictionary, target: Dictionary, path_tiles: Variant, graph: Dictionary = {}) -> bool:
	if path_tiles is not Array or (path_tiles as Array).is_empty():
		return false
	var active_graph := graph if not graph.is_empty() else build_graph(world)
	var source_access := entity_access(world, source, active_graph)
	var target_access := entity_access(world, target, active_graph)
	var path: Array = path_tiles
	var component := str(source_access.get("road_component_id", ""))
	if component.is_empty() or component != str(target_access.get("road_component_id", "")):
		return false
	var first := str(path[0])
	var last := str(path[-1])
	if str(active_graph.get("tile_to_component", {}).get(first, "")) != component:
		return false
	if not source_access.get("access_tiles", []).has(first) or not target_access.get("access_tiles", []).has(last):
		return false
	for key_value in path:
		if not active_graph.get("tile_to_component", {}).has(str(key_value)):
			return false
	for index in range(1, path.size()):
		var previous: Variant = _parse_key(str(path[index - 1]))
		var current: Variant = _parse_key(str(path[index]))
		if previous == null or current == null or abs(previous.x - current.x) + abs(previous.y - current.y) != 1:
			return false
	return true


static func road_tiles_snapshot(world: Dictionary) -> Array:
	var roads: Dictionary = world.get("roads", {}) if world.get("roads", {}) is Dictionary else {}
	var keys: Array = roads.keys()
	keys.sort()
	var result: Array = []
	for key_value in keys:
		var key := str(key_value)
		var tile: Variant = _parse_key(key)
		var record: Variant = roads.get(key_value)
		if tile == null or record is not Dictionary or not _tile_in_world(world, tile) or not _live_record(record):
			continue
		result.append({"x":tile.x, "y":tile.y, "tier":int((record as Dictionary).get("tier", 1))})
	return result


static func _road_path_keys(graph: Dictionary, source_key: String, target_key: String) -> Dictionary:
	if source_key == target_key:
		return {"ok":true, "path_tiles":[source_key], "distance_tiles":0, "tie_breaker":source_key}
	var parent := {source_key:""}
	var queue: Array[String] = [source_key]
	var queue_head := 0
	while queue_head < queue.size():
		var current := str(queue[queue_head])
		queue_head += 1
		for neighbor in _neighbor_keys(current):
			if parent.has(neighbor) or not graph.get("tile_to_component", {}).has(neighbor):
				continue
			parent[neighbor] = current
			if neighbor == target_key:
				queue.clear()
				break
			queue.append(neighbor)
	if not parent.has(target_key):
		return {"ok":false}
	var reverse_path: Array[String] = []
	var cursor := target_key
	while not cursor.is_empty():
		reverse_path.append(cursor)
		cursor = str(parent.get(cursor, ""))
	reverse_path.reverse()
	return {"ok":true, "path_tiles":reverse_path, "distance_tiles":maxi(0, reverse_path.size() - 1), "tie_breaker":"%s>%s" % [source_key, target_key]}


static func _nearest_path(graph: Dictionary, source_keys: Array, target_keys: Array) -> Dictionary:
	if source_keys.is_empty() or target_keys.is_empty():
		return {}
	var target_set := {}
	for target_value in target_keys:
		target_set[str(target_value)] = true
	var parent := {}
	var root := {}
	var queue: Array[String] = []
	for source_value in source_keys:
		var source_key := str(source_value)
		if parent.has(source_key):
			continue
		parent[source_key] = ""
		root[source_key] = source_key
		queue.append(source_key)
	var queue_head := 0
	var found_key := ""
	while queue_head < queue.size():
		var current := str(queue[queue_head])
		queue_head += 1
		if target_set.has(current):
			found_key = current
			break
		for neighbor in _neighbor_keys(current):
			if parent.has(neighbor) or not graph.get("tile_to_component", {}).has(neighbor):
				continue
			parent[neighbor] = current
			root[neighbor] = root.get(current, "")
			queue.append(neighbor)
	if found_key.is_empty():
		return {}
	var reverse_path: Array[String] = []
	var cursor := found_key
	while not cursor.is_empty():
		reverse_path.append(cursor)
		cursor = str(parent.get(cursor, ""))
	reverse_path.reverse()
	return {"ok":true, "path_tiles":reverse_path, "distance_tiles":maxi(0, reverse_path.size() - 1), "tie_breaker":"%s>%s" % [str(root.get(found_key, "")), found_key]}


static func _neighbor_keys(key: String) -> Array[String]:
	var tile: Variant = _parse_key(key)
	if tile == null:
		return []
	var result: Array[String] = []
	for direction in DIRECTIONS:
		result.append(_tile_key(tile + direction))
	return result


static func _cache_path(graph: Dictionary, key: String, value: Dictionary) -> Dictionary:
	if not key.is_empty():
		if graph.get("path_cache", {}).size() >= 2048:
			graph["path_cache"].clear()
		graph["path_cache"][key] = value.duplicate(true)
	return value


static func _live_record(record: Dictionary) -> bool:
	return not bool(record.get("ghost", false)) and str(record.get("status", "BUILT")).to_upper() not in ["GHOST", "PLANNED", "UNDER_CONSTRUCTION"]


static func _add_access_tile(accesses: Dictionary, roads: Dictionary, graph: Dictionary, tile: Vector2i) -> void:
	var key := _tile_key(tile)
	if roads.has(key) and graph.get("tile_to_component", {}).has(key):
		accesses[key] = true


static func _footprint_contains_any(world: Dictionary, tile: Vector2i) -> bool:
	for collection_name in ["entities", "construction_orders"]:
		var collection: Dictionary = world.get(collection_name, {}) if world.get(collection_name, {}) is Dictionary else {}
		for value in collection.values():
			if value is Dictionary and _footprint_contains(value as Dictionary, tile):
				return true
	return false


static func _footprint_contains(value: Dictionary, tile: Vector2i) -> bool:
	var footprint: Dictionary = value.get("footprint", value)
	var origin := _point(footprint.get("origin", {}))
	var size := _point(footprint.get("size", {}))
	return tile.x >= origin.x and tile.y >= origin.y and tile.x < origin.x + maxi(1, size.x) and tile.y < origin.y + maxi(1, size.y)


static func _tile_in_world(world: Dictionary, tile: Vector2i) -> bool:
	var bounds: Dictionary = world.get("bounds", {})
	var origin := _point(bounds.get("origin", {}))
	var size := _point(bounds.get("size", {}))
	return tile.x >= origin.x and tile.y >= origin.y and tile.x < origin.x + maxi(1, size.x) and tile.y < origin.y + maxi(1, size.y)


static func _has_integer_coordinate(value: Dictionary, key: String) -> bool:
	return value.has(key) and typeof(value.get(key)) == TYPE_INT


static func _tile_key(tile: Vector2i) -> String:
	return "%d,%d" % [tile.x, tile.y]


static func _tile_record(tile: Vector2i, tier: int) -> Dictionary:
	return {"x":tile.x, "y":tile.y, "tier":tier}


static func _parse_key(value: String) -> Variant:
	var parts := value.split(",")
	if parts.size() != 2 or parts[0].strip_edges().is_empty() or parts[1].strip_edges().is_empty():
		return null
	if not _integer_text(parts[0]) or not _integer_text(parts[1]):
		return null
	return Vector2i(int(parts[0]), int(parts[1]))


static func _integer_text(value: String) -> bool:
	var trimmed := value.strip_edges()
	if trimmed.is_empty():
		return false
	for index in range(trimmed.length()):
		var code := trimmed.unicode_at(index)
		if index == 0 and code == 45:
			continue
		if code < 48 or code > 57:
			return false
	return trimmed != "-"


static func _point(value: Variant) -> Vector2i:
	if value is Vector2i:
		return value
	if value is Dictionary:
		var data := value as Dictionary
		return Vector2i(int(data.get("x", 0)), int(data.get("y", 0)))
	return Vector2i.ZERO


static func _failure(reason_code: String, reason: String) -> Dictionary:
	return {"ok":false, "reason_code":reason_code, "reason":reason, "changed_tiles":[]}
