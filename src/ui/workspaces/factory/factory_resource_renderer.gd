extends RefCounted

## Actual ground sprites, distinct from inventory icons. Presentation sampling
## never changes field_contains(), extraction grade, or sustainable production.
const Terrain = preload("res://src/core/factory_terrain.gd")
const ROOT := "res://assets/ui/factory/natural/ores/"
const MAX_CACHED_FIELDS := 128
const MAX_FIELD_CELLS := 4096
const ICE_IDS := ["water", "ice", "fire_ice", "deuterium", "hydrogen", "silicon_ore", "optical_grating_crystal", "kimberlite_ore", "unipolar_magnet"]
const FLUID_IDS := ["water", "crude_oil", "hydrogen", "deuterium", "sulfuric_acid"]
var _textures: Dictionary = {}
var _bed_texture: Texture2D
var _cache: Dictionary = {}
var _overview_cache: Dictionary = {}
# Canvas draw commands hold RIDs, not Resource ownership. Keep meshes alive
# until Godot clears those commands immediately before the next _draw().
var _frame_meshes: Array[ArrayMesh] = []
var mesh_build_count := 0

func begin_frame() -> void:
	_frame_meshes.clear()

func configure() -> void:
	if _bed_texture == null and ResourceLoader.exists("res://assets/ui/factory/natural/ground/rock.jpg"):
		_bed_texture = load("res://assets/ui/factory/natural/ground/rock.jpg") as Texture2D
	if not _textures.is_empty():
		return
	for name in ["iron", "copper", "ice"]:
		var path: String = ROOT + str(name) + "-ore.png"
		if ResourceLoader.exists(path):
			_textures[name] = load(path) as Texture2D

func clear() -> void:
	_cache.clear()
	_overview_cache.clear()

func draw_field(canvas: CanvasItem, field: Dictionary, tile_scale: float, camera: Vector2, overview: bool = false) -> void:
	var key := _key(field)
	var resource_id := str(field.get("resource_id", "")).trim_prefix("dsp_")
	var fluid := is_fluid_field(field)
	var transform := Transform2D(Vector2(tile_scale, 0), Vector2(0, tile_scale), camera)
	if overview:
		# Survey distance shows the deposit's geography, never a giant item icon.
		if not _overview_cache.has(key):
			_overview_cache[key] = _survey_mesh(field)
		var mesh: ArrayMesh = _overview_cache[key]
		if mesh != null:
			_frame_meshes.append(mesh)
			var color := Color.from_string(str(field.get("resource_color", "#8997a2")), Color("8997a2"))
			color.a = 0.80
			canvas.draw_mesh(mesh, null, transform, color)
		while _overview_cache.size() > 512:
			_overview_cache.erase(_overview_cache.keys()[0])
		return
	var material_name := "copper" if resource_id == "copper_ore" else ("ice" if resource_id in ICE_IDS else "iron")
	var texture: Texture2D = _textures.get(material_name)
	if texture == null and not fluid:
		return
	if not _cache.has(key):
		_cache[key] = {"bed":_bed_mesh(field), "clusters":_cluster_mesh(field, texture) if texture != null and not fluid else null}
		mesh_build_count += 1
	var entry: Dictionary = _cache[key]
	_cache.erase(key)
	_cache[key] = entry
	var bed: ArrayMesh = entry.bed
	if _bed_texture != null and bed != null:
		_frame_meshes.append(bed)
		var bed_tint := Color(0.51,0.56,0.59,0.56)
		if resource_id == "copper_ore": bed_tint = Color(0.64,0.44,0.29,0.56)
		elif fluid: bed_tint = Color(0.20,0.32,0.34,0.78)
		canvas.draw_mesh(bed, _bed_texture, transform, bed_tint)
	var mesh: ArrayMesh = entry.clusters
	if fluid:
		_trim_cache()
		return
	if mesh != null:
		_frame_meshes.append(mesh)
		var tint := Color.WHITE
		if resource_id not in ["iron_ore", "copper_ore", "ice", "fire_ice"]:
			var identity := Color.from_string(str(field.get("resource_color", "#aaaaaa")), Color("aaaaaa"))
			tint = Color.WHITE.lerp(identity, 0.52)
			if resource_id in ["coal", "coal_ore"]:
				tint = Color(0.34, 0.36, 0.36)
		canvas.draw_mesh(mesh, texture, transform, tint)
	_trim_cache()

func _trim_cache() -> void:
	while _cache.size() > MAX_CACHED_FIELDS:
		_cache.erase(_cache.keys()[0])

func draw_outline(canvas: CanvasItem, field: Dictionary, tile_scale: float, camera: Vector2, color: Color) -> void:
	var rect := _field_rect(field)
	var step := maxi(1, ceili(sqrt(float(rect.get_area()) / MAX_FIELD_CELLS)))
	for y in range(rect.position.y, rect.end.y, step):
		for x in range(rect.position.x, rect.end.x, step):
			var tile := Vector2i(x, y)
			if not Terrain.field_contains(field, tile):
				continue
			var p := camera + Vector2(tile) * tile_scale
			var edge := Vector2.ONE * step * tile_scale
			if not Terrain.field_contains(field, tile + Vector2i(0, -step)):
				canvas.draw_line(p, p + Vector2(edge.x, 0), color, 1.4)
			if not Terrain.field_contains(field, tile + Vector2i(-step, 0)):
				canvas.draw_line(p, p + Vector2(0, edge.y), color, 1.4)
			if not Terrain.field_contains(field, tile + Vector2i(step, 0)):
				canvas.draw_line(p + Vector2(edge.x, 0), p + edge, color, 1.4)
			if not Terrain.field_contains(field, tile + Vector2i(0, step)):
				canvas.draw_line(p + Vector2(0, edge.y), p + edge, color, 1.4)

func _cluster_mesh(field: Dictionary, texture: Texture2D) -> ArrayMesh:
	var vertices := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var rect := _field_rect(field)
	var step := maxi(2 if mini(rect.size.x, rect.size.y) >= 8 else 1, ceili(sqrt(float(rect.get_area()) / MAX_FIELD_CELLS)))
	var rows := maxi(1, int(texture.get_height()) / 128)
	var columns := maxi(1, int(texture.get_width()) / 128)
	for y in range(rect.position.y, rect.end.y, step):
		for x in range(rect.position.x, rect.end.x, step):
			var tile := Vector2i(x, y)
			if not _cell_inside(field, tile, step):
				continue
			var neighbours := 0
			var edge_tile := false
			for offset in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				if _cell_inside(field, tile + offset * step, step):
					neighbours += 1
			for offset in [Vector2i(-1,-1), Vector2i(1,-1), Vector2i(-1,1), Vector2i(1,1)]:
				if not _cell_inside(field, tile + offset * step, step):
					edge_tile = true
			var seed := int(field.get("seed", rect.position.x * 719 + rect.position.y * 193))
			var random := Terrain._coordinate_noise(seed + 7919, x, y)
			var variation := posmod(random, columns)
			var stage := clampi((4 - neighbours) + (1 if posmod(random / columns, 9) == 0 else 0), 0, rows - 1)
			var offset := Vector2(float(posmod(random / 17, 101)) / 100.0 - 0.5, float(posmod(random / 137, 101)) / 100.0 - 0.5) * 0.40 * step
			var edge := float(step) * (1.37 + float(posmod(random / 31, 100)) * 0.002)
			var sprite_rect := Rect2(Vector2(tile) + Vector2.ONE * step * 0.5 + offset - Vector2.ONE * edge * 0.5, Vector2.ONE * edge)
			var clipped := sprite_rect
			# At the real edge, clip to the owning tile: no decorative pixels can
			# claim adjacent non-mineable ground. Interior clusters may overlap.
			if neighbours < 4 or edge_tile:
				clipped = sprite_rect.intersection(Rect2(Vector2(tile), Vector2.ONE * step))
			clipped = clipped.intersection(Rect2(rect))
			var cell := Vector2(1.0 / columns, 1.0 / rows)
			var inset := Vector2.ONE * 1.5 / texture.get_size()
			var uv_origin := Vector2(variation, stage) * cell + inset
			var uv_size := cell - inset * 2.0
			var uv_rect := Rect2(uv_origin + (clipped.position - sprite_rect.position) / sprite_rect.size * uv_size, clipped.size / sprite_rect.size * uv_size)
			var shade := 0.85 + float(posmod(random / 71, 100)) * 0.0015
			_append_quad(vertices, uvs, colors, indices, clipped, uv_rect, Color(shade, shade, shade, 1.0))
	return _mesh(vertices, uvs, colors, indices)

func _bed_mesh(field: Dictionary) -> ArrayMesh:
	var vertices := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var bounds := _field_rect(field)
	var step := maxi(1, ceili(sqrt(float(bounds.get_area()) / MAX_FIELD_CELLS)))
	for y in range(bounds.position.y, bounds.end.y, step):
		for x in range(bounds.position.x, bounds.end.x, step):
			var tile := Vector2i(x,y)
			if not _cell_inside(field,tile,step): continue
			var rect := Rect2(Vector2(tile), Vector2(mini(step,bounds.end.x-x),mini(step,bounds.end.y-y)))
			_append_quad(vertices,uvs,colors,indices,rect,Rect2(rect.position / 23.0,rect.size / 23.0),Color.WHITE)
			for corner_index in range(4):
				var corner := Vector2i(vertices[vertices.size()-4+corner_index])
				var neighbours := 0
				for offset in [Vector2i(-1,-1),Vector2i(0,-1),Vector2i(-1,0),Vector2i.ZERO]:
					if Terrain.field_contains(field,corner+offset): neighbours += 1
				colors[colors.size()-4+corner_index] = Color(1,1,1,pow(float(neighbours)/4.0,2.0))
	return _mesh(vertices,uvs,colors,indices)

func _survey_mesh(field: Dictionary) -> ArrayMesh:
	var vertices := PackedVector2Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()
	var rect := _field_rect(field)
	var step := maxi(1, ceili(sqrt(float(rect.get_area()) / 256.0)))
	for y in range(rect.position.y, rect.end.y, step):
		for x in range(rect.position.x, rect.end.x, step):
			if _cell_inside(field, Vector2i(x, y), step):
				var cell := Rect2(Vector2(x, y), Vector2(mini(step, rect.end.x - x), mini(step, rect.end.y - y)))
				_append_quad(vertices, uvs, colors, indices, cell, Rect2(0,0,1,1), Color.WHITE)
	return _mesh(vertices, uvs, colors, indices)

## Coarse cells are conservative: they may omit a tiny edge at survey distance,
## but never paint holes as ore. Large authored fields retain bounded work.
static func _cell_inside(field: Dictionary, tile: Vector2i, step: int) -> bool:
	var bounds := _field_rect(field)
	if not bounds.has_point(tile):
		return false
	var extent := Vector2i(step, step).min(bounds.end - tile)
	if step <= 16:
		for y in range(tile.y, tile.y + extent.y):
			for x in range(tile.x, tile.x + extent.x):
				if not Terrain.field_contains(field, Vector2i(x,y)):
					return false
		return true
	if str(field.get("shape", "RECTANGLE")).to_upper() != "IRREGULAR":
		return true
	# All points of this rectangle lie in the guaranteed solid ellipse when
	# its four corners do. The authoritative sampler defines that core radius.
	var center := Vector2(bounds.position) + Vector2(bounds.size - Vector2i.ONE) * 0.5
	var radius := Vector2(bounds.size - Vector2i.ONE) * 0.5
	if radius.x <= 0 or radius.y <= 0:
		return false
	for corner in [tile, tile + Vector2i(extent.x - 1, 0), tile + extent - Vector2i.ONE, tile + Vector2i(0, extent.y - 1)]:
		if ((Vector2(corner) - center) / radius).length() > Terrain.SOLID_FIELD_CORE_RADIUS:
			return false
	return true

static func _key(field: Dictionary) -> String:
	return str(hash([field.get("id"), field.get("footprint"), field.get("seed"), field.get("shape"), field.get("resource_id"), field.get("resource_category"), field.get("grade")]))

static func is_fluid_field(field: Dictionary) -> bool:
	return str(field.get("resource_category", "")).to_lower() in ["gas", "liquid"] or str(field.get("resource_id", "")).trim_prefix("dsp_") in FLUID_IDS

static func _field_rect(field: Dictionary) -> Rect2i:
	var footprint: Dictionary = field.get("footprint", {})
	var origin: Dictionary = footprint.get("origin", {})
	var extent: Dictionary = footprint.get("size", {})
	return Rect2i(int(origin.get("x", 0)), int(origin.get("y", 0)), int(extent.get("x", 0)), int(extent.get("y", 0)))

static func _append_quad(vertices: PackedVector2Array, uvs: PackedVector2Array, colors: PackedColorArray, indices: PackedInt32Array, rect: Rect2, uv: Rect2, color: Color) -> void:
	var start := vertices.size()
	vertices.append_array(PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]))
	uvs.append_array(PackedVector2Array([uv.position, Vector2(uv.end.x, uv.position.y), uv.end, Vector2(uv.position.x, uv.end.y)]))
	colors.append_array(PackedColorArray([color, color, color, color]))
	indices.append_array(PackedInt32Array([start, start + 1, start + 2, start, start + 2, start + 3]))

static func _mesh(vertices: PackedVector2Array, uvs: PackedVector2Array, colors: PackedColorArray, indices: PackedInt32Array) -> ArrayMesh:
	if vertices.is_empty():
		return null
	var result := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return result
