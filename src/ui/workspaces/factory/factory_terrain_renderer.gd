class_name FactoryTerrainRenderer
extends RefCounted

## Bounded presentation cache. Only chunks intersecting the current viewport
## get meshes; zoomed-out views sample coarser tiles, never millions of quads.
const Terrain = preload("res://src/core/factory_terrain.gd")
const ATLAS_PATH := "res://assets/ui/factory/terrain/generated/terrain_atlas_v1.png"
const MAX_CACHED_CHUNKS := 96
const MAX_VISIBLE_CELLS := 8192
const CHUNK_CELLS := 16
const MATERIAL_SPAN_TILES := 64
const ORE_SPAN_TILES := 16
const GROUND_TINT := Color(0.58, 0.64, 0.66, 1.0)
const TYPE_INDEX := {"PLAIN":0,"FOREST":1,"DESERT":2,"WATER":3,"MOUNTAIN":4}
var _atlas: Texture2D
var _cache: Dictionary = {}
var _field_cache: Dictionary = {}
var _signature := ""
var last_visible_chunks := 0
var last_lod := 1
var mesh_build_count := 0
var field_mesh_build_count := 0


func configure(snapshot: Dictionary) -> void:
	var signature := "%s:%s:%s:%s" % [snapshot.get("world_id",""), snapshot.get("seed",1), hash(snapshot.get("terrain_safe_rect",{})), hash(snapshot.get("tile_deltas",{}))]
	if signature != _signature:
		_signature = signature
		_cache.clear()
		_field_cache.clear()
	if _atlas == null and ResourceLoader.exists(ATLAS_PATH):
		_atlas = load(ATLAS_PATH) as Texture2D


func draw_ground(canvas: CanvasItem, snapshot: Dictionary, visible: Rect2, scale: float, camera: Vector2) -> void:
	last_visible_chunks = 0
	if _atlas == null or not visible.has_area():
		return
	var step := 1
	while ceilf(visible.size.x / step) * ceilf(visible.size.y / step) > MAX_VISIBLE_CELLS:
		step *= 2
	last_lod = step
	var span := CHUNK_CELLS * step
	var first := Vector2i(floori(visible.position.x / span), floori(visible.position.y / span))
	var last := Vector2i(floori((visible.end.x - 0.001) / span), floori((visible.end.y - 0.001) / span))
	var transform := Transform2D(Vector2(scale,0), Vector2(0,scale), camera)
	for y in range(first.y, last.y + 1):
		for x in range(first.x, last.x + 1):
			var key := "%d:%d:%d" % [step,x,y]
			if not _cache.has(key):
				_cache[key] = _mesh(snapshot, Vector2i(x,y) * span, Vector2i(span,span), step)
				mesh_build_count += 1
			var mesh: ArrayMesh = _cache[key]
			# Refresh insertion order for a small deterministic LRU.
			_cache.erase(key)
			_cache[key] = mesh
			if mesh.get_surface_count() > 0:
				canvas.draw_mesh(mesh, _atlas, transform, GROUND_TINT)
			last_visible_chunks += 1
			while _cache.size() > MAX_CACHED_CHUNKS:
				_cache.erase(_cache.keys()[0])


func draw_field(canvas: CanvasItem, field: Dictionary, scale: float, camera: Vector2) -> void:
	if _atlas == null:
		return
	var footprint: Dictionary = field.get("footprint", {})
	var origin_data: Dictionary = footprint.get("origin", {})
	var size_data: Dictionary = footprint.get("size", {})
	var origin := Vector2i(int(origin_data.get("x",0)),int(origin_data.get("y",0)))
	var extent := Vector2i(int(size_data.get("x",0)),int(size_data.get("y",0)))
	var step := 1 if scale >= 1.0 else 2
	var key := "%s:%s:%s:%s" % [field.get("id",""),step,field.get("seed",1),hash(footprint)]
	if not _field_cache.has(key):
		_field_cache[key] = _mesh({}, origin, extent, step, field)
		field_mesh_build_count += 1
	var mesh: ArrayMesh = _field_cache[key]
	if mesh.get_surface_count() > 0:
		canvas.draw_mesh(mesh, _atlas, Transform2D(Vector2(scale,0),Vector2(0,scale),camera))
	while _field_cache.size() > 128:
		_field_cache.erase(_field_cache.keys()[0])


func cached_chunk_count() -> int:
	return _cache.size()


func has_art() -> bool:
	return _atlas != null


func _mesh(snapshot: Dictionary, origin: Vector2i, extent: Vector2i, step: int, field: Dictionary = {}) -> ArrayMesh:
	var vertices := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var field_vertex_colors: Dictionary = {}
	var indices := PackedInt32Array()
	var bounds: Dictionary = snapshot.get("bounds", {})
	var bounds_origin: Dictionary = bounds.get("origin", {})
	var bounds_size: Dictionary = bounds.get("size", {})
	var limits := Rect2i(Vector2i(int(bounds_origin.get("x",0)),int(bounds_origin.get("y",0))),Vector2i(int(bounds_size.get("x",0)),int(bounds_size.get("y",0))))
	for y in range(origin.y, origin.y + extent.y, step):
		for x in range(origin.x, origin.x + extent.x, step):
			var tile := Vector2i(x,y)
			var quad_size := Vector2i(mini(step,origin.x + extent.x - x),mini(step,origin.y + extent.y - y))
			if field.is_empty():
				if not limits.has_point(tile):
					continue
				quad_size = quad_size.min(limits.end - tile)
			elif not Terrain.field_contains(field,tile):
				continue
			var index := int(TYPE_INDEX.get(Terrain.terrain_type(snapshot,tile),0)) if field.is_empty() else (5 if str(field.get("resource_id","")) == "iron_ore" else (6 if str(field.get("resource_id","")) == "copper_ore" else 7))
			var cell_size := Vector2(0.25, 0.5)
			# Keep bilinear samples inside each authored material, including the
			# fractional pixel cells of the original generated atlas.
			var inset := Vector2.ONE * 1.5 / _atlas.get_size()
			var uv_origin := Vector2(index % 4, index / 4) * cell_size + inset
			var material_size := cell_size - inset * 2.0
			# One surface spans 64 world tiles. Its phase stays fixed while panning
			# and changing LOD, instead of repeating a whole high-contrast photo
			# every 16 tiles or changing its physical size at the LOD boundary.
			var material_span := MATERIAL_SPAN_TILES if field.is_empty() else ORE_SPAN_TILES
			var span := float(material_span)
			var local_uv := Vector2(posmod(x,material_span),posmod(y,material_span)) / span if step < material_span else Vector2.ZERO
			var uv_size := Vector2(quad_size) / span if step < material_span else Vector2.ONE
			# Adjacent material repeats meet at the same source edge. Mirroring
			# removes the visible hard seams of a generated, non-tileable photo.
			if posmod(floori(float(x) / span),2) == 1:
				local_uv.x = 1.0 - local_uv.x
				uv_size.x = -uv_size.x
			if posmod(floori(float(y) / span),2) == 1:
				local_uv.y = 1.0 - local_uv.y
				uv_size.y = -uv_size.y
			var uv_rect := Rect2(uv_origin + local_uv * material_size, uv_size * material_size)
			var rect := Rect2(Vector2(tile), Vector2(quad_size))
			var first := vertices.size()
			vertices.append_array(PackedVector2Array([rect.position,Vector2(rect.end.x,rect.position.y),rect.end,Vector2(rect.position.x,rect.end.y)]))
			for corner in [tile, tile + Vector2i(quad_size.x,0), tile + quad_size, tile + Vector2i(0,quad_size.y)]:
				if field.is_empty():
					colors.append(Color.WHITE)
				else:
					if not field_vertex_colors.has(corner):
						var covered := 0
						for offset in [Vector2i(-1,-1),Vector2i(0,-1),Vector2i(-1,0),Vector2i.ZERO]:
							if Terrain.field_contains(field, corner + offset):
								covered += 1
						# Feather only inside the real deposit footprint. This softens
						# the cutout without claiming extra mineable ground.
						field_vertex_colors[corner] = Color(0.84, 0.88, 0.90, pow(float(covered) / 4.0, 2.0) * 0.94)
					colors.append(field_vertex_colors[corner])
			uvs.append_array(PackedVector2Array([uv_rect.position,Vector2(uv_rect.end.x,uv_rect.position.y),uv_rect.end,Vector2(uv_rect.position.x,uv_rect.end.y)]))
			indices.append_array(PackedInt32Array([first,first+1,first+2,first,first+2,first+3]))
	var mesh := ArrayMesh.new()
	if not vertices.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_COLOR] = colors
		arrays[Mesh.ARRAY_INDEX] = indices
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return mesh
