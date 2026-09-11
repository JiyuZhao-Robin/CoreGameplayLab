extends SceneTree

## Focused Factory v1 presentation contract for finished-building deployment.
## It uses only an immutable synthetic workspace snapshot and observes emitted
## intents; production authority remains outside the UI.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Control.new()
	host.name = "FactoryBuildingDeploymentUiHost"
	host.size = Vector2(1920, 1080)
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.add_child(workspace)
	workspace.apply_snapshot(_fixture())
	await _settle()
	var intents: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: intents.append(intent.duplicate(true)))
	await _test_deployment_palette_and_intent(workspace, intents)
	await _test_waiting_building_ghost_inspector(workspace, intents)
	await _test_building_manufacture_recipe_selector(workspace, intents)
	workspace.queue_free()
	await process_frame
	host.queue_free()
	await process_frame
	_finish()


func _test_deployment_palette_and_intent(workspace, intents: Array) -> void:
	var card := workspace.find_child("FactoryBuildCardGridBulkDepot", true, false) as Button
	var count_label := card.find_child("FactoryBuildCardDetail", true, false) as Label if card != null else null
	_check(card != null and int(card.get_meta("available_count", -1)) == 2 and count_label != null and count_label.text.ends_with(" 2") and card.accessibility_name.contains("Bulk Depot"), "the build palette exposes the unreserved finished-building count and an accessible building name")
	workspace.call("_select_building_id", "grid_bulk_depot")
	workspace.call("_request_construction", Vector2i(4, 4))
	_check(intents.size() == 1, "placing a selected building emits one versioned deployment intent")
	if not intents.is_empty():
		var intent: Dictionary = intents.back() as Dictionary
		var payload: Dictionary = intent.get("payload", {}) as Dictionary
		_check(
			str(intent.get("kind", "")) == "DEPLOY_BUILDING"
			and str(payload.get("definition_id", "")) == "grid_bulk_depot"
			and payload.get("origin", {}) == {"x":4, "y":4}
			and str(payload.get("recipe_id", "")) == ""
			and int(payload.get("priority", -1)) == 50
			and not payload.has("funding_policy"),
			"deployment sends only the frozen definition/origin/recipe/priority payload and never a raw-material funding policy"
		)
	var updated := _fixture()
	var palette: Dictionary = updated.get("palette", {}) as Dictionary
	var buildings: Array = palette.get("buildings", []) as Array
	for building_value in buildings:
		if not building_value is Dictionary:
			continue
		var building := building_value as Dictionary
		if str(building.get("id", "")) == "grid_bulk_depot":
			building["available_count"] = 0
	updated["runtime_revision"] = 2
	workspace.apply_snapshot(updated)
	await _settle()
	card = workspace.find_child("FactoryBuildCardGridBulkDepot", true, false) as Button
	count_label = card.find_child("FactoryBuildCardDetail", true, false) as Label if card != null else null
	_check(card != null and int(card.get_meta("available_count", -1)) == 0 and count_label != null and count_label.text.ends_with(" 0") and card.accessibility_name.ends_with(" 0") and not card.disabled, "a fresh snapshot updates both visual and accessible counts while zero stock remains placeable as an automatic-deployment ghost")


func _test_waiting_building_ghost_inspector(workspace, intents: Array) -> void:
	var ghost := _ghost_order(_fixture())
	workspace.call("_on_construction_order_selected", ghost)
	await _settle()
	var waiting := workspace.find_child("ConstructionWaitingBuilding", true, false) as Label
	var item := workspace.find_child("ConstructionDeploymentItem", true, false) as Label
	var cancel := workspace.find_child("CancelConstructionOrder", true, false) as Button
	var bom: Node = workspace.find_child("ConstructionBom", true, false)
	var progress: Node = workspace.find_child("ConstructionProgress", true, false)
	var funding_storage: Node = workspace.find_child("FundingStorage", true, false)
	var location_fund: Node = workspace.find_child("FundConstructionFromSharedInventory", true, false)
	_check(waiting != null and item != null and item.text.contains("Bulk Depot") and cancel != null, "a WAITING_BUILDING ghost inspector names the missing finished building and retains cancellation")
	_check(bom == null and progress == null and funding_storage == null and location_fund == null, "a deployment ghost never renders construction BOM, progress, or any funding controls")
	if cancel != null:
		var before := intents.size()
		cancel.pressed.emit()
		var cancel_intent: Dictionary = intents.back() as Dictionary if intents.size() > before else {}
		_check(intents.size() == before + 1 and str(cancel_intent.get("kind", "")) == "CANCEL_CONSTRUCTION", "the ghost cancellation button preserves the stable cancel-construction intent")


func _test_building_manufacture_recipe_selector(workspace, intents: Array) -> void:
	workspace.call("_on_entity_selected", _machine_entity(_fixture()))
	await _settle()
	var selector := workspace.find_child("EntityRecipeSelector", true, false) as OptionButton
	var building_recipe_index := _option_index(selector, "manufacture_grid_bulk_depot")
	var selector_text := selector.get_item_text(building_recipe_index) if selector != null and building_recipe_index > 0 else ""
	_check(selector != null and building_recipe_index > 0 and not selector_text.is_empty() and selector_text != "Build Bulk Depot", "machine configuration exposes finished-building manufacture recipes with a building-specific label")
	if selector != null and building_recipe_index > 0:
		var before := intents.size()
		selector.select(building_recipe_index)
		selector.item_selected.emit(building_recipe_index)
		_check(intents.size() == before + 1, "selecting a building manufacture recipe continues through the existing machine configuration command boundary")
		if intents.size() > before:
			var intent: Dictionary = intents.back() as Dictionary
			_check(str(intent.get("kind", "")) == "SET_RECIPE" and str((intent.get("payload", {}) as Dictionary).get("recipe_id", "")) == "manufacture_grid_bulk_depot", "building manufacture selection emits SET_RECIPE rather than a separate recipe-page action")


func _option_index(selector: OptionButton, recipe_id: String) -> int:
	if selector == null:
		return -1
	for index in selector.item_count:
		if str(selector.get_item_metadata(index)) == recipe_id:
			return index
	return -1


func _fixture() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_id":"deployment-ui-grid",
		"location_name":"Earth",
		"topology_revision":1,
		"runtime_revision":1,
		"logistics_mode":"PLANET_SHARED_ROADS",
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":128, "y":96}},
		"canvas_limits":{"max_world_size_tiles":{"x":128, "y":96}},
		"chunk_size_tiles":64,
		"roads":[],
		"road_logistics":{"capacity":0, "required":0, "utilization":0.0, "active_shipments":0},
		"shared_inventory":{"building_grid_bulk_depot":2},
		"location_inventory":{"building_grid_bulk_depot":2},
		"location_available_inventory":{"building_grid_bulk_depot":2},
		"item_names":{"building_grid_bulk_depot":"Bulk Depot"},
		"entities":[_machine_entity({})],
		"links":[],
		"resource_fields":[],
		"construction_orders":[
			{
				"id":"ghost-depot", "definition_id":"grid_bulk_depot", "building_name":"Bulk Depot",
				"deployment_item_id":"building_grid_bulk_depot", "status":"WAITING_BUILDING", "progress":0.0,
				"required_items":{"building_grid_bulk_depot":1}, "staged_items":{}, "delivered_items":{},
				"remaining_ms":-1.0, "footprint":{"origin":{"x":30, "y":30}, "size":{"x":4, "y":4}}
			}
		],
		"palette":{
			"buildings":[
				{"id":"grid_bulk_depot", "name":"Bulk Depot", "kind":"STORAGE", "footprint":{"width":4, "height":4}, "recipe_ids":[], "deployment_item_id":"building_grid_bulk_depot", "available_count":2},
				{"id":"grid_engineering_works", "name":"Engineering Works", "kind":"MACHINE", "footprint":{"width":12, "height":10}, "recipe_ids":["manufacture_grid_bulk_depot"], "deployment_item_id":"building_grid_engineering_works", "available_count":1}
			],
			"recipes":[
				{"id":"manufacture_grid_bulk_depot", "name":"Build Bulk Depot", "building_definition_id":"grid_bulk_depot", "inputs":[{"item":"iron_ingot", "quantity":2}], "outputs":[{"item":"building_grid_bulk_depot", "quantity":1}]}
			]
		}
	}


func _ghost_order(snapshot: Dictionary) -> Dictionary:
	return ((snapshot.get("construction_orders", []) as Array)[0] as Dictionary).duplicate(true)


func _machine_entity(_snapshot: Dictionary) -> Dictionary:
	return {
		"id":"engineering-a", "node_kind":"MACHINE", "definition_id":"grid_engineering_works", "name":"Engineering Works",
		"footprint":{"origin":{"x":70, "y":20}, "size":{"x":12, "y":10}}, "status":"READY", "power_factor":1.0,
		"actual_rate":0.0, "road_connected":true, "road_component_id":"road-main", "recipe_id":"",
		"ports":{"inputs":[], "outputs":[], "accepts_power":false, "provides_power":false},
		"inputs":{}, "outputs":{}, "inventory":{}, "input_capacity":64, "output_capacity":64
	}


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
		print("FACTORY_BUILDING_DEPLOYMENT_UI_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
