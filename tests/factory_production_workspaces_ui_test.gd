extends SceneTree

## Focused Factory control-room presentation test.  It exercises the v1
## snapshot only; no Game singleton or simulation mutator is reachable here.

const WorkspaceScript = preload("res://src/ui/workspaces/factory/factory_workspace.gd")
const ChunkIndexScript = preload("res://src/ui/workspaces/factory/factory_canvas_chunk_index.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node.new()
	get_root().add_child(host)
	var workspace = WorkspaceScript.new()
	workspace.size = Vector2(1280, 720)
	host.add_child(workspace)
	var intents: Array = []
	workspace.command_requested.connect(func(intent: Dictionary) -> void: intents.append(intent.duplicate(true)))
	workspace.apply_snapshot(_fixture())
	await process_frame
	await process_frame

	_test_authored_route_chunk_index()
	_test_authored_route_geometry(workspace)
	_test_same_frame_port_hit_rebuild(workspace)
	_test_small_router_overlapping_port_hits(workspace)
	_test_workspace_tabs(workspace)
	_test_hidden_canvas_defers_snapshot_rebuild(workspace)
	_test_production_and_recipe_views(workspace)
	_test_construction_intents(workspace, intents)
	_test_structured_port_drag_intent(workspace, intents)
	_test_router_accepts_multiple_inputs(workspace, intents)
	_test_router_mode_connection_validation(workspace)
	_test_empty_wildcard_ports_use_catalog(workspace, intents)
	_test_inspector_intents(workspace, intents)

	host.free()
	await process_frame
	if failures.is_empty():
		print("FACTORY_PRODUCTION_WORKSPACES_UI_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)


func _test_authored_route_chunk_index() -> void:
	var index = ChunkIndexScript.new()
	index.rebuild({
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":256, "y":160}},
		"chunk_size_tiles":64,
		"resource_fields":[],
		"construction_orders":[],
		"entities":[
			{"id":"source", "footprint":{"origin":{"x":8, "y":8}, "size":{"x":4, "y":4}}},
			{"id":"target", "footprint":{"origin":{"x":24, "y":8}, "size":{"x":4, "y":4}}}
		],
		"links":[{"id":"detour", "source_id":"source", "target_id":"target", "path_tiles":[{"x":11, "y":10}, {"x":11, "y":130}, {"x":24, "y":130}, {"x":24, "y":10}]}]
	})
	_check(index.query(Rect2(0, 128, 64, 32)).get("link_ids", []).has("detour"), "Viewport chunk index retains authored route detours outside the endpoint rectangle")
	index.rebuild({
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":768, "y":480}},
		"chunk_size_tiles":64,
		"resource_fields":[],
		"construction_orders":[],
		"entities":[
			{"id":"far-source", "footprint":{"origin":{"x":8, "y":8}, "size":{"x":4, "y":4}}},
			{"id":"far-target", "footprint":{"origin":{"x":700, "y":400}, "size":{"x":4, "y":4}}}
		],
		"links":[{"id":"large-l", "source_id":"far-source", "target_id":"far-target", "path_tiles":[{"x":11, "y":10}, {"x":700, "y":10}, {"x":700, "y":402}]}]
	})
	_check(index.query(Rect2(320, 240, 64, 64)).get("link_ids", []).is_empty(), "Large-planet route indexing excludes chunks outside the actual L-shaped segments")


func _test_authored_route_geometry(workspace) -> void:
	var canvas = workspace.canvas()
	var source := _entity("route-source", "ROUTER", "Route source", Vector2i(20, 20), {"outputs":["iron_ore", "iron_ingot"], "output_ports":[{"id":"route-out-ore", "direction":"OUTPUT", "channel":"ITEM", "item_id":"iron_ore"}, {"id":"route-out-ingot", "direction":"OUTPUT", "channel":"ITEM", "item_id":"iron_ingot"}]})
	var target := _entity("route-target", "ROUTER", "Route target", Vector2i(60, 20), {"inputs":["iron_ore", "iron_ingot"], "input_ports":[{"id":"route-in-ore", "direction":"INPUT", "channel":"ITEM", "item_id":"iron_ore"}, {"id":"route-in-ingot", "direction":"INPUT", "channel":"ITEM", "item_id":"iron_ingot"}]})
	var endpoints: Array = canvas._connection_endpoints(source, target, "CARGO", "route-out-ingot", "route-in-ore")
	var route: PackedVector2Array = canvas._link_route({"path_tiles":[{"x":27, "y":24}, {"x":60, "y":24}]}, endpoints[0], endpoints[1])
	var orthogonal := route.size() <= 4
	for index in range(1, route.size()):
		orthogonal = orthogonal and (is_equal_approx(route[index - 1].x, route[index].x) or is_equal_approx(route[index - 1].y, route[index].y))
	_check(orthogonal, "Authored route vertices stay compact and connect to visible structured ports without diagonal endpoint segments")


func _test_same_frame_port_hit_rebuild(workspace) -> void:
	var canvas = workspace.canvas()
	var source: Dictionary = workspace._entity_by_id("mine-a")
	var view_model = canvas.get("_view_model")
	var port: Dictionary = view_model.connection_port_by_id(source, "mine-out-iron", "OUTPUT")
	var rect: Rect2 = canvas._footprint_rect(source.get("footprint", {}), 4.0)
	var center: Vector2 = canvas._port_center(source, port, rect, "OUTPUT", "CARGO")
	canvas._invalidate_hit_geometry()
	_check(canvas._begin_port_drag(center), "Port hit geometry rebuilds synchronously after camera or snapshot invalidation")
	canvas.cancel_port_drag()


func _test_small_router_overlapping_port_hits(workspace) -> void:
	var canvas = workspace.canvas()
	var router := _entity(
		"small-router",
		"ROUTER",
		"Small router",
		Vector2i.ZERO,
		{"inputs":["*"], "outputs":["*"], "input_ports":[{"id":"small-in", "direction":"INPUT", "channel":"ITEM", "item_id":"*"}], "output_ports":[{"id":"small-out", "direction":"OUTPUT", "channel":"ITEM", "item_id":"*"}]},
		"SPLIT",
		Vector2i(4, 4)
	)
	var tiny_rect := Rect2(Vector2(100, 100), Vector2(4, 4))
	canvas.get("_port_hit_rects").clear()
	canvas.set("_hit_geometry_dirty", false)
	canvas._register_entity_port_hits(router, tiny_rect, 3.0)
	var output_port: Dictionary = (router.get("ports", {}).get("output_ports", []) as Array)[0]
	var output_center: Vector2 = canvas._port_center(router, output_port, tiny_rect, "OUTPUT", "CARGO")
	var began: bool = bool(canvas._begin_port_drag(output_center))
	var drag: Dictionary = canvas.get("_port_drag")
	_check(began and str(drag.get("source_port", {}).get("id", "")) == "small-out", "A 4x4 router at low detail selects the nearest OUTPUT hit even when input/output hit boxes overlap")
	canvas.cancel_port_drag()
	canvas._invalidate_hit_geometry()


func _test_workspace_tabs(workspace) -> void:
	for workspace_id in ["CANVAS", "PRODUCTION", "RECIPES", "CONSTRUCTION"]:
		workspace._set_active_subworkspace(workspace_id)
		_check(str(workspace.get("_active_subworkspace")) == workspace_id, "Factory tab %s is stable" % workspace_id)
	_check(workspace.find_child("FactoryTabCanvas", true, false) != null and workspace.find_child("FactoryTabProduction", true, false) != null and workspace.find_child("FactoryTabRecipes", true, false) != null and workspace.find_child("FactoryTabConstruction", true, false) != null, "Factory exposes four persistent workspaces")


func _test_hidden_canvas_defers_snapshot_rebuild(workspace) -> void:
	workspace._set_active_subworkspace("PRODUCTION")
	var canvas = workspace.canvas()
	var before_revision := int((canvas.get("_snapshot") as Dictionary).get("runtime_revision", -1))
	var updated := _fixture()
	updated["runtime_revision"] = before_revision + 10
	workspace.apply_snapshot(updated)
	_check(int((canvas.get("_snapshot") as Dictionary).get("runtime_revision", -1)) == before_revision, "Hidden Canvas defers its full-world spatial-index rebuild during Production refreshes")
	workspace._set_active_subworkspace("CANVAS")
	_check(int((canvas.get("_snapshot") as Dictionary).get("runtime_revision", -1)) == before_revision + 10, "Canvas applies the newest deferred snapshot when the player returns")


func _test_production_and_recipe_views(workspace) -> void:
	workspace._set_active_subworkspace("PRODUCTION")
	_check(workspace.find_child("ProductionStatusSummary", true, false) != null and workspace.find_child("ProductionRows", true, false) != null, "Production workspace shows operating summary and rows")
	var filter := workspace.find_child("ProductionStatusFilter", true, false) as OptionButton
	_check(filter != null and filter.item_count >= 6, "Production workspace exposes state filters")
	workspace._set_active_subworkspace("RECIPES")
	var search := workspace.find_child("RecipeSearch", true, false) as LineEdit
	_check(search != null and workspace.find_child("RecipeRows", true, false) != null, "Recipe workspace exposes searchable recipe catalog")
	if search != null:
		search.text = "iron"
		search.text_changed.emit(search.text)
	_check(workspace.find_child("SelectRecipegrid_refine_iron", true, false) != null, "Recipe workspace shows cycle, IO, machines, and selectable recipe")


func _test_construction_intents(workspace, intents: Array) -> void:
	workspace._set_active_subworkspace("CONSTRUCTION")
	_check(workspace.find_child("ConstructionStatusSummary", true, false) != null and workspace.find_child("ConstructionProgress", true, false) != null, "Construction workspace shows queue state and material progress")
	var before := intents.size()
	workspace._request_cancel_construction("order-a")
	_check(intents.size() == before + 1 and str((intents.back() as Dictionary).get("kind", "")) == "CANCEL_CONSTRUCTION", "Construction cancellation emits only the required versioned intent")


func _test_structured_port_drag_intent(workspace, intents: Array) -> void:
	var before := intents.size()
	workspace.canvas().port_connection_requested.emit("smelter-a", {"id":"smelter-out-ingot", "direction":"OUTPUT", "kind":"CARGO", "item_id":"iron_ingot"}, "depot-a", {"id":"depot-in-any", "direction":"INPUT", "kind":"CARGO", "item_id":"*"})
	var intent: Dictionary = intents.back() as Dictionary if intents.size() > before else {}
	var payload: Dictionary = intent.get("payload", {}) as Dictionary
	_check(str(intent.get("kind", "")) == "CONNECT_ENTITIES" and str(payload.get("source_port_id", "")) == "smelter-out-ingot" and str(payload.get("target_port_id", "")) == "depot-in-any", "Dragging compatible structured ports emits CONNECT_ENTITIES with concrete port ids")


func _test_router_accepts_multiple_inputs(workspace, intents: Array) -> void:
	var before := intents.size()
	workspace.canvas().port_connection_requested.emit("mine-c", {"id":"mine-c-out-iron", "direction":"OUTPUT", "kind":"CARGO", "item_id":"iron_ore"}, "router-a", {"id":"router-in-any", "direction":"INPUT", "kind":"CARGO", "item_id":"*"})
	var intent: Dictionary = intents.back() as Dictionary if intents.size() > before else {}
	var payload: Dictionary = intent.get("payload", {}) as Dictionary
	_check(str(intent.get("kind", "")) == "CONNECT_ENTITIES" and str(payload.get("source_id", "")) == "mine-c" and str(payload.get("target_id", "")) == "router-a", "Cargo Merger inputs accept a second same-item cargo route like the Factory domain")


func _test_router_mode_connection_validation(workspace) -> void:
	_check(_probe_cargo_connection(workspace, "mine-a", "mine-out-iron", "depot-b", "depot-b-in-any", "iron_ore") == "CARGO_OUTPUT_OCCUPIED", "UI preflight blocks ordinary producer fan-out without a Cargo Splitter")
	_check(_probe_cargo_connection(workspace, "mine-c", "mine-c-out-iron", "router-a", "router-in-any", "iron_ore").is_empty(), "UI preflight allows Cargo Merger fan-in")
	_check(_probe_cargo_connection(workspace, "mine-c", "mine-c-out-iron", "splitter-a", "splitter-in-any", "iron_ore") == "CARGO_INPUT_OCCUPIED", "UI preflight blocks a second input into a Cargo Splitter")
	_check(_probe_cargo_connection(workspace, "splitter-a", "splitter-out-any", "depot-b", "depot-b-in-any", "iron_ore").is_empty(), "UI preflight allows Cargo Splitter fan-out")


func _probe_cargo_connection(workspace, source_id: String, source_port_id: String, target_id: String, target_port_id: String, item_id: String) -> String:
	workspace.set("_connection_kind", "CARGO")
	workspace.set("_connection_source_id", source_id)
	workspace.set("_connection_target_id", target_id)
	workspace.set("_connection_source_port_id", source_port_id)
	workspace.set("_connection_target_port_id", target_port_id)
	workspace.set("_selected_cargo_item_id", item_id)
	return workspace._connection_validation_reason(workspace._entity_by_id(source_id), workspace._entity_by_id(target_id))


func _test_empty_wildcard_ports_use_catalog(workspace, intents: Array) -> void:
	var before := intents.size()
	workspace.canvas().port_connection_requested.emit("router-a", {"id":"router-out-any", "direction":"OUTPUT", "kind":"CARGO", "item_id":"*"}, "depot-a", {"id":"depot-in-any", "direction":"INPUT", "kind":"CARGO", "item_id":"*"})
	var selector := workspace.find_child("CargoItem", true, false) as OptionButton
	_check(intents.size() == before and selector != null and selector.item_count > 2, "Ambiguous wildcard routes wait for an explicit cargo choice")
	if selector != null and selector.item_count > 1:
		selector.select(1)
		selector.item_selected.emit(1)
		workspace._request_connection()
	var intent: Dictionary = intents.back() as Dictionary if intents.size() > before else {}
	var payload: Dictionary = intent.get("payload", {}) as Dictionary
	_check(str(intent.get("kind", "")) == "CONNECT_ENTITIES" and not str(payload.get("item_id", "")).is_empty(), "Empty wildcard router/storage ports use the player's catalog selection instead of silently choosing an arbitrary item")


func _test_inspector_intents(workspace, intents: Array) -> void:
	var before := intents.size()
	workspace._request_remove_entity("smelter-a")
	workspace._request_configure_link("belt-a", 2)
	var configuration: Dictionary = (intents[before + 1] as Dictionary).get("payload", {}) if intents.size() > before + 1 else {}
	var control_count: int = int(workspace.get("_inspector_body").get_child_count())
	workspace._add_link_configuration_controls({"id":"power-link", "kind":"POWER"})
	_check(intents.size() == before + 2 and str((intents[before] as Dictionary).get("kind", "")) == "REMOVE_ENTITY" and str((intents[before + 1] as Dictionary).get("kind", "")) == "CONFIGURE_LINK" and int(configuration.get("priority", -1)) == 2 and not configuration.has("capacity_per_second") and not configuration.has("lane_count") and not configuration.has("tier"), "Inspector changes Cargo priority without granting free physical route upgrades")
	_check(workspace.get("_inspector_body").get_child_count() == control_count, "Power-link inspector does not expose a Cargo-only priority control that the domain would reject")


func _fixture() -> Dictionary:
	return {
		"valid":true,
		"protocol_version":1,
		"world_id":"production-ui",
		"topology_revision":4,
		"runtime_revision":7,
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":256, "y":160}},
		"chunk_size_tiles":64,
		"entities":[
			_entity("mine-a", "EXTRACTOR", "Surface mine", Vector2i(20, 20), {"outputs":["iron_ore"], "output_ports":[{"id":"mine-out-iron", "direction":"OUTPUT", "channel":"ITEM", "item_id":"iron_ore"}], "accepts_power":true}),
			_entity("mine-b", "EXTRACTOR", "Surface mine B", Vector2i(20, 50), {"outputs":["iron_ore"], "output_ports":[{"id":"mine-b-out-iron", "direction":"OUTPUT", "channel":"ITEM", "item_id":"iron_ore"}], "accepts_power":true}),
			_entity("mine-c", "EXTRACTOR", "Surface mine C", Vector2i(20, 80), {"outputs":["iron_ore"], "output_ports":[{"id":"mine-c-out-iron", "direction":"OUTPUT", "channel":"ITEM", "item_id":"iron_ore"}], "accepts_power":true}),
			_entity("mine-d", "EXTRACTOR", "Surface mine D", Vector2i(55, 80), {"outputs":["iron_ore"], "output_ports":[{"id":"mine-d-out-iron", "direction":"OUTPUT", "channel":"ITEM", "item_id":"iron_ore"}], "accepts_power":true}),
			_entity("smelter-a", "MACHINE", "Arc smelter", Vector2i(60, 20), {"inputs":["iron_ore"], "outputs":["iron_ingot"], "input_ports":[{"id":"smelter-in-iron", "direction":"INPUT", "channel":"ITEM", "item_id":"iron_ore"}], "output_ports":[{"id":"smelter-out-ingot", "direction":"OUTPUT", "channel":"ITEM", "item_id":"iron_ingot"}], "accepts_power":true}),
			_entity("depot-a", "STORAGE", "Bulk depot", Vector2i(100, 20), {"inputs":["*"], "outputs":["*"], "input_ports":[{"id":"depot-in-any", "direction":"INPUT", "channel":"ITEM", "item_id":"*"}], "output_ports":[{"id":"depot-out-any", "direction":"OUTPUT", "channel":"ITEM", "item_id":"*"}]}),
			_entity("depot-b", "STORAGE", "Bulk depot B", Vector2i(135, 20), {"inputs":["*"], "outputs":["*"], "input_ports":[{"id":"depot-b-in-any", "direction":"INPUT", "channel":"ITEM", "item_id":"*"}], "output_ports":[{"id":"depot-b-out-any", "direction":"OUTPUT", "channel":"ITEM", "item_id":"*"}]}),
			_entity("router-a", "ROUTER", "Cargo merger", Vector2i(100, 50), {"inputs":["*"], "outputs":["*"], "input_ports":[{"id":"router-in-any", "direction":"INPUT", "channel":"ITEM", "item_id":"*"}], "output_ports":[{"id":"router-out-any", "direction":"OUTPUT", "channel":"ITEM", "item_id":"*"}]}, "MERGE", Vector2i(4, 4)),
			_entity("splitter-a", "ROUTER", "Cargo splitter", Vector2i(100, 80), {"inputs":["*"], "outputs":["*"], "input_ports":[{"id":"splitter-in-any", "direction":"INPUT", "channel":"ITEM", "item_id":"*"}], "output_ports":[{"id":"splitter-out-any", "direction":"OUTPUT", "channel":"ITEM", "item_id":"*"}]}, "SPLIT", Vector2i(4, 4))
		],
		"links":[
			{"id":"belt-a", "kind":"CARGO", "source_id":"mine-a", "target_id":"smelter-a", "source_port_id":"mine-out-iron", "target_port_id":"smelter-in-iron", "item_id":"iron_ore", "status":"FLOWING", "last_flow":1.0, "capacity_per_second":2.0, "utilization":0.5, "congestion":0.25, "lane_count":2, "tier":"MK2", "priority":1},
			{"id":"router-input-a", "kind":"CARGO", "source_id":"mine-b", "target_id":"router-a", "source_port_id":"mine-b-out-iron", "target_port_id":"router-in-any", "item_id":"iron_ore", "status":"FLOWING", "last_flow":0.5, "capacity_per_second":2.0, "utilization":0.25, "congestion":0.0, "lane_count":1, "tier":"MK1", "priority":1},
			{"id":"splitter-input-a", "kind":"CARGO", "source_id":"mine-d", "target_id":"splitter-a", "source_port_id":"mine-d-out-iron", "target_port_id":"splitter-in-any", "item_id":"iron_ore", "status":"FLOWING", "last_flow":0.5, "capacity_per_second":1.0, "utilization":0.5, "congestion":0.0, "lane_count":1, "tier":"MK1", "priority":1},
			{"id":"splitter-output-a", "kind":"CARGO", "source_id":"splitter-a", "target_id":"depot-a", "source_port_id":"splitter-out-any", "target_port_id":"depot-in-any", "item_id":"iron_ore", "status":"FLOWING", "last_flow":0.5, "capacity_per_second":1.0, "utilization":0.5, "congestion":0.0, "lane_count":1, "tier":"MK1", "priority":1}
		],
		"resource_fields":[],
		"construction_orders":[{"id":"order-a", "definition_id":"grid_arc_smelter", "building_name":"Arc smelter", "status":"WAITING_MATERIALS", "progress":0.4, "required_items":{"iron_ingot":4}, "delivered_items":{"iron_ingot":1}, "footprint":{"origin":{"x":100, "y":20}, "size":{"x":8, "y":8}}}],
		"production":{"summary":{"running":1, "input_shortage":0, "output_full":0, "blocked":0, "idle":1}, "rows":[{"entity_id":"smelter-a", "status":"RUNNING", "rate_per_second":0.5, "utilization":0.75}]},
		"palette":{"buildings":[{"id":"grid_arc_smelter", "name":"Arc Smelter", "kind":"MACHINE", "footprint":{"width":8, "height":8}, "recipe_ids":["grid_refine_iron"]}], "recipes":[{"id":"grid_refine_iron", "name":"Grid iron refining", "duration_seconds":2.0, "inputs":[{"item":"iron_ore", "quantity":1}], "outputs":[{"item":"iron_ingot", "quantity":1}]}]},
		"item_names":{"iron_ore":"Iron ore", "iron_ingot":"Iron ingot"}
	}


func _entity(entity_id: String, node_kind: String, title: String, origin: Vector2i, ports: Dictionary, router_mode: String = "BIDIRECTIONAL", footprint_size: Vector2i = Vector2i(8, 8)) -> Dictionary:
	return {"id":entity_id, "node_kind":node_kind, "router_mode":router_mode if node_kind == "ROUTER" else "", "name":title, "definition_id":"grid_arc_smelter", "recipe_id":"grid_refine_iron" if node_kind == "MACHINE" else "", "footprint":{"origin":{"x":origin.x, "y":origin.y}, "size":{"x":footprint_size.x, "y":footprint_size.y}}, "ports":ports, "status":"READY", "inputs":{}, "outputs":{}, "inventory":{}, "actual_rate":0.0, "power_factor":1.0}


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
