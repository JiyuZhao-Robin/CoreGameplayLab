extends SceneTree

## Empty Factory boards must return the player to the existing palette-driven
## placement flow.  This fixture is presentation-only: it never reaches Game
## and a CTA press must not submit a construction command by itself.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node.new()
	host.name = "FactoryEmptyStateActionsHost"
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.size = Vector2(1280, 720)
	host.add_child(workspace)
	var intents: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: intents.append(intent.duplicate(true)))
	var fixture := _fixture()
	var fixture_signature := JSON.stringify(fixture)
	workspace.apply_snapshot(fixture)
	await process_frame
	await process_frame

	_test_production_empty_cta(workspace, intents)
	workspace.call("_on_placement_cancelled")
	_test_construction_empty_cta(workspace, intents)
	workspace.call("_on_placement_cancelled")
	_test_no_target_stays_disabled(workspace, intents)
	_check(JSON.stringify(fixture) == fixture_signature, "Empty-state CTAs never mutate their caller-owned snapshot")
	_check(intents.is_empty(), "Opening a build target submits no Factory command before a player selects a tile")

	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_EMPTY_STATE_ACTIONS_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)


func _test_production_empty_cta(workspace, intents: Array) -> void:
	workspace.call("_set_active_subworkspace", "PRODUCTION")
	var open_build := workspace.find_child("FactoryProductionEmptyOpenBuild", true, false) as Button
	var before := intents.size()
	if open_build != null:
		open_build.pressed.emit()
	_check(
		open_build != null and not open_build.disabled
		and str(workspace.get("_active_subworkspace")) == "CANVAS"
		and str(workspace.get("_selected_building_id")) == "grid_arc_smelter"
		and str(workspace.get("_active_tool")) == "BUILD"
		and _palette_has(workspace, "grid_arc_smelter")
		and intents.size() == before,
		"An empty Production board uses its stage SELECT_BUILDING intent to open a legal machine in the existing Canvas palette without simulation side effects"
	)


func _test_construction_empty_cta(workspace, intents: Array) -> void:
	workspace.call("_set_active_subworkspace", "CONSTRUCTION")
	var open_build := workspace.find_child("FactoryConstructionEmptyOpenBuild", true, false) as Button
	var before := intents.size()
	if open_build != null:
		open_build.pressed.emit()
	_check(
		open_build != null and not open_build.disabled
		and str(workspace.get("_active_subworkspace")) == "CANVAS"
		and str(workspace.get("_selected_building_id")) == "grid_solar_array"
		and str(workspace.get("_active_tool")) == "BUILD"
		and _palette_has(workspace, "grid_solar_array")
		and intents.size() == before,
		"An empty Construction board falls back to its first affordable unlocked Operations plan and enters the same Canvas placement path"
	)


func _test_no_target_stays_disabled(workspace, intents: Array) -> void:
	var empty_fixture := _fixture()
	empty_fixture["palette"] = {"buildings":[], "recipes":[]}
	empty_fixture["operations"]["build_plans"] = []
	empty_fixture["operations"]["stages"][1]["action"] = {"kind":"OPEN_TAB", "tab":"PRODUCTION"}
	workspace.apply_snapshot(empty_fixture)
	workspace.call("_set_active_subworkspace", "PRODUCTION")
	var open_build := workspace.find_child("FactoryProductionEmptyOpenBuild", true, false) as Button
	var before := intents.size()
	if open_build != null:
		open_build.pressed.emit()
	_check(
		open_build != null and open_build.disabled
		and str(workspace.get("_active_subworkspace")) == "PRODUCTION"
		and str(workspace.get("_selected_building_id")).is_empty()
		and intents.size() == before,
		"A board with no unlocked palette definition exposes no fictional build target or command"
	)


func _palette_has(workspace, building_id: String) -> bool:
	var palette = workspace.find_child("FactoryBuildPalette", true, false)
	return palette != null and (palette.visible_building_ids() as Array).has(building_id)


func _fixture() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_id":"empty-actions-fixture",
		"location_id":"earth_orbit",
		"location_name":"Earth Orbit",
		"topology_revision":1,
		"runtime_revision":1,
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":160, "y":120}},
		"chunk_size_tiles":32,
		"entities":[],
		"links":[],
		"resource_fields":[],
		"construction_orders":[],
		"production":{"summary":{"running":0, "input_shortage":0, "output_full":0, "blocked":0, "idle":0}, "rows":[]},
		"item_names":{"iron_ingot":"Iron ingot"},
		"palette":{
			"buildings":[
				{"id":"grid_arc_smelter", "name":"Arc smelter", "kind":"MACHINE", "footprint":{"width":12, "height":10}, "construction_cost":[{"item":"iron_ingot", "quantity":4}], "recipe_ids":[]},
				{"id":"grid_solar_array", "name":"Solar array", "kind":"POWER", "footprint":{"width":8, "height":8}, "construction_cost":[{"item":"iron_ingot", "quantity":2}], "recipe_ids":[]}
			],
			"recipes":[]
		},
		"operations":{
			"schema_version":1,
			"metrics":{"extractors":0, "running_machines":0, "blocked_entities":0, "stored_items":0, "power_supply_kw":0.0, "power_demand_kw":0.0, "active_orders":0, "waiting_orders":0},
			"stages":[
				{"id":"COLLECTION", "state":"MISSING", "count":0, "action":{"kind":"OPEN_TAB", "tab":"CANVAS"}},
				{"id":"PRODUCTION", "state":"MISSING", "count":0, "action":{"kind":"SELECT_BUILDING", "target_id":"grid_arc_smelter"}},
				{"id":"CONSTRUCTION", "state":"MISSING", "count":0, "action":{"kind":"OPEN_TAB", "tab":"CONSTRUCTION"}},
				{"id":"EXPANSION", "state":"READY", "count":0, "action":{"kind":"SELECT_BUILDING", "target_id":"grid_solar_array"}}
			],
			"alerts":[],
			"materials":[],
			"build_plans":[
				{"definition_id":"grid_arc_smelter", "affordable":false, "work_required":45.0, "power_demand_kw":80.0, "materials":[], "dependencies":[]},
				{"definition_id":"grid_solar_array", "affordable":true, "work_required":10.0, "power_demand_kw":0.0, "materials":[], "dependencies":[]}
			]
		}
	}


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
