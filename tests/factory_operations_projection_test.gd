extends SceneTree

const Operations = preload("res://src/core/factory_operations_projection.gd")

var failures: Array[String] = []


func _initialize() -> void:
	_test_empty_fixture()
	_test_live_chain_rates_deficits_and_buffers()
	_test_build_dependencies_are_cycle_safe_deterministic_and_detached()
	_test_producer_candidates_are_bootstrap_aware_and_self_safe()
	_test_extraction_dependencies_require_mapped_compatible_fields()
	_test_inactive_storage_is_buffered_not_spendable()
	_finish()


func _test_empty_fixture() -> void:
	var fixture_value = JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/factory_operations_v1.json"))
	var fixture: Dictionary = fixture_value as Dictionary
	var actual: Dictionary = Operations.build(fixture)
	# JSON numbers are floats on read; roundtrip both sides into the same wire
	# representation before comparing the complete contract, including all keys.
	_check(JSON.parse_string(JSON.stringify(actual)) == fixture.get("operations", {}), "empty workspace matches the JSON v1 operations fixture exactly")


func _test_live_chain_rates_deficits_and_buffers() -> void:
	var snapshot := _live_snapshot()
	var source_before := JSON.stringify(snapshot)
	var operations: Dictionary = Operations.build(snapshot)
	_check(JSON.stringify(snapshot) == source_before, "projection does not mutate the authoritative snapshot")
	var metrics: Dictionary = operations.get("metrics", {})
	_check(
		int(metrics.get("extractors", 0)) == 1
		and int(metrics.get("running_machines", 0)) == 1
		and int(metrics.get("blocked_entities", 0)) == 1
		and int(metrics.get("stored_items", 0)) == 4
		and int(metrics.get("active_orders", 0)) == 0
		and int(metrics.get("waiting_orders", 0)) == 2,
		"metrics count physical extractors, running/blocked machines, factory storage only, and construction states"
	)
	var ore := _material(operations, "iron_ore")
	var ingot := _material(operations, "iron_ingot")
	var frame := _material(operations, "structural_frame")
	_check(
		is_equal_approx(float(ore.get("production_per_second", 0.0)), 3.0)
		and is_equal_approx(float(ore.get("consumption_per_second", 0.0)), 2.0)
		and is_equal_approx(float(ingot.get("production_per_second", 0.0)), 4.0)
		and is_equal_approx(float(ingot.get("consumption_per_second", 0.0)), 0.0),
		"rates use authoritative actual cycle rates times recipe quantities and ignore routers"
	)
	_check(
		int(ingot.get("stored", 0)) == 3
		and int(ingot.get("location_available", 0)) == 2
		and int(ingot.get("buffered", 0)) == 9
		and int(ingot.get("available", 0)) == 5
		and int(ingot.get("required", 0)) == 8
		and int(ingot.get("missing", 0)) == 3,
		"storage and unreserved location inventory are spendable once while machine/router buffers stay diagnostic only"
	)
	_check(int(frame.get("required", 0)) == 4 and int(frame.get("available", 0)) == 1 and int(frame.get("missing", 0)) == 3, "construction deficits aggregate all outstanding orders before stock is subtracted")
	var stages: Array = operations.get("stages", [])
	_check(
		str((stages[0] as Dictionary).get("state", "")) == "ACTIVE"
		and str((stages[1] as Dictionary).get("state", "")) == "ACTIVE"
		and str((stages[2] as Dictionary).get("state", "")) == "BLOCKED"
		and str((stages[3] as Dictionary).get("state", "")) == "BLOCKED",
		"the four-stage chain reports collection, production, construction, and physical expansion state"
	)
	var alert_codes := {}
	for alert_value in operations.get("alerts", []):
		alert_codes[str((alert_value as Dictionary).get("code", ""))] = true
	_check(alert_codes.has("INPUT_SHORTAGE") and alert_codes.has("WAITING_MATERIALS") and alert_codes.has("MATERIAL_SHORTAGE"), "blockers, waiting orders, and material deficits produce actionable alerts")
	var target_plan := _plan(operations, "upgrade-kit")
	var target_iron := _plan_material(target_plan, "iron_ingot")
	_check(
		str(target_iron.get("producer_building_id", "")) == "smelter-a"
		and str(target_iron.get("recipe_id", "")) == "smelt_iron"
		and int(target_iron.get("missing", 0)) == 5,
		"unlocked building plans expose their BOM affordability and deterministic direct producer"
	)
	var material_rows: Array = operations.get("materials", [])
	var detached_material := material_rows[0] as Dictionary
	detached_material["stored"] = -999
	_check(int((_entity(snapshot, "storage-a").get("inventory", {}) as Dictionary).get("iron_ingot", 0)) == 3, "projection output is detached from source storage inventory")


func _test_build_dependencies_are_cycle_safe_deterministic_and_detached() -> void:
	var snapshot := {
		"entities":[],
		"construction_orders":[],
		"location_available_inventory":{},
		"palette":{
			"buildings":[
				{"id":"target", "kind":"CONSTRUCTION", "construction_cost":[{"item":"cycle_a", "quantity":1}], "construction_work":9, "power_demand_kw":3},
				{"id":"b-machine", "kind":"MACHINE", "recipe_ids":["make_b"], "construction_cost":[]},
				{"id":"a-machine", "kind":"MACHINE", "recipe_ids":["make_a"], "construction_cost":[]}
			],
			"recipes":[
				{"id":"make_b", "inputs":[{"item":"cycle_a", "quantity":1}], "outputs":[{"item":"cycle_b", "quantity":1}]},
				{"id":"make_a", "inputs":[{"item":"cycle_b", "quantity":1}], "outputs":[{"item":"cycle_a", "quantity":1}]}
			]
		}
	}
	var source_before := JSON.stringify(snapshot)
	var first: Dictionary = Operations.build(snapshot)
	var reordered := snapshot.duplicate(true)
	var reordered_palette := reordered.get("palette", {}) as Dictionary
	var original_palette := snapshot.get("palette", {}) as Dictionary
	var original_buildings := original_palette.get("buildings", []) as Array
	var original_recipes := original_palette.get("recipes", []) as Array
	reordered_palette["buildings"] = [
		original_buildings[2],
		original_buildings[1],
		original_buildings[0]
	]
	reordered_palette["recipes"] = [
		original_recipes[1],
		original_recipes[0]
	]
	var second: Dictionary = Operations.build(reordered)
	_check(JSON.stringify(snapshot) == source_before, "dependency planning also leaves its source snapshot immutable")
	_check(JSON.stringify(first) == JSON.stringify(second), "projection ordering is deterministic across equivalent palette ordering")
	var plan := _plan(first, "target")
	var dependencies: Array = plan.get("dependencies", [])
	_check(
		dependencies.size() == 2
		and str((dependencies[0] as Dictionary).get("item_id", "")) == "cycle_a"
		and int((dependencies[0] as Dictionary).get("depth", -1)) == 0
		and str((dependencies[1] as Dictionary).get("item_id", "")) == "cycle_b"
		and int((dependencies[1] as Dictionary).get("depth", -1)) == 1,
		"bounded dependency traversal stops a recipe cycle while preserving direct dependency order"
	)
	var plan_ids: Array[String] = []
	for plan_value in first.get("build_plans", []):
		plan_ids.append(str((plan_value as Dictionary).get("definition_id", "")))
	_check(plan_ids == ["a-machine", "b-machine", "target"], "every unlocked building receives an identifier-sorted BOM plan")


func _test_producer_candidates_are_bootstrap_aware_and_self_safe() -> void:
	var snapshot := {
		"entities":[],
		"construction_orders":[],
		"resource_fields":[{"id":"iron-field", "resource_id":"iron_ore"}],
		"location_available_inventory":{"scrap":4, "electronics":2},
		"palette":{
			"buildings":[
				{"id":"arc-refiner", "kind":"MACHINE", "recipe_ids":["refine_iron"], "construction_cost":[{"item":"structural_frame", "quantity":1}, {"item":"iron_ingot", "quantity":4}, {"item":"electronics", "quantity":2}], "construction_work":45},
				{"id":"works-refiner", "kind":"MACHINE", "recipe_ids":["assemble_frame", "recycle_scrap", "refine_iron"], "construction_cost":[{"item":"scrap", "quantity":4}, {"item":"electronics", "quantity":2}], "construction_work":20},
				{"id":"iron-depot", "kind":"STORAGE", "construction_cost":[{"item":"iron_ingot", "quantity":10}], "construction_work":30}
			],
			"recipes":[
				{"id":"refine_iron", "inputs":[{"item":"iron_ore", "quantity":2}], "outputs":[{"item":"iron_ingot", "quantity":1}]},
				{"id":"recycle_scrap", "inputs":[{"item":"scrap", "quantity":2}], "outputs":[{"item":"iron_ingot", "quantity":1}]},
				{"id":"assemble_frame", "inputs":[{"item":"iron_ingot", "quantity":2}], "outputs":[{"item":"structural_frame", "quantity":1}]}
			]
		}
	}
	var first: Dictionary = Operations.build(snapshot)
	var reversed := snapshot.duplicate(true)
	var reversed_palette := reversed.get("palette", {}) as Dictionary
	var source_palette := snapshot.get("palette", {}) as Dictionary
	var source_buildings := source_palette.get("buildings", []) as Array
	var source_recipes := source_palette.get("recipes", []) as Array
	reversed_palette["buildings"] = [source_buildings[2], source_buildings[1], source_buildings[0]]
	reversed_palette["recipes"] = [source_recipes[2], source_recipes[1], source_recipes[0]]
	var reordered: Dictionary = Operations.build(reversed)
	_check(JSON.stringify(first) == JSON.stringify(reordered), "same-output producer candidates are deterministic across palette ordering")
	var depot_iron := _plan_material(_plan(first, "iron-depot"), "iron_ingot")
	var arc_plan := _plan(first, "arc-refiner")
	var arc_iron := _plan_material(arc_plan, "iron_ingot")
	_check(
		str(depot_iron.get("producer_building_id", "")) == "works-refiner"
		and str(depot_iron.get("recipe_id", "")) == "refine_iron",
		"an affordable resource-backed refinery wins over a finite-stock recycler and an alphabetically earlier unfinished producer"
	)
	var production_stage := (first.get("stages", [])[1] as Dictionary)
	_check(
		str(production_stage.get("state", "")) == "MISSING"
		and str((production_stage.get("action", {}) as Dictionary).get("kind", "")) == "SELECT_BUILDING"
		and str((production_stage.get("action", {}) as Dictionary).get("target_id", "")) == "works-refiner",
		"a missing production stage opens the affordable starter machine instead of an alphabetically earlier blocked machine"
	)
	_check(
		str(arc_iron.get("producer_building_id", "")) == "works-refiner"
		and not (arc_plan.get("dependencies", []) as Array).any(func(value): return str((value as Dictionary).get("building_id", "")) == "arc-refiner"),
		"a first construction plan does not prescribe itself as its own material producer"
	)
	var configured := snapshot.duplicate(true)
	var configured_entities := configured.get("entities", []) as Array
	configured_entities.append({"id":"arc-live", "node_kind":"MACHINE", "definition_id":"arc-refiner", "recipe_id":"refine_iron", "status":"NO_POWER"})
	var configured_iron := _plan_material(_plan(Operations.build(configured), "iron-depot"), "iron_ingot")
	_check(str(configured_iron.get("producer_building_id", "")) == "arc-refiner", "an existing configured producer is preferred over a merely affordable construction candidate")
	var self_only := {
		"entities":[],
		"construction_orders":[],
		"palette":{
			"buildings":[{"id":"self-refiner", "kind":"MACHINE", "recipe_ids":["refine_iron"], "construction_cost":[{"item":"iron_ingot", "quantity":1}]}],
			"recipes":[{"id":"refine_iron", "inputs":[{"item":"iron_ore", "quantity":1}], "outputs":[{"item":"iron_ingot", "quantity":1}]}]
		}
	}
	var self_plan := _plan(Operations.build(self_only), "self-refiner")
	var self_iron := _plan_material(self_plan, "iron_ingot")
	_check(
		str(self_iron.get("producer_building_id", "")) == "" and (self_plan.get("dependencies", []) as Array).is_empty(),
		"a first building with no alternate producer reports no fictional self dependency"
	)


func _test_extraction_dependencies_require_mapped_compatible_fields() -> void:
	var snapshot := {
		"entities":[],
		"construction_orders":[],
		"resource_fields":[
			{"id":"z-iron-field", "resource_id":"iron_ore", "resource_category":"solid"},
			{"id":"a-iron-field", "resource_id":"iron_ore", "resource_category":"solid"}
		],
		"palette":{
			"buildings":[
				{"id":"grid_bulk_depot", "kind":"STORAGE", "construction_cost":[{"item":"iron_ingot", "quantity":1}]},
				{"id":"grid_engineering_works", "kind":"MACHINE", "recipe_ids":["grid_refine_iron"], "construction_cost":[]},
				{"id":"grid_surface_mine", "kind":"EXTRACTOR", "resource_categories":["solid"], "construction_cost":[]}
			],
			"recipes":[
				{"id":"grid_refine_iron", "inputs":[{"item":"iron_ore", "quantity":2}], "outputs":[{"item":"iron_ingot", "quantity":1}]}
			]
		}
	}
	var source_before := JSON.stringify(snapshot)
	var first: Dictionary = Operations.build(snapshot)
	var extraction := _dependency(_plan(first, "grid_bulk_depot"), "iron_ore")
	_check(
		str(extraction.get("kind", "")) == "EXTRACTION"
		and int(extraction.get("depth", -1)) == 1
		and str(extraction.get("recipe_id", "not-empty")) == ""
		and str(extraction.get("building_id", "")) == "grid_surface_mine"
		and str(extraction.get("resource_field_id", "")) == "a-iron-field"
		and (extraction.get("inputs", []) as Array).is_empty()
		and (extraction.get("outputs", []) as Array).is_empty()
		and str((extraction.get("action", {}) as Dictionary).get("kind", "")) == "SELECT_BUILDING"
		and str((extraction.get("action", {}) as Dictionary).get("target_id", "")) == "grid_surface_mine",
		"a raw recipe input receives a terminal, mapped, compatible extraction dependency with a physical build action"
	)
	var reordered := snapshot.duplicate(true)
	var reordered_palette := reordered.get("palette", {}) as Dictionary
	var source_palette := snapshot.get("palette", {}) as Dictionary
	var source_buildings := source_palette.get("buildings", []) as Array
	var source_recipes := source_palette.get("recipes", []) as Array
	reordered["resource_fields"] = [
		(snapshot.get("resource_fields", []) as Array)[1],
		(snapshot.get("resource_fields", []) as Array)[0]
	]
	reordered_palette["buildings"] = [source_buildings[2], source_buildings[1], source_buildings[0]]
	reordered_palette["recipes"] = [source_recipes[0]]
	_check(JSON.stringify(snapshot) == source_before and JSON.stringify(first) == JSON.stringify(Operations.build(reordered)), "extraction dependency selection is deterministic and leaves source fields untouched")
	var no_field := snapshot.duplicate(true)
	no_field["resource_fields"] = []
	_check(_dependency(_plan(Operations.build(no_field), "grid_bulk_depot"), "iron_ore").is_empty(), "an unmapped raw input does not invent an extraction dependency")
	var incompatible_field := snapshot.duplicate(true)
	incompatible_field["resource_fields"] = [{"id":"iron-gas-field", "resource_id":"iron_ore", "resource_category":"gas"}]
	_check(_dependency(_plan(Operations.build(incompatible_field), "grid_bulk_depot"), "iron_ore").is_empty(), "a mapped field without a compatible unlocked extractor does not invent an extraction dependency")


func _test_inactive_storage_is_buffered_not_spendable() -> void:
	var snapshot := {
		"entities":[
			{"id":"active-store", "node_kind":"STORAGE", "status":"READY", "inventory":{"iron_ingot":3}},
			{"id":"inactive-store", "node_kind":"STORAGE", "status":"UNDER_CONSTRUCTION", "inventory":{"iron_ingot":7}},
			{"id":"machine-buffer", "node_kind":"MACHINE", "status":"IDLE", "outputs":{"iron_ingot":9}}
		],
		"construction_orders":[{"id":"waiting", "required_items":{"iron_ingot":5}, "delivered_items":{}}],
		"location_available_inventory":{"iron_ingot":2},
		"palette":{"buildings":[{"id":"iron-builder", "kind":"CONSTRUCTION", "construction_cost":[{"item":"iron_ingot", "quantity":5}]}], "recipes":[]}
	}
	var operations: Dictionary = Operations.build(snapshot)
	var iron := _material(operations, "iron_ingot")
	var metrics: Dictionary = operations.get("metrics", {})
	_check(
		int(iron.get("stored", 0)) == 3
		and int(iron.get("buffered", 0)) == 16
		and int(iron.get("location_available", 0)) == 2
		and int(iron.get("available", 0)) == 5
		and int(iron.get("missing", 0)) == 0
		and int(metrics.get("stored_items", 0)) == 3
		and bool(_plan(operations, "iron-builder").get("affordable", false)),
		"only operational storage counts as stored; inactive storage remains buffered while location stock remains build-ready"
	)
	var no_spendable_stock := snapshot.duplicate(true)
	var location_inventory := no_spendable_stock.get("location_available_inventory", {}) as Dictionary
	location_inventory.clear()
	var active_storage := _entity(no_spendable_stock, "active-store")
	active_storage["inventory"] = {}
	var unavailable: Dictionary = Operations.build(no_spendable_stock)
	var unavailable_iron := _material(unavailable, "iron_ingot")
	var unavailable_metrics: Dictionary = unavailable.get("metrics", {})
	_check(
		int(unavailable_iron.get("stored", 0)) == 0
		and int(unavailable_iron.get("buffered", 0)) == 16
		and int(unavailable_iron.get("available", 0)) == 0
		and int(unavailable_metrics.get("stored_items", 0)) == 0
		and not bool(_plan(unavailable, "iron-builder").get("affordable", true)),
		"an inactive storage inventory alone cannot make a construction plan affordable"
	)


func _live_snapshot() -> Dictionary:
	return {
		"power":{"generation_kw":120.0, "demand_kw":75.0},
		"location_available_inventory":{"iron_ingot":2},
		"entities":[
			{"id":"router-z", "node_kind":"ROUTER", "status":"FLOWING", "actual_rate":99.0, "inventory":{"iron_ingot":4}},
			{"id":"machine-b", "node_kind":"MACHINE", "recipe_id":"smelt_iron", "status":"INPUT_SHORTAGE", "actual_rate":0.0, "inputs":{}, "outputs":{}},
			{"id":"storage-a", "node_kind":"STORAGE", "status":"READY", "inventory":{"iron_ingot":3, "structural_frame":1}},
			{"id":"machine-a", "node_kind":"MACHINE", "recipe_id":"smelt_iron", "status":"RUNNING", "actual_rate":2.0, "inputs":{"iron_ore":7}, "outputs":{"iron_ingot":5}},
			{"id":"mine-a", "node_kind":"EXTRACTOR", "resource_id":"iron_ore", "status":"RUNNING", "actual_rate":3.0, "outputs":{"iron_ore":1}}
		],
		"construction_orders":[
			{"id":"order-z", "status":"WAITING_MATERIALS", "required_items":{"iron_ingot":4}, "delivered_items":{}},
			{"id":"order-a", "status":"WAITING_MATERIALS", "required_items":{"iron_ingot":5, "structural_frame":4}, "delivered_items":{"iron_ingot":1}}
		],
		"palette":{
			"buildings":[
				{"id":"upgrade-kit", "kind":"CONSTRUCTION", "construction_cost":[{"item":"iron_ingot", "quantity":10}, {"item":"structural_frame", "quantity":4}], "construction_work":12, "power_demand_kw":5},
				{"id":"struct-works", "kind":"MACHINE", "recipe_ids":["make_frame"], "construction_cost":[{"item":"scrap_metal", "quantity":1}]},
				{"id":"smelter-a", "kind":"MACHINE", "recipe_ids":["smelt_iron"], "construction_cost":[{"item":"scrap_metal", "quantity":1}]}
			],
			"recipes":[
				{"id":"make_frame", "inputs":[{"item":"iron_ingot", "quantity":3}], "outputs":[{"item":"structural_frame", "quantity":1}]},
				{"id":"smelt_iron", "inputs":[{"item":"iron_ore", "quantity":1}], "outputs":[{"item":"iron_ingot", "quantity":2}]}
			]
		}
	}


func _material(operations: Dictionary, item_id: String) -> Dictionary:
	for material_value in operations.get("materials", []):
		var material := material_value as Dictionary
		if str(material.get("item_id", "")) == item_id:
			return material
	return {}


func _plan(operations: Dictionary, definition_id: String) -> Dictionary:
	for plan_value in operations.get("build_plans", []):
		var plan := plan_value as Dictionary
		if str(plan.get("definition_id", "")) == definition_id:
			return plan
	return {}


func _plan_material(plan: Dictionary, item_id: String) -> Dictionary:
	for material_value in plan.get("materials", []):
		var material := material_value as Dictionary
		if str(material.get("item_id", "")) == item_id:
			return material
	return {}


func _dependency(plan: Dictionary, item_id: String) -> Dictionary:
	for dependency_value in plan.get("dependencies", []):
		var dependency := dependency_value as Dictionary
		if str(dependency.get("item_id", "")) == item_id:
			return dependency
	return {}


func _entity(snapshot: Dictionary, entity_id: String) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity
	return {}


func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("FACTORY_OPERATIONS_PROJECTION_PASS")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
