extends SceneTree

## Focused presentation checks for the finished-building/planetary-inventory
## contract. Fixtures are immutable snapshots; this test never reaches Game,
## simulation, or content mutation APIs.

const LocationWorkspaceScript = preload("res://src/ui/workspaces/location/location_operations_workspace.gd")
const FactoryWorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")
const BuildingArt = preload("res://src/ui/workspaces/factory/factory_building_art.gd")
const ItemIcon = preload("res://src/ui/workspaces/location/location_item_icon.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")
const LocalizationScript = preload("res://src/application/localization.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var game := get_root().get_node_or_null("Game")
	if game != null:
		game.set_process(false)
		game.persistence_enabled = false
	UiTokens.set_ui_scale(1.0)
	var i18n := get_root().get_node_or_null("I18n")
	var owns_i18n := i18n == null
	if owns_i18n:
		i18n = LocalizationScript.new()
		i18n.name = "I18n"
		get_root().add_child(i18n)
		await process_frame
	i18n.set("current_locale", "en")

	var host := Control.new()
	host.name = "ContentSyncUiTestHost"
	host.size = Vector2(1920, 1080)
	get_root().add_child(host)
	var location = LocationWorkspaceScript.new()
	location.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(location)
	var location_intents: Array[Dictionary] = []
	location.action_requested.connect(func(action: Dictionary) -> void: location_intents.append(action.duplicate(true)))
	location.configure(_surface_preparation_fixture())
	await _settle()
	await _test_surface_preparation_location(location, location_intents)
	location.configure(_location_fixture(true))
	await _settle()
	await _test_pre_landing_location(location, location_intents)
	await _test_post_landing_location(location, location_intents)
	await _test_location_deployment_ghost(location)

	var factory := FactoryWorkspaceScript.new()
	factory.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(factory)
	factory.apply_snapshot(_factory_fixture())
	await _settle()
	await _test_deployment_ghost_board(factory)
	_test_planetary_inventory_art(factory)

	factory.queue_free()
	location.queue_free()
	host.queue_free()
	if owns_i18n:
		i18n.queue_free()
	await process_frame
	_finish()


func _test_pre_landing_location(workspace: Control, intents: Array[Dictionary]) -> void:
	var hero := workspace.find_child("LocationOperationsFactoryArt", true, false) as TextureRect
	var industry_empty := workspace.find_child("LocationFacilityEmptyAction", true, false) as Button
	var tasks_empty := workspace.find_child("LocationTaskEmptyAction", true, false) as Button
	var inventory := workspace.find_child("InventoryRow_iron_ingot", true, false) as Panel
	var stock_action := inventory.get_meta("action") as Button if inventory != null else null
	var environment := workspace.find_child("LocationEnvironmentDetailsButton", true, false) as Button
	_check(_is_core_art(hero.texture if hero != null else null), "pre-landing Location hero uses the real Planetary Development Core art rather than a prebuilt research facility")
	_check(industry_empty != null and industry_empty.text.contains("Deploy") and tasks_empty != null and tasks_empty.text.contains("Deploy"), "pre-landing industry and task empty actions explicitly lead to core deployment")
	_check(stock_action != null and stock_action.tooltip_text.contains("Location-held 2400") and not stock_action.tooltip_text.contains("Factory warehouses"), "inventory tooltip presents one Location-held quantity and never a second warehouse store")
	_check(environment != null and not environment.tooltip_text.contains("Construction work") and not environment.tooltip_text.contains("Construction speed"), "environment UI omits retired onsite-construction work and speed multipliers")
	var before := intents.size()
	if industry_empty != null:
		industry_empty.pressed.emit()
	var industry_action: Dictionary = intents.back() if intents.size() > before else {}
	before = intents.size()
	if tasks_empty != null:
		tasks_empty.pressed.emit()
	var task_action: Dictionary = intents.back() if intents.size() > before else {}
	_check(_factory_canvas_action(industry_action) and _factory_canvas_action(task_action), "pre-landing empty actions preserve their authoritative Factory canvas intent shape")


func _test_surface_preparation_location(workspace: Control, intents: Array[Dictionary]) -> void:
	var hero := workspace.find_child("LocationOperationsFactoryArt", true, false) as TextureRect
	var industry_empty := workspace.find_child("LocationFacilityEmptyAction", true, false) as Button
	var tasks_empty := workspace.find_child("LocationTaskEmptyAction", true, false) as Button
	var empty_art := workspace.find_child("EmptyStateBuildingArt", true, false) as TextureRect
	_check(hero != null and not hero.visible and hero.texture == null, "surveyed Locations without a Factory world do not imply that a Development Core is already present")
	_check(empty_art != null and not empty_art.visible and empty_art.texture == null, "surface preparation does not reuse Development Core art before a Factory snapshot requires it")
	_check(industry_empty != null and industry_empty.text.contains("Prepare Planet Surface") and tasks_empty != null and tasks_empty.text.contains("Prepare Planet Surface"), "a surveyed Location without a Factory world explicitly asks the player to prepare its planetary surface")
	var before := intents.size()
	if industry_empty != null:
		industry_empty.pressed.emit()
	var industry_action: Dictionary = intents.back() if intents.size() > before else {}
	before = intents.size()
	if tasks_empty != null:
		tasks_empty.pressed.emit()
	var task_action: Dictionary = intents.back() if intents.size() > before else {}
	_check(str(industry_action.get("kind", "")) == "INITIALIZE_FACTORY" and str(task_action.get("kind", "")) == "INITIALIZE_FACTORY", "surface-preparation CTA preserves the snapshot initialization intent instead of falsely emitting a core deployment")


func _test_post_landing_location(workspace: Control, intents: Array[Dictionary]) -> void:
	var fixture := _location_fixture(false)
	fixture["tasks"] = [
		{"id":"survey-earth", "name":"Survey sweep", "kind":"SURVEY", "item_id":"sensor_array", "status":"RUNNING", "progress":0.4, "remaining_ms":3000.0, "action":{"kind":"OPEN_SURVEY", "location_id":"earth"}},
		{"id":"iron-haul", "name":"Iron delivery", "kind":"TRANSPORT", "item_id":"iron_ore", "status":"RUNNING", "progress":0.2, "remaining_ms":4000.0, "action":{"kind":"OPEN_FACTORY", "world_id":"earth-grid", "section":"CANVAS"}}
	]
	workspace.configure(fixture)
	await _settle()
	var industry_empty := workspace.find_child("LocationFacilityEmptyAction", true, false) as Button
	var task_heading := workspace.find_child("LocationTasksOpen", true, false) as Button
	var survey_row := workspace.find_child("TaskRow_" + "survey-earth".validate_node_name(), true, false) as Panel
	var haul_row := workspace.find_child("TaskRow_" + "iron-haul".validate_node_name(), true, false) as Panel
	var survey_art := survey_row.find_child("TaskArt", true, false) as TextureRect if survey_row != null else null
	var haul_art := haul_row.find_child("TaskArt", true, false) as TextureRect if haul_row != null else null
	_check(industry_empty != null and industry_empty.text.contains("Manufacture / deploy"), "post-landing industry empty state directs the player to manufacture or deploy finished buildings")
	_check(task_heading != null and task_heading.text.contains("Open Factory"), "local task board no longer routes an empty/local workflow to global engineering")
	_check(survey_art != null and survey_art.texture == ItemIcon.texture_for_item("sensor_array") and haul_art != null and haul_art.texture == ItemIcon.texture_for_item("iron_ore"), "survey and transport tasks use their authoritative sensor/cargo material icons instead of research or depot substitutions")
	var before := intents.size()
	if industry_empty != null:
		industry_empty.pressed.emit()
	var action: Dictionary = intents.back() if intents.size() > before else {}
	_check(str(action.get("kind", "")) == "OPEN_FACTORY" and str(action.get("section", "")) == "CONSTRUCTION", "post-landing industry CTA consumes the snapshot's manufacturing/deployment route")
	before = intents.size()
	if task_heading != null:
		task_heading.pressed.emit()
	var task_action: Dictionary = intents.back() if intents.size() > before else {}
	_check(str(task_action.get("kind", "")) == "OPEN_FACTORY" and str(task_action.get("section", "")) == "CANVAS", "local task heading follows the snapshot Factory route instead of emitting OPEN_ENGINEERING")


func _test_location_deployment_ghost(workspace: Control) -> void:
	var fixture := _location_fixture(false)
	fixture["tasks"] = [{
		"id":"ghost-delivery",
		"name":"Bulk Depot",
		"kind":"DEPLOYMENT",
		"definition_id":"grid_bulk_depot",
		"item_id":"building_grid_bulk_depot",
		"status":"WAITING_BUILDING",
		"action":{"kind":"OPEN_FACTORY", "world_id":"earth-grid", "section":"CONSTRUCTION"}
	}]
	workspace.configure(fixture)
	await _settle()
	var row := workspace.find_child("TaskRow_" + "ghost-delivery".validate_node_name(), true, false) as Panel
	var art := row.find_child("TaskArt", true, false) as TextureRect if row != null else null
	var status := row.get_meta("status") as Label if row != null else null
	var progress := row.get_meta("progress") as ProgressBar if row != null else null
	var percent := row.get_meta("percent") as Label if row != null else null
	var remaining := row.get_meta("remaining") as Label if row != null else null
	var action := row.get_meta("action") as Button if row != null else null
	var expected_art := BuildingArt.icon_texture(BuildingArt.atlas_texture(), "grid_bulk_depot", "CONSTRUCTION")
	_check(row != null and status != null and status.text.contains("Awaiting finished building"), "a deployment ghost states that it is waiting for its finished building")
	_check(progress != null and not progress.visible and percent != null and not percent.visible and remaining != null and not remaining.visible, "a deployment ghost shows no construction progress, percentage, or ETA")
	_check(art != null and _same_atlas_region(art.texture, expected_art), "a deployment ghost uses the real building illustration rather than a generic finished-item material icon")
	_check(action != null and not action.tooltip_text.contains("—"), "a deployment ghost tooltip does not invent an ETA")


func _test_deployment_ghost_board(workspace: Control) -> void:
	workspace.call("_set_active_subworkspace", "CONSTRUCTION")
	await _settle()
	var ghost := workspace.find_child("ConstructionOrderghost_waiting", true, false)
	var legacy := workspace.find_child("ConstructionOrderlegacy_progress", true, false)
	var summary := workspace.find_child("ConstructionStatusSummary", true, false)
	var bom := workspace.find_child("ConstructionBom", true, false)
	var progress := workspace.find_child("ConstructionProgress", true, false)
	var waiting := workspace.find_child("ConstructionWaitingBuildingghost_waiting", true, false) as Label
	_check(ghost != null and waiting != null and legacy == null, "deployment board renders only WAITING_BUILDING ghosts and excludes retired onsite construction records")
	_check(summary == null and bom == null and progress == null, "deployment board contains no status summary, BOM, or construction progress UI")


func _test_planetary_inventory_art(workspace: Control) -> void:
	var thumbnail := workspace.find_child("FactoryOperationsWarehouseThumbnail", true, false) as TextureRect
	_check(_is_core_art(thumbnail.texture if thumbnail != null else null), "Factory overview labels shared stock with the real planetary-core inventory art, not a bulk-depot icon")


func _location_fixture(landing_required: bool) -> Dictionary:
	var industry_section := "CANVAS" if landing_required else "CONSTRUCTION"
	return {
		"valid":true,
		"location_id":"earth",
		"name":"Earth",
		"system_name":"Sol",
		"survey_state":"SURVEYED",
		"world_id":"earth-grid",
		"can_initialize_factory":true,
		"landing_required":landing_required,
		"hero_definition_id":"grid_planetary_core",
		"power":{"generation_kw":400.0, "demand_kw":120.0},
		"industry":{"running":0, "blocked":0},
		"storage":{"storage_mode":"PER_ITEM", "item_count":1, "stocked_item_count":1, "full_item_count":0, "max_utilization":0.48},
		"inventory":[{"id":"iron_ingot", "item_id":"iron_ingot", "name":"Iron Ingot", "category":"COMPONENT", "quantity":2400, "capacity":5000, "fill_ratio":0.48, "incoming":8, "location_quantity":2400, "warehouse_quantity":999, "trend_known":true, "net_rate_per_minute":2.0}],
		"resources":[],
		"facilities":[],
		"tasks":[],
		"alerts":[],
		"fleet_count":0,
		"survey":{"ships":[], "can_start":false, "next_state":""},
		"environment":{"construction_difficulty":"HIGH"},
		"environment_effects":{"solar_generation_multiplier":0.7, "construction_work_multiplier":1.6, "construction_speed_multiplier":0.6, "thermal_power_multiplier":1.2},
		"industry_empty_action":{"kind":"OPEN_FACTORY", "world_id":"earth-grid", "section":industry_section},
		"task_empty_action":{"kind":"OPEN_FACTORY", "world_id":"earth-grid", "section":"CANVAS"}
	}


func _surface_preparation_fixture() -> Dictionary:
	var fixture := _location_fixture(false)
	fixture["world_id"] = ""
	fixture["hero_definition_id"] = ""
	fixture["industry_empty_action"] = {"kind":"INITIALIZE_FACTORY"}
	fixture["task_empty_action"] = {"kind":"INITIALIZE_FACTORY"}
	return fixture


func _factory_fixture() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_id":"earth-grid",
		"location_name":"Earth",
		"topology_revision":1,
		"runtime_revision":1,
		"landing_required":false,
		"logistics_mode":"PLANET_SHARED_ROADS",
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":128, "y":96}},
		"canvas_limits":{"max_world_size_tiles":{"x":128, "y":96}},
		"chunk_size_tiles":64,
		"roads":[],
		"road_logistics":{"capacity":0, "required":0, "utilization":0.0, "active_shipments":0},
		"shared_inventory":{"iron_ingot":2400},
		"location_inventory":{"iron_ingot":2400},
		"location_available_inventory":{"iron_ingot":2400},
		"item_names":{"iron_ingot":"Iron Ingot", "building_grid_bulk_depot":"Bulk Depot"},
		"entities":[],
		"links":[],
		"resource_fields":[],
		"construction_orders":[
			{"id":"ghost_waiting", "definition_id":"grid_bulk_depot", "building_name":"Bulk Depot", "deployment_item_id":"building_grid_bulk_depot", "status":"WAITING_BUILDING", "required_items":{"building_grid_bulk_depot":1}, "delivered_items":{}, "progress":0.0, "remaining_ms":-1.0, "footprint":{"origin":{"x":12, "y":12}, "size":{"x":4, "y":4}}},
			{"id":"legacy_progress", "definition_id":"grid_bulk_depot", "building_name":"Legacy depot record", "status":"IN_PROGRESS", "required_items":{"iron_ingot":8}, "delivered_items":{"iron_ingot":3}, "progress":0.4, "remaining_ms":2000.0, "footprint":{"origin":{"x":20, "y":12}, "size":{"x":4, "y":4}}}
		],
		"palette":{"buildings":[], "recipes":[]}
	}


func _factory_canvas_action(action: Dictionary) -> bool:
	return str(action.get("kind", "")) == "OPEN_FACTORY" and str(action.get("world_id", "")) == "earth-grid" and str(action.get("section", "")) == "CANVAS"


func _is_core_art(texture: Variant) -> bool:
	var expected := BuildingArt.icon_texture(BuildingArt.atlas_texture(), "grid_planetary_core", "STORAGE")
	return _same_atlas_region(texture, expected)


func _same_atlas_region(actual_value: Variant, expected_value: Variant) -> bool:
	var actual := actual_value as AtlasTexture
	var expected := expected_value as AtlasTexture
	return actual != null and expected != null and actual.atlas == expected.atlas and actual.region == expected.region


func _settle() -> void:
	await process_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("CONTENT_SYNC_UI_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
