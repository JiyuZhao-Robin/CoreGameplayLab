extends SceneTree

## Factory Operations v1 presentation boundary. This test intentionally uses a
## detached fixture: the overview can route focus and construction placement,
## but it cannot reach Game or mutate a Factory simulation.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node.new()
	host.name = "FactoryOperationsUiTestHost"
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.size = Vector2(1408, 730)
	host.add_child(workspace)
	var i18n := get_root().get_node_or_null("I18n")
	if i18n != null:
		i18n.call("set_locale", "zh_CN")
	var intents: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: intents.append(intent.duplicate(true)))
	workspace.apply_snapshot(_fixture())
	await process_frame
	await process_frame

	_test_default_operations_overview(workspace)
	await _test_overview_width_locale_and_selector_retention(workspace)
	_test_stage_and_alert_routes(workspace)
	_test_build_plan_route_and_intent(workspace, intents)
	_test_canvas_camera_retention(workspace)
	_test_recipe_buffer_and_deficit_semantics(workspace)

	host.queue_free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_OPERATIONS_UI_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)


func _test_default_operations_overview(workspace) -> void:
	var overview = workspace.find_child("FactoryOperationsOverview", true, false) as Control
	var hero = workspace.find_child("FactoryOperationsHero", true, false) as Control
	var planner = workspace.find_child("FactoryOperationsPlanner", true, false) as Control
	var stage = workspace.find_child("FactoryOperationsStageProduction", true, false) as Button
	var plan = workspace.find_child("FactoryOperationsBuildTarget", true, false) as OptionButton
	var material = workspace.find_child("FactoryOperationsPlanMaterialIronIngot", true, false) as Control
	var deficit_material = workspace.find_child("FactoryOperationsPlanMaterialElectronics", true, false) as Control
	var warehouse = workspace.find_child("FactoryOperationsWarehouseThumbnail", true, false) as TextureRect
	_check(
		str(workspace.get("_active_subworkspace")) == "OVERVIEW"
		and workspace.find_child("FactoryTabOverview", true, false) != null
		and overview != null and overview.visible and hero != null and hero.size.y >= 120.0
		and planner != null and stage != null and plan != null and plan.item_count == 2 and material != null and deficit_material != null and warehouse != null,
		"Factory opens a full operations overview with a visible chain, all unlocked plans, live material deficits, warehouse telemetry and authored hero surface"
	)


func _test_overview_width_locale_and_selector_retention(workspace) -> void:
	var overview = workspace.find_child("FactoryOperationsOverview", true, false) as Control
	var content = workspace.find_child("FactoryOperationsContent", true, false) as Control
	var hero = workspace.find_child("FactoryOperationsHero", true, false) as Control
	var selector = workspace.find_child("FactoryOperationsBuildTarget", true, false) as OptionButton
	var alert = workspace.find_child("FactoryOperationsAlertmaterial_shortage", true, false) as Button
	var overview_text := _descendant_text(overview)
	_check(
		overview != null and content != null and hero != null
		and content.size.x >= overview.size.x * 0.90 and hero.size.x >= overview.size.x * 0.90
		and not overview_text.contains("Extractors") and not overview_text.contains("MATERIAL_SHORTAGE")
		and alert != null and not alert.text.contains("MATERIAL_SHORTAGE"),
		"Overview occupies the authored width and zh telemetry localizes KPI and alert status labels without internal codes"
	)
	if selector == null:
		_check(false, "Build target selector is available for runtime refresh retention")
		return
	selector.show_popup()
	await process_frame
	var updated := _fixture()
	updated["runtime_revision"] = 13
	workspace.apply_snapshot(updated)
	await process_frame
	_check(
		is_instance_valid(selector) and selector.get_popup().visible,
		"A runtime snapshot does not rebuild an open build target selector"
	)
	selector.get_popup().hide()
	await process_frame


func _test_stage_and_alert_routes(workspace) -> void:
	var production_stage = workspace.find_child("FactoryOperationsStageProduction", true, false) as Button
	if production_stage != null:
		production_stage.pressed.emit()
	_check(
		str(workspace.get("_active_subworkspace")) == "PRODUCTION"
		and workspace.find_child("ProductionStatusSummary", true, false) != null
		and workspace.find_child("ProductionMaterialLedger", true, false) != null
		and workspace.find_child("FactoryBuildingThumbnailGridSurfaceMine", true, false) != null,
		"Operations chain routes Production to a persistent board with live material flow and authored building art"
	)
	workspace.call("_set_active_subworkspace", "OVERVIEW")
	var alert = workspace.find_child("FactoryOperationsAlertentity_smelter_blocked", true, false) as Button
	if alert != null:
		alert.pressed.emit()
	var selection: Dictionary = workspace.get("_selection") as Dictionary
	_check(
		alert != null and str(workspace.get("_active_subworkspace")) == "CANVAS"
		and str(selection.get("kind", "")) == "ENTITY" and str(selection.get("id", "")) == "smelter-blocked",
		"An actionable overview alert focuses its exact physical factory entity on the canvas"
	)


func _test_build_plan_route_and_intent(workspace, intents: Array) -> void:
	workspace.call("_set_active_subworkspace", "OVERVIEW")
	var open_build = workspace.find_child("FactoryOperationsBuildGridArcSmelter", true, false) as Button
	if open_build != null:
		open_build.pressed.emit()
	_check(
		open_build != null and str(workspace.get("_active_subworkspace")) == "CANVAS"
		and str(workspace.get("_selected_building_id")) == "grid_arc_smelter"
		and str(workspace.get("_active_tool")) == "BUILD",
		"Build target planner opens the exact physical building in the existing construction palette"
	)
	var before := intents.size()
	workspace.call("_request_construction", Vector2i(100, 100))
	var intent: Dictionary = intents.back() as Dictionary if intents.size() > before else {}
	var payload: Dictionary = intent.get("payload", {}) as Dictionary
	_check(
		intents.size() == before + 1 and str(intent.get("kind", "")) == "QUEUE_CONSTRUCTION"
		and str(payload.get("definition_id", "")) == "grid_arc_smelter"
		and str(payload.get("funding_policy", "")) == "AUTO_SAME_LOCATION",
		"Planner-to-canvas placement emits only the established versioned construction intent with automatic same-world staging"
	)


func _test_canvas_camera_retention(workspace) -> void:
	var canvas = workspace.canvas()
	canvas.focus_tile(Vector2i(34, 34))
	var camera_before: Vector2 = canvas.get("_camera") as Vector2
	var updated := _fixture()
	updated["runtime_revision"] = 12
	updated["operations"]["metrics"]["stored_items"] = 44
	workspace.apply_snapshot(updated)
	var camera_after: Vector2 = canvas.get("_camera") as Vector2
	_check(
		camera_before.distance_to(camera_after) < 0.01
		and not bool(canvas.get("_overview_mode")),
		"Runtime operations refresh retains the player-selected physical canvas camera instead of resetting to a world overview"
	)


func _test_recipe_buffer_and_deficit_semantics(workspace) -> void:
	var fixture := _fixture()
	fixture["palette"]["recipes"] = [{"id":"smelt-test", "name":"Smelt", "inputs":[{"item":"iron_ore", "quantity":2}], "outputs":[{"item":"iron_ingot", "quantity":1}]}]
	var machine: Dictionary = fixture["entities"][1]
	machine["recipe_id"] = "smelt-test"
	machine["inputs"] = {"iron_ore":1}
	machine["outputs"] = {"iron_ingot":0}
	workspace.apply_snapshot(fixture)
	_check(workspace.call("_production_recipe_manifest", machine, "outputs") == {"iron_ingot":1}, "per-cycle output is the recipe yield, not an empty live output buffer")
	var shortage := str(workspace.call("_production_deficit_line", machine))
	_check(shortage.contains("Iron ore 1"), "input-shortage diagnosis compares this machine's own buffer with its next recipe cycle")
	machine["status"] = "RUNNING"
	_check(str(workspace.call("_production_deficit_line", machine)).is_empty(), "global construction deficits are never shown as a running machine's input shortage")
	workspace.call("_set_active_subworkspace", "OVERVIEW")
	var telemetry := workspace.find_child("FactoryOperationsTelemetry", true, false) as Label
	_check(telemetry != null and telemetry.text.contains("2 条异常报告"), "hero exception count includes the same reports as the attention board")
	var feedback := workspace.find_child("FactoryCommandFeedback", true, false) as Label
	_check(feedback != null and not feedback.text.contains("不可用"), "first valid snapshot replaces initial unavailable telemetry")
	fixture["construction_orders"][0]["blocker_code"] = "MISSING_MATERIALS"
	workspace.apply_snapshot(fixture)
	workspace.call("_set_active_subworkspace", "CONSTRUCTION")
	var order_text := _descendant_text(workspace.find_child("ConstructionOrderorder-auto", true, false))
	_check(order_text.contains("制约因素：") and not order_text.contains("阻塞："), "waiting materials is reported as a constraint, not falsely counted as a BLOCKED order")


func _fixture() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_id":"operations-fixture",
		"location_id":"earth_orbit",
		"location_name":"Earth Orbit",
		"topology_revision":4,
		"runtime_revision":11,
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":160, "y":120}},
		"chunk_size_tiles":32,
		"entities":[
			_entity("mine-running", "EXTRACTOR", "Surface mining field", Vector2i(18, 22), "RUNNING", {"outputs":{"iron_ore":8}, "power_demand_kw":50.0}),
			_entity("smelter-blocked", "MACHINE", "Arc smelter", Vector2i(42, 28), "INPUT_SHORTAGE", {"inputs":{}, "outputs":{}, "blocker_code":"INPUT_SHORTAGE", "power_demand_kw":80.0}),
			_entity("depot-local", "STORAGE", "Bulk depot", Vector2i(72, 34), "READY", {"inventory":{"iron_ingot":3, "electronics":1}}),
			_entity("solar-local", "POWER", "Solar array", Vector2i(22, 55), "RUNNING", {"power_generation_kw":100.0})
		],
		"links":[],
		"resource_fields":[{"id":"iron-field", "resource_id":"iron_ore", "resource_name":"Iron ore", "grade":1.2, "footprint":{"origin":{"x":12, "y":16}, "size":{"x":18, "y":16}}}],
		"construction_orders":[{"id":"order-auto", "definition_id":"grid_arc_smelter", "building_name":"Arc smelter", "status":"WAITING_MATERIALS", "funding_policy":"AUTO_SAME_LOCATION", "progress":0.2, "required_items":{"iron_ingot":4}, "delivered_items":{"iron_ingot":1}, "footprint":{"origin":{"x":100, "y":20}, "size":{"x":12, "y":10}}}],
		"location_available_inventory":{"iron_ingot":2, "electronics":1},
		"item_names":{"iron_ore":"Iron ore", "iron_ingot":"Iron ingot", "electronics":"Electronics"},
		"palette":{"buildings":[
			{"id":"grid_arc_smelter", "name":"Arc smelter", "kind":"MACHINE", "footprint":{"width":12, "height":10}, "power_demand_kw":80.0, "construction_work":45.0, "construction_cost":[{"item":"iron_ingot", "quantity":4}, {"item":"electronics", "quantity":2}], "recipe_ids":[]},
			{"id":"grid_solar_array", "name":"Solar array", "kind":"POWER", "footprint":{"width":8, "height":8}, "power_generation_kw":100.0, "construction_work":10.0, "construction_cost":[{"item":"iron_ingot", "quantity":2}], "recipe_ids":[]}
		], "recipes":[]},
		"operations":{
			"schema_version":1,
			"metrics":{"extractors":1, "running_machines":1, "blocked_entities":1, "stored_items":12, "power_supply_kw":100.0, "power_demand_kw":130.0, "active_orders":0, "waiting_orders":1},
			"stages":[
				{"id":"COLLECTION", "state":"ACTIVE", "count":1, "action":{"kind":"OPEN_TAB", "tab":"CANVAS"}},
				{"id":"PRODUCTION", "state":"BLOCKED", "count":1, "action":{"kind":"OPEN_TAB", "tab":"PRODUCTION"}},
				{"id":"CONSTRUCTION", "state":"ACTIVE", "count":1, "action":{"kind":"OPEN_TAB", "tab":"CONSTRUCTION"}},
				{"id":"EXPANSION", "state":"READY", "count":2, "action":{"kind":"OPEN_TAB", "tab":"CANVAS"}}
			],
			"alerts":[
				{"id":"entity_smelter_blocked", "code":"INPUT_SHORTAGE", "entity_id":"smelter-blocked", "action":{"kind":"FOCUS_ENTITY", "target_id":"smelter-blocked"}},
				{"id":"material_shortage", "code":"MATERIAL_SHORTAGE", "item_id":"electronics", "amount":1, "action":{"kind":"OPEN_TAB", "tab":"PRODUCTION"}}
			],
			"materials":[
				{"item_id":"iron_ingot", "stored":3, "location_available":2, "buffered":0, "available":5, "required":4, "missing":0, "production_per_second":0.5, "consumption_per_second":0.75},
				{"item_id":"electronics", "stored":1, "location_available":1, "buffered":0, "available":2, "required":2, "missing":0, "production_per_second":0.0, "consumption_per_second":0.0}
			],
			"build_plans":[
				{"definition_id":"grid_arc_smelter", "affordable":false, "work_required":45.0, "power_demand_kw":80.0, "materials":[{"item_id":"iron_ingot", "required":4, "available":5, "missing":0, "producer_building_id":"", "recipe_id":"grid_refine_iron"}, {"item_id":"electronics", "required":2, "available":1, "missing":1, "producer_building_id":"grid_engineering_works", "recipe_id":"grid_fabricate_electronics"}], "dependencies":[{"item_id":"electronics", "depth":1, "recipe_id":"grid_fabricate_electronics", "building_id":"grid_engineering_works", "inputs":[], "outputs":[]}]},
				{"definition_id":"grid_solar_array", "affordable":true, "work_required":10.0, "power_demand_kw":0.0, "materials":[{"item_id":"iron_ingot", "required":2, "available":5, "missing":0, "producer_building_id":"", "recipe_id":""}], "dependencies":[]}
			]
		}
	}


func _entity(entity_id: String, kind: String, title: String, origin: Vector2i, status: String, extra: Dictionary) -> Dictionary:
	var entity := {
		"id":entity_id,
		"definition_id":"grid_surface_mine" if kind == "EXTRACTOR" else "grid_arc_smelter",
		"node_kind":kind,
		"name":title,
		"status":status,
		"footprint":{"origin":{"x":origin.x, "y":origin.y}, "size":{"x":8, "y":8}},
		"ports":{"inputs":[], "outputs":[]},
		"inventory":{},
		"inputs":{},
		"outputs":{},
		"power_factor":1.0
	}
	for key in extra.keys():
		entity[key] = extra.get(key)
	return entity


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _descendant_text(node: Node) -> String:
	if node == null:
		return ""
	var text_value := (node as Label).text if node is Label else ((node as Button).text if node is Button else "")
	for child in node.get_children():
		text_value += _descendant_text(child)
	return text_value
