class_name ShipHullVisual
extends Control

const ShipHullProfiles = preload("res://src/ui/components/ship_hull_profiles.gd")
const HullFxShader = preload("res://src/ui/shaders/ship_hull_fx.gdshader")
const HullGhostShader = preload("res://src/ui/shaders/ship_hull_ghost.gdshader")
const NOISE_TEXTURE_PATH := "res://assets/ui/ship_hull_noise.png"

var visual_spec: Dictionary = {}
var ui_visual: Dictionary = {}
var _base_texture: Texture2D
var _fx_mask: Texture2D
var _noise_texture: Texture2D
var _main_rect: ColorRect
var _ghost_rect: ColorRect
var _main_material: ShaderMaterial
var _ghost_material: ShaderMaterial
var _asset_loaded := false
var _hovered := false
var _selected := false
var _zoom_level := 1.0
var _connection_activity := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = false
	resized.connect(_layout_layers)
	_layout_layers()


func configure(presentation: Dictionary, spec: Dictionary) -> bool:
	ui_visual = presentation.duplicate(true)
	visual_spec = spec.duplicate(true)
	var base_path := String(ui_visual.get("topdown_texture", ""))
	var mask_path := String(ui_visual.get("fx_mask", ""))
	if base_path.is_empty() or mask_path.is_empty() or not ResourceLoader.exists(base_path) or not ResourceLoader.exists(mask_path) or not ResourceLoader.exists(NOISE_TEXTURE_PATH):
		_asset_loaded = false
		visible = false
		return false
	_base_texture = load(base_path) as Texture2D
	_fx_mask = load(mask_path) as Texture2D
	_noise_texture = load(NOISE_TEXTURE_PATH) as Texture2D
	if _base_texture == null or _fx_mask == null or _noise_texture == null:
		_asset_loaded = false
		visible = false
		return false
	_asset_loaded = true
	visible = true
	_ensure_layers()
	_configure_materials()
	_layout_layers()
	return true


func asset_loaded() -> bool:
	return _asset_loaded


func hull_draw_rect() -> Rect2:
	if not _asset_loaded:
		return Rect2()
	var physical_size := Vector2(
		float(visual_spec.get("beam_m", 36.0)),
		float(visual_spec.get("length_m", 120.0))
	) * ShipHullProfiles.WORLD_SCALE
	var physical_rect := Rect2((size - physical_size) * 0.5, physical_size)
	var texture_size := _base_texture.get_size()
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return physical_rect
	var uniform_scale := minf(physical_rect.size.x / texture_size.x, physical_rect.size.y / texture_size.y)
	uniform_scale *= clampf(float(ui_visual.get("visual_scale", 1.0)), 0.85, 1.05)
	var registered_size := texture_size * uniform_scale
	var offset_m := _array_vector2(ui_visual.get("offset_m", []))
	return Rect2(physical_rect.get_center() - registered_size * 0.5 + offset_m * ShipHullProfiles.WORLD_SCALE, registered_size)


func set_presentation_state(hovered: bool, selected: bool, zoom_level: float, connection_activity: float) -> void:
	_hovered = hovered
	_selected = selected
	_zoom_level = zoom_level
	_connection_activity = clampf(connection_activity, 0.0, 1.0)
	_sync_state_parameters()


func _ensure_layers() -> void:
	if is_instance_valid(_main_rect) and is_instance_valid(_ghost_rect):
		return
	_ghost_rect = ColorRect.new()
	_ghost_rect.name = "ShipHullGhost"
	_ghost_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ghost_rect.color = Color.WHITE
	add_child(_ghost_rect)
	_main_rect = ColorRect.new()
	_main_rect.name = "ShipHullBaseFx"
	_main_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_main_rect.color = Color.WHITE
	add_child(_main_rect)
	_ghost_material = ShaderMaterial.new()
	_ghost_material.shader = HullGhostShader
	_ghost_rect.material = _ghost_material
	_main_material = ShaderMaterial.new()
	_main_material.shader = HullFxShader
	_main_rect.material = _main_material


func _configure_materials() -> void:
	var glow_color := Color.from_string(String(ui_visual.get("glow_color", "#5fc4c9")), Color("5fc4c9"))
	var texture_size := _base_texture.get_size()
	var texel_size := Vector2(1.0 / maxf(texture_size.x, 1.0), 1.0 / maxf(texture_size.y, 1.0))
	for material_value in [_main_material, _ghost_material]:
		var shader_material := material_value as ShaderMaterial
		shader_material.set_shader_parameter("base_texture", _base_texture)
		shader_material.set_shader_parameter("noise_texture", _noise_texture)
		shader_material.set_shader_parameter("base_texel_size", texel_size)
	_main_material.set_shader_parameter("fx_mask", _fx_mask)
	_main_material.set_shader_parameter("glow_color", glow_color)
	_main_material.set_shader_parameter("flow_strength", float(ui_visual.get("flow_strength", 0.075)))
	_main_material.set_shader_parameter("flow_speed", float(ui_visual.get("flow_speed", 0.055)))
	_main_material.set_shader_parameter("edge_strength", float(ui_visual.get("edge_strength", 0.10)))
	_main_material.set_shader_parameter("emission_strength", float(ui_visual.get("emission_strength", 0.13)))
	_main_material.set_shader_parameter("scan_strength", float(ui_visual.get("scan_strength", 0.028)))
	_main_material.set_shader_parameter("scan_speed", float(ui_visual.get("scan_speed", 0.067)))
	_main_material.set_shader_parameter("halo_strength", float(ui_visual.get("halo_strength", 0.12)))
	_ghost_material.set_shader_parameter("ghost_color", glow_color)
	_ghost_material.set_shader_parameter("ghost_strength", float(ui_visual.get("ghost_strength", 0.032)))
	_sync_state_parameters()


func _layout_layers() -> void:
	if not _asset_loaded or not is_instance_valid(_main_rect) or size.x <= 1.0 or size.y <= 1.0:
		return
	var registered := hull_draw_rect()
	_layout_shader_rect(_ghost_rect, _ghost_material, registered, 11.0, Vector2(1.4, -0.7))
	_layout_shader_rect(_main_rect, _main_material, registered, 22.0, Vector2.ZERO)


func _layout_shader_rect(target: ColorRect, shader_material: ShaderMaterial, registered: Rect2, padding: float, offset: Vector2) -> void:
	var expanded := registered.grow(padding)
	expanded.position += offset
	target.position = expanded.position
	target.size = expanded.size
	var uv_rect := Rect2((registered.position - expanded.position) / expanded.size, registered.size / expanded.size)
	shader_material.set_shader_parameter("ship_uv_rect", Vector4(uv_rect.position.x, uv_rect.position.y, uv_rect.size.x, uv_rect.size.y))


func _sync_state_parameters() -> void:
	if not is_instance_valid(_main_material) or not is_instance_valid(_ghost_material):
		return
	var lod := smoothstep(0.26, 0.66, _zoom_level)
	for material_value in [_main_material, _ghost_material]:
		var shader_material := material_value as ShaderMaterial
		shader_material.set_shader_parameter("hover_amount", 1.0 if _hovered else 0.0)
		shader_material.set_shader_parameter("selection_amount", 1.0 if _selected else 0.0)
		shader_material.set_shader_parameter("lod_amount", lod)
	_main_material.set_shader_parameter("connection_activity", _connection_activity)


func _array_vector2(value: Variant) -> Vector2:
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO
