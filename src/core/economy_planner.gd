class_name EconomyPlanner
extends RefCounted

## Read-only industrial calculator. It never mutates SpaceGameState and every
## rate comes from SimulationEngine's runtime formula entry points.

var content: ContentDatabase
var simulation: RefCounted
var _dependency_graph_cache := {}


func _init(database: ContentDatabase, simulation_engine: RefCounted) -> void:
	content = database
	simulation = simulation_engine


func production_dependency_graph() -> Dictionary:
	if not _dependency_graph_cache.is_empty():
		return _dependency_graph_cache
	var nodes := {}
	var edges: Array = []
	var producers := {}
	for item_id_value in content.items.keys():
		var item_id := str(item_id_value)
		nodes["product:%s" % item_id] = {"id":"product:%s" % item_id, "kind":"PRODUCT", "definition_id":item_id}
	for recipe_value in content.factory_recipes.values():
		var recipe := recipe_value as Dictionary
		var recipe_id := str(recipe.get("id", ""))
		var recipe_node := "recipe:%s" % recipe_id
		nodes[recipe_node] = {"id":recipe_node, "kind":"FACTORY_RECIPE", "definition_id":recipe_id}
		for building_id_value in _compatible_building_ids(recipe_id):
			var building_id := str(building_id_value)
			var building_node := "building:%s" % building_id
			nodes[building_node] = {"id":building_node, "kind":"FACTORY_BUILDING", "definition_id":building_id}
			edges.append({"from":recipe_node, "to":building_node, "type":"REQUIRES"})
		for input_value in recipe.get("inputs", []):
			var input := input_value as Dictionary
			edges.append({"from":recipe_node, "to":"product:%s" % input.get("item", ""), "type":"CONSUMES", "quantity":input.get("quantity", 0)})
		for output_value in recipe.get("outputs", []):
			var output := output_value as Dictionary
			var product_id := str(output.get("item", ""))
			edges.append({"from":"product:%s" % product_id, "to":recipe_node, "type":"PRODUCED_BY", "quantity":output.get("quantity", 0)})
			var product_producers: Array = producers.get(product_id, [])
			product_producers.append(recipe_id)
			producers[product_id] = product_producers
		for support in ["power", "storage", "cargo_links"]:
			var infrastructure_node := "infrastructure:%s" % support
			nodes[infrastructure_node] = {"id":infrastructure_node, "kind":"INFRASTRUCTURE_REQUIREMENT", "definition_id":support}
			edges.append({"from":recipe_node, "to":infrastructure_node, "type":"REQUIRES"})
	_dependency_graph_cache = {"nodes":nodes, "edges":edges, "producers":producers, "cycle_policy":"EXTERNAL_CREDIT"}
	return _dependency_graph_cache


func upstream_dependencies(product_id: String) -> Dictionary:
	var graph := production_dependency_graph()
	var nodes := {}
	var edges: Array = []
	var credits: Array = []
	_expand_upstream(product_id, graph, nodes, edges, credits, [])
	return {"root":"product:%s" % product_id, "nodes":nodes, "edges":edges, "external_credits":credits}


func _expand_upstream(product_id: String, graph: Dictionary, nodes: Dictionary, edges: Array, credits: Array, stack: Array) -> void:
	var product_node := "product:%s" % product_id
	if stack.has(product_id):
		if not credits.has(product_id):
			credits.append(product_id)
		return
	nodes[product_node] = graph.get("nodes", {}).get(product_node, {"id":product_node, "kind":"PRODUCT", "definition_id":product_id})
	var next_stack := stack.duplicate()
	next_stack.append(product_id)
	for method_id_value in graph.get("producers", {}).get(product_id, []):
		var method_id := str(method_id_value)
		var method_node := "recipe:%s" % method_id
		nodes[method_node] = graph.get("nodes", {}).get(method_node, {})
		for edge_value in graph.get("edges", []):
			var edge := edge_value as Dictionary
			if str(edge.get("from", "")) not in [product_node, method_node]:
				continue
			edges.append(edge.duplicate(true))
			var target := str(edge.get("to", ""))
			if graph.get("nodes", {}).has(target):
				nodes[target] = graph["nodes"][target]
			if str(edge.get("type", "")) == "CONSUMES" and target.begins_with("product:"):
				_expand_upstream(target.trim_prefix("product:"), graph, nodes, edges, credits, next_stack)


func current_economy_analysis(state: SpaceGameState, location_id: String) -> Dictionary:
	var rows := {}
	var storage_snapshot: Dictionary = simulation.location_storage_snapshot(state, location_id)
	for item_id_value in content.items.keys():
		var item_id := str(item_id_value)
		rows[item_id] = _empty_economy_row(state, location_id, item_id, storage_snapshot)
	for world_id_value in state.factory_worlds.keys():
		var world_id := str(world_id_value)
		var world: Dictionary = state.factory_worlds.get(world_id_value, {})
		if str(world.get("location_id", "")) != location_id:
			continue
		for entity_id_value in world.get("entities", {}).keys():
			var entity_id := str(entity_id_value)
			var entity: Dictionary = world.get("entities", {}).get(entity_id_value, {})
			for field in ["inventory", "inputs", "outputs"]:
				for item_id_value in entity.get(field, {}).keys():
					var item_id := str(item_id_value)
					if rows.has(item_id):
						var quantity := maxi(0, int(entity.get(field, {}).get(item_id_value, 0)))
						rows[item_id]["stock"] = int(rows[item_id].get("stock", 0)) + quantity
						rows[item_id]["on_hand"] = int(rows[item_id].get("on_hand", 0)) + quantity
						rows[item_id]["available"] = int(rows[item_id].get("available", 0)) + quantity
						rows[item_id]["factory_on_hand"] = int(rows[item_id].get("factory_on_hand", 0)) + quantity
			match str(entity.get("kind", "")):
				"EXTRACTOR":
					var deposit := _deposit_for_extractor(world, entity_id)
					var product_id := str(deposit.get("resource_id", ""))
					if product_id.is_empty() or not rows.has(product_id):
						continue
					rows[product_id]["production_rate"] = float(rows[product_id].get("production_rate", 0.0)) + maxf(0.0, float(entity.get("actual_rate", 0.0))) * 3600.0
					_append_factory_blocker(rows[product_id], world_id, entity)
				"MACHINE":
					var recipe: Dictionary = content.factory_recipes.get(str(entity.get("recipe_id", "")), {})
					if recipe.is_empty():
						continue
					var cycles_per_hour := maxf(0.0, float(entity.get("actual_rate", 0.0))) * 3600.0
					for output_value in recipe.get("outputs", []):
						var output := output_value as Dictionary
						var product_id := str(output.get("item", ""))
						if rows.has(product_id):
							rows[product_id]["production_rate"] = float(rows[product_id].get("production_rate", 0.0)) + float(output.get("quantity", 0.0)) * cycles_per_hour
							_append_factory_blocker(rows[product_id], world_id, entity)
					for input_value in recipe.get("inputs", []):
						var input := input_value as Dictionary
						var input_id := str(input.get("item", ""))
						if rows.has(input_id):
							rows[input_id]["production_consumption_rate"] = float(rows[input_id].get("production_consumption_rate", 0.0)) + float(input.get("quantity", 0.0)) * cycles_per_hour
		for order_value in world.get("construction_orders", {}).values():
			var order := order_value as Dictionary
			for item_id_value in order.get("delivered_items", {}).keys():
				var item_id := str(item_id_value)
				if rows.has(item_id):
					var quantity := maxi(0, int(order.get("delivered_items", {}).get(item_id_value, 0)))
					rows[item_id]["stock"] = int(rows[item_id].get("stock", 0)) + quantity
					rows[item_id]["on_hand"] = int(rows[item_id].get("on_hand", 0)) + quantity
					rows[item_id]["reserved"] = int(rows[item_id].get("reserved", 0)) + quantity
					rows[item_id]["construction_staging"] = int(rows[item_id].get("construction_staging", 0)) + quantity
	for demand_value in state.demand_registry.get("sources", {}).values():
		var demand := demand_value as Dictionary
		if str(demand.get("location_id", "")) != location_id:
			continue
		var product_id := str(demand.get("product_id", ""))
		if not rows.has(product_id):
			continue
		rows[product_id]["demand_sources"].append(demand.duplicate(true))
		if str(demand.get("demand_kind", "")) == "CONTINUOUS":
			rows[product_id]["continuous_demand_rate"] = float(rows[product_id].get("continuous_demand_rate", 0.0)) + float(demand.get("rate_per_hour", 0.0))
			rows[product_id]["committed_demand"] = float(rows[product_id].get("committed_demand", 0.0)) + float(demand.get("backlog_quantity", 0.0))
		else:
			rows[product_id]["committed_demand"] = float(rows[product_id].get("committed_demand", 0.0)) + float(demand.get("quantity", 0.0))
	for shipment_value in state.logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		var duration_hours := maxf(0.001, float(shipment.get("total_ms", 1.0)) / 3600000.0)
		for item_id_value in shipment.get("cargo", {}).keys():
			var item_id := str(item_id_value)
			var rate := float(shipment.get("cargo", {}).get(item_id, 0)) / duration_hours
			if str(shipment.get("destination", "")) == location_id:
				rows[item_id]["import_rate"] = float(rows[item_id].get("import_rate", 0.0)) + rate
			if str(shipment.get("origin", "")) == location_id:
				rows[item_id]["export_rate"] = float(rows[item_id].get("export_rate", 0.0)) + rate
	var result: Array = []
	for item_id_value in rows.keys():
		var row: Dictionary = rows[item_id_value]
		_finalize_economy_row(row)
		if int(row.get("stock", 0)) > 0 or absf(float(row.get("net_rate", 0.0))) > 0.000001 or float(row.get("committed_demand", 0.0)) > 0.0 or not row.get("blocked_sources", []).is_empty():
			result.append(row)
	result.sort_custom(func(a, b): return _status_rank(str(a.get("status", "STABLE"))) > _status_rank(str(b.get("status", "STABLE"))) if _status_rank(str(a.get("status", "STABLE"))) != _status_rank(str(b.get("status", "STABLE"))) else str(a.get("product_id", "")) < str(b.get("product_id", "")))
	return {"location_id":location_id, "products":result, "storage":storage_snapshot, "generated_at_ms":int(state.total_elapsed_ms)}


func _append_factory_blocker(row: Dictionary, world_id: String, entity: Dictionary) -> void:
	var status := str(entity.get("status", "IDLE"))
	if status in ["RUNNING", "POWER_LIMITED", "IDLE"]:
		return
	row["blocked_sources"].append({
		"source_id":str(entity.get("id", "")),
		"world_id":world_id,
		"method_id":str(entity.get("recipe_id", "")),
		"blocker":{"primary_reason":status, "world_id":world_id, "entity_id":str(entity.get("id", ""))}
	})


func _empty_economy_row(state: SpaceGameState, location_id: String, item_id: String, storage: Dictionary) -> Dictionary:
	var storage_class: String = str(simulation.storage_class_for_item(item_id))
	var class_row: Dictionary = storage.get("classes", {}).get(storage_class, {})
	var on_hand := state.item_quantity(item_id, location_id)
	var available := state.available_item_quantity(item_id, location_id)
	return {"product_id":item_id, "stock":on_hand, "on_hand":on_hand, "location_on_hand":on_hand, "factory_on_hand":0, "construction_staging":0, "reserved":maxi(0, on_hand - available), "available":available, "storage_class":storage_class, "storage_capacity":class_row.get("capacity", 0.0), "free_storage":class_row.get("free", 0.0), "storage_utilization":class_row.get("utilization", 0.0), "production_rate":0.0, "production_consumption_rate":0.0, "continuous_demand_rate":0.0, "committed_demand":0.0, "import_rate":0.0, "export_rate":0.0, "net_rate":0.0, "stock_coverage_hours":INF, "demand_sources":[], "blocked_sources":[], "status":"STABLE"}


func _finalize_economy_row(row: Dictionary) -> void:
	var gross_consumption := float(row.get("production_consumption_rate", 0.0)) + float(row.get("continuous_demand_rate", 0.0)) + float(row.get("export_rate", 0.0))
	var gross_supply := float(row.get("production_rate", 0.0)) + float(row.get("import_rate", 0.0))
	row["consumption_rate"] = gross_consumption
	row["net_rate"] = gross_supply - gross_consumption
	var net_consumption := maxf(0.0, gross_consumption - gross_supply)
	row["stock_coverage_hours"] = float(row.get("stock", 0)) / net_consumption if net_consumption > 0.000001 else INF
	if float(row.get("storage_utilization", 0.0)) >= 0.999999:
		row["status"] = "STORAGE_FULL"
	elif not row.get("blocked_sources", []).is_empty():
		row["status"] = "CRITICAL"
	elif float(row.get("net_rate", 0.0)) < -0.000001 and float(row.get("stock_coverage_hours", INF)) < 6.0:
		row["status"] = "CRITICAL"
	elif float(row.get("net_rate", 0.0)) < -0.000001 or float(row.get("stock_coverage_hours", INF)) < 24.0:
		row["status"] = "TIGHT"
	elif float(row.get("net_rate", 0.0)) > 0.000001:
		row["status"] = "SURPLUS"
	else:
		row["status"] = "STABLE"


func plan_targets(state: SpaceGameState, targets: Dictionary, location_id: String) -> Dictionary:
	var required := {}
	var method_cycles := {}
	var selections := {}
	var external_credits: Array = []
	for item_id_value in targets.keys():
		_expand_requirement(state, str(item_id_value), maxf(0.0, float(targets[item_id_value])), location_id, required, method_cycles, selections, external_credits, [])
	var factories: Array = []
	var power_required := 0.0
	var capital_goods := {}
	for recipe_id_value in method_cycles.keys():
		var recipe_id := str(recipe_id_value)
		var recipe: Dictionary = _recipe_with_building(recipe_id)
		if recipe.is_empty():
			continue
		var building_id := str(recipe.get("building_definition_id", ""))
		var definition: Dictionary = content.factory_buildings.get(building_id, {})
		var cycles_required := float(method_cycles.get(recipe_id, 0.0))
		var per_device := maxf(0.000001, float(definition.get("speed", 1.0)) * 3600.0 / maxf(0.000001, float(recipe.get("duration_seconds", 1.0))))
		var current_count := _factory_entity_count(state, location_id, building_id, recipe_id)
		var recommended := ceili(cycles_required / per_device)
		var shortage := maxi(0, recommended - current_count)
		power_required += float(recommended) * maxf(0.0, float(definition.get("power_demand_kw", 0.0)))
		for cost_value in definition.get("construction_cost", []):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			capital_goods[item_id] = int(capital_goods.get(item_id, 0)) + int(cost.get("quantity", 0)) * shortage
		factories.append({
			"building_definition_id":building_id,
			"recipe_id":recipe_id,
			"required_cycles_per_hour":cycles_required,
			"cycles_per_hour_per_entity":per_device,
			"current":current_count,
			"recommended":recommended,
			"shortage":shortage,
			"utilization":cycles_required / maxf(0.000001, per_device * float(maxi(1, recommended)))
		})
	var current_analysis := current_economy_analysis(state, location_id)
	var bottlenecks: Array = []
	for item_id_value in targets.keys():
		bottlenecks.append(trace_bottleneck(state, str(item_id_value), location_id, float(targets[item_id_value])))
	return {"location_id":location_id, "targets":targets.duplicate(true), "product_requirements":required, "method_selections":selections, "factory_requirements":factories, "infrastructure_requirements":{"power_kw":power_required, "storage":_planned_storage(required), "capital_goods":capital_goods}, "logistics":_planned_logistics(state, location_id, required), "industrial_geography":extraction_capacity_analysis(state, required), "bottlenecks":bottlenecks, "external_credits":external_credits, "current_economy":current_analysis, "read_only":true}


func plan_bom_target(state: SpaceGameState, target_id: String, bom: Dictionary, location_id: String, horizon_hours: float = 1.0) -> Dictionary:
	var safe_horizon := maxf(0.000001, horizon_hours)
	var normalized_bom := {}
	var throughput_targets := {}
	for item_id_value in bom.keys():
		var item_id := str(item_id_value)
		var quantity := maxf(0.0, float(bom.get(item_id_value, 0.0)))
		if quantity <= 0.0:
			continue
		normalized_bom[item_id] = quantity
		throughput_targets[item_id] = quantity / safe_horizon
	return {"target_type":"BOM", "target_id":target_id, "location_id":location_id, "horizon_hours":safe_horizon, "bom":normalized_bom, "throughput_targets":throughput_targets, "production_plan":plan_targets(state, throughput_targets, location_id), "read_only":true}


func plan_ship_per_month(state: SpaceGameState, ship_plan_id: String, ships_per_month: float, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> Dictionary:
	var plan: Dictionary = content.ship_construction_projects.get(ship_plan_id, {})
	if plan.is_empty() or ships_per_month <= 0.0:
		return {"target_type":"SHIP_PER_MONTH", "target_id":ship_plan_id, "error":"INVALID_SHIP_TARGET", "read_only":true}
	var per_ship_bom: Dictionary = simulation.ship_construction_material_totals(plan).duplicate(true)
	for fixed_value in plan.get("fixed_costs", []):
		var fixed_cost := fixed_value as Dictionary
		var item_id := str(fixed_cost.get("item", ""))
		per_ship_bom[item_id] = int(per_ship_bom.get(item_id, 0)) + int(fixed_cost.get("quantity", 0))
	var monthly_bom := {}
	for item_id_value in per_ship_bom.keys():
		monthly_bom[str(item_id_value)] = float(per_ship_bom[item_id_value]) * ships_per_month
	var cycle_duration_ms := float(simulation.shipyard_cycle_duration_ms(state, plan))
	var current_ships_per_month := 720.0 * 3600000.0 / maxf(0.000001, cycle_duration_ms * 100.0)
	var result := plan_bom_target(state, ship_plan_id, monthly_bom, location_id, 720.0)
	result.merge({"target_type":"SHIP_PER_MONTH", "ships_per_month":ships_per_month, "per_ship_bom":per_ship_bom, "shipyard_cycle_duration_ms":cycle_duration_ms, "current_shipyard_throughput_per_month":current_ships_per_month, "shipyard_shortfall_per_month":maxf(0.0, ships_per_month - current_ships_per_month)}, true)
	return result


func plan_research_phase(state: SpaceGameState, project_id: String, phase_id: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID, route_id: String = "", horizon_hours: float = 1.0) -> Dictionary:
	var project: Dictionary = content.research_projects.get(project_id, {})
	if project.is_empty():
		return {"target_type":"RESEARCH_PHASE", "target_id":"%s:%s" % [project_id, phase_id], "error":"UNKNOWN_RESEARCH_PROJECT", "read_only":true}
	var stage_index := -1
	var stages: Array = simulation.research_stages(project)
	for index in stages.size():
		if str((stages[index] as Dictionary).get("id", "")) == phase_id:
			stage_index = index
			break
	if stage_index < 0:
		return {"target_type":"RESEARCH_PHASE", "target_id":"%s:%s" % [project_id, phase_id], "error":"UNKNOWN_RESEARCH_PHASE", "read_only":true}
	var stage: Dictionary = simulation.research_stage_definition(state, project, stage_index, route_id)
	var bom := _entry_totals(stage.get("costs", []))
	var result := plan_bom_target(state, "%s:%s" % [project_id, phase_id], bom, location_id, horizon_hours)
	result.merge({"target_type":"RESEARCH_PHASE", "project_id":project_id, "phase_id":phase_id, "route_id":route_id, "work_required":stage.get("work_required", 0.0), "capacity_required":stage.get("capacity_required", 0.0), "requirements":stage.get("requirements", []).duplicate(true), "operating_conditions":stage.get("operating_conditions", []).duplicate(true)}, true)
	return result


func plan_megastructure_phase(state: SpaceGameState, megastructure_id: String, phase_id: String, location_id: String = "", horizon_hours: float = 1.0) -> Dictionary:
	var megastructure: Dictionary = content.megastructures.get(megastructure_id, {})
	if megastructure.is_empty():
		return {"target_type":"MEGASTRUCTURE_PHASE", "target_id":"%s:%s" % [megastructure_id, phase_id], "error":"UNKNOWN_MEGASTRUCTURE", "read_only":true}
	var phase := {}
	for phase_value in megastructure.get("phases", []):
		if str((phase_value as Dictionary).get("id", "")) == phase_id:
			phase = (phase_value as Dictionary).duplicate(true)
			break
	if phase.is_empty():
		return {"target_type":"MEGASTRUCTURE_PHASE", "target_id":"%s:%s" % [megastructure_id, phase_id], "error":"UNKNOWN_MEGASTRUCTURE_PHASE", "read_only":true}
	var project: Dictionary = state.megastructure_projects.get(megastructure_id, {})
	var target_location := location_id
	if target_location.is_empty():
		target_location = str(project.get("site_location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var activity: Dictionary = content.activities.get(str(phase.get("activity_id", "")), {})
	var bom := _entry_totals(activity.get("costs", []))
	var result := plan_bom_target(state, "%s:%s" % [megastructure_id, phase_id], bom, target_location, horizon_hours)
	result.merge({"target_type":"MEGASTRUCTURE_PHASE", "megastructure_id":megastructure_id, "phase_id":phase_id, "activity_id":activity.get("id", ""), "phase_kind":phase.get("kind", ""), "site_requirements":simulation.megastructure_effective_site_requirements(state, phase), "completion_site_effects":phase.get("completion_site_effects", {}).duplicate(true)}, true)
	return result


func _entry_totals(entries: Array) -> Dictionary:
	var result := {}
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var item_id := str(entry.get("item", ""))
		result[item_id] = float(result.get(item_id, 0.0)) + float(entry.get("quantity", 0.0))
	return result


func _expand_requirement(state: SpaceGameState, item_id: String, rate: float, location_id: String, required: Dictionary, method_cycles: Dictionary, selections: Dictionary, external_credits: Array, stack: Array) -> void:
	required[item_id] = float(required.get(item_id, 0.0)) + rate
	if rate <= 0.0:
		return
	if stack.has(item_id):
		if not external_credits.has(item_id):
			external_credits.append(item_id)
		return
	var method := _preferred_method(state, item_id, location_id)
	if method.is_empty():
		return
	var output_quantity := 0.0
	for output_value in method.get("outputs", []):
		var output := output_value as Dictionary
		if str(output.get("item", "")) == item_id:
			output_quantity += float(output.get("quantity", 0))
	if output_quantity <= 0.0:
		return
	var cycles := rate / output_quantity
	var method_id := str(method.get("id", ""))
	method_cycles[method_id] = float(method_cycles.get(method_id, 0.0)) + cycles
	selections[item_id] = method_id
	var next_stack := stack.duplicate()
	next_stack.append(item_id)
	for input_value in method.get("inputs", []):
		var input := input_value as Dictionary
		_expand_requirement(state, str(input.get("item", "")), float(input.get("quantity", 0)) * cycles, location_id, required, method_cycles, selections, external_credits, next_stack)


func _preferred_method(state: SpaceGameState, item_id: String, location_id: String) -> Dictionary:
	var candidates: Array = []
	for recipe_value in content.factory_recipes.values():
		var recipe := recipe_value as Dictionary
		if recipe.get("outputs", []).any(func(output): return str((output as Dictionary).get("item", "")) == item_id):
			var candidate := _recipe_with_building(str(recipe.get("id", "")))
			if not candidate.is_empty():
				candidates.append(candidate)
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a, b): return float(a.get("duration_seconds", 1.0)) < float(b.get("duration_seconds", 1.0)) if float(a.get("duration_seconds", 1.0)) != float(b.get("duration_seconds", 1.0)) else str(a.get("id", "")) < str(b.get("id", "")))
	return candidates[0]


func trace_bottleneck(state: SpaceGameState, product_id: String, location_id: String, target_rate: float = 0.0) -> Dictionary:
	var analysis := current_economy_analysis(state, location_id)
	var rows := {}
	for row_value in analysis.get("products", []):
		rows[str((row_value as Dictionary).get("product_id", ""))] = row_value
	var chain: Array = [{"kind":"PRODUCT", "id":product_id}]
	var current_id := product_id
	var visited := {}
	var primary := "CAPACITY_SHORTAGE"
	while not visited.has(current_id):
		visited[current_id] = true
		var row: Dictionary = rows.get(current_id, {})
		if not row.get("blocked_sources", []).is_empty():
			var blocked: Dictionary = row.get("blocked_sources", [])[0]
			chain.append({"kind":"ENTITY", "id":blocked.get("source_id", ""), "world_id":blocked.get("world_id", "")})
			var blocker: Dictionary = blocked.get("blocker", {})
			primary = str(blocker.get("primary_reason", "CAPACITY_SHORTAGE"))
			if blocker.has("item_id"):
				current_id = str(blocker.get("item_id", ""))
				chain.append({"kind":"PRODUCT", "id":current_id})
				continue
			chain.append({"kind":"CONSTRAINT", "id":primary, "details":blocker})
			break
		var method := _preferred_method(state, current_id, location_id)
		if method.is_empty():
			var source_transport := _known_source_transport(state, current_id, location_id)
			if source_transport.is_empty():
				primary = "NO_FIXED_DEPOSIT" if _has_resource_source(state, current_id) else "NO_FACTORY_RECIPE"
				chain.append({"kind":"CONSTRAINT", "id":primary})
				break
			var geography: Dictionary = extraction_capacity_analysis(state, {current_id:target_rate}).get("products", {}).get(current_id, {})
			primary = "EXTRACTION_CAPACITY_SHORTAGE" if target_rate > float(geography.get("installed_capacity", 0.0)) + 0.000001 else "LOGISTICS_CAPACITY_SHORTAGE"
			chain.append({"kind":"DEPOSIT", "id":source_transport.get("deposit_id", ""), "world_id":source_transport.get("world_id", ""), "location_id":source_transport.get("origin", ""), "mapped_potential":source_transport.get("mapped_potential", 0.0)})
			chain.append({"kind":"WORLD", "id":source_transport.get("world_id", ""), "location_id":source_transport.get("origin", "")})
			var route_ids: Array = source_transport.get("route_ids", [])
			var nodes: Array = source_transport.get("nodes", [])
			for index in route_ids.size():
				var route_id := str(route_ids[index])
				var route_snapshot: Dictionary = source_transport.get("route_snapshots", {}).get(route_id, {})
				chain.append({"kind":"ROUTE", "id":route_id, "capacity_per_hour":float(route_snapshot.get("capacity_per_minute", 0.0)) * 60.0, "utilization":route_snapshot.get("utilization", 0.0)})
				if index + 1 < nodes.size() - 1:
					chain.append({"kind":"HUB", "id":nodes[index + 1]})
			chain.append({"kind":"DESTINATION", "id":location_id})
			if not bool(source_transport.get("service_available", false)):
				primary = "LOGISTICS_ROUTE_UNAVAILABLE"
			elif float(source_transport.get("bottleneck_capacity_per_hour", 0.0)) + 0.000001 < target_rate * float(content.item_freight_profile(current_id).get("freight_units", 1.0)):
				primary = "LOGISTICS_CAPACITY_SHORTAGE"
			break
		chain.append({"kind":"RECIPE", "id":method.get("id", "")})
		var critical_input := ""
		var inputs: Array = method.get("inputs", []).duplicate(true)
		inputs.sort_custom(func(a, b): return str((a as Dictionary).get("item", "")) < str((b as Dictionary).get("item", "")))
		for input_value in inputs:
			var input_id := str((input_value as Dictionary).get("item", ""))
			var input_row: Dictionary = rows.get(input_id, {})
			if float(input_row.get("net_rate", 0.0)) < -0.000001 or int(input_row.get("stock", 0)) <= 0:
				critical_input = input_id
				break
		if not critical_input.is_empty():
			current_id = critical_input
			chain.append({"kind":"PRODUCT", "id":current_id})
			primary = "INPUT_SHORTAGE"
			continue
		var building_id := str(method.get("building_definition_id", ""))
		primary = "MISSING_FACTORY_ENTITY" if _factory_entity_count(state, location_id, building_id, str(method.get("id", ""))) <= 0 else "FACTORY_SATURATED"
		chain.append({"kind":"FACTORY_BUILDING", "id":building_id})
		break
	return {"product_id":product_id, "target_rate":target_rate, "actual_rate":float(rows.get(product_id, {}).get("production_rate", 0.0)), "primary_bottleneck":primary, "shortest_chain":chain}


func _planned_storage(required: Dictionary) -> Dictionary:
	var result := {}
	for item_id_value in required.keys():
		var item_id := str(item_id_value)
		var storage_class: String = str(simulation.storage_class_for_item(item_id))
		result[storage_class] = float(result.get(storage_class, 0.0)) + float(required[item_id]) * simulation.storage_units_for_item(item_id)
	return result


func _planned_logistics(state: SpaceGameState, location_id: String, required: Dictionary) -> Array:
	var result: Array = []
	var item_ids: Array = required.keys()
	item_ids.sort()
	for item_id_value in item_ids:
		var item_id := str(item_id_value)
		if not _preferred_method(state, item_id, location_id).is_empty() or not _has_resource_source(state, item_id):
			continue
		var source_transport := _known_source_transport(state, item_id, location_id)
		if source_transport.is_empty() or str(source_transport.get("origin", "")) == location_id:
			continue
		var freight_profile: Dictionary = content.item_freight_profile(item_id)
		var fallback_units := float(freight_profile.get("freight_units", 1.0))
		var cargo_mass_per_item := float(freight_profile.get("cargo_mass", freight_profile.get("mass_per_unit", freight_profile.get("mass", fallback_units))))
		var cargo_volume_per_item := float(freight_profile.get("cargo_volume", freight_profile.get("volume_per_unit", freight_profile.get("volume", fallback_units))))
		result.append({"product_id":item_id, "source_deposit_id":source_transport.get("deposit_id", ""), "source_world_id":source_transport.get("world_id", ""), "origin":source_transport.get("origin", ""), "destination":location_id, "required_rate":required[item_id], "cargo_mass_per_hour":float(required[item_id]) * cargo_mass_per_item, "cargo_volume_per_hour":float(required[item_id]) * cargo_volume_per_item, "current_route_capacity":source_transport.get("bottleneck_capacity_per_hour", 0.0), "lead_time_ms":source_transport.get("lead_time_ms", INF), "route_ids":source_transport.get("route_ids", []).duplicate(), "nodes":source_transport.get("nodes", []).duplicate(), "potential_congestion":"ROUTE_UNAVAILABLE" if not bool(source_transport.get("service_available", false)) else "ROUTE_CAPACITY"})
	return result


func extraction_capacity_analysis(state: SpaceGameState, requirements: Dictionary) -> Dictionary:
	var products := {}
	for product_id_value in requirements.keys():
		var product_id := str(product_id_value)
		var deposits: Array = []
		var mapped_potential := 0.0
		var installed_capacity := 0.0
		for world_id_value in state.factory_worlds.keys():
			var world_id := str(world_id_value)
			var world: Dictionary = state.factory_worlds.get(world_id_value, {})
			for entity_value in world.get("entities", {}).values():
				var deposit := entity_value as Dictionary
				if str(deposit.get("kind", "")) != "DEPOSIT" or str(deposit.get("resource_id", "")) != product_id:
					continue
				var potential := _deposit_mapped_potential_per_hour(deposit)
				var extractor_ids: Array[String] = []
				var deposit_installed := 0.0
				for link_value in world.get("links", {}).values():
					var link := link_value as Dictionary
					if str(link.get("kind", "")) != "RESOURCE" or str(link.get("source_id", "")) != str(deposit.get("id", "")):
						continue
					var extractor: Dictionary = world.get("entities", {}).get(str(link.get("target_id", "")), {})
					extractor_ids.append(str(extractor.get("id", "")))
					deposit_installed += maxf(0.0, float(extractor.get("actual_rate", 0.0))) * 3600.0
				mapped_potential += potential
				installed_capacity += deposit_installed
				deposits.append({"deposit_id":str(deposit.get("id", "")), "world_id":world_id, "location_id":str(world.get("location_id", "")), "resource_id":product_id, "grade":float(deposit.get("grade", 1.0)), "mapped_potential":potential, "installed_capacity":deposit_installed, "extractor_ids":extractor_ids})
		var required_rate := maxf(0.0, float(requirements.get(product_id, 0.0)))
		if deposits.is_empty():
			continue
		var solutions: Array[String] = []
		if required_rate > installed_capacity + 0.000001:
			solutions.append("PLACE_EXTRACTOR" if installed_capacity <= 0.000001 else "EXPAND_EXTRACTOR_COVERAGE")
			if mapped_potential <= installed_capacity + 0.000001:
				solutions.append("MAP_ADDITIONAL_DEPOSITS")
			solutions.append("CONNECT_POWER_AND_CARGO")
		products[product_id] = {"required_rate":required_rate, "mapped_potential":mapped_potential, "installed_capacity":installed_capacity, "shortfall":maxf(0.0, required_rate - installed_capacity), "deposits":deposits, "potential_solutions":solutions}
	return {"products":products, "read_only":true}


func _best_known_source_lead_time(state: SpaceGameState, item_id: String, destination: String) -> float:
	return float(_known_source_transport(state, item_id, destination).get("lead_time_ms", INF))


func _has_resource_source(state: SpaceGameState, item_id: String) -> bool:
	for world_value in state.factory_worlds.values():
		for entity_value in (world_value as Dictionary).get("entities", {}).values():
			var entity := entity_value as Dictionary
			if str(entity.get("kind", "")) == "DEPOSIT" and str(entity.get("resource_id", "")) == item_id:
				return true
	return false


func _known_source_transport(state: SpaceGameState, item_id: String, destination: String) -> Dictionary:
	var candidates: Array = []
	for world_id_value in state.factory_worlds.keys():
		var world_id := str(world_id_value)
		var world: Dictionary = state.factory_worlds.get(world_id_value, {})
		var origin := str(world.get("location_id", ""))
		for entity_value in world.get("entities", {}).values():
			var deposit := entity_value as Dictionary
			if str(deposit.get("kind", "")) != "DEPOSIT" or str(deposit.get("resource_id", "")) != item_id:
				continue
			if not state.has_location(origin) or not state.has_location(destination):
				continue
			var path: Dictionary = simulation.logistics._shortest_path(state, origin, destination, item_id)
			var service_available := origin == destination or not path.is_empty()
			if path.is_empty():
				path = _topology_shortest_path(state, origin, destination)
			if path.is_empty():
				continue
			var route_snapshots := {}
			var bottleneck_capacity_per_hour := INF
			for route_id_value in path.get("route_ids", []):
				var route_id := str(route_id_value)
				var snapshot: Dictionary = simulation.logistics.service_snapshot(state, route_id)
				route_snapshots[route_id] = snapshot
				bottleneck_capacity_per_hour = minf(bottleneck_capacity_per_hour, float(snapshot.get("capacity_per_minute", 0.0)) * 60.0)
			if path.get("route_ids", []).is_empty():
				bottleneck_capacity_per_hour = INF
			candidates.append({"deposit_id":str(deposit.get("id", "")), "world_id":world_id, "origin":origin, "destination":destination, "nodes":path.get("nodes", [origin, destination]).duplicate(), "route_ids":path.get("route_ids", []).duplicate(), "lead_time_ms":float(path.get("transit_time_ms", simulation.logistics_lead_time_ms(state, origin, destination))), "score":float(path.get("score", path.get("transit_time_ms", INF))), "service_available":service_available, "route_snapshots":route_snapshots, "bottleneck_capacity_per_hour":0.0 if not service_available else bottleneck_capacity_per_hour, "mapped_potential":_deposit_mapped_potential_per_hour(deposit)})
	if candidates.is_empty():
		return {}
	candidates.sort_custom(func(a, b): return float(a.get("score", INF)) < float(b.get("score", INF)) if not is_equal_approx(float(a.get("score", INF)), float(b.get("score", INF))) else str(a.get("deposit_id", "")) < str(b.get("deposit_id", "")))
	return (candidates[0] as Dictionary).duplicate(true)


func _topology_shortest_path(state: SpaceGameState, origin: String, destination: String) -> Dictionary:
	if origin == destination:
		return {"nodes":[origin], "route_ids":[], "transit_time_ms":0.0, "score":0.0}
	var distances := {origin:0.0}
	var previous_nodes := {}
	var previous_routes := {}
	var pending: Array = [origin]
	while not pending.is_empty():
		pending.sort_custom(func(a, b): return float(distances.get(a, INF)) < float(distances.get(b, INF)) if not is_equal_approx(float(distances.get(a, INF)), float(distances.get(b, INF))) else str(a) < str(b))
		var current := str(pending.pop_front())
		if current == destination:
			break
		var route_ids: Array = content.logistics_routes.keys()
		route_ids.sort()
		for route_id_value in route_ids:
			var route_id := str(route_id_value)
			var route: Dictionary = content.logistics_routes.get(route_id, {})
			var route_from := str(route.get("from", ""))
			var route_to := str(route.get("to", ""))
			var neighbor := ""
			if route_from == current:
				neighbor = route_to
			elif bool(route.get("bidirectional", false)) and route_to == current:
				neighbor = route_from
			if neighbor.is_empty() or not state.has_location(neighbor):
				continue
			var candidate := float(distances.get(current, INF)) + float(route.get("transit_time_ms", 0.0))
			if candidate + 0.000001 < float(distances.get(neighbor, INF)):
				distances[neighbor] = candidate
				previous_nodes[neighbor] = current
				previous_routes[neighbor] = route_id
				if not pending.has(neighbor):
					pending.append(neighbor)
	if not distances.has(destination):
		return {}
	var reversed_nodes: Array = [destination]
	var reversed_routes: Array = []
	var cursor := destination
	while cursor != origin:
		reversed_routes.append(str(previous_routes.get(cursor, "")))
		cursor = str(previous_nodes.get(cursor, ""))
		if cursor.is_empty():
			return {}
		reversed_nodes.append(cursor)
	reversed_nodes.reverse()
	reversed_routes.reverse()
	return {"nodes":reversed_nodes, "route_ids":reversed_routes, "transit_time_ms":distances[destination], "score":distances[destination]}


func _compatible_building_ids(recipe_id: String) -> Array:
	var result: Array = []
	for building_id_value in content.factory_buildings.keys():
		var building_id := str(building_id_value)
		var definition: Dictionary = content.factory_buildings.get(building_id, {})
		if str(definition.get("kind", "")) == "MACHINE" and definition.get("recipe_ids", []).has(recipe_id):
			result.append(building_id)
	result.sort()
	return result


func _recipe_with_building(recipe_id: String) -> Dictionary:
	var recipe: Dictionary = content.factory_recipes.get(recipe_id, {})
	var building_ids := _compatible_building_ids(recipe_id)
	if recipe.is_empty() or building_ids.is_empty():
		return {}
	var result := recipe.duplicate(true)
	result["building_definition_id"] = str(building_ids[0])
	return result


func _factory_entity_count(state: SpaceGameState, location_id: String, building_id: String, recipe_id: String = "") -> int:
	var result := 0
	for world_value in state.factory_worlds.values():
		var world := world_value as Dictionary
		if str(world.get("location_id", "")) != location_id:
			continue
		for entity_value in world.get("entities", {}).values():
			var entity := entity_value as Dictionary
			if str(entity.get("definition_id", "")) != building_id:
				continue
			if not recipe_id.is_empty() and str(entity.get("recipe_id", "")) != recipe_id:
				continue
			result += 1
	return result


func _deposit_for_extractor(world: Dictionary, extractor_id: String) -> Dictionary:
	for link_value in world.get("links", {}).values():
		var link := link_value as Dictionary
		if str(link.get("kind", "")) == "RESOURCE" and str(link.get("target_id", "")) == extractor_id:
			return world.get("entities", {}).get(str(link.get("source_id", "")), {})
	return {}


func _deposit_mapped_potential_per_hour(deposit: Dictionary) -> float:
	var size: Dictionary = deposit.get("footprint", {}).get("size", {})
	var area := maxi(0, int(size.get("x", 0))) * maxi(0, int(size.get("y", 0)))
	return maxf(0.0, float(deposit.get("potential_density", 0.0))) * float(area) * 3600.0


func _status_rank(status: String) -> int:
	match status:
		"CRITICAL": return 5
		"TIGHT": return 4
		"STORAGE_FULL": return 3
		"SURPLUS": return 2
		_: return 1
