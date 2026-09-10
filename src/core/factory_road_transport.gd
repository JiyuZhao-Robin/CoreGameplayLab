class_name FactoryRoadTransport
extends RefCounted

## Deterministic, timed local logistics for PLANET_SHARED_ROADS worlds.
## road_shipments is the only persisted in-transit custody: source cargo is
## removed before a job is created and destination cargo is added on arrival.

const EPSILON := 0.000001
const LOCATION_SOURCE_KIND := "WAREHOUSE"
const ENTITY_SOURCE_KIND := "ENTITY"
const WAREHOUSE_DESTINATION_KIND := "WAREHOUSE"
const ENTITY_DESTINATION_KIND := "ENTITY"


static func normalize_shipments(value: Variant, world: Dictionary) -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	for key_value in value.keys():
		var raw: Variant = value.get(key_value)
		if raw is not Dictionary:
			continue
		var job := (raw as Dictionary).duplicate(true)
		var job_id := str(job.get("id", key_value))
		var item_id := str(job.get("item_id", ""))
		var cargo_value: Variant = job.get("cargo", {})
		var cargo: Dictionary = _positive_manifest((cargo_value as Dictionary) if cargo_value is Dictionary else {})
		if job_id.is_empty() or item_id.is_empty() or int(cargo.get(item_id, 0)) <= 0:
			continue
		var target_id := str(job.get("target_id", ""))
		var destination_kind := str(job.get("destination_kind", "")).to_upper()
		if destination_kind not in [WAREHOUSE_DESTINATION_KIND, ENTITY_DESTINATION_KIND]:
			destination_kind = WAREHOUSE_DESTINATION_KIND if str(world.get("entities", {}).get(target_id, {}).get("kind", "")) == "STORAGE" else ENTITY_DESTINATION_KIND
		job["id"] = job_id
		job["item_id"] = item_id
		job["cargo"] = cargo
		job["source_id"] = str(job.get("source_id", ""))
		job["source_kind"] = str(job.get("source_kind", ENTITY_SOURCE_KIND)).to_upper()
		job["target_id"] = target_id
		job["destination_kind"] = destination_kind
		job["remaining_ms"] = maxf(0.0, float(job.get("remaining_ms", job.get("travel_ms", 0.0))))
		job["travel_ms"] = maxf(0.0, float(job.get("travel_ms", job.get("remaining_ms", 0.0))))
		job["path_tiles"] = job.get("path_tiles", []).duplicate(true) if job.get("path_tiles", []) is Array else []
		job["distance_tiles"] = maxi(0, int(job.get("distance_tiles", 0)))
		job["status"] = str(job.get("status", "IN_TRANSIT"))
		job["road_topology_revision"] = int(job.get("road_topology_revision", -1))
		result[job_id] = job
	return result


static func advance(world: Dictionary, seconds: float, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary = {}, graph: Dictionary = {}) -> Dictionary:
	if str(world.get("logistics_mode", "PLANET_SHARED_ROADS")) != "PLANET_SHARED_ROADS":
		return {"delivered":0, "created":0, "blocked":0}
	var active_graph := graph if not graph.is_empty() else FactoryRoadNetwork.build_graph(world)
	var delivered := _advance_shipments(world, maxf(0.0, seconds), building_definitions, recipe_definitions, rules, inventory_context, active_graph)
	var created := 0
	created += _route_machine_inputs(world, building_definitions, recipe_definitions, rules, inventory_context, active_graph)
	created += _route_producer_outputs(world, building_definitions, recipe_definitions, rules, inventory_context, active_graph)
	var blocked := 0
	for job_value in world.get("road_shipments", {}).values():
		if str((job_value as Dictionary).get("status", "")) in ["BLOCKED_PATH", "BLOCKED_TARGET", "BLOCKED_TARGET_FULL", "BLOCKED_MANIFEST"]:
			blocked += 1
	return {"delivered":delivered, "created":created, "blocked":blocked}


static func queue(world: Dictionary, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary = {}, graph: Dictionary = {}) -> int:
	if str(world.get("logistics_mode", "PLANET_SHARED_ROADS")) != "PLANET_SHARED_ROADS":
		return 0
	var active_graph := graph if not graph.is_empty() else FactoryRoadNetwork.build_graph(world)
	return _route_machine_inputs(world, building_definitions, recipe_definitions, rules, inventory_context, active_graph) + _route_producer_outputs(world, building_definitions, recipe_definitions, rules, inventory_context, active_graph)


static func logistics_snapshot(world: Dictionary, rules: Dictionary, graph: Dictionary = {}) -> Dictionary:
	# Capacity is the actual number of concurrent courier slots, not an invented
	# items/second rate independent of trip distance and loading time.
	var active_graph := graph if not graph.is_empty() else FactoryRoadNetwork.build_graph(world)
	var capacity := 0.0
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		if str(entity.get("kind", "")) in ["MACHINE", "EXTRACTOR"] and bool(FactoryRoadNetwork.entity_access(world, entity, active_graph).get("road_connected", false)):
			capacity += maxi(1, int(rules.get("road_couriers_per_building", 1)))
	capacity = minf(capacity, maxi(1, int(rules.get("road_max_active_shipments", 64))))
	var required := 0.0
	var active := 0
	for job_value in world.get("road_shipments", {}).values():
		var job := job_value as Dictionary
		var cargo: Dictionary = job.get("cargo", {}) if job.get("cargo", {}) is Dictionary else {}
		var quantity := _dictionary_total(cargo)
		if quantity <= 0:
			continue
		active += 1
		required += 1.0
	return {
		"capacity":capacity,
		"required":required,
		"utilization":0.0 if capacity <= EPSILON else clampf(required / capacity, 0.0, 1.0),
		"active_shipments":active,
		"capacity_unit":"CONCURRENT_COURIERS"
	}


## Read-only v1 presentation extension. Never expose mutable job dictionaries
## or estimate delivery by altering the authoritative transport clock.
static func workspace_shipments(world: Dictionary, rules: Dictionary) -> Array:
	var result: Array = []
	var ids: Array = world.get("road_shipments", {}).keys()
	ids.sort()
	for id_value in ids:
		var job: Dictionary = world["road_shipments"][id_value]
		var remaining := maxf(0.0, float(job.get("remaining_ms", 0.0)))
		var travel := maxf(EPSILON, float(job.get("travel_ms", 0.0)))
		var loading := maxf(0.0, float(job.get("loading_remaining_ms", 0.0)))
		var status := str(job.get("status", "IN_TRANSIT"))
		var blocked := status.begins_with("BLOCKED_")
		var phase := "TRAVEL"
		var progress := clampf(1.0 - remaining / travel, 0.0, 1.0)
		var path_progress := _shipment_path_progress(world, job.get("path_tiles", []), progress, rules)
		var phase_progress := progress
		if blocked:
			phase = "BLOCKED"
		elif str(job.get("source_kind", "")) == LOCATION_SOURCE_KIND and loading > EPSILON:
			phase = "LOADING"
		elif remaining <= EPSILON:
			phase = "UNLOADING"
		if phase in ["LOADING", "UNLOADING"]:
			phase_progress = clampf(1.0 - loading / maxf(EPSILON, float(rules.get("road_loading_seconds", 1.0)) * 1000.0), 0.0, 1.0)
		result.append({
			"id":str(job.get("id", id_value)),
			"source_id":str(job.get("source_id", "")), "target_id":str(job.get("target_id", "")),
			"source_kind":str(job.get("source_kind", "")), "destination_kind":str(job.get("destination_kind", "")),
			"item_id":str(job.get("item_id", "")), "quantity":_job_quantity(job),
			"cargo":job.get("cargo", {}).duplicate(true), "status":status, "phase":phase,
			"travel_progress":progress, "phase_progress":phase_progress,
			"path_progress":path_progress,
			# Loading-bay queue delays are unknown: this is remaining work, not a
			# promise of arrival. A blocked job has no meaningful ETA.
			"eta_ms":-1.0 if blocked else remaining + loading,
			"remaining_ms":remaining, "loading_remaining_ms":loading,
			"position":_shipment_position(job.get("path_tiles", []), path_progress),
			"path_tiles":job.get("path_tiles", []).duplicate(true)
		})
	return result


static func _shipment_path_progress(world: Dictionary, path: Array, time_progress: float, rules: Dictionary) -> float:
	if path.size() < 2:
		return 0.0
	var tier1 := maxf(EPSILON, float(rules.get("road_tier1_speed_tiles_per_second", 4.0)))
	var tier2 := maxf(tier1, float(rules.get("road_tier2_speed_tiles_per_second", 8.0)))
	var durations: Array[float] = []
	var total := 0.0
	for index in range(1, path.size()):
		var tier := int(world.get("roads", {}).get(str(path[index]), {}).get("tier", 1))
		var duration := 1.0 / (tier1 if tier <= 1 else tier2)
		durations.append(duration)
		total += duration
	var elapsed := clampf(time_progress, 0.0, 1.0) * total
	for index in range(durations.size()):
		if elapsed <= durations[index]:
			return (float(index) + elapsed / durations[index]) / durations.size()
		elapsed -= durations[index]
	return 1.0


static func _shipment_position(path: Array, progress: float) -> Dictionary:
	if path.is_empty():
		return {}
	var offset := clampf(progress, 0.0, 1.0) * maxi(0, path.size() - 1)
	var index := mini(int(floorf(offset)), path.size() - 1)
	var from_parts := str(path[index]).split(",")
	var to_parts := str(path[mini(index + 1, path.size() - 1)]).split(",")
	if from_parts.size() != 2 or to_parts.size() != 2:
		return {}
	var from := Vector2(float(from_parts[0]), float(from_parts[1])) + Vector2.ONE * 0.5
	var to := Vector2(float(to_parts[0]), float(to_parts[1])) + Vector2.ONE * 0.5
	var position := from.lerp(to, offset - floorf(offset))
	return {"x":position.x, "y":position.y}


static func _advance_shipments(world: Dictionary, seconds: float, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary, graph: Dictionary) -> int:
	var completed: Array[String] = []
	var delivered := 0
	var loading_budget := {}
	var job_ids: Array = world.get("road_shipments", {}).keys()
	job_ids.sort()
	for job_id_value in job_ids:
		var job_id := str(job_id_value)
		var job: Dictionary = world.get("road_shipments", {}).get(job_id, {})
		if job.is_empty():
			continue
		# Dispatch creates single-item manifests. Preserve malformed multi-item
		# custody intact instead of delivering one key then deleting the others.
		var cargo: Dictionary = job.get("cargo", {})
		if cargo.size() != 1 or not cargo.has(str(job.get("item_id", ""))):
			job["status"] = "BLOCKED_MANIFEST"
			continue
		var source: Dictionary = world.get("entities", {}).get(str(job.get("source_id", "")), {})
		var target: Dictionary = world.get("entities", {}).get(str(job.get("target_id", "")), {})
		var destination_kind := str(job.get("destination_kind", ENTITY_DESTINATION_KIND))
		if destination_kind == ENTITY_DESTINATION_KIND and target.is_empty():
			job["status"] = "BLOCKED_TARGET"
			continue
		if destination_kind == WAREHOUSE_DESTINATION_KIND and (target.is_empty() or str(target.get("kind", "")) != "STORAGE"):
			job["status"] = "BLOCKED_TARGET"
			continue
		if destination_kind == ENTITY_DESTINATION_KIND and not _entity_can_input(target, str(job.get("item_id", "")), recipe_definitions, building_definitions, world, graph):
			# Recipe changes must not strand a loaded courier forever. Return the
			# actual cargo through a reachable warehouse using another timed trip.
			var fallback := _best_warehouse_for_output(world, str(job.get("source_id", "")), str(job.get("item_id", "")), building_definitions, recipe_definitions, rules, inventory_context, graph)
			if fallback.is_empty() or int(fallback.get("available", 0)) < _job_quantity(job):
				job["status"] = "BLOCKED_TARGET"
				continue
			job["target_id"] = str(fallback["target_id"])
			job["destination_kind"] = WAREHOUSE_DESTINATION_KIND
			destination_kind = WAREHOUSE_DESTINATION_KIND
			target = world.get("entities", {}).get(str(job["target_id"]), {})
			job["source_kind"] = ENTITY_SOURCE_KIND
			# The same loaded vehicle returns the rejected cargo. Retain its
			# original owner/slot, including while waiting at a full warehouse.
			job["loading_remaining_ms"] = maxf(0.0, float(rules.get("road_loading_seconds", 1.0))) * 1000.0
			_apply_route(job, fallback.get("path", {}), world, rules)
		var route: Dictionary = {}
		var route_is_current := int(job.get("road_topology_revision", -1)) == int(world.get("topology_revision", 0)) and FactoryRoadNetwork.path_tiles_valid(world, source, target, job.get("path_tiles", []), graph)
		if route_is_current:
			route = {"ok":true, "path_tiles":job.get("path_tiles", []).duplicate(true), "distance_tiles":maxi(0, int(job.get("distance_tiles", 0)))}
		else:
			route = FactoryRoadNetwork.path_between(world, source, target, graph)
		if not bool(route.get("ok", false)):
			job["status"] = "BLOCKED_PATH"
			continue
		if int(route.get("distance_tiles", 0)) > maxi(1, int(rules.get("road_max_service_distance_tiles", 256))):
			job["status"] = "BLOCKED_PATH"
			continue
		if not route_is_current:
			var same_path: bool = job.get("path_tiles", []) == route.get("path_tiles", [])
			var fraction := clampf(float(job.get("remaining_ms", 0.0)) / maxf(EPSILON, float(job.get("travel_ms", 1.0))), 0.0, 1.0)
			_apply_route(job, route, world, rules)
			if same_path:
				job["remaining_ms"] = float(job["travel_ms"]) * fraction
		if str(job.get("status", "")) == "BLOCKED_TARGET_FULL" and not _destination_can_accept(job, target, building_definitions, recipe_definitions, inventory_context, world, graph):
			continue
		job["status"] = "IN_TRANSIT"
		var available_ms := seconds * 1000.0
		if str(job.get("source_kind", "")) == LOCATION_SOURCE_KIND:
			available_ms -= _advance_loading(job, str(job.get("source_id", "")), available_ms, loading_budget, seconds, building_definitions, world, rules)
			if float(job.get("loading_remaining_ms", 0.0)) > EPSILON:
				job["status"] = "WAITING_LOADING"
				continue
		var moving_ms := minf(available_ms, float(job.get("remaining_ms", 0.0)))
		job["remaining_ms"] = maxf(0.0, float(job.get("remaining_ms", 0.0)) - moving_ms)
		available_ms -= moving_ms
		if float(job.get("remaining_ms", 0.0)) > EPSILON:
			continue
		if destination_kind == WAREHOUSE_DESTINATION_KIND:
			_advance_loading(job, str(job.get("target_id", "")), available_ms, loading_budget, seconds, building_definitions, world, rules)
			if float(job.get("loading_remaining_ms", 0.0)) > EPSILON:
				job["status"] = "WAITING_LOADING"
				continue
		var quantity := _job_quantity(job)
		if quantity <= 0:
			completed.append(job_id)
			continue
		if not _deliver_job(job, target, building_definitions, recipe_definitions, inventory_context, world, graph):
			job["status"] = "BLOCKED_TARGET_FULL"
			job["remaining_ms"] = 0.0
			continue
		delivered += quantity
		completed.append(job_id)
	for job_id in completed:
		world["road_shipments"].erase(job_id)
	return delivered


static func _advance_loading(job: Dictionary, warehouse_id: String, available_ms: float, budgets: Dictionary, seconds: float, definitions: Dictionary, world: Dictionary, rules: Dictionary) -> float:
	var warehouse: Dictionary = world.get("entities", {}).get(warehouse_id, {})
	var definition: Dictionary = definitions.get(str(warehouse.get("definition_id", "")), {})
	if not budgets.has(warehouse_id):
		budgets[warehouse_id] = seconds * 1000.0 * maxi(1, int(definition.get("loading_bays", rules.get("road_warehouse_loading_bays", 2))))
	var work := minf(maxf(0.0, available_ms), minf(float(budgets[warehouse_id]), maxf(0.0, float(job.get("loading_remaining_ms", 0.0)))))
	budgets[warehouse_id] = float(budgets[warehouse_id]) - work
	job["loading_remaining_ms"] = maxf(0.0, float(job.get("loading_remaining_ms", 0.0)) - work)
	return work


static func _route_machine_inputs(world: Dictionary, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary, graph: Dictionary) -> int:
	var created := 0
	var target_ids := _fair_entity_ids(world)
	for target_id_value in target_ids:
		var target_id := str(target_id_value)
		var target: Dictionary = world.get("entities", {}).get(target_id, {})
		if str(target.get("status", "")) == "UNDER_CONSTRUCTION":
			continue
		var definition: Dictionary = building_definitions.get(str(target.get("definition_id", "")), {})
		if definition.is_empty():
			continue
		var recipe: Dictionary = recipe_definitions.get(str(target.get("recipe_id", "")), {})
		if not recipe.is_empty() and _definition_supports_recipe(definition, recipe):
			var recipe_input_total := 0
			for entry in recipe.get("inputs", []):
				recipe_input_total += maxi(0, int(entry.get("quantity", 0)))
			var fitting_cycles := maxi(1, int(float(definition.get("input_capacity", 0)) / maxf(1.0, recipe_input_total)))
			for input_value in recipe.get("inputs", []):
				var input := input_value as Dictionary
				var item_id := str(input.get("item", ""))
				if item_id.is_empty():
					continue
				var buffer_cycles := mini(fitting_cycles, maxi(1, int(rules.get("road_input_buffer_cycles", 1))))
				var target_quantity := maxi(1, int(input.get("quantity", 1))) * buffer_cycles
				var required := _machine_input_demand(world, target_id, item_id, target_quantity, building_definitions)
				created += _queue_target_input(world, target_id, item_id, required, building_definitions, recipe_definitions, rules, inventory_context, graph)

		# Fuel-driven power is an actual road-delivered material input, rather than
		# an implicit infinite generator reservoir.  Select one reachable fuel at a
		# time so a generator does not reserve its entire buffer for every supported
		# fuel type.
		var fuel_item := _select_road_fuel_item(world, target_id, target, definition, recipe_definitions, rules, inventory_context, graph)
		if not fuel_item.is_empty():
			var fuel_target := mini(maxi(1, int(definition.get("input_capacity", 0))), maxi(1, int(rules.get("road_fuel_buffer_items", 1))))
			var fuel_required := _machine_input_demand(world, target_id, fuel_item, fuel_target, building_definitions)
			var fuel_jobs := _queue_target_input(world, target_id, fuel_item, fuel_required, building_definitions, recipe_definitions, rules, inventory_context, graph)
			if fuel_jobs > 0:
				target["fuel_item_id"] = fuel_item
				created += fuel_jobs

		# A coater is an inline production modifier in the source design.  Root
		# derives `world.spray_services` from the live road graph; transport merely
		# validates that reference and carries the selected finite spray item into
		# the serviced machine's existing input buffer.
		var spray_item := _spray_service_item(world, target_id, target, definition, building_definitions, recipe_definitions, rules, graph)
		if not spray_item.is_empty():
			var spray_target := mini(maxi(1, int(definition.get("input_capacity", 0))), maxi(1, int(rules.get("road_spray_buffer_items", 1))))
			var spray_required := _machine_input_demand(world, target_id, spray_item, spray_target, building_definitions)
			created += _queue_target_input(world, target_id, spray_item, spray_required, building_definitions, recipe_definitions, rules, inventory_context, graph)
	return created


static func _queue_target_input(world: Dictionary, target_id: String, item_id: String, required: int, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary, graph: Dictionary) -> int:
	var created := 0
	var remaining := maxi(0, required)
	while remaining > 0 and _can_queue(world, rules, target_id):
		var direct := _best_producer_candidate(world, target_id, item_id, building_definitions, recipe_definitions, graph, rules)
		if not direct.is_empty():
			var quantity := mini(remaining, mini(int(direct.get("available", 0)), _cargo_limit(rules)))
			if quantity > 0 and _create_entity_job(world, direct, target_id, item_id, quantity, rules):
				remaining -= quantity
				created += 1
				continue
		var warehouse := _best_warehouse_candidate(world, target_id, item_id, building_definitions, recipe_definitions, rules, inventory_context, graph)
		if warehouse.is_empty():
			break
		var warehouse_quantity := mini(remaining, mini(int(warehouse.get("available", 0)), _cargo_limit(rules)))
		if warehouse_quantity <= 0 or not _create_warehouse_source_job(world, warehouse, target_id, item_id, warehouse_quantity, rules, inventory_context):
			break
		remaining -= warehouse_quantity
		created += 1
	return created


static func _route_producer_outputs(world: Dictionary, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary, graph: Dictionary) -> int:
	var created := 0
	var source_ids := _fair_entity_ids(world)
	for source_id_value in source_ids:
		var source_id := str(source_id_value)
		var source: Dictionary = world.get("entities", {}).get(source_id, {})
		if str(source.get("kind", "")) == "STORAGE" or str(source.get("status", "")) == "UNDER_CONSTRUCTION":
			continue
		var outputs: Dictionary = source.get("outputs", {}) if source.get("outputs", {}) is Dictionary else {}
		var item_ids: Array = outputs.keys()
		item_ids.sort()
		for item_id_value in item_ids:
			var item_id := str(item_id_value)
			if not _entity_can_output(source, item_id, recipe_definitions, building_definitions):
				continue
			while _source_quantity(source, item_id) > 0 and _can_queue(world, rules, source_id):
				var candidate := _best_warehouse_for_output(world, source_id, item_id, building_definitions, recipe_definitions, rules, inventory_context, graph)
				if candidate.is_empty():
					break
				var quantity := mini(_source_quantity(source, item_id), mini(int(candidate.get("available", 0)), _cargo_limit(rules)))
				if quantity <= 0 or not _create_entity_to_warehouse_job(world, source, candidate, source_id, item_id, quantity, rules, inventory_context):
					break
				created += 1
	return created


static func _best_producer_candidate(world: Dictionary, target_id: String, item_id: String, building_definitions: Dictionary, recipe_definitions: Dictionary, graph: Dictionary, rules: Dictionary) -> Dictionary:
	var candidates: Array = []
	var source_ids: Array = world.get("entities", {}).keys()
	source_ids.sort()
	for source_id_value in source_ids:
		var source_id := str(source_id_value)
		var source: Dictionary = world.get("entities", {}).get(source_id, {})
		if str(source.get("kind", "")) == "STORAGE" or str(source.get("status", "")) == "UNDER_CONSTRUCTION" or not _entity_can_output(source, item_id, recipe_definitions, building_definitions):
			continue
		var target: Dictionary = world.get("entities", {}).get(target_id, {})
		var route := FactoryRoadNetwork.path_between(world, source, target, graph)
		if not bool(route.get("ok", false)) or int(route.get("distance_tiles", 0)) > maxi(1, int(rules.get("road_max_service_distance_tiles", 256))):
			continue
		candidates.append({"source_id":source_id, "target_id":target_id, "available":_source_quantity(source, item_id), "distance_tiles":int(route.get("distance_tiles", 0)), "path":route})
	candidates.sort_custom(func(a, b):
		return int(a.get("distance_tiles", 0)) < int(b.get("distance_tiles", 0)) if int(a.get("distance_tiles", 0)) != int(b.get("distance_tiles", 0)) else str(a.get("source_id", "")) < str(b.get("source_id", ""))
	)
	return {} if candidates.is_empty() else candidates[0]


static func _best_warehouse_candidate(world: Dictionary, target_id: String, item_id: String, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary, graph: Dictionary) -> Dictionary:
	var candidates: Array = []
	for storage_id_value in _sorted_entity_ids(world, "STORAGE"):
		var storage_id := str(storage_id_value)
		var storage: Dictionary = world.get("entities", {}).get(storage_id, {})
		if str(storage.get("status", "")) == "UNDER_CONSTRUCTION":
			continue
		var available := _warehouse_available(inventory_context, storage, item_id)
		if available <= 0:
			continue
		var target: Dictionary = world.get("entities", {}).get(target_id, {})
		var route := FactoryRoadNetwork.path_between(world, storage, target, graph)
		if not bool(route.get("ok", false)) or int(route.get("distance_tiles", 0)) > maxi(1, int(rules.get("road_max_service_distance_tiles", 256))):
			continue
		candidates.append({"source_id":storage_id, "target_id":target_id, "available":available, "distance_tiles":int(route.get("distance_tiles", 0)), "path":route})
	candidates.sort_custom(func(a, b):
		return int(a.get("distance_tiles", 0)) < int(b.get("distance_tiles", 0)) if int(a.get("distance_tiles", 0)) != int(b.get("distance_tiles", 0)) else str(a.get("source_id", "")) < str(b.get("source_id", ""))
	)
	return {} if candidates.is_empty() else candidates[0]


static func _best_warehouse_for_output(world: Dictionary, source_id: String, item_id: String, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary, graph: Dictionary) -> Dictionary:
	var candidates: Array = []
	var source: Dictionary = world.get("entities", {}).get(source_id, {})
	for storage_id_value in _sorted_entity_ids(world, "STORAGE"):
		var storage_id := str(storage_id_value)
		var storage: Dictionary = world.get("entities", {}).get(storage_id, {})
		if str(storage.get("status", "")) == "UNDER_CONSTRUCTION":
			continue
		var capacity := _warehouse_destination_capacity(world, storage_id, item_id, building_definitions, inventory_context)
		if capacity <= 0:
			continue
		var route := FactoryRoadNetwork.path_between(world, source, storage, graph)
		if not bool(route.get("ok", false)) or int(route.get("distance_tiles", 0)) > maxi(1, int(rules.get("road_max_service_distance_tiles", 256))):
			continue
		candidates.append({"source_id":source_id, "target_id":storage_id, "available":capacity, "distance_tiles":int(route.get("distance_tiles", 0)), "path":route})
	candidates.sort_custom(func(a, b):
		return int(a.get("distance_tiles", 0)) < int(b.get("distance_tiles", 0)) if int(a.get("distance_tiles", 0)) != int(b.get("distance_tiles", 0)) else str(a.get("target_id", "")) < str(b.get("target_id", ""))
	)
	return {} if candidates.is_empty() else candidates[0]


static func _create_entity_job(world: Dictionary, candidate: Dictionary, target_id: String, item_id: String, quantity: int, rules: Dictionary) -> bool:
	var source_id := str(candidate.get("source_id", ""))
	var source: Dictionary = world.get("entities", {}).get(source_id, {})
	if _source_quantity(source, item_id) < quantity:
		return false
	var route: Dictionary = candidate.get("path", {})
	if not bool(route.get("ok", false)):
		return false
	_remove_source_quantity(source, item_id, quantity)
	var job := _new_job(world, source_id, ENTITY_SOURCE_KIND, target_id, ENTITY_DESTINATION_KIND, item_id, quantity, route, rules)
	world["road_shipments"][str(job.get("id", ""))] = job
	return true


static func _create_warehouse_source_job(world: Dictionary, candidate: Dictionary, target_id: String, item_id: String, quantity: int, rules: Dictionary, inventory_context: Dictionary) -> bool:
	var storage_id := str(candidate.get("source_id", ""))
	var storage: Dictionary = world.get("entities", {}).get(storage_id, {})
	if _warehouse_available(inventory_context, storage, item_id) < quantity:
		return false
	if not _withdraw_warehouse(inventory_context, storage, item_id, quantity):
		return false
	var route: Dictionary = candidate.get("path", {})
	var job := _new_job(world, storage_id, LOCATION_SOURCE_KIND, target_id, ENTITY_DESTINATION_KIND, item_id, quantity, route, rules)
	world["road_shipments"][str(job.get("id", ""))] = job
	return true


static func _create_entity_to_warehouse_job(world: Dictionary, source: Dictionary, candidate: Dictionary, source_id: String, item_id: String, quantity: int, rules: Dictionary, inventory_context: Dictionary) -> bool:
	var route: Dictionary = candidate.get("path", {})
	if not bool(route.get("ok", false)) or _source_quantity(source, item_id) < quantity:
		return false
	if _warehouse_destination_capacity(world, str(candidate.get("target_id", "")), item_id, {}, inventory_context) < quantity:
		return false
	_remove_source_quantity(source, item_id, quantity)
	var job := _new_job(world, source_id, ENTITY_SOURCE_KIND, str(candidate.get("target_id", "")), WAREHOUSE_DESTINATION_KIND, item_id, quantity, route, rules)
	world["road_shipments"][str(job.get("id", ""))] = job
	return true


static func _new_job(world: Dictionary, source_id: String, source_kind: String, target_id: String, destination_kind: String, item_id: String, quantity: int, route: Dictionary, rules: Dictionary) -> Dictionary:
	var job_id := _next_shipment_id(world)
	var job := {
		"id":job_id,
		"source_id":source_id,
		"source_kind":source_kind,
		"target_id":target_id,
		"destination_kind":destination_kind,
		"item_id":item_id,
		"cargo":{item_id:quantity},
		"path_tiles":route.get("path_tiles", []).duplicate(true),
		"distance_tiles":maxi(0, int(route.get("distance_tiles", 0))),
		"travel_ms":0.0,
		"remaining_ms":0.0,
		"status":"IN_TRANSIT",
		"courier_owner_id":source_id if destination_kind == WAREHOUSE_DESTINATION_KIND else target_id,
		"loading_remaining_ms":maxf(0.0, float(rules.get("road_loading_seconds", 1.0))) * 1000.0 if source_kind == LOCATION_SOURCE_KIND or destination_kind == WAREHOUSE_DESTINATION_KIND else 0.0,
		"created_at_ms":float(world.get("elapsed_ms", 0.0))
	}
	_apply_route(job, route, world, rules)
	world["road_dispatch_after"] = str(job["courier_owner_id"])
	return job


static func _apply_route(job: Dictionary, route: Dictionary, world: Dictionary, rules: Dictionary) -> void:
	var distance := maxi(0, int(route.get("distance_tiles", 0)))
	var speed := _route_speed(world, route.get("path_tiles", []), rules)
	var minimum_seconds := maxf(0.05, float(rules.get("road_min_travel_seconds", 0.25)))
	var travel_ms := maxf(minimum_seconds * 1000.0, float(distance) / maxf(EPSILON, speed) * 1000.0)
	job["path_tiles"] = route.get("path_tiles", []).duplicate(true)
	job["distance_tiles"] = distance
	job["travel_ms"] = travel_ms
	job["remaining_ms"] = travel_ms
	job["status"] = "IN_TRANSIT"
	job["road_topology_revision"] = int(world.get("topology_revision", 0))


static func _deliver_job(job: Dictionary, target: Dictionary, building_definitions: Dictionary, recipe_definitions: Dictionary, inventory_context: Dictionary, world: Dictionary = {}, graph: Dictionary = {}) -> bool:
	var item_id := str(job.get("item_id", ""))
	var quantity := _job_quantity(job)
	if quantity <= 0:
		return true
	var destination_kind := str(job.get("destination_kind", ENTITY_DESTINATION_KIND))
	if destination_kind == WAREHOUSE_DESTINATION_KIND:
		if not _deposit_warehouse(inventory_context, target, item_id, quantity, building_definitions):
			return false
		job["cargo"] = {}
		return true
	if not _entity_can_input(target, item_id, recipe_definitions, building_definitions, world, graph):
		return false
	var definition: Dictionary = building_definitions.get(str(target.get("definition_id", "")), {})
	var free := maxi(0, int(definition.get("input_capacity", 0)) - _dictionary_total(target.get("inputs", {})))
	if free < quantity:
		return false
	target["inputs"][item_id] = int(target.get("inputs", {}).get(item_id, 0)) + quantity
	job["cargo"] = {}
	return true


static func _destination_can_accept(job: Dictionary, target: Dictionary, building_definitions: Dictionary, recipe_definitions: Dictionary, inventory_context: Dictionary, world: Dictionary = {}, graph: Dictionary = {}) -> bool:
	var item_id := str(job.get("item_id", ""))
	var quantity := _job_quantity(job)
	if str(job.get("destination_kind", ENTITY_DESTINATION_KIND)) == WAREHOUSE_DESTINATION_KIND:
		return _warehouse_destination_capacity({}, str(target.get("id", "")), item_id, building_definitions, inventory_context) >= quantity
	if not _entity_can_input(target, item_id, recipe_definitions, building_definitions, world, graph):
		return false
	var definition: Dictionary = building_definitions.get(str(target.get("definition_id", "")), {})
	return maxi(0, int(definition.get("input_capacity", 0)) - _dictionary_total(target.get("inputs", {}))) >= quantity


static func _deposit_warehouse(inventory_context: Dictionary, target: Dictionary, item_id: String, quantity: int, building_definitions: Dictionary) -> bool:
	var context_inventory := _context_dictionary(inventory_context, "inventory")
	if not context_inventory.is_empty() or inventory_context.has("inventory"):
		var context_free := _context_dictionary(inventory_context, "free_capacity")
		if maxi(0, int(context_free.get(item_id, 0))) < quantity:
			return false
		context_inventory[item_id] = int(context_inventory.get(item_id, 0)) + quantity
		var available := _context_dictionary(inventory_context, "available")
		available[item_id] = int(available.get(item_id, 0)) + quantity
		context_free[item_id] = int(context_free.get(item_id, 0)) - quantity
		return true
	return false


static func _withdraw_warehouse(inventory_context: Dictionary, storage: Dictionary, item_id: String, quantity: int) -> bool:
	var context_inventory := _context_dictionary(inventory_context, "inventory")
	if not context_inventory.is_empty() or inventory_context.has("inventory"):
		var available := _context_dictionary(inventory_context, "available")
		if int(available.get(item_id, 0)) < quantity or int(context_inventory.get(item_id, 0)) < quantity:
			return false
		context_inventory[item_id] = int(context_inventory.get(item_id, 0)) - quantity
		available[item_id] = int(available.get(item_id, 0)) - quantity
		var free := _context_dictionary(inventory_context, "free_capacity")
		free[item_id] = int(free.get(item_id, 0)) + quantity
		return true
	return false


static func _warehouse_available(inventory_context: Dictionary, storage: Dictionary, item_id: String) -> int:
	var context_inventory := _context_dictionary(inventory_context, "inventory")
	if not context_inventory.is_empty() or inventory_context.has("inventory"):
		return mini(maxi(0, int(context_inventory.get(item_id, 0))), maxi(0, int(_context_dictionary(inventory_context, "available").get(item_id, 0))))
	return 0


static func _warehouse_destination_capacity(world: Dictionary, storage_id: String, item_id: String, building_definitions: Dictionary, inventory_context: Dictionary) -> int:
	var context_free := _context_dictionary(inventory_context, "free_capacity")
	if not context_free.is_empty() or inventory_context.has("free_capacity"):
		var free := maxi(0, int(context_free.get(item_id, 0)))
		for job_value in world.get("road_shipments", {}).values():
			var job := job_value as Dictionary
			if str(job.get("destination_kind", "")) == WAREHOUSE_DESTINATION_KIND and str(job.get("item_id", "")) == item_id:
				free -= _job_quantity(job)
		return maxi(0, free)
	return 0


static func _machine_input_demand(world: Dictionary, target_id: String, item_id: String, target_quantity: int, building_definitions: Dictionary) -> int:
	var target: Dictionary = world.get("entities", {}).get(target_id, {})
	var definition: Dictionary = building_definitions.get(str(target.get("definition_id", "")), {})
	var loaded := int(target.get("inputs", {}).get(item_id, 0))
	var in_flight_item := 0
	var in_flight_total := 0
	for job_value in world.get("road_shipments", {}).values():
		var job := job_value as Dictionary
		if str(job.get("destination_kind", "")) == ENTITY_DESTINATION_KIND and str(job.get("target_id", "")) == target_id:
			var quantity := _job_quantity(job)
			in_flight_total += quantity
			if str(job.get("item_id", "")) == item_id:
				in_flight_item += quantity
	var desired_item_free := maxi(0, target_quantity - loaded - in_flight_item)
	var physical_free := maxi(0, int(definition.get("input_capacity", 0)) - _dictionary_total(target.get("inputs", {})) - in_flight_total)
	return mini(desired_item_free, physical_free)


## Roads move only existing entity output custody.  This intentionally permits
## a POWER/MATRIX/LAUNCH-capable building to return buffered outputs after a
## recipe change, while excluding Location-backed warehouse access points.
static func _entity_can_output(entity: Dictionary, item_id: String, _recipe_definitions: Dictionary, _building_definitions: Dictionary = {}) -> bool:
	return str(entity.get("kind", "")) != "STORAGE" and _source_quantity(entity, item_id) > 0


## All special material inputs remain finite physical buffer entries.  Recipes
## are not limited to legacy MACHINE kind: POWER buildings such as the energy
## exchanger can declare a compatible recipe, fuel generators accept exactly
## their metadata-listed fuels, and proliferator inputs require a valid derived
## road service record.
static func _entity_can_input(entity: Dictionary, item_id: String, recipe_definitions: Dictionary, building_definitions: Dictionary = {}, world: Dictionary = {}, graph: Dictionary = {}) -> bool:
	if entity.is_empty() or item_id.is_empty() or str(entity.get("kind", "")) == "STORAGE":
		return false
	var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
	var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
	if not recipe.is_empty() and _definition_supports_recipe(definition, recipe) and _item_entries(recipe.get("inputs", [])).has(item_id):
		return true
	if _fuel_item_ids(definition).has(item_id):
		return true
	return not world.is_empty() and _spray_service_item(world, str(entity.get("id", "")), entity, definition, building_definitions, recipe_definitions, {}, graph) == item_id


static func _definition_supports_recipe(definition: Dictionary, recipe: Dictionary) -> bool:
	var recipe_id := str(recipe.get("id", ""))
	var allowed_value: Variant = definition.get("recipe_ids", [])
	return not recipe_id.is_empty() and allowed_value is Array and (allowed_value as Array).has(recipe_id)


static func _runtime_metadata(definition: Dictionary) -> Dictionary:
	var metadata: Variant = definition.get("runtime_metadata", {})
	return metadata as Dictionary if metadata is Dictionary else {}


static func _fuel_item_ids(definition: Dictionary) -> Dictionary:
	var result := {}
	var metadata := _runtime_metadata(definition)
	if str(metadata.get("power_mode", "")).to_upper() != "FUEL_GENERATOR":
		return result
	var value: Variant = metadata.get("fuel_item_ids", [])
	if value is Array:
		for item_value in value:
			var item_id := str(item_value)
			if not item_id.is_empty():
				result[item_id] = true
	return result


static func _select_road_fuel_item(world: Dictionary, target_id: String, target: Dictionary, definition: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary, graph: Dictionary) -> String:
	var allowed := _fuel_item_ids(definition)
	if allowed.is_empty():
		return ""
	# Do not mix nine fuels or reserve a second one while any selected fuel is
	# already buffered/in transit.  DSP settlement consumes the selected finite
	# stack and preserves its remaining MJ between ticks.
	for item_id_value in allowed:
		var buffered := maxi(0, int(target.get("inputs", {}).get(str(item_id_value), 0)))
		if buffered > 0 or _target_has_in_flight_item(world, target_id, str(item_id_value)):
			return ""
	var ordered: Array[String] = []
	var selected := str(target.get("fuel_item_id", target.get("dsp_fuel_item_id", "")))
	if allowed.has(selected):
		ordered.append(selected)
	var allowed_ids: Array = allowed.keys()
	allowed_ids.sort()
	for item_id_value in allowed_ids:
		var item_id := str(item_id_value)
		if not ordered.has(item_id):
			ordered.append(item_id)
	for item_id in ordered:
		var target_quantity := mini(maxi(1, int(definition.get("input_capacity", 0))), maxi(1, int(rules.get("road_fuel_buffer_items", 1))))
		if _machine_input_demand(world, target_id, item_id, target_quantity, {str(target.get("definition_id", "")):definition}) <= 0:
			continue
		if _input_source_available(world, target_id, item_id, {str(target.get("definition_id", "")):definition}, recipe_definitions, rules, inventory_context, graph):
			return item_id
	return ""


static func _target_has_in_flight_item(world: Dictionary, target_id: String, item_id: String) -> bool:
	for job_value in world.get("road_shipments", {}).values():
		var job := job_value as Dictionary
		if str(job.get("destination_kind", "")) == ENTITY_DESTINATION_KIND and str(job.get("target_id", "")) == target_id and str(job.get("item_id", "")) == item_id and _job_quantity(job) > 0:
			return true
	return false


static func _input_source_available(world: Dictionary, target_id: String, item_id: String, building_definitions: Dictionary, recipe_definitions: Dictionary, rules: Dictionary, inventory_context: Dictionary, graph: Dictionary) -> bool:
	return not _best_producer_candidate(world, target_id, item_id, building_definitions, recipe_definitions, graph, rules).is_empty() \
		or not _best_warehouse_candidate(world, target_id, item_id, building_definitions, recipe_definitions, rules, inventory_context, graph).is_empty()


## `spray_services` is derived by the integration owner each step; this module
## neither creates records nor chooses a range/tier.  A record is valid only
## while its nominated coater is live and shares a road path with its target.
## Expected shape: `{target_id: {coater_id, enabled, item_id}}`.
static func _spray_service_item(world: Dictionary, target_id: String, target: Dictionary, _definition: Dictionary, building_definitions: Dictionary, _recipe_definitions: Dictionary, rules: Dictionary, graph: Dictionary) -> String:
	var config_value: Variant = target.get("proliferator", {})
	if config_value is not Dictionary:
		return ""
	var config := config_value as Dictionary
	if str(config.get("mode", "NORMAL")).to_upper() not in ["EXTRA", "SPEED"]:
		return ""
	var services_value: Variant = world.get("spray_services", {})
	if services_value is not Dictionary:
		return ""
	var service_value: Variant = (services_value as Dictionary).get(target_id, {})
	if service_value is not Dictionary:
		return ""
	var service := service_value as Dictionary
	if not bool(service.get("enabled", true)):
		return ""
	var item_id := str(config.get("item_id", service.get("item_id", "")))
	if item_id.is_empty() or (service.has("item_id") and str(service.get("item_id", "")) != item_id):
		return ""
	var coater_id := str(service.get("coater_id", ""))
	var coater: Dictionary = world.get("entities", {}).get(coater_id, {})
	if coater_id.is_empty() or coater_id == target_id or coater.is_empty() or str(coater.get("status", "")) == "UNDER_CONSTRUCTION":
		return ""
	var coater_definition: Dictionary = building_definitions.get(str(coater.get("definition_id", "")), {})
	var coater_metadata := _runtime_metadata(coater_definition)
	if str(coater_metadata.get("special_effect_id", "")) != "PROLIFERATOR_SERVICE":
		return ""
	var route := FactoryRoadNetwork.path_between(world, coater, target, graph)
	if not bool(route.get("ok", false)):
		return ""
	if int(route.get("distance_tiles", 0)) > maxi(1, int(rules.get("road_max_service_distance_tiles", 256))):
		return ""
	return item_id


static func _item_entries(entries: Variant) -> Dictionary:
	var result := {}
	if entries is not Array:
		return result
	for value in entries:
		if value is Dictionary:
			var item_id := str((value as Dictionary).get("item", ""))
			if not item_id.is_empty():
				result[item_id] = true
	return result


static func _source_quantity(entity: Dictionary, item_id: String) -> int:
	return maxi(0, int(entity.get("outputs", {}).get(item_id, 0)))


static func _remove_source_quantity(entity: Dictionary, item_id: String, quantity: int) -> void:
	entity["outputs"][item_id] = maxi(0, int(entity.get("outputs", {}).get(item_id, 0)) - quantity)


static func _sorted_entity_ids(world: Dictionary, kind: String) -> Array:
	var result: Array = []
	for id_value in world.get("entities", {}).keys():
		var id := str(id_value)
		if str(world.get("entities", {}).get(id, {}).get("kind", "")) == kind:
			result.append(id)
	result.sort()
	return result


static func _fair_entity_ids(world: Dictionary) -> Array:
	var ids: Array = world.get("entities", {}).keys()
	ids.sort()
	var cursor := str(world.get("road_dispatch_after", ""))
	var pivot := ids.find(cursor) + 1
	return ids.slice(pivot) + ids.slice(0, pivot) if pivot > 0 and pivot < ids.size() else ids


static func _can_queue(world: Dictionary, rules: Dictionary, owner_id: String) -> bool:
	if world.get("road_shipments", {}).size() >= maxi(1, int(rules.get("road_max_active_shipments", 64))):
		return false
	var moving := 0
	for job_value in world.get("road_shipments", {}).values():
		var job := job_value as Dictionary
		var owner := str(job.get("courier_owner_id", job.get("source_id", "") if str(job.get("destination_kind", "")) == WAREHOUSE_DESTINATION_KIND else job.get("target_id", "")))
		if owner == owner_id:
			moving += 1
	return moving < maxi(1, int(rules.get("road_couriers_per_building", 1)))


static func _cargo_limit(rules: Dictionary) -> int:
	return maxi(1, int(rules.get("road_courier_cargo_capacity", rules.get("road_courier_capacity_per_second", 1))))


static func _route_speed(world: Dictionary, path_tiles: Variant, rules: Dictionary) -> float:
	var tier1 := maxf(EPSILON, float(rules.get("road_tier1_speed_tiles_per_second", 4.0)))
	var tier2 := maxf(tier1, float(rules.get("road_tier2_speed_tiles_per_second", 8.0)))
	var speed := tier2
	var travel_seconds := 0.0
	var segments := 0
	var roads: Dictionary = world.get("roads", {}) if world.get("roads", {}) is Dictionary else {}
	if path_tiles is Array:
		for index in range(1, path_tiles.size()):
			var key_value: Variant = path_tiles[index]
			var key := str(key_value)
			var tier := int(roads.get(key, {}).get("tier", 1))
			speed = tier1 if tier <= 1 else tier2
			travel_seconds += 1.0 / speed
			segments += 1
	return float(segments) / travel_seconds if travel_seconds > EPSILON else tier1


static func _context_dictionary(context: Dictionary, key: String) -> Dictionary:
	return context.get(key, {}) if context.get(key, {}) is Dictionary else {}


static func _positive_manifest(source: Dictionary) -> Dictionary:
	var result := {}
	for key_value in source.keys():
		var item_id := str(key_value)
		var quantity := maxi(0, int(source.get(key_value, 0)))
		if quantity > 0:
			result[item_id] = quantity
	return result


static func _dictionary_total(source: Variant) -> int:
	if source is not Dictionary:
		return 0
	var total := 0
	for value in (source as Dictionary).values():
		total += maxi(0, int(value))
	return total


static func _job_quantity(job: Dictionary) -> int:
	return maxi(0, int(job.get("cargo", {}).get(str(job.get("item_id", "")), 0)))


static func _next_shipment_id(world: Dictionary) -> String:
	var serial := maxi(1, int(world.get("next_road_shipment_serial", 1)))
	world["next_road_shipment_serial"] = serial + 1
	return "ROAD-SHIP-%d" % serial
