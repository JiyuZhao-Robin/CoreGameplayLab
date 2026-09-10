class_name FactoryCanvasChunkIndex
extends RefCounted

## Immutable presentation index built once for each Factory workspace snapshot.
## It keeps draw and hit-test work proportional to the chunks intersecting the
## viewport instead of rescanning every record on a large planet.

var _chunk_size_tiles := 64
var _bounds := Rect2()
var _resource_ids_by_chunk: Dictionary = {}
var _entity_ids_by_chunk: Dictionary = {}
var _order_ids_by_chunk: Dictionary = {}
var _link_ids_by_chunk: Dictionary = {}
var _road_ids_by_chunk: Dictionary = {}
var _entities_by_id: Dictionary = {}
var _rebuild_count := 0


func rebuild(snapshot: Dictionary) -> void:
	_rebuild_count += 1
	_chunk_size_tiles = maxi(1, int(snapshot.get("chunk_size_tiles", 64)))
	var bounds_value: Variant = snapshot.get("bounds", {})
	var bounds: Dictionary = bounds_value as Dictionary if bounds_value is Dictionary else {}
	var origin := _point(bounds.get("origin", {}))
	var extent := _size(bounds.get("size", {}))
	_bounds = Rect2(Vector2(origin), Vector2(extent))
	_resource_ids_by_chunk.clear()
	_entity_ids_by_chunk.clear()
	_order_ids_by_chunk.clear()
	_link_ids_by_chunk.clear()
	_road_ids_by_chunk.clear()
	_entities_by_id.clear()

	for resource_value in snapshot.get("resource_fields", []):
		if resource_value is Dictionary:
			var resource := resource_value as Dictionary
			_add_record(_resource_ids_by_chunk, str(resource.get("id", "")), _footprint_rect(resource.get("footprint", {})))
	for entity_value in snapshot.get("entities", []):
		if entity_value is Dictionary:
			var entity := entity_value as Dictionary
			var entity_id := str(entity.get("id", ""))
			_entities_by_id[entity_id] = entity
			_add_record(_entity_ids_by_chunk, entity_id, _footprint_rect(entity.get("footprint", {})))
	for order_value in snapshot.get("construction_orders", []):
		if order_value is Dictionary:
			var order := order_value as Dictionary
			_add_record(_order_ids_by_chunk, str(order.get("id", "")), _footprint_rect(order.get("footprint", {})))
	for link_value in snapshot.get("links", []):
		if not link_value is Dictionary:
			continue
		var link := link_value as Dictionary
		var source: Dictionary = _entities_by_id.get(str(link.get("source_id", "")), {})
		var target: Dictionary = _entities_by_id.get(str(link.get("target_id", "")), {})
		if source.is_empty() or target.is_empty():
			continue
		# Explicit routes are indexed segment-by-segment. A long L-shaped belt must
		# not be registered in every chunk inside its large bounding rectangle.
		var source_bounds := _footprint_rect(source.get("footprint", {}))
		var target_bounds := _footprint_rect(target.get("footprint", {}))
		var path_tiles_value: Variant = link.get("path_tiles", [])
		var link_id := str(link.get("id", ""))
		if path_tiles_value is Array and (path_tiles_value as Array).size() >= 2:
			_add_record(_link_ids_by_chunk, link_id, source_bounds)
			_add_record(_link_ids_by_chunk, link_id, target_bounds)
			var path_tiles := path_tiles_value as Array
			for index in range(1, path_tiles.size()):
				var previous := Vector2(_point(path_tiles[index - 1])) + Vector2.ONE * 0.5
				var current := Vector2(_point(path_tiles[index])) + Vector2.ONE * 0.5
				_add_record(_link_ids_by_chunk, link_id, Rect2(previous, Vector2.ZERO).expand(current).grow(0.501))
		else:
			# Legacy snapshots have no authored route. Retain the previous conservative
			# endpoint union until the authoritative domain normalizes them.
			_add_record(_link_ids_by_chunk, link_id, source_bounds.merge(target_bounds).grow(0.001))
	for road_value in snapshot.get("roads", []):
		if not road_value is Dictionary:
			continue
		var road := road_value as Dictionary
		var position := _point(road)
		var road_id := "%d:%d" % [position.x, position.y]
		_add_record(_road_ids_by_chunk, road_id, Rect2(Vector2(position), Vector2.ONE))


func query(world_rect: Rect2) -> Dictionary:
	var chunk_keys := visible_chunk_keys(world_rect)
	return {
		"chunk_keys":chunk_keys,
		"resource_ids":_collect_ids(_resource_ids_by_chunk, chunk_keys),
		"entity_ids":_collect_ids(_entity_ids_by_chunk, chunk_keys),
		"order_ids":_collect_ids(_order_ids_by_chunk, chunk_keys),
		"link_ids":_collect_ids(_link_ids_by_chunk, chunk_keys),
		"road_ids":_collect_ids(_road_ids_by_chunk, chunk_keys)
	}


func visible_chunk_keys(world_rect: Rect2) -> Array[String]:
	var clipped := world_rect.intersection(_bounds)
	var result: Array[String] = []
	if not clipped.has_area():
		return result
	var first := _chunk_for_point(clipped.position)
	var last := _chunk_for_point(clipped.end - Vector2.ONE * 0.0001)
	for chunk_y in range(first.y, last.y + 1):
		for chunk_x in range(first.x, last.x + 1):
			result.append(_chunk_key(Vector2i(chunk_x, chunk_y)))
	return result


func chunk_size_tiles() -> int:
	return _chunk_size_tiles


func indexed_chunk_count() -> int:
	var keys := {}
	for index in [_resource_ids_by_chunk, _entity_ids_by_chunk, _order_ids_by_chunk, _link_ids_by_chunk, _road_ids_by_chunk]:
		for key_value in (index as Dictionary).keys():
			keys[str(key_value)] = true
	return keys.size()


func rebuild_count() -> int:
	return _rebuild_count


func _add_record(index: Dictionary, record_id: String, world_rect: Rect2) -> void:
	if record_id.is_empty():
		return
	var clipped := world_rect.intersection(_bounds)
	if not clipped.has_area():
		return
	var first := _chunk_for_point(clipped.position)
	var last := _chunk_for_point(clipped.end - Vector2.ONE * 0.0001)
	for chunk_y in range(first.y, last.y + 1):
		for chunk_x in range(first.x, last.x + 1):
			var key := _chunk_key(Vector2i(chunk_x, chunk_y))
			var bucket: Array = index.get(key, [])
			if not bucket.has(record_id):
				bucket.append(record_id)
			index[key] = bucket


func _collect_ids(index: Dictionary, chunk_keys: Array[String]) -> Array[String]:
	var seen := {}
	for chunk_key in chunk_keys:
		for record_id_value in index.get(chunk_key, []):
			seen[str(record_id_value)] = true
	var result: Array[String] = []
	result.assign(seen.keys())
	result.sort()
	return result


func _chunk_for_point(point: Vector2) -> Vector2i:
	var relative := point - _bounds.position
	return Vector2i(
		floori(relative.x / float(_chunk_size_tiles)),
		floori(relative.y / float(_chunk_size_tiles))
	)


func _chunk_key(chunk: Vector2i) -> String:
	return "%d:%d" % [chunk.x, chunk.y]


func _footprint_rect(footprint_value: Variant) -> Rect2:
	var footprint: Dictionary = footprint_value as Dictionary if footprint_value is Dictionary else {}
	return Rect2(Vector2(_point(footprint.get("origin", {}))), Vector2(_size(footprint.get("size", {}))))


func _point(value: Variant) -> Vector2i:
	var data: Dictionary = value as Dictionary if value is Dictionary else {}
	return Vector2i(int(data.get("x", 0)), int(data.get("y", 0)))


func _size(value: Variant) -> Vector2i:
	var data: Dictionary = value as Dictionary if value is Dictionary else {}
	return Vector2i(maxi(0, int(data.get("x", 0))), maxi(0, int(data.get("y", 0))))
