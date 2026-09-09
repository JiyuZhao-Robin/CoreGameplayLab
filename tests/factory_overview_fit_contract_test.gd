extends SceneTree

## Fixed-board layout contract for Industrial Operations. The target is the
## 1880 x 800 logical work surface used by the 4K review at the player's 125%
## text scale. This fixture contains no Game or simulation authority.

const OverviewScript = preload("res://src/ui/workspaces/factory/factory_operations_overview.gd")
const UiTokens = preload("res://src/ui/ui_theme_tokens.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	UiTokens.set_ui_scale(1.25)
	var host := Control.new()
	host.name = "FactoryOverviewFitHost"
	host.size = Vector2(1880, 800)
	get_root().add_child(host)
	var overview = OverviewScript.new()
	overview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overview.size_flags_vertical = Control.SIZE_EXPAND_FILL
	host.add_child(overview)
	overview.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	await process_frame
	overview.configure(_fixture())
	await process_frame
	await process_frame

	_test_primary_board_fit(overview)
	_test_bounded_list_regions(overview)
	_test_stage_and_art_geometry(overview)

	host.queue_free()
	await process_frame
	_finish()


func _test_primary_board_fit(overview: Control) -> void:
	var content := overview.find_child("FactoryOperationsContent", true, false) as Control
	var hero := overview.find_child("FactoryOperationsHero", true, false) as Control
	var kpis := overview.find_child("FactoryOperationsKpis", true, false) as Control
	var chain := overview.find_child("FactoryOperationsChain", true, false) as Control
	var boards := overview.find_child("FactoryOperationsBoards", true, false) as Control
	var page_scroll := overview.find_child("FactoryOperationsScroll", true, false)
	_check(
		overview.size.is_equal_approx(Vector2(1880, 800))
		and page_scroll == null
		and content != null and hero != null and kpis != null and chain != null and boards != null
		and _inside(content, overview)
		and _inside(hero, overview) and _inside(kpis, overview) and _inside(chain, overview) and _inside(boards, overview)
		and hero.get_global_rect().end.y <= kpis.get_global_rect().position.y + 0.5
		and kpis.get_global_rect().end.y <= chain.get_global_rect().position.y + 0.5
		and chain.get_global_rect().end.y <= boards.get_global_rect().position.y + 0.5,
		"industrial overview keeps hero, KPI rail, stage chain, and lower decision boards inside one 1880 x 800 operations surface without a page scroll container"
	)


func _test_bounded_list_regions(overview: Control) -> void:
	var alerts := overview.find_child("FactoryOperationsAlerts", true, false) as Control
	var planner := overview.find_child("FactoryOperationsPlanner", true, false) as Control
	var alert_region := overview.find_child("FactoryOperationsAlertListRegion", true, false) as Control
	var planner_region := overview.find_child("FactoryOperationsPlannerDetailsRegion", true, false) as Control
	var alert_scroll := overview.find_child("FactoryOperationsAlertListScroll", true, false) as ScrollContainer
	var planner_scroll := overview.find_child("FactoryOperationsPlannerDetailsScroll", true, false) as ScrollContainer
	var selector := overview.find_child("FactoryOperationsBuildTarget", true, false) as OptionButton
	var material_row := overview.find_child("FactoryOperationsPlanMaterialElectronics", true, false) as Control
	_check(
		alerts != null and planner != null and alert_region != null and planner_region != null
		and alert_scroll != null and planner_scroll != null and selector != null and material_row != null
		and _inside(alert_region, alerts) and _inside(planner_region, planner)
		and _inside(alert_scroll, alert_region) and _inside(planner_scroll, planner_region)
		and selector.get_global_rect().end.y <= planner_region.get_global_rect().position.y + 0.5,
		"only alert and planner detail lists use bounded internal scrolling; the target selector remains pinned above its plan ledger"
	)


func _test_stage_and_art_geometry(overview: Control) -> void:
	var stages: Array[Control] = []
	for stage_id in ["Collection", "Production", "Construction", "Expansion"]:
		var stage := overview.find_child("FactoryOperationsStage%s" % stage_id, true, false) as Control
		if stage != null:
			stages.append(stage)
	var panorama := overview.find_child("FactoryOperationsPanorama", true, false) as TextureRect
	var artwork := overview.find_child("FactoryOperationsPlanArtworkTexture", true, false) as TextureRect
	var stages_do_not_overlap := stages.size() == 4
	for index in range(stages.size() - 1):
		stages_do_not_overlap = stages_do_not_overlap and stages[index].get_global_rect().end.x <= stages[index + 1].get_global_rect().position.x + 0.5
	_check(
		stages_do_not_overlap
		and panorama != null and panorama.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_COVERED
		and artwork != null and artwork.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		and _inside(panorama, overview) and _inside(artwork, overview),
		"stage controls preserve separate click targets and hero/building art keeps its intended aspect treatment inside the operations board"
	)


func _inside(child: Control, ancestor: Control) -> bool:
	var child_rect := child.get_global_rect()
	var ancestor_rect := ancestor.get_global_rect()
	return child_rect.position.x + 0.5 >= ancestor_rect.position.x \
		and child_rect.position.y + 0.5 >= ancestor_rect.position.y \
		and child_rect.end.x <= ancestor_rect.end.x + 0.5 \
		and child_rect.end.y <= ancestor_rect.end.y + 0.5


func _fixture() -> Dictionary:
	return {
		"valid":true,
		"world_id":"earth_orbit",
		"location_name":"Earth Orbit",
		"item_names":{"iron_ingot":"Iron ingot", "electronics":"Electronics", "frame":"Structural frame", "copper_ingot":"Copper ingot"},
		"palette":{"buildings":[{"id":"grid_arc_smelter", "name":"Arc smelter", "kind":"MACHINE"}]},
		"entities":[{"id":"smelter-a", "name":"Arc smelter"}],
		"operations":{
			"schema_version":1,
			"metrics":{"extractors":8, "running_machines":24, "power_supply_kw":120.0, "power_demand_kw":160.0, "active_orders":3, "waiting_orders":1},
			"stages":[
				{"id":"COLLECTION", "state":"ACTIVE", "count":8, "action":{"kind":"OPEN_TAB", "tab":"CANVAS"}},
				{"id":"PRODUCTION", "state":"ACTIVE", "count":24, "action":{"kind":"OPEN_TAB", "tab":"PRODUCTION"}},
				{"id":"CONSTRUCTION", "state":"ACTIVE", "count":3, "action":{"kind":"OPEN_TAB", "tab":"CONSTRUCTION"}},
				{"id":"EXPANSION", "state":"READY", "count":12, "action":{"kind":"OPEN_TAB", "tab":"CANVAS"}}
			],
			"alerts":[
				{"id":"entity_smelter", "code":"INPUT_SHORTAGE", "entity_id":"smelter-a", "action":{"kind":"FOCUS_ENTITY", "target_id":"smelter-a"}},
				{"id":"material_electronics", "code":"MATERIAL_SHORTAGE", "item_id":"electronics", "amount":4, "action":{"kind":"OPEN_TAB", "tab":"PRODUCTION"}},
				{"id":"material_frames", "code":"MATERIAL_SHORTAGE", "item_id":"frame", "amount":2, "action":{"kind":"OPEN_TAB", "tab":"PRODUCTION"}}
			],
			"materials":[
				{"item_id":"iron_ingot", "available":12, "stored":12, "missing":0, "production_per_second":1.5, "consumption_per_second":0.8},
				{"item_id":"electronics", "available":2, "stored":2, "missing":4, "production_per_second":0.2, "consumption_per_second":0.8},
				{"item_id":"frame", "available":0, "stored":0, "missing":2, "production_per_second":0.0, "consumption_per_second":0.3}
			],
			"build_plans":[{
				"definition_id":"grid_arc_smelter", "affordable":false,
				"materials":[
					{"item_id":"iron_ingot", "available":12, "required":4, "missing":0},
					{"item_id":"electronics", "available":2, "required":6, "missing":4},
					{"item_id":"frame", "available":0, "required":2, "missing":2},
					{"item_id":"copper_ingot", "available":4, "required":4, "missing":0}
				],
				"dependencies":[
					{"item_id":"electronics", "building_id":"grid_arc_smelter", "action":{"kind":"SELECT_BUILDING", "target_id":"grid_arc_smelter"}},
					{"item_id":"frame", "building_id":"grid_arc_smelter", "action":{"kind":"SELECT_BUILDING", "target_id":"grid_arc_smelter"}}
				]
			}]
		}
	}


func _check(condition: bool, message: String) -> void:
	if condition:
		print("PASS: %s" % message)
	else:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_OVERVIEW_FIT_CONTRACT_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
