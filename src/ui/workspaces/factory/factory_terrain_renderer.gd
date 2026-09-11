class_name FactoryTerrainRenderer
extends RefCounted

## Bounded semantic masks: geography is owned exclusively by FactoryTerrain.
const Terrain = preload("res://src/core/factory_terrain.gd")
const GroundLayer = preload("res://src/ui/workspaces/factory/factory_ground_layer.gd")
const GroundShader = preload("res://src/ui/workspaces/factory/factory_ground.gdshader")
const Resources = preload("res://src/ui/workspaces/factory/factory_resource_renderer.gd")
const Foliage = preload("res://src/ui/workspaces/factory/earth_foliage_renderer.gd")
const MAX_CACHED_CHUNKS := 96
const MAX_VISIBLE_CELLS := 8192
const CHUNK_CELLS := 16
const MATERIAL_SPAN_TILES := 64
const ART_ROOT := "res://assets/ui/factory/natural/"
const MASK_COLORS := {"PLAIN":Color(0,0,0,0), "FOREST":Color(1,0,0,0), "DESERT":Color(0,1,0,0), "WATER":Color(0,0,1,0), "MOUNTAIN":Color(0,0,0,1)}
var _textures: Dictionary = {}
var _cache: Dictionary = {}
var _signature := ""
var _ground_layer: Node2D
var _resources := Resources.new()
var _foliage := Foliage.new()
var last_visible_chunks := 0
var last_lod := 1
var mesh_build_count := 0
var field_mesh_build_count: int:
	get: return _resources.mesh_build_count

func attach(canvas: Control) -> void:
	if is_instance_valid(_ground_layer):
		return
	_ground_layer = GroundLayer.new()
	_ground_layer.name = "NaturalGroundLayer"
	_ground_layer.show_behind_parent = true
	_ground_layer.visible = false
	canvas.add_child(_ground_layer)
	_foliage.attach(_ground_layer)

func configure(snapshot: Dictionary) -> void:
	# Runtime changes do not invalidate geography. Every terrain input does.
	var inputs: Array = []
	for key in ["world_id", "seed", "terrain_seed", "generator_version", "terrain_profile", "terrain_enabled", "terrain_scale_tiles", "terrain_safe_rect", "tile_deltas", "bounds"]:
		inputs.append(snapshot.get(key))
	var signature := str(hash(inputs))
	if signature != _signature:
		_signature = signature
		_clear_chunks()
		_resources.clear()
		_foliage.clear()
	if _textures.is_empty():
		for material_name in ["soil", "grass", "sand", "rock"]:
			var path: String = ART_ROOT + "ground/" + str(material_name) + ".jpg"
			if ResourceLoader.exists(path):
				_textures[material_name] = load(path) as Texture2D
	_resources.configure()
	_foliage.configure(snapshot)

func draw_ground(canvas: Control, snapshot: Dictionary, visible: Rect2, tile_scale: float, camera: Vector2) -> void:
	last_visible_chunks = 0
	_foliage.hide()
	if not has_art():
		return
	if not is_instance_valid(_ground_layer):
		attach(canvas)
	_ground_layer.visible = true
	_ground_layer.set_viewport_rect(Rect2(Vector2.ZERO, canvas.size))
	for entry in _cache.values():
		(entry.node as Polygon2D).visible = false
	visible = visible.intersection(_bounds_rect(snapshot))
	if not visible.has_area():
		return
	var step := 1
	while ceilf(visible.size.x / step) * ceilf(visible.size.y / step) > MAX_VISIBLE_CELLS:
		step *= 2
	last_lod = step
	var span := CHUNK_CELLS * step
	var first := Vector2i(floori(visible.position.x / span), floori(visible.position.y / span))
	var last := Vector2i(floori((visible.end.x - 0.001) / span), floori((visible.end.y - 0.001) / span))
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var key := "%d:%d:%d" % [step, x, y]
			if not _cache.has(key):
				_cache[key] = _build_chunk(snapshot, Vector2i(x, y) * span, step)
				mesh_build_count += 1
			var entry: Dictionary = _cache[key]
			_cache.erase(key)
			_cache[key] = entry
			var node: Polygon2D = entry.node
			node.position = camera + Vector2(entry.origin) * tile_scale
			node.scale = Vector2.ONE * tile_scale
			node.visible = true
			last_visible_chunks += 1
			while _cache.size() > MAX_CACHED_CHUNKS:
				var oldest = _cache.keys()[0]
				(_cache[oldest].node as Polygon2D).queue_free()
				_cache.erase(oldest)
	_foliage.draw_visible(snapshot, visible, tile_scale, camera, step)

func hide_ground() -> void:
	if is_instance_valid(_ground_layer):
		_ground_layer.visible = false
	last_visible_chunks = 0
	_foliage.hide()

func begin_frame() -> void:
	_resources.begin_frame()

func draw_field(canvas: CanvasItem, field: Dictionary, tile_scale: float, camera: Vector2, overview: bool = false) -> void:
	_resources.draw_field(canvas, field, tile_scale, camera, overview)

func draw_field_outline(canvas: CanvasItem, field: Dictionary, tile_scale: float, camera: Vector2, color: Color) -> void:
	_resources.draw_outline(canvas, field, tile_scale, camera, color)

func cached_chunk_count() -> int:
	return _cache.size()

func has_art() -> bool:
	return _textures.size() == 4

func _clear_chunks() -> void:
	for entry in _cache.values():
		if is_instance_valid(entry.node):
			(entry.node as Polygon2D).visible = false
			(entry.node as Polygon2D).queue_free()
	_cache.clear()

func _build_chunk(snapshot: Dictionary, origin: Vector2i, step: int) -> Dictionary:
	var span := CHUNK_CELLS * step
	var earth := not Terrain.FLAT_GROUND_ONLY and str(snapshot.get("terrain_profile", "")) == "earth_v2"
	var fields: Dictionary = surface_masks(snapshot, origin, step) if earth else {}
	var mask_texture := ImageTexture.create_from_image(fields.semantic if earth else semantic_mask(snapshot, origin, step))
	var material := ShaderMaterial.new()
	material.shader = GroundShader
	material.set_shader_parameter("terrain_mask", mask_texture)
	material.set_shader_parameter("chunk_origin", Vector2(origin))
	material.set_shader_parameter("cell_step", float(step))
	material.set_shader_parameter("mask_edge", float(CHUNK_CELLS + 2))
	material.set_shader_parameter("earth_surface", earth)
	if earth:
		material.set_shader_parameter("surface_fields", ImageTexture.create_from_image(fields.surface))
		material.set_shader_parameter("rock_field", ImageTexture.create_from_image(fields.rock))
	for material_name in _textures:
		material.set_shader_parameter(material_name + "_texture", _textures[material_name])
	var node := Polygon2D.new()
	var clipped := Rect2(Vector2(origin), Vector2.ONE * span).intersection(_bounds_rect(snapshot))
	var rect := Rect2(clipped.position - Vector2(origin), clipped.size)
	node.polygon = PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	node.material = material
	_ground_layer.add_child(node)
	return {"node":node, "origin":origin, "mask":mask_texture}

## Halo cells sample world coordinates even when adjacent chunks are absent.
static func semantic_mask(snapshot: Dictionary, origin: Vector2i, step: int) -> Image:
	var edge := CHUNK_CELLS + 2
	var result := Image.create(edge, edge, false, Image.FORMAT_RGBA8)
	for y in range(edge):
		for x in range(edge):
			var tile := origin + Vector2i(x - 1, y - 1) * step + Vector2i(step / 2, step / 2)
			result.set_pixel(x, y, MASK_COLORS[Terrain.terrain_type(snapshot, tile)])
	return result

## Float textures retain shallow relief; both masks share the semantic halo and
## sampling phase, so chunk edges have identical heights and surface normals.
static func surface_masks(snapshot: Dictionary, origin: Vector2i, step: int) -> Dictionary:
	var edge := CHUNK_CELLS + 2
	var surface := Image.create(edge, edge, false, Image.FORMAT_RGBAF)
	var rock := Image.create(edge, edge, false, Image.FORMAT_RF)
	var semantic := Image.create(edge, edge, false, Image.FORMAT_RGBA8)
	for y in range(edge):
		for x in range(edge):
			var tile := origin + Vector2i(x - 1, y - 1) * step + Vector2i(step / 2, step / 2)
			var sample: Dictionary = Terrain.surface_sample(snapshot, tile)
			semantic.set_pixel(x, y, MASK_COLORS[str(sample.get("terrain", "PLAIN"))])
			surface.set_pixel(x, y, Color(float(sample.get("elevation", 0.5)), float(sample.get("moisture", 0.5)), float(sample.get("forest_density", 0.0)), float(sample.get("water_depth", 0.0))))
			rock.set_pixel(x, y, Color(float(sample.get("rock", 0.0)), 0.0, 0.0, 1.0))
	return {"surface":surface, "rock":rock, "semantic":semantic}

static func _bounds_rect(snapshot: Dictionary) -> Rect2:
	var bounds: Dictionary = snapshot.get("bounds", {})
	var origin: Dictionary = bounds.get("origin", {})
	var extent: Dictionary = bounds.get("size", {})
	return Rect2(float(origin.get("x", 0)), float(origin.get("y", 0)), float(extent.get("x", 0)), float(extent.get("y", 0)))
