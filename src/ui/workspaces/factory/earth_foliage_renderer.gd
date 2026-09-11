extends RefCounted

## Presentation-only, deterministic tree canopies. Local spatial bins keep
## placement/road/resource clearance independent of the total entity count.
const Terrain = preload("res://src/core/factory_terrain.gd")
const Geometry = preload("res://src/ui/workspaces/factory/factory_resource_renderer.gd")
const CANOPY_PATH := "res://assets/ui/factory/natural/kenney_nature/kenney_earth_canopies_v1.png"
const CHUNK_CELLS := 16
const MAX_CACHED_CHUNKS := 96
var _layer: Node2D
var _texture: Texture2D
var _cache: Dictionary = {}
var _blockers: Dictionary = {}
var _occupancy_signature := ""
var mesh_build_count := 0
var visible_tree_count := 0

func attach(parent: Node2D) -> void:
	if is_instance_valid(_layer):
		return
	_layer = Node2D.new()
	_layer.name = "EarthCanopies"
	_layer.texture_repeat = CanvasItem.TEXTURE_REPEAT_DISABLED
	_layer.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	parent.add_child(_layer)

func configure(snapshot: Dictionary) -> void:
	if Terrain.FLAT_GROUND_ONLY:
		clear()
		hide()
		_texture = null
		_blockers.clear()
		return
	if _texture == null and ResourceLoader.exists(CANOPY_PATH):
		_texture = load(CANOPY_PATH) as Texture2D
	var occupied: Array = []
	for category in ["entities", "construction_orders", "resource_fields"]:
		for record in snapshot.get(category, []):
			if record is Dictionary:
				occupied.append([category, record.get("footprint", {}), record.get("shape"), record.get("seed")])
	for road in snapshot.get("roads", []):
		if road is Dictionary:
			occupied.append([int(road.get("x", 0)), int(road.get("y", 0))])
	var signature := str(hash(occupied))
	if signature == _occupancy_signature:
		return
	_occupancy_signature = signature
	clear()
	_blockers.clear()
	for category in ["entities", "construction_orders", "resource_fields"]:
		for record in snapshot.get(category, []):
			if record is Dictionary:
				var rect := _footprint_rect(record.get("footprint", {}))
				_index_blocker(rect, record if category == "resource_fields" else {})
	for road in snapshot.get("roads", []):
		if road is Dictionary:
			_index_blocker(Rect2(float(road.get("x", 0)), float(road.get("y", 0)), 1.0, 1.0), {})

func clear() -> void:
	for entry in _cache.values():
		if is_instance_valid(entry.node):
			entry.node.visible = false
			entry.node.queue_free()
	_cache.clear()
	visible_tree_count = 0

func hide() -> void:
	if is_instance_valid(_layer):
		_layer.visible = false
	visible_tree_count = 0

func cached_chunk_count() -> int:
	return _cache.size()

func draw_visible(snapshot: Dictionary, visible: Rect2, tile_scale: float, camera: Vector2, lod: int) -> void:
	visible_tree_count = 0
	if not is_instance_valid(_layer):
		return
	_layer.visible = not Terrain.FLAT_GROUND_ONLY and str(snapshot.get("terrain_profile", "")) == "earth_v2" and _texture != null
	if not _layer.visible:
		return
	# All trees remain beneath the parent canvas's roads, ore and buildings.
	_layer.get_parent().move_child(_layer, -1)
	for entry in _cache.values():
		entry.node.visible = false
	var span := CHUNK_CELLS * lod
	var first := Vector2i(floori(visible.position.x / span), floori(visible.position.y / span))
	var last := Vector2i(floori((visible.end.x - 0.001) / span), floori((visible.end.y - 0.001) / span))
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var key := "%d:%d:%d" % [lod, x, y]
			if not _cache.has(key):
				_cache[key] = _build_chunk(snapshot, Vector2i(x, y) * span, lod)
				mesh_build_count += 1
			var entry: Dictionary = _cache[key]
			_cache.erase(key)
			_cache[key] = entry
			entry.node.position = camera + Vector2(entry.origin) * tile_scale
			entry.node.scale = Vector2.ONE * tile_scale
			entry.node.visible = true
			visible_tree_count += int(entry.count)
			while _cache.size() > MAX_CACHED_CHUNKS:
				var oldest: String = _cache.keys()[0]
				_cache[oldest].node.visible = false
				_cache[oldest].node.queue_free()
				_cache.erase(oldest)

func _build_chunk(snapshot: Dictionary, origin: Vector2i, lod: int) -> Dictionary:
	var vertices := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var seed := int(snapshot.get("terrain_seed", snapshot.get("seed", 1)))
	var bounds := _footprint_rect(snapshot.get("bounds", {}))
	var span := CHUNK_CELLS * lod
	# Fixed two-tile lattice with subcell jitter: no camera-dependent randomness.
	for y in range(origin.y, origin.y + span, 2 * lod):
		for x in range(origin.x, origin.x + span, 2 * lod):
			var tile := Vector2i(x, y)
			var sample: Dictionary = Terrain.surface_sample(snapshot, tile)
			if str(sample.get("terrain", "PLAIN")) in ["WATER", "MOUNTAIN", "DESERT"]:
				continue
			var density := float(sample.get("forest_density", 0.0))
			var random := Terrain._coordinate_noise(seed + 17011, x, y)
			if float(posmod(random, 1000)) / 1000.0 >= density * 0.92:
				continue
			var jitter := Vector2(float(posmod(random / 17, 101)) / 100.0 - 0.5, float(posmod(random / 139, 101)) / 100.0 - 0.5) * 1.2
			var center := Vector2(tile) + Vector2.ONE + jitter
			var edge := 2.6 + float(posmod(random / 37, 100)) * 0.012
			var canopy := Rect2(center - Vector2.ONE * edge * 0.5, Vector2.ONE * edge)
			if not bounds.encloses(canopy) or _blocked(canopy):
				continue
			var variant := posmod(random / 251, 4)
			var uv := Rect2(Vector2(variant % 2, variant / 2) * 0.5, Vector2.ONE * 0.5)
			var inset := Vector2.ONE * 2.0 / _texture.get_size()
			uv.position += inset
			uv.size -= inset * 2.0
			var shade := 0.83 + float(posmod(random / 71, 100)) * 0.0017
			Geometry._append_quad(vertices, uvs, colors, indices, Rect2(canopy.position - Vector2(origin), canopy.size), uv, Color(shade, shade, shade, 1.0))
	var node := MeshInstance2D.new()
	node.name = "CanopyChunk"
	node.texture = _texture
	node.mesh = Geometry._mesh(vertices, uvs, colors, indices)
	_layer.add_child(node)
	return {"node":node, "origin":origin, "count":indices.size() / 6}

func _index_blocker(rect: Rect2, field: Dictionary) -> void:
	if not rect.has_area():
		return
	var expanded := rect.grow(2.5)
	var first := Vector2i(floori(expanded.position.x / CHUNK_CELLS), floori(expanded.position.y / CHUNK_CELLS))
	var last := Vector2i(floori(expanded.end.x / CHUNK_CELLS), floori(expanded.end.y / CHUNK_CELLS))
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var key := Vector2i(x, y)
			if not _blockers.has(key):
				_blockers[key] = []
			_blockers[key].append({"rect":rect, "field":field})

func _blocked(canopy: Rect2) -> bool:
	var center := canopy.get_center()
	var key := Vector2i(floori(center.x / CHUNK_CELLS), floori(center.y / CHUNK_CELLS))
	for blocker in _blockers.get(key, []):
		var overlap: Rect2 = canopy.intersection(blocker.rect)
		if not overlap.has_area():
			continue
		var field: Dictionary = blocker.field
		if field.is_empty():
			return true
		for y in range(floori(overlap.position.y), ceili(overlap.end.y)):
			for x in range(floori(overlap.position.x), ceili(overlap.end.x)):
				if Terrain.field_contains(field, Vector2i(x, y)):
					return true
	return false

static func _footprint_rect(footprint: Dictionary) -> Rect2:
	var origin: Dictionary = footprint.get("origin", {})
	var extent: Dictionary = footprint.get("size", {})
	return Rect2(float(origin.get("x", footprint.get("x", 0))), float(origin.get("y", footprint.get("y", 0))), float(extent.get("x", footprint.get("width", 0))), float(extent.get("y", footprint.get("height", 0))))
