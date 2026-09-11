class_name FactoryOperationsProjection
extends RefCounted

## A pure, presentation-safe read model for the Factory operations workspace.
## It intentionally consumes only the public Factory workspace snapshot: no
## Game singleton, Simulation calls, mutations, or authoritative calculations.

const SCHEMA_VERSION := 1
const MAX_DEPENDENCY_DEPTH := 4

const BLOCKING_ENTITY_STATUSES := [
	"NO_RESOURCE", "NO_POWER", "INPUT_SHORTAGE", "OUTPUT_FULL", "NO_RECIPE",
	"SOURCE_EMPTY", "TARGET_FULL", "BLOCKED", "FAILED", "INCOMPATIBLE_ENDPOINT", "NO_CAPACITY"
]
const WARNING_ENTITY_STATUSES := ["POWER_LIMITED", "PARTIAL_COVERAGE"]


static func build(snapshot: Dictionary) -> Dictionary:
	var entities := _sorted_rows(snapshot.get("entities", []), "id")
	var orders := _sorted_rows(snapshot.get("construction_orders", []), "id")
	var palette: Dictionary = snapshot.get("palette", {}) if snapshot.get("palette", {}) is Dictionary else {}
	var buildings := _sorted_rows(palette.get("buildings", []), "id")
	var recipes := _sorted_rows(palette.get("recipes", []), "id")
	var resource_fields := _sorted_rows(snapshot.get("resource_fields", []), "id")
	var recipes_by_id := _indexed_rows(recipes, "id")
	var material_result := _materials(snapshot, entities, orders, buildings, recipes_by_id)
	var materials: Array = material_result.get("rows", [])
	var materials_by_item: Dictionary = material_result.get("by_item", {})
	var resource_item_ids := _resource_item_ids(snapshot.get("resource_fields", []))
	var producer_candidates_by_item := _producer_candidates(buildings, recipes_by_id, entities, materials_by_item, resource_item_ids)
	var extraction_candidates_by_item := _extraction_candidates(buildings, resource_fields)
	var build_plans := _build_plans(buildings, materials_by_item, producer_candidates_by_item, extraction_candidates_by_item, recipes_by_id)
	var metrics := _metrics(snapshot, entities, orders, material_result)
	var stages := _stages(entities, orders, buildings, build_plans)
	var alerts := _alerts(entities, orders, materials)
	return {
		"schema_version":SCHEMA_VERSION,
		"metrics":metrics,
		"stages":stages,
		"alerts":alerts,
		"materials":materials,
		"build_plans":build_plans
	}


static func _metrics(snapshot: Dictionary, entities: Array, orders: Array, material_result: Dictionary) -> Dictionary:
	var extractors := 0
	var running_machines := 0
	var blocked_entities := 0
	var power_supply_kw := 0.0
	var power_demand_kw := 0.0
	for entity_value in entities:
		var entity := entity_value as Dictionary
		var kind := _kind(entity)
		var status := str(entity.get("status", "")).to_upper()
		if kind == "EXTRACTOR":
			extractors += 1
		if kind == "MACHINE" and maxf(0.0, float(entity.get("actual_rate", 0.0))) > 0.0:
			running_machines += 1
		if _is_blocking_status(status):
			blocked_entities += 1
		power_supply_kw += maxf(0.0, float(entity.get("power_generation_kw", 0.0)))
		power_demand_kw += maxf(0.0, float(entity.get("power_demand_kw", 0.0)))
	var power: Dictionary = snapshot.get("power", {}) if snapshot.get("power", {}) is Dictionary else {}
	if power.has("generation_kw"):
		power_supply_kw = maxf(0.0, float(power.get("generation_kw", 0.0)))
	if power.has("demand_kw"):
		power_demand_kw = maxf(0.0, float(power.get("demand_kw", 0.0)))
	var active_orders := 0
	var waiting_orders := 0
	for order_value in orders:
		var order := order_value as Dictionary
		if _order_remaining_total(order) > 0:
			waiting_orders += 1
		else:
			active_orders += 1
	return {
		"extractors":extractors,
		"running_machines":running_machines,
		"blocked_entities":blocked_entities,
		"stored_items":int(material_result.get("stored_items", 0)),
		"power_supply_kw":power_supply_kw,
		"power_demand_kw":power_demand_kw,
		"active_orders":active_orders,
		"waiting_orders":waiting_orders
	}


static func _materials(snapshot: Dictionary, entities: Array, orders: Array, buildings: Array, recipes_by_id: Dictionary) -> Dictionary:
	var totals := {}
	var road_mode := str(snapshot.get("logistics_mode", "")) == "PLANET_SHARED_DRONES"
	if road_mode:
		_add_manifest(totals, snapshot.get("shared_inventory", {}), "stored")
	for entity_value in entities:
		var entity := entity_value as Dictionary
		var kind := _kind(entity)
		if _is_operational_storage(entity):
			if not road_mode:
				_add_manifest(totals, entity.get("inventory", {}), "stored")
		else:
			# Machine/router buffers and inactive storage remain visible for
			# diagnostics, but never enter construction-spendable stock.
			for buffer_name in ["inputs", "outputs", "inventory"]:
				_add_manifest(totals, entity.get(buffer_name, {}), "buffered")
		if kind == "EXTRACTOR":
			var resource_id := str(entity.get("resource_id", ""))
			if not resource_id.is_empty():
				_add_rate(totals, resource_id, "production_per_second", maxf(0.0, float(entity.get("actual_rate", 0.0))))
		elif kind == "MACHINE":
			var recipe: Dictionary = recipes_by_id.get(str(entity.get("recipe_id", "")), {})
			var cycles_per_second := maxf(0.0, float(entity.get("actual_rate", 0.0)))
			if not recipe.is_empty() and cycles_per_second > 0.0:
				_add_recipe_rates(totals, recipe, cycles_per_second)
		# ROUTER records may carry material buffers, but are transport-only and
		# deliberately contribute no production or consumption rate.
	var location_available := _location_available_manifest(snapshot)
	_add_manifest(totals, location_available, "location_available")
	for order_value in orders:
		var order := order_value as Dictionary
		var required := _item_quantities(order.get("required_items", {}))
		var delivered := _item_quantities(order.get("delivered_items", {}))
		for item_id_value in required.keys():
			var item_id := str(item_id_value)
			_add_amount(totals, item_id, "required", maxi(0, int(required.get(item_id, 0)) - int(delivered.get(item_id, 0))))
	# Present all unlocked construction requirements, including future expansion
	# targets that have no stock or live order yet.
	for building_value in buildings:
		var building := building_value as Dictionary
		var deployment_item_id := str(building.get("deployment_item_id", ""))
		if not deployment_item_id.is_empty():
			_add_manifest(totals, {deployment_item_id:1}, "none")

	var rows: Array = []
	var by_item := {}
	var stored_items := 0
	var item_ids: Array = totals.keys()
	item_ids.sort_custom(func(left, right): return str(left) < str(right))
	for item_id_value in item_ids:
		var item_id := str(item_id_value)
		var total: Dictionary = totals.get(item_id, {})
		var stored := maxi(0, int(total.get("stored", 0)))
		var location_available_amount := maxi(0, int(total.get("location_available", 0)))
		# In road mode these are two views of ONE pool: on-hand versus
		# unreserved. Adding them would count each usable material twice.
		var available := location_available_amount if road_mode else stored + location_available_amount
		var required := maxi(0, int(total.get("required", 0)))
		var row := {
			"item_id":item_id,
			"stored":stored,
			"location_available":location_available_amount,
			"buffered":maxi(0, int(total.get("buffered", 0))),
			"available":available,
			"required":required,
			"missing":maxi(0, required - available),
			"production_per_second":maxf(0.0, float(total.get("production_per_second", 0.0))),
			"consumption_per_second":maxf(0.0, float(total.get("consumption_per_second", 0.0)))
		}
		# Road mode reports planetary on-hand stock; legacy mode retains the
		# original physical-storage metric. Availability excludes reservations.
		stored_items += stored
		rows.append(row)
		by_item[item_id] = row
	return {"rows":rows, "by_item":by_item, "stored_items":stored_items}


static func _add_recipe_rates(totals: Dictionary, recipe: Dictionary, cycles_per_second: float) -> void:
	for input_value in _item_rows(recipe.get("inputs", [])):
		var input := input_value as Dictionary
		_add_rate(totals, str(input.get("item_id", "")), "consumption_per_second", cycles_per_second * float(input.get("quantity", 0)))
	for output_value in _item_rows(recipe.get("outputs", [])):
		var output := output_value as Dictionary
		_add_rate(totals, str(output.get("item_id", "")), "production_per_second", cycles_per_second * float(output.get("quantity", 0)))


static func _build_plans(buildings: Array, materials_by_item: Dictionary, producer_candidates_by_item: Dictionary, extraction_candidates_by_item: Dictionary, recipes_by_id: Dictionary) -> Array:
	var plans: Array = []
	for building_value in buildings:
		var building := building_value as Dictionary
		var definition_id := str(building.get("id", ""))
		var materials: Array = []
		var dependencies: Array = []
		var seen_dependencies := {}
		var deployment_item_id := str(building.get("deployment_item_id", ""))
		var costs := {deployment_item_id:1} if not deployment_item_id.is_empty() else {}
		var item_ids: Array = costs.keys()
		item_ids.sort_custom(func(left, right): return str(left) < str(right))
		var affordable := not deployment_item_id.is_empty()
		for item_id_value in item_ids:
			var item_id := str(item_id_value)
			var required := maxi(0, int(costs.get(item_id, 0)))
			var material: Dictionary = materials_by_item.get(item_id, {})
			var available := maxi(0, int(material.get("available", 0)))
			var missing := maxi(0, required - available)
			if missing > 0:
				affordable = false
			var producer := _producer_for_item(item_id, producer_candidates_by_item, definition_id)
			materials.append({
				"item_id":item_id,
				"required":required,
				"available":available,
				"missing":missing,
				"producer_building_id":str(producer.get("building_id", "")),
				"recipe_id":str(producer.get("recipe_id", ""))
			})
			_append_dependencies(item_id, 0, producer_candidates_by_item, extraction_candidates_by_item, recipes_by_id, definition_id, seen_dependencies, dependencies)
		plans.append({
			"definition_id":definition_id,
			"affordable":affordable,
			"deployment_item_id":deployment_item_id,
			"work_required":0.0,
			"power_demand_kw":maxf(0.0, float(building.get("power_demand_kw", 0.0))),
			"materials":materials,
			"dependencies":dependencies
		})
	return plans


static func _append_dependencies(item_id: String, depth: int, producer_candidates_by_item: Dictionary, extraction_candidates_by_item: Dictionary, recipes_by_id: Dictionary, plan_definition_id: String, seen: Dictionary, target: Array) -> void:
	if item_id.is_empty() or depth > MAX_DEPENDENCY_DEPTH:
		return
	# One selected producer path per material keeps a construction dependency
	# graph concise and prevents a cyclic alternate recipe from re-entering an
	# item already explained higher in this plan.
	if seen.has(item_id):
		return
	var producer := _producer_for_item(item_id, producer_candidates_by_item, plan_definition_id)
	var recipe_id := str(producer.get("recipe_id", ""))
	var building_id := str(producer.get("building_id", ""))
	if recipe_id.is_empty() or building_id.is_empty():
		_append_extraction_dependency(item_id, depth, extraction_candidates_by_item, seen, target)
		return
	var recipe: Dictionary = recipes_by_id.get(recipe_id, {})
	if recipe.is_empty():
		return
	seen[item_id] = true
	var inputs := _item_rows(recipe.get("inputs", []))
	var outputs := _item_rows(recipe.get("outputs", []))
	target.append({
		"item_id":item_id,
		"depth":depth,
		"recipe_id":recipe_id,
		"building_id":building_id,
		"inputs":inputs,
		"outputs":outputs
	})
	if depth >= MAX_DEPENDENCY_DEPTH:
		return
	for input_value in inputs:
		_append_dependencies(str((input_value as Dictionary).get("item_id", "")), depth + 1, producer_candidates_by_item, extraction_candidates_by_item, recipes_by_id, plan_definition_id, seen, target)


static func _stages(entities: Array, orders: Array, buildings: Array, build_plans: Array) -> Array:
	var extractors := _entities_of_kind(entities, "EXTRACTOR")
	var machines := _entities_of_kind(entities, "MACHINE")
	var waiting_orders: Array = []
	var active_orders: Array = []
	for order_value in orders:
		var order := order_value as Dictionary
		if _order_remaining_total(order) > 0:
			waiting_orders.append(order)
		else:
			active_orders.append(order)
	var stages: Array = []
	stages.append(_entity_stage("COLLECTION", extractors, "EXTRACTOR", buildings, build_plans, "CANVAS"))
	stages.append(_entity_stage("PRODUCTION", machines, "MACHINE", buildings, build_plans, "PRODUCTION"))
	if orders.is_empty():
		stages.append(_stage("CONSTRUCTION", "MISSING", 0, _open_tab("CONSTRUCTION")))
	elif not waiting_orders.is_empty():
		stages.append(_stage("CONSTRUCTION", "BLOCKED", orders.size(), _focus_order(str((waiting_orders[0] as Dictionary).get("id", "")))))
	elif not active_orders.is_empty():
		stages.append(_stage("CONSTRUCTION", "ACTIVE", orders.size(), _focus_order(str((active_orders[0] as Dictionary).get("id", "")))))
	else:
		stages.append(_stage("CONSTRUCTION", "READY", orders.size(), _open_tab("CONSTRUCTION")))
	if buildings.is_empty():
		stages.append(_stage("EXPANSION", "MISSING", 0, _open_tab("CANVAS")))
	else:
		var selected_plan: Dictionary = {}
		if not build_plans.is_empty():
			selected_plan = build_plans[0] as Dictionary
		var any_affordable := false
		for plan_value in build_plans:
			var plan := plan_value as Dictionary
			if bool(plan.get("affordable", false)):
				any_affordable = true
				selected_plan = plan
				break
		var expansion_state := "ACTIVE" if not active_orders.is_empty() else ("READY" if any_affordable else "BLOCKED")
		stages.append(_stage("EXPANSION", expansion_state, buildings.size(), _select_building(str(selected_plan.get("definition_id", "")))))
	return stages


static func _entity_stage(id: String, entities: Array, building_kind: String, buildings: Array, build_plans: Array, tab: String) -> Dictionary:
	if entities.is_empty():
		var building_id := _first_affordable_building_id(buildings, build_plans, building_kind)
		return _stage(id, "MISSING", 0, _select_building(building_id) if not building_id.is_empty() else _open_tab(tab))
	var blocked: Dictionary = {}
	var active: Dictionary = {}
	for entity_value in entities:
		var entity := entity_value as Dictionary
		if blocked.is_empty() and _is_blocking_status(str(entity.get("status", "")).to_upper()):
			blocked = entity
		if active.is_empty() and maxf(0.0, float(entity.get("actual_rate", 0.0))) > 0.0:
			active = entity
	if not blocked.is_empty() and active.is_empty():
		return _stage(id, "BLOCKED", entities.size(), _focus_entity(str(blocked.get("id", ""))))
	if not active.is_empty():
		return _stage(id, "ACTIVE", entities.size(), _focus_entity(str(active.get("id", ""))))
	return _stage(id, "READY", entities.size(), _focus_entity(str((entities[0] as Dictionary).get("id", ""))))


static func _alerts(entities: Array, orders: Array, materials: Array) -> Array:
	var alerts: Array = []
	for entity_value in entities:
		var entity := entity_value as Dictionary
		var entity_id := str(entity.get("id", ""))
		var status := str(entity.get("status", "")).to_upper()
		if entity_id.is_empty() or (not _is_blocking_status(status) and not WARNING_ENTITY_STATUSES.has(status)):
			continue
		alerts.append({
			"id":"entity:%s:%s" % [entity_id, status],
			"code":status,
			"entity_id":entity_id,
			"action":_focus_entity(entity_id)
		})
	for order_value in orders:
		var order := order_value as Dictionary
		var order_id := str(order.get("id", ""))
		var remaining := _order_remaining_total(order)
		if order_id.is_empty() or remaining <= 0:
			continue
		alerts.append({
			"id":"order:%s:WAITING_MATERIALS" % order_id,
			"code":"WAITING_MATERIALS",
			"order_id":order_id,
			"amount":remaining,
			"action":_focus_order(order_id)
		})
	for material_value in materials:
		var material := material_value as Dictionary
		var item_id := str(material.get("item_id", ""))
		var missing := maxi(0, int(material.get("missing", 0)))
		if item_id.is_empty() or missing <= 0:
			continue
		alerts.append({
			"id":"material:%s:SHORTAGE" % item_id,
			"code":"MATERIAL_SHORTAGE",
			"item_id":item_id,
			"amount":missing,
			"action":_open_tab("PRODUCTION")
		})
	alerts.sort_custom(func(left, right): return str((left as Dictionary).get("id", "")) < str((right as Dictionary).get("id", "")))
	return alerts


## Candidates are preserved until a specific construction plan asks for one.
## A global lexical winner is misleading: a large building can alphabetically
## precede the small, presently buildable machine required to bootstrap it.
static func _producer_candidates(buildings: Array, recipes_by_id: Dictionary, entities: Array, materials_by_item: Dictionary, resource_item_ids: Dictionary) -> Dictionary:
	var result := {}
	for building_value in buildings:
		var building := building_value as Dictionary
		var building_id := str(building.get("id", ""))
		if building_id.is_empty():
			continue
		var recipe_ids: Array = []
		for recipe_id_value in building.get("recipe_ids", []):
			recipe_ids.append(str(recipe_id_value))
		recipe_ids.sort()
		for recipe_id in recipe_ids:
			var recipe: Dictionary = recipes_by_id.get(recipe_id, {})
			if recipe.is_empty():
				continue
			for output_value in _item_rows(recipe.get("outputs", [])):
				var item_id := str((output_value as Dictionary).get("item_id", ""))
				if item_id.is_empty():
					continue
				var candidate := {
					"building_id":building_id,
					"recipe_id":recipe_id,
					"configured":_has_configured_producer(entities, building_id, recipe_id),
					"construction_affordable":_building_construction_affordable(building, materials_by_item),
					"resource_backed":_recipe_is_resource_backed(recipe, resource_item_ids),
					"requires_own_output":str(building.get("deployment_item_id", "")) == item_id,
					"construction_work":0.0
				}
				var candidates: Array = result.get(item_id, []) as Array
				candidates.append(candidate)
				result[item_id] = candidates
	for item_id_value in result.keys():
		var item_id := str(item_id_value)
		var candidates: Array = result.get(item_id, []) as Array
		candidates.sort_custom(func(left, right): return _producer_candidate_before(left as Dictionary, right as Dictionary))
		result[item_id] = candidates
	return result


## Resource fields are not entities and do not themselves produce cargo.  This
## compact terminal only describes the actionable, unlocked extractor that can
## collect a recipe's raw input from a mapped compatible field.
static func _extraction_candidates(buildings: Array, resource_fields: Array) -> Dictionary:
	var extractors: Array = []
	for building_value in buildings:
		var building := building_value as Dictionary
		if str(building.get("kind", "")).to_upper() != "EXTRACTOR":
			continue
		var building_id := str(building.get("id", ""))
		if building_id.is_empty():
			continue
		var categories: Array = []
		for category_value in building.get("resource_categories", []):
			categories.append(str(category_value))
		categories.sort()
		if not categories.is_empty():
			extractors.append({"building_id":building_id, "resource_categories":categories})
	var result := {}
	for field_value in resource_fields:
		var field := field_value as Dictionary
		var resource_id := str(field.get("resource_id", ""))
		var resource_field_id := str(field.get("id", ""))
		var resource_category := str(field.get("resource_category", ""))
		if resource_id.is_empty() or resource_field_id.is_empty() or resource_category.is_empty():
			continue
		for extractor_value in extractors:
			var extractor := extractor_value as Dictionary
			if not (extractor.get("resource_categories", []) as Array).has(resource_category):
				continue
			var candidates: Array = result.get(resource_id, []) as Array
			candidates.append({
				"resource_field_id":resource_field_id,
				"building_id":str(extractor.get("building_id", ""))
			})
			result[resource_id] = candidates
	for resource_id_value in result.keys():
		var resource_id := str(resource_id_value)
		var candidates: Array = result.get(resource_id, []) as Array
		candidates.sort_custom(func(left, right): return _extraction_candidate_before(left as Dictionary, right as Dictionary))
		result[resource_id] = candidates
	return result


static func _append_extraction_dependency(item_id: String, depth: int, extraction_candidates_by_item: Dictionary, seen: Dictionary, target: Array) -> void:
	if seen.has(item_id):
		return
	var candidates: Array = extraction_candidates_by_item.get(item_id, []) as Array
	if candidates.is_empty():
		return
	var candidate := candidates[0] as Dictionary
	var resource_field_id := str(candidate.get("resource_field_id", ""))
	var building_id := str(candidate.get("building_id", ""))
	if resource_field_id.is_empty() or building_id.is_empty():
		return
	seen[item_id] = true
	target.append({
		"item_id":item_id,
		"depth":depth,
		"recipe_id":"",
		"building_id":building_id,
		"inputs":[],
		"outputs":[],
		"kind":"EXTRACTION",
		"resource_field_id":resource_field_id,
		"action":{"kind":"SELECT_BUILDING", "target_id":building_id}
	})


static func _extraction_candidate_before(left: Dictionary, right: Dictionary) -> bool:
	var left_field_id := str(left.get("resource_field_id", ""))
	var right_field_id := str(right.get("resource_field_id", ""))
	if left_field_id != right_field_id:
		return left_field_id < right_field_id
	return str(left.get("building_id", "")) < str(right.get("building_id", ""))


static func _producer_for_item(item_id: String, producer_candidates_by_item: Dictionary, plan_definition_id: String) -> Dictionary:
	var candidates: Array = producer_candidates_by_item.get(item_id, []) as Array
	for candidate_value in candidates:
		var candidate := candidate_value as Dictionary
		# A first build cannot rely on itself. Once a configured instance exists,
		# though, it is a legitimate physical producer for another copy.
		if str(candidate.get("building_id", "")) == plan_definition_id and not bool(candidate.get("configured", false)):
			continue
		return candidate
	return {}


static func _producer_candidate_before(left: Dictionary, right: Dictionary) -> bool:
	var left_configured := bool(left.get("configured", false))
	var right_configured := bool(right.get("configured", false))
	if left_configured != right_configured:
		return left_configured
	var left_affordable := bool(left.get("construction_affordable", false))
	var right_affordable := bool(right.get("construction_affordable", false))
	if left_affordable != right_affordable:
		return left_affordable
	# Where an affordable building exposes both a finite-stock recycler and a
	# refinery fed by a mapped field, lead the player toward the renewable
	# collection chain.  A configured machine still remains the strongest
	# signal, so this does not override an operator's existing production plan.
	var left_resource_backed := bool(left.get("resource_backed", false))
	var right_resource_backed := bool(right.get("resource_backed", false))
	if left_resource_backed != right_resource_backed:
		return left_resource_backed
	var left_requires_own_output := bool(left.get("requires_own_output", false))
	var right_requires_own_output := bool(right.get("requires_own_output", false))
	if left_requires_own_output != right_requires_own_output:
		return not left_requires_own_output
	var left_work := float(left.get("construction_work", 0.0))
	var right_work := float(right.get("construction_work", 0.0))
	if left_work != right_work:
		return left_work < right_work
	return _producer_key(left) < _producer_key(right)


static func _has_configured_producer(entities: Array, building_id: String, recipe_id: String) -> bool:
	for entity_value in entities:
		var entity := entity_value as Dictionary
		if (
			str(entity.get("definition_id", "")) == building_id
			and str(entity.get("recipe_id", "")) == recipe_id
			and str(entity.get("status", "")).to_upper() != "UNDER_CONSTRUCTION"
		):
			return true
	return false


static func _building_construction_affordable(building: Dictionary, materials_by_item: Dictionary) -> bool:
	var item_id := str(building.get("deployment_item_id", ""))
	return not item_id.is_empty() and int(materials_by_item.get(item_id, {}).get("available", 0)) >= 1


static func _resource_item_ids(resource_fields_value) -> Dictionary:
	var result := {}
	if resource_fields_value is not Array:
		return result
	for field_value in resource_fields_value as Array:
		if field_value is not Dictionary:
			continue
		var resource_id := str((field_value as Dictionary).get("resource_id", ""))
		if not resource_id.is_empty():
			result[resource_id] = true
	return result


static func _recipe_is_resource_backed(recipe: Dictionary, resource_item_ids: Dictionary) -> bool:
	var inputs := _item_rows(recipe.get("inputs", []))
	if inputs.is_empty():
		return false
	for input_value in inputs:
		var item_id := str((input_value as Dictionary).get("item_id", ""))
		if item_id.is_empty() or not resource_item_ids.has(item_id):
			return false
	return true


static func _producer_key(producer: Dictionary) -> String:
	return "%s|%s" % [str(producer.get("building_id", "")), str(producer.get("recipe_id", ""))]


static func _entities_of_kind(entities: Array, kind: String) -> Array:
	var result: Array = []
	for entity_value in entities:
		var entity := entity_value as Dictionary
		if _kind(entity) == kind:
			result.append(entity)
	return result


static func _first_building_id(buildings: Array, kind: String) -> String:
	for building_value in buildings:
		var building := building_value as Dictionary
		if str(building.get("kind", "")).to_upper() == kind:
			return str(building.get("id", ""))
	return ""


static func _first_affordable_building_id(buildings: Array, build_plans: Array, kind: String) -> String:
	var plans_by_definition := {}
	for plan_value in build_plans:
		var plan := plan_value as Dictionary
		plans_by_definition[str(plan.get("definition_id", ""))] = plan
	for building_value in buildings:
		var building := building_value as Dictionary
		if str(building.get("kind", "")).to_upper() != kind:
			continue
		var definition_id := str(building.get("id", ""))
		if bool((plans_by_definition.get(definition_id, {}) as Dictionary).get("affordable", false)):
			return definition_id
	return _first_building_id(buildings, kind)


static func _stage(id: String, state: String, count: int, action: Dictionary) -> Dictionary:
	return {"id":id, "state":state, "count":maxi(0, count), "action":action}


static func _focus_entity(entity_id: String) -> Dictionary:
	return {"kind":"FOCUS_ENTITY", "target_id":entity_id}


static func _focus_order(order_id: String) -> Dictionary:
	return {"kind":"FOCUS_ORDER", "target_id":order_id}


static func _select_building(definition_id: String) -> Dictionary:
	return {"kind":"SELECT_BUILDING", "target_id":definition_id}


static func _open_tab(tab: String) -> Dictionary:
	return {"kind":"OPEN_TAB", "tab":tab}


static func _order_remaining_total(order: Dictionary) -> int:
	var required := _item_quantities(order.get("required_items", {}))
	var delivered := _item_quantities(order.get("delivered_items", {}))
	var total := 0
	for item_id_value in required.keys():
		var item_id := str(item_id_value)
		total += maxi(0, int(required.get(item_id, 0)) - int(delivered.get(item_id, 0)))
	return total


static func _location_available_manifest(snapshot: Dictionary) -> Dictionary:
	var source: Dictionary = snapshot.get("location_available_inventory", {}) if snapshot.get("location_available_inventory", {}) is Dictionary else {}
	if source.get("items", null) is Dictionary:
		source = source.get("items", {}) as Dictionary
	return _item_quantities(source)


static func _add_manifest(totals: Dictionary, value, field: String) -> void:
	var manifest := _item_quantities(value)
	for item_id_value in manifest.keys():
		var item_id := str(item_id_value)
		_add_amount(totals, item_id, field, int(manifest.get(item_id, 0)))


static func _add_amount(totals: Dictionary, item_id: String, field: String, amount: int) -> void:
	if item_id.is_empty():
		return
	var total: Dictionary = totals.get(item_id, {})
	if field != "none":
		total[field] = maxi(0, int(total.get(field, 0))) + maxi(0, amount)
	totals[item_id] = total


static func _add_rate(totals: Dictionary, item_id: String, field: String, amount: float) -> void:
	if item_id.is_empty():
		return
	var total: Dictionary = totals.get(item_id, {})
	total[field] = maxf(0.0, float(total.get(field, 0.0))) + maxf(0.0, amount)
	totals[item_id] = total


static func _item_quantities(value) -> Dictionary:
	var result := {}
	if value is Dictionary:
		for item_id_value in (value as Dictionary).keys():
			var item_id := str(item_id_value)
			if not item_id.is_empty():
				result[item_id] = maxi(0, int((value as Dictionary).get(item_id_value, 0)))
	elif value is Array:
		for entry_value in value as Array:
			if entry_value is not Dictionary:
				continue
			var entry := entry_value as Dictionary
			var item_id := str(entry.get("item_id", entry.get("item", "")))
			if not item_id.is_empty():
				result[item_id] = int(result.get(item_id, 0)) + maxi(0, int(entry.get("quantity", entry.get("amount", 0))))
	return result


static func _item_rows(value) -> Array:
	var quantities := _item_quantities(value)
	var item_ids: Array = quantities.keys()
	item_ids.sort_custom(func(left, right): return str(left) < str(right))
	var result: Array = []
	for item_id_value in item_ids:
		var item_id := str(item_id_value)
		result.append({"item_id":item_id, "quantity":maxi(0, int(quantities.get(item_id, 0)))})
	return result


static func _indexed_rows(rows: Array, key: String) -> Dictionary:
	var result := {}
	for row_value in rows:
		var row := row_value as Dictionary
		var id := str(row.get(key, ""))
		if not id.is_empty():
			result[id] = row
	return result


static func _sorted_rows(value, key: String) -> Array:
	var rows: Array = []
	if value is Array:
		for row_value in value as Array:
			if row_value is Dictionary:
				rows.append(row_value as Dictionary)
	elif value is Dictionary:
		var source := value as Dictionary
		var source_keys: Array = source.keys()
		source_keys.sort_custom(func(left, right): return str(left) < str(right))
		for source_key in source_keys:
			if source.get(source_key) is Dictionary:
				rows.append(source.get(source_key) as Dictionary)
	rows.sort_custom(func(left, right): return str((left as Dictionary).get(key, "")) < str((right as Dictionary).get(key, "")))
	return rows


static func _kind(entity: Dictionary) -> String:
	return str(entity.get("node_kind", entity.get("kind", ""))).to_upper()


static func _is_operational_storage(entity: Dictionary) -> bool:
	return _kind(entity) == "STORAGE" and str(entity.get("status", "")).to_upper() != "UNDER_CONSTRUCTION"


static func _is_blocking_status(status: String) -> bool:
	return BLOCKING_ENTITY_STATUSES.has(status)
