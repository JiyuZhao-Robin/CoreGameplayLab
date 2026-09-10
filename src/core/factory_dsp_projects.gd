class_name FactoryDspProjects
extends RefCounted

## Stateless adapters for DSPONLINE's four global/endgame facilities.
##
## `extend_catalog` augments the already-loaded Factory dictionaries in place.
## `finish_recipe` only reads its arguments and returns a settlement proposal;
## the integration boundary must consume normal recipe inputs only up to
## `allowed_cycles`, then call `apply_effects` once.  `world.dsp_effects` is the
## sole persistent authority for all project progress in this adapter.

const RECIPE_MODE_GLOBAL_PROJECT := "GLOBAL_PROJECT"
const RECIPE_MODE_BLACK_HOLE := "BLACK_HOLE"

const EFFECT_GALACTIC_EXPORT := "GALACTIC_EXPORT"
const EFFECT_BLACK_HOLE_DESTROY := "BLACK_HOLE_DESTROY"
const EFFECT_SPACE_STATION_DELIVERY := "SPACE_STATION_DELIVERY"

const BLACK_HOLE_AUTHORIZATION_FIELD := "black_hole_authorized_recipe_id"
const TIME_WARP_BASE_POWER_KW := 100000.0
const TIME_WARP_MINIMUM_MULTIPLIER := 4
const EXPORT_TARGET_CAP := 2000000000

# Direct source adaptation: DSPONLINE src/game/endgame.ts.
const GALACTIC_EXPORTS := [
	{
		"id":"universe_archive", "name":"宇宙矩阵档案", "item_id":"dsp_universe_matrix",
		"base_target":1000, "target_growth":1.55, "credits_per_item":12,
		"base_rate_per_minute":120, "reserve":120
	},
	{
		"id":"solar_sail_array", "name":"太阳帆阵列", "item_id":"dsp_solar_sail",
		"base_target":5000, "target_growth":1.5, "credits_per_item":3,
		"base_rate_per_minute":360, "reserve":240
	},
	{
		"id":"carrier_rocket_fleet", "name":"运载火箭舰队", "item_id":"dsp_small_carrier_rocket",
		"base_target":1000, "target_growth":1.52, "credits_per_item":24,
		"base_rate_per_minute":60, "reserve":60
	},
	{
		"id":"antimatter_exchange", "name":"反物质能源交换", "item_id":"dsp_antimatter_fuel_rod",
		"base_target":500, "target_growth":1.58, "credits_per_item":80,
		"base_rate_per_minute":30, "reserve":24
	}
]

# Direct source adaptation: DSPONLINE src/game/systemSpaceStation.ts.
# The source groups these into four named stages; the Factory runner exposes
# every material row as an ordered phase, so an unavailable later material can
# never be consumed or stranded ahead of the authoritative current phase.
const SPACE_STATION_PHASES := [
	{"name":"轨道基座", "item_id":"titanium_alloy", "amount":1000000},
	{"name":"轨道基座", "item_id":"dsp_frame_material", "amount":500000},
	{"name":"轨道基座", "item_id":"dsp_small_carrier_rocket", "amount":100000},
	{"name":"轨道基座", "item_id":"dsp_universe_matrix", "amount":100000},
	{"name":"主体框架", "item_id":"dsp_frame_material", "amount":2000000},
	{"name":"主体框架", "item_id":"dsp_dyson_sphere_component", "amount":1000000},
	{"name":"主体框架", "item_id":"dsp_titanium_glass", "amount":1000000},
	{"name":"主体框架", "item_id":"dsp_quantum_chip", "amount":500000},
	{"name":"能源核心", "item_id":"dsp_antimatter_fuel_rod", "amount":250000},
	{"name":"能源核心", "item_id":"dsp_annihilation_constraint_sphere", "amount":500000},
	{"name":"能源核心", "item_id":"dsp_strange_matter", "amount":1000000},
	{"name":"能源核心", "item_id":"dsp_plane_filter", "amount":1000000},
	{"name":"调度核心", "item_id":"dsp_processor", "amount":5000000},
	{"name":"调度核心", "item_id":"dsp_particle_broadband", "amount":2000000},
	{"name":"调度核心", "item_id":"dsp_quantum_chip", "amount":2000000},
	{"name":"调度核心", "item_id":"dsp_universe_matrix", "amount":1000000}
]


## Extends the runtime dictionaries idempotently. The caller owns loading and
## validation; this method owns no copy of any catalog or state.
static func extend_catalog(items: Dictionary, buildings: Dictionary, recipes: Dictionary) -> void:
	_add_export_recipes(buildings, recipes)
	_add_black_hole_recipes(items, buildings, recipes)
	_add_space_station_recipes(buildings, recipes)
	_decorate_time_warp(buildings)


## Pure completion proposal. The `blocked` value is stable and the caller must
## not consume recipe inputs when `allowed_cycles` is zero.
static func finish_recipe(world: Dictionary, entity: Dictionary, recipe: Dictionary, cycles: int) -> Dictionary:
	var requested_cycles := maxi(0, cycles)
	var result := {
		"allowed_cycles":requested_cycles,
		"effects":{"exports":[], "destroyed":{}, "station_delivered":[]},
		"blocked":""
	}
	if requested_cycles <= 0:
		return result
	var metadata := _metadata(recipe)
	var mode := str(metadata.get("recipe_mode", "")).to_upper()
	var effect_id := str(metadata.get("special_effect_id", "")).to_upper()
	if mode == RECIPE_MODE_BLACK_HOLE or effect_id == EFFECT_BLACK_HOLE_DESTROY:
		return _finish_black_hole(entity, recipe, result)
	if effect_id == EFFECT_GALACTIC_EXPORT:
		return _finish_export(recipe, result)
	if effect_id == EFFECT_SPACE_STATION_DELIVERY:
		return _finish_station_delivery(world, recipe, result)
	return result


## Applies accepted effects to the canonical world record.  This is deliberately
## the only mutating method in the adapter and never touches entity buffers.
static func apply_effects(world: Dictionary, effects: Dictionary) -> Dictionary:
	var record := _effects_record(world)
	_apply_export_effects(record, _dictionary_array(effects.get("exports", [])))
	_apply_destroyed_effects(record, _dictionary(effects.get("destroyed", {})))
	_apply_station_effects(record, _dictionary_array(effects.get("station_delivered", [])))
	world["dsp_effects"] = record
	return record.duplicate(true)


## Direct source behavior from engine.ts:getMaximumStableTimeWarpMultiplier.
## The source returns null below the usable threshold; this integer API returns
## 1, the normal realtime multiplier, so callers cannot accidentally accelerate
## a powerless or offline simulation.
static func stable_multiplier(surplus_kw: float, requested: int = 5) -> int:
	if not is_finite(surplus_kw) or surplus_kw < TIME_WARP_BASE_POWER_KW or requested < 5:
		return 1
	var supported := maxi(TIME_WARP_MINIMUM_MULTIPLIER, floori(log(surplus_kw) / log(10.0) - 1.0 + 0.000000000001))
	return mini(requested, supported)


static func _add_export_recipes(buildings: Dictionary, recipes: Dictionary) -> void:
	var building := _building(buildings, "grid_dsp_galactic_material_exporter")
	if building.is_empty():
		return
	var recipe_ids := _string_array(building.get("recipe_ids", []))
	for project_value in GALACTIC_EXPORTS:
		var project := project_value as Dictionary
		var project_id := str(project.get("id", ""))
		var recipe_id := "dsp_export_%s" % project_id
		if not recipes.has(recipe_id):
			var metadata := {
				"recipe_mode":RECIPE_MODE_GLOBAL_PROJECT,
				"special_effect_id":EFFECT_GALACTIC_EXPORT,
				"project_id":project_id,
				"base_target":int(project.get("base_target", 1)),
				"target_growth":float(project.get("target_growth", 1.0)),
				"credits_per_item":int(project.get("credits_per_item", 0)),
				"base_rate_per_minute":int(project.get("base_rate_per_minute", 0)),
				"reserve":int(project.get("reserve", 0))
			}
			recipes[recipe_id] = _project_recipe(recipe_id, str(project.get("name", recipe_id)), str(project.get("item_id", "")), building, metadata, "endgame.ts")
		if not recipe_ids.has(recipe_id):
			recipe_ids.append(recipe_id)
	building["recipe_ids"] = recipe_ids
	buildings[str(building.get("id", "grid_dsp_galactic_material_exporter"))] = building


static func _add_black_hole_recipes(items: Dictionary, buildings: Dictionary, recipes: Dictionary) -> void:
	var building := _building(buildings, "grid_dsp_micro_black_hole_connector")
	if building.is_empty():
		return
	var recipe_ids: Array[String] = []
	var item_ids: Array[String] = []
	for item_id_value in items.keys():
		var item_id := str(item_id_value)
		var item := _dictionary(items.get(item_id_value, {}))
		if _is_ordinary_item(item_id, item):
			item_ids.append(item_id)
	item_ids.sort()
	for item_id in item_ids:
		var recipe_id := "dsp_black_hole_destroy_%s" % item_id
		if not recipes.has(recipe_id):
			recipes[recipe_id] = _project_recipe(
				recipe_id,
				"黑洞销毁：%s" % item_id,
				item_id,
				building,
				{"recipe_mode":RECIPE_MODE_BLACK_HOLE, "special_effect_id":EFFECT_BLACK_HOLE_DESTROY, "destroyed_item_id":item_id, "requires_recipe_authorization":true},
				"engine.ts"
			)
		recipe_ids.append(recipe_id)
	building["recipe_ids"] = recipe_ids
	buildings[str(building.get("id", "grid_dsp_micro_black_hole_connector"))] = building


static func _add_space_station_recipes(buildings: Dictionary, recipes: Dictionary) -> void:
	var building := _building(buildings, "grid_dsp_space_station_construction_launcher")
	if building.is_empty():
		return
	var recipe_ids: Array[String] = []
	for phase_index in range(SPACE_STATION_PHASES.size()):
		var phase := SPACE_STATION_PHASES[phase_index] as Dictionary
		var recipe_id := "dsp_station_phase_%02d" % phase_index
		if not recipes.has(recipe_id):
			var metadata := {
				"recipe_mode":RECIPE_MODE_GLOBAL_PROJECT,
				"special_effect_id":EFFECT_SPACE_STATION_DELIVERY,
				"station_phase_index":phase_index,
				"station_phase_name":str(phase.get("name", "")),
				"station_required_amount":int(phase.get("amount", 0)),
				"station_item_id":str(phase.get("item_id", ""))
			}
			recipes[recipe_id] = _project_recipe(recipe_id, "空间站施工：%s" % str(phase.get("name", "")), str(phase.get("item_id", "")), building, metadata, "systemSpaceStation.ts")
		recipe_ids.append(recipe_id)
	building["kind"] = "MACHINE"
	building["recipe_ids"] = recipe_ids
	building["speed"] = maxf(0.001, float(building.get("speed", 1.0)))
	building["input_capacity"] = maxi(1, int(building.get("input_capacity", 1)))
	building["output_capacity"] = maxi(1, int(building.get("output_capacity", 1)))
	var runtime := _metadata(building).duplicate(true)
	runtime["special_effect_id"] = EFFECT_SPACE_STATION_DELIVERY
	runtime["station_phase_count"] = SPACE_STATION_PHASES.size()
	building["runtime_metadata"] = runtime
	buildings[str(building.get("id", "grid_dsp_space_station_construction_launcher"))] = building


static func _decorate_time_warp(buildings: Dictionary) -> void:
	var building := _building(buildings, "grid_dsp_time_warp_device")
	if building.is_empty():
		return
	var runtime := _metadata(building).duplicate(true)
	runtime["special_effect_id"] = "TIME_WARP"
	runtime["time_warp_base_power_kw"] = TIME_WARP_BASE_POWER_KW
	runtime["time_warp_minimum_multiplier"] = TIME_WARP_MINIMUM_MULTIPLIER
	building["runtime_metadata"] = runtime
	buildings[str(building.get("id", "grid_dsp_time_warp_device"))] = building


static func _project_recipe(recipe_id: String, recipe_name: String, item_id: String, building: Dictionary, runtime_metadata: Dictionary, source_file: String) -> Dictionary:
	var recipe := {
		"id":recipe_id,
		"name":recipe_name,
		"duration_seconds":1.0,
		"inputs":[{"item":item_id, "quantity":1}],
		"outputs":[],
		"source_id":recipe_id,
		"source_family":"dsponline_industry_adaptation",
		"source_building_id":str(building.get("id", "")),
		"source_metadata":{"source_file":"src/game/%s" % source_file},
		"runtime_metadata":runtime_metadata.duplicate(true)
	}
	for key in ["requirements", "reveal_requirements"]:
		var inherited: Variant = building.get(key, [])
		if inherited is Array and not (inherited as Array).is_empty():
			recipe[key] = (inherited as Array).duplicate(true)
	return recipe


static func _finish_export(recipe: Dictionary, result: Dictionary) -> Dictionary:
	var metadata := _metadata(recipe)
	var project_id := str(metadata.get("project_id", ""))
	if project_id.is_empty():
		result["allowed_cycles"] = 0
		result["blocked"] = "UNKNOWN_EXPORT_PROJECT"
		return result
	var delivered := maxi(0, int(result.get("allowed_cycles", 0)))
	result["effects"]["exports"].append({
		"project_id":project_id,
		"delivered":delivered,
		"credits":delivered * maxi(0, int(metadata.get("credits_per_item", 0))),
		"base_target":maxi(1, int(metadata.get("base_target", 1))),
		"target_growth":maxf(1.0, float(metadata.get("target_growth", 1.0))),
		"credits_per_item":maxi(0, int(metadata.get("credits_per_item", 0))),
		"base_rate_per_minute":maxi(0, int(metadata.get("base_rate_per_minute", 0))),
		"reserve":maxi(0, int(metadata.get("reserve", 0)))
	})
	return result


static func _finish_black_hole(entity: Dictionary, recipe: Dictionary, result: Dictionary) -> Dictionary:
	var recipe_id := str(recipe.get("id", ""))
	if recipe_id.is_empty() or str(entity.get(BLACK_HOLE_AUTHORIZATION_FIELD, "")) != recipe_id:
		result["allowed_cycles"] = 0
		result["blocked"] = "BLACK_HOLE_AUTHORIZATION_REQUIRED"
		return result
	var item_id := str(_metadata(recipe).get("destroyed_item_id", ""))
	if item_id.is_empty():
		result["allowed_cycles"] = 0
		result["blocked"] = "BLACK_HOLE_ITEM_MISSING"
		return result
	result["effects"]["destroyed"][item_id] = maxi(0, int(result.get("allowed_cycles", 0)))
	return result


static func _finish_station_delivery(world: Dictionary, recipe: Dictionary, result: Dictionary) -> Dictionary:
	var metadata := _metadata(recipe)
	var phase_index := int(metadata.get("station_phase_index", -1))
	if phase_index < 0 or phase_index >= SPACE_STATION_PHASES.size():
		result["allowed_cycles"] = 0
		result["blocked"] = "STATION_PHASE_INVALID"
		return result
	var source_phase := SPACE_STATION_PHASES[phase_index] as Dictionary
	if str(metadata.get("station_item_id", "")) != str(source_phase.get("item_id", "")) or int(metadata.get("station_required_amount", 0)) != int(source_phase.get("amount", 0)):
		result["allowed_cycles"] = 0
		result["blocked"] = "STATION_PHASE_INVALID"
		return result
	var record := _effects_view(world)
	if bool(record.get("station_completed", false)):
		result["allowed_cycles"] = 0
		result["blocked"] = "STATION_COMPLETE"
		return result
	var current_phase := clampi(int(record.get("station_phase_index", 0)), 0, SPACE_STATION_PHASES.size())
	if current_phase >= SPACE_STATION_PHASES.size():
		result["allowed_cycles"] = 0
		result["blocked"] = "STATION_COMPLETE"
		return result
	if phase_index != current_phase:
		result["allowed_cycles"] = 0
		result["blocked"] = "STATION_PHASE_LOCKED"
		return result
	var delivered := _dictionary(record.get("station_delivered", {}))
	var delivered_amount := maxi(0, int(delivered.get(str(phase_index), 0)))
	var required_amount := maxi(1, int(metadata.get("station_required_amount", 1)))
	var allowed := mini(maxi(0, int(result.get("allowed_cycles", 0))), maxi(0, required_amount - delivered_amount))
	if allowed <= 0:
		result["allowed_cycles"] = 0
		result["blocked"] = "STATION_PHASE_COMPLETE"
		return result
	result["allowed_cycles"] = allowed
	result["effects"]["station_delivered"].append({
		"phase_index":phase_index,
		"item_id":str(metadata.get("station_item_id", "")),
		"delivered":allowed,
		"required_amount":required_amount,
		"phase_name":str(metadata.get("station_phase_name", ""))
	})
	return result


static func _apply_export_effects(record: Dictionary, rows: Array) -> void:
	var projects := _dictionary(record.get("export_projects", {})).duplicate(true)
	var levels := _dictionary(record.get("export_levels", {})).duplicate(true)
	var total_credits := maxi(0, int(record.get("galactic_credits", 0)))
	var total_exported := maxi(0, int(record.get("total_exported", 0)))
	for row_value in rows:
		var row := row_value as Dictionary
		var project_id := str(row.get("project_id", ""))
		var amount := maxi(0, int(row.get("delivered", 0)))
		if project_id.is_empty() or amount <= 0:
			continue
		var project := _dictionary(projects.get(project_id, {})).duplicate(true)
		var base_target := maxi(1, int(row.get("base_target", project.get("base_target", 1))))
		var target_growth := maxf(1.0, float(row.get("target_growth", project.get("target_growth", 1.0))))
		var credits_per_item := maxi(0, int(row.get("credits_per_item", project.get("credits_per_item", 0))))
		var level := maxi(0, int(project.get("level", 0)))
		var delivered := maxi(0, int(project.get("delivered", 0))) + amount
		var credits := amount * credits_per_item
		while delivered >= _export_target(base_target, target_growth, level):
			var target := _export_target(base_target, target_growth, level)
			delivered -= target
			credits += target * credits_per_item
			level += 1
		project = {
			"id":project_id,
			"level":level,
			"delivered":delivered,
			"total_delivered":maxi(0, int(project.get("total_delivered", 0))) + amount,
			"base_target":base_target,
			"target_growth":target_growth,
			"credits_per_item":credits_per_item,
			"base_rate_per_minute":maxi(0, int(row.get("base_rate_per_minute", project.get("base_rate_per_minute", 0)))),
			"reserve":maxi(0, int(row.get("reserve", project.get("reserve", 0))))
		}
		projects[project_id] = project
		levels[project_id] = level
		total_credits += credits
		total_exported += amount
	record["export_projects"] = projects
	record["export_levels"] = levels
	record["galactic_credits"] = total_credits
	record["total_exported"] = total_exported


static func _apply_destroyed_effects(record: Dictionary, manifest: Dictionary) -> void:
	var destroyed := _dictionary(record.get("destroyed", {})).duplicate(true)
	for item_id_value in manifest.keys():
		var item_id := str(item_id_value)
		var amount := maxi(0, int(manifest.get(item_id_value, 0)))
		if item_id.is_empty() or amount <= 0:
			continue
		destroyed[item_id] = maxi(0, int(destroyed.get(item_id, 0))) + amount
	record["destroyed"] = destroyed


static func _apply_station_effects(record: Dictionary, rows: Array) -> void:
	var delivered := _dictionary(record.get("station_delivered", {})).duplicate(true)
	var phase_index := clampi(int(record.get("station_phase_index", 0)), 0, SPACE_STATION_PHASES.size())
	if bool(record.get("station_completed", false)):
		return
	for row_value in rows:
		if phase_index >= SPACE_STATION_PHASES.size():
			break
		var row := row_value as Dictionary
		if int(row.get("phase_index", -1)) != phase_index:
			continue
		var phase := SPACE_STATION_PHASES[phase_index] as Dictionary
		if str(row.get("item_id", "")) != str(phase.get("item_id", "")):
			continue
		var required := maxi(1, int(phase.get("amount", 1)))
		var current := maxi(0, int(delivered.get(str(phase_index), 0)))
		var moved := mini(maxi(0, int(row.get("delivered", 0))), maxi(0, required - current))
		if moved <= 0:
			continue
		delivered[str(phase_index)] = current + moved
		if int(delivered.get(str(phase_index), 0)) >= required:
			phase_index += 1
	record["station_delivered"] = delivered
	record["station_phase_index"] = phase_index
	record["station_stage"] = phase_index
	record["station_completed"] = phase_index >= SPACE_STATION_PHASES.size()


static func _export_target(base_target: int, growth: float, level: int) -> int:
	return clampi(roundi(float(base_target) * pow(growth, maxi(0, level))), 1, EXPORT_TARGET_CAP)


static func _building(buildings: Dictionary, id: String) -> Dictionary:
	return _dictionary(buildings.get(id, {})).duplicate(true)


static func _metadata(record: Dictionary) -> Dictionary:
	return _dictionary(record.get("runtime_metadata", {}))


static func _effects_view(world: Dictionary) -> Dictionary:
	return _dictionary(world.get("dsp_effects", {}))


static func _effects_record(world: Dictionary) -> Dictionary:
	return _effects_view(world).duplicate(true)


static func _dictionary(value: Variant) -> Dictionary:
	return value as Dictionary if value is Dictionary else {}


static func _dictionary_array(value: Variant) -> Array:
	var result: Array = []
	if value is Array:
		for entry in value as Array:
			if entry is Dictionary:
				result.append(entry as Dictionary)
	return result


static func _string_array(value: Variant) -> Array[String]:
	var result: Array[String] = []
	if value is Array:
		for entry in value as Array:
			var text := str(entry)
			if not text.is_empty() and not result.has(text):
				result.append(text)
	return result


static func _is_ordinary_item(item_id: String, item: Dictionary) -> bool:
	if item_id.is_empty() or not str(item.get("building_definition_id", "")).is_empty():
		return false
	return str(item.get("category", "")).to_lower() != "building"
