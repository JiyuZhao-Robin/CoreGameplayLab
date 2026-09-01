class_name FactoryGridSimulation
extends RefCounted

## Authoritative square-grid factory simulation used by the post-1.29 gameplay
## rewrite. One tile is one square metre, but worlds are sparse address spaces:
## only resource-field descriptors, player structures, links, construction
## orders and modified tiles are persisted. Terrain and resources are tile
## attributes; they are never physical entities or network endpoints.

const WORLD_SCHEMA_VERSION := 2
const DEFAULT_CHUNK_SIZE := 64
const DEFAULT_STEP_SECONDS := 1.0
const EPSILON := 0.000001
const ENTITY_KINDS := ["EXTRACTOR", "MACHINE", "STORAGE", "POWER", "CONSTRUCTION"]
const LINK_KINDS := ["CARGO", "POWER"]

var building_definitions: Dictionary = {}
var recipe_definitions: Dictionary = {}
var rules: Dictionary = {}


func _init(buildings: Dictionary = {}, recipes: Dictionary = {}, grid_rules: Dictionary = {}) -> void:
	configure(buildings, recipes, grid_rules)


func configure(buildings: Dictionary, recipes: Dictionary, grid_rules: Dictionary = {}) -> void:
	building_definitions = buildings.duplicate(true)
	recipe_definitions = recipes.duplicate(true)
	rules = grid_rules.duplicate(true)
	rules.merge({
		"chunk_size_tiles":DEFAULT_CHUNK_SIZE,
		"simulation_step_seconds":DEFAULT_STEP_SECONDS,
		"base_construction_capacity_per_second":1.0
	}, false)


func create_world(world_id: String, location_id: String, size_tiles: Vector2i, seed: int = 1) -> Dictionary:
	return {
		"schema_version":WORLD_SCHEMA_VERSION,
		"world_id":world_id,
		"location_id":location_id,
		"seed":seed,
		"generator_version":maxi(1, int(rules.get("generator_version", 1))),
		"tile_size_m":1,
		"bounds":{"origin":{"x":0, "y":0}, "size":{"x":maxi(1, size_tiles.x), "y":maxi(1, size_tiles.y)}},
		"chunk_size_tiles":maxi(1, int(rules.get("chunk_size_tiles", DEFAULT_CHUNK_SIZE))),
		"elapsed_ms":0.0,
		"resource_fields":{},
		"entities":{},
		"links":{},
		"construction_orders":{},
		"tile_deltas":{},
		"revealed_chunks":{},
		"next_entity_serial":1,
		"next_link_serial":1,
		"next_construction_serial":1,
		"statistics":{"produced":{}, "consumed":{}, "transferred":{}, "construction_delivered":{}, "construction_completed":0}
	}


func normalize_world(source: Dictionary) -> Dictionary:
	var bounds: Dictionary = source.get("bounds", {})
	var origin: Dictionary = bounds.get("origin", {})
	var size: Dictionary = bounds.get("size", {})
	var normalized := create_world(
		str(source.get("world_id", "factory-world")),
		str(source.get("location_id", "")),
		Vector2i(maxi(1, int(size.get("x", 1))), maxi(1, int(size.get("y", 1)))),
		int(source.get("seed", 1))
	)
	normalized["schema_version"] = WORLD_SCHEMA_VERSION
	normalized["generator_version"] = maxi(1, int(source.get("generator_version", normalized.get("generator_version", 1))))
	normalized["bounds"]["origin"] = {"x":int(origin.get("x", 0)), "y":int(origin.get("y", 0))}
	normalized["chunk_size_tiles"] = maxi(1, int(source.get("chunk_size_tiles", normalized["chunk_size_tiles"])))
	normalized["elapsed_ms"] = maxf(0.0, float(source.get("elapsed_ms", 0.0)))
	for field in ["resource_fields", "entities", "links", "construction_orders", "tile_deltas", "revealed_chunks", "statistics"]:
		if source.get(field, null) is Dictionary:
			normalized[field] = source.get(field, {}).duplicate(true)
	for field in ["next_entity_serial", "next_link_serial", "next_construction_serial"]:
		normalized[field] = maxi(1, int(source.get(field, 1)))
	_normalize_runtime_records(normalized)
	return normalized


func _normalize_runtime_records(world: Dictionary) -> void:
	var structures := {}
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		if str(entity.get("kind", "")) == "DEPOSIT":
			var legacy_id := str(entity.get("id", ""))
			if not legacy_id.is_empty():
				world["resource_fields"][legacy_id] = {
					"id":legacy_id,
					"resource_id":str(entity.get("resource_id", "")),
					"resource_category":str(entity.get("resource_category", "solid")),
					"footprint":entity.get("footprint", {}).duplicate(true),
					"grade":maxf(EPSILON, float(entity.get("grade", 1.0))),
					"potential_density":maxf(EPSILON, float(entity.get("potential_density", 1.0)))
				}
			continue
		entity["inputs"] = entity.get("inputs", {}).duplicate(true)
		entity["outputs"] = entity.get("outputs", {}).duplicate(true)
		entity["inventory"] = entity.get("inventory", {}).duplicate(true)
		entity["routing_cursor"] = entity.get("routing_cursor", {}).duplicate(true)
		entity["progress"] = maxf(0.0, float(entity.get("progress", 0.0)))
		entity["power_factor"] = clampf(float(entity.get("power_factor", 1.0)), 0.0, 1.0)
		structures[str(entity.get("id", ""))] = entity
	world["entities"] = structures
	for field_value in world.get("resource_fields", {}).values():
		var resource_field := field_value as Dictionary
		resource_field["resource_category"] = str(resource_field.get("resource_category", "solid"))
		resource_field["grade"] = maxf(EPSILON, float(resource_field.get("grade", 1.0)))
		resource_field["potential_density"] = maxf(EPSILON, float(resource_field.get("potential_density", 1.0)))
	var valid_links := {}
	for link_value in world.get("links", {}).values():
		var link := link_value as Dictionary
		if str(link.get("kind", "")) not in LINK_KINDS or not structures.has(str(link.get("source_id", ""))) or not structures.has(str(link.get("target_id", ""))):
			continue
		link["capacity_progress"] = maxf(0.0, float(link.get("capacity_progress", 0.0)))
		link["last_flow"] = maxf(0.0, float(link.get("last_flow", 0.0)))
		link["total_transferred"] = maxi(0, int(link.get("total_transferred", 0)))
		valid_links[str(link.get("id", ""))] = link
	world["links"] = valid_links
	for order_value in world.get("construction_orders", {}).values():
		var order := order_value as Dictionary
		order["required_items"] = order.get("required_items", {}).duplicate(true)
		order["delivered_items"] = order.get("delivered_items", {}).duplicate(true)
		order["work_done"] = maxf(0.0, float(order.get("work_done", 0.0)))


func chunk_coordinate(world: Dictionary, tile: Vector2i) -> Vector2i:
	var chunk_size := maxi(1, int(world.get("chunk_size_tiles", DEFAULT_CHUNK_SIZE)))
	var origin := _point(world.get("bounds", {}).get("origin", {}))
	var relative := tile - origin
	return Vector2i(floori(float(relative.x) / float(chunk_size)), floori(float(relative.y) / float(chunk_size)))


func chunk_local_coordinate(world: Dictionary, tile: Vector2i) -> Vector2i:
	var chunk_size := maxi(1, int(world.get("chunk_size_tiles", DEFAULT_CHUNK_SIZE)))
	var origin := _point(world.get("bounds", {}).get("origin", {}))
	var relative := tile - origin
	return Vector2i(posmod(relative.x, chunk_size), posmod(relative.y, chunk_size))


func tile_snapshot(world: Dictionary, tile: Vector2i) -> Dictionary:
	if not _tile_in_world(world, tile):
		return {"valid":false, "coordinate":_point_dict(tile)}
	var terrain_type := _terrain_type_at(world, tile)
	var terrain_definition: Dictionary = rules.get("terrain_types", {}).get(terrain_type, {})
	var snapshot := {
		"valid":true,
		"coordinate":_point_dict(tile),
		"terrain_type":terrain_type,
		"terrain_color":str(terrain_definition.get("color", "#808080")),
		"terrain_buildable":bool(terrain_definition.get("buildable", true)),
		"resource_field_id":"",
		"resource_id":"",
		"resource_color":"",
		"resource_category":"",
		"grade":0.0,
		"potential_density":0.0
	}
	for field_id_value in _sorted_keys(world.get("resource_fields", {})):
		var resource_field: Dictionary = world.get("resource_fields", {}).get(field_id_value, {})
		if _footprint_contains(resource_field, tile):
			var resource_id := str(resource_field.get("resource_id", ""))
			snapshot["resource_field_id"] = str(resource_field.get("id", ""))
			snapshot["resource_id"] = resource_id
			snapshot["resource_color"] = str(rules.get("resource_colors", {}).get(resource_id, "#FFFFFF"))
			snapshot["resource_category"] = str(resource_field.get("resource_category", "solid"))
			snapshot["grade"] = float(resource_field.get("grade", 1.0))
			snapshot["potential_density"] = float(resource_field.get("potential_density", 1.0))
			break
	var tile_key := _tile_key(tile)
	if world.get("tile_deltas", {}).has(tile_key):
		var delta: Dictionary = world.get("tile_deltas", {}).get(tile_key, {})
		if delta.has("terrain_override"):
			var override_type := str(delta.get("terrain_override", terrain_type))
			var override_definition: Dictionary = rules.get("terrain_types", {}).get(override_type, {})
			snapshot["terrain_type"] = override_type
			snapshot["terrain_color"] = str(override_definition.get("color", snapshot.get("terrain_color", "#808080")))
			snapshot["terrain_buildable"] = bool(override_definition.get("buildable", snapshot.get("terrain_buildable", true)))
		if bool(delta.get("resource_cleared", false)):
			snapshot["resource_field_id"] = ""
			snapshot["resource_id"] = ""
			snapshot["resource_color"] = ""
			snapshot["resource_category"] = ""
			snapshot["grade"] = 0.0
			snapshot["potential_density"] = 0.0
		if delta.has("remaining_resource"):
			snapshot["remaining_resource"] = maxi(0, int(delta.get("remaining_resource", 0)))
	return snapshot


func tile_view_snapshot(world: Dictionary, tile: Vector2i, view_mode: String = "TERRAIN") -> Dictionary:
	var snapshot := tile_snapshot(world, tile)
	if not bool(snapshot.get("valid", false)):
		return snapshot
	var normalized_mode := view_mode.to_upper()
	if normalized_mode not in ["TERRAIN", "RESOURCE"]:
		normalized_mode = "TERRAIN"
	var display_color := str(snapshot.get("terrain_color", "#808080"))
	var display_value := str(snapshot.get("terrain_type", "UNKNOWN"))
	if normalized_mode == "RESOURCE":
		display_color = str(snapshot.get("resource_color", "")) if not str(snapshot.get("resource_id", "")).is_empty() else "#252A30"
		display_value = str(snapshot.get("resource_id", "")) if not str(snapshot.get("resource_id", "")).is_empty() else "NO_RESOURCE"
	snapshot["view_mode"] = normalized_mode
	snapshot["display_color"] = display_color
	snapshot["display_value"] = display_value
	return snapshot


func resource_coverage_for_footprint(world: Dictionary, footprint: Dictionary, loss_per_missing_tile: float = 0.1) -> Dictionary:
	var origin := _point(footprint.get("origin", {}))
	var size := _point(footprint.get("size", {}))
	var footprint_tiles := maxi(0, size.x) * maxi(0, size.y)
	var resource_ids := {}
	var field_ids := {}
	var covered_by_field := {}
	var covered_tiles := 0
	var grade_sum := 0.0
	var sustainable_rate := 0.0
	var resource_category := ""
	for y in range(origin.y, origin.y + maxi(0, size.y)):
		for x in range(origin.x, origin.x + maxi(0, size.x)):
			var tile := tile_snapshot(world, Vector2i(x, y))
			var resource_id := str(tile.get("resource_id", ""))
			if resource_id.is_empty():
				continue
			var field_id := str(tile.get("resource_field_id", ""))
			resource_ids[resource_id] = true
			if not field_id.is_empty():
				field_ids[field_id] = true
				covered_by_field[field_id] = int(covered_by_field.get(field_id, 0)) + 1
			covered_tiles += 1
			grade_sum += maxf(EPSILON, float(tile.get("grade", 1.0)))
			sustainable_rate += maxf(0.0, float(tile.get("potential_density", 0.0)))
			if resource_category.is_empty():
				resource_category = str(tile.get("resource_category", "solid"))
	var sorted_resources := _sorted_keys(resource_ids)
	var sorted_fields := _sorted_keys(field_ids)
	var missing_tiles := maxi(0, footprint_tiles - covered_tiles)
	var efficiency := 0.0 if covered_tiles <= 0 else clampf(1.0 - float(missing_tiles) * clampf(loss_per_missing_tile, 0.0, 1.0), 0.0, 1.0)
	return {
		"resource_id":"" if sorted_resources.is_empty() else str(sorted_resources[0]),
		"resource_ids":sorted_resources,
		"resource_category":resource_category,
		"resource_field_ids":sorted_fields,
		"covered_tiles_by_field":covered_by_field,
		"covered_resource_tiles":covered_tiles,
		"footprint_tiles":footprint_tiles,
		"missing_resource_tiles":missing_tiles,
		"coverage_efficiency":efficiency,
		"average_grade":0.0 if covered_tiles <= 0 else grade_sum / float(covered_tiles),
		"sustainable_rate_per_second":sustainable_rate,
		"mixed_resource_types":sorted_resources.size() > 1
	}


func add_resource_field(world: Dictionary, resource_field_id: String, resource_id: String, origin: Vector2i, size: Vector2i, grade: float = 1.0, potential_density: float = 1.0, resource_category: String = "solid") -> Dictionary:
	if resource_field_id.is_empty() or resource_id.is_empty() or world.get("resource_fields", {}).has(resource_field_id) or world.get("entities", {}).has(resource_field_id):
		return _failure("INVALID_RESOURCE_FIELD", "Resource-field identity and resource must be unique")
	var footprint := _footprint(origin, size)
	if not _footprint_in_world(world, footprint):
		return _failure("OUT_OF_BOUNDS", "Resource field is outside the world")
	var candidate := {
		"id":resource_field_id,
		"footprint":footprint,
		"resource_id":resource_id,
		"resource_category":resource_category,
		"grade":maxf(EPSILON, grade),
		"potential_density":maxf(EPSILON, potential_density)
	}
	for field_value in world.get("resource_fields", {}).values():
		var existing := field_value as Dictionary
		if _footprints_overlap(footprint, existing.get("footprint", {})):
			return _failure("RESOURCE_FIELD_OVERLAP", "Resource fields cannot overlap")
		if str(existing.get("resource_id", "")) != resource_id and _resource_fields_share_extractor_span(candidate, existing):
			return _failure("RESOURCE_FIELD_EXCLUSION", "Different resources are too close for the available extractor footprints")
	world["resource_fields"][resource_field_id] = candidate
	return {"ok":true, "resource_field_id":resource_field_id}


func place_entity_immediate(world: Dictionary, definition_id: String, origin: Vector2i, recipe_id: String = "", requested_id: String = "") -> Dictionary:
	var placement := can_place_entity(world, definition_id, origin, recipe_id)
	if not bool(placement.get("ok", false)):
		return placement
	var entity_id := requested_id
	if entity_id.is_empty():
		entity_id = _next_id(world, "next_entity_serial", "ENTITY-")
	elif world.get("entities", {}).has(entity_id):
		return _failure("ENTITY_ID_OCCUPIED", "Entity id is already in use")
	var entity := _create_entity(entity_id, definition_id, origin, recipe_id)
	_apply_extractor_resource_profile(entity, placement.get("resource_profile", {}))
	world["entities"][entity_id] = entity
	return {"ok":true, "entity_id":entity_id}


func can_place_entity(world: Dictionary, definition_id: String, origin: Vector2i, recipe_id: String = "", ignored_order_id: String = "") -> Dictionary:
	var definition: Dictionary = building_definitions.get(definition_id, {})
	if definition.is_empty() or str(definition.get("kind", "")) not in ENTITY_KINDS:
		return _failure("UNKNOWN_BUILDING", "Unknown or invalid building definition")
	if str(definition.get("kind", "")) == "MACHINE":
		var recipe: Dictionary = recipe_definitions.get(recipe_id, {})
		if recipe.is_empty() or not definition.get("recipe_ids", []).has(recipe_id):
			return _failure("INCOMPATIBLE_RECIPE", "Machine requires a compatible recipe")
	var size_data: Dictionary = definition.get("footprint", {})
	var footprint := _footprint(origin, Vector2i(maxi(1, int(size_data.get("width", 1))), maxi(1, int(size_data.get("height", 1)))))
	if not _footprint_in_world(world, footprint):
		return _failure("OUT_OF_BOUNDS", "Building footprint is outside the world")
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		if not _footprints_overlap(footprint, entity.get("footprint", {})):
			continue
		return _failure("FOOTPRINT_OCCUPIED", "Building footprint overlaps another structure")
	for order_id_value in world.get("construction_orders", {}).keys():
		var order_id := str(order_id_value)
		if order_id == ignored_order_id:
			continue
		var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
		if str(order.get("status", "")) in ["CANCELLED", "FAILED", "COMPLETE"]:
			continue
		if _footprints_overlap(footprint, order.get("footprint", {})):
			return _failure("CONSTRUCTION_OCCUPIED", "Building footprint overlaps a construction order")
	var result := {"ok":true, "footprint":footprint}
	if str(definition.get("kind", "")) == "EXTRACTOR":
		var resource_profile := resource_coverage_for_footprint(world, footprint, float(definition.get("resource_coverage_loss_per_missing_tile", 0.1)))
		if int(resource_profile.get("covered_resource_tiles", 0)) <= 0:
			return _failure("RESOURCE_REQUIRED", "Extractor must cover at least one resource-bearing tile")
		if bool(resource_profile.get("mixed_resource_types", false)):
			return _failure("MIXED_RESOURCE_COVERAGE", "One extractor cannot cover different resource types")
		if not definition.get("resource_categories", []).has(str(resource_profile.get("resource_category", ""))):
			return _failure("RESOURCE_INCOMPATIBLE", "Extractor is incompatible with the covered tile resource")
		result["resource_profile"] = resource_profile
	return result


func queue_construction(world: Dictionary, definition_id: String, origin: Vector2i, recipe_id: String = "", priority: int = 50) -> Dictionary:
	var placement := can_place_entity(world, definition_id, origin, recipe_id)
	if not bool(placement.get("ok", false)):
		return placement
	var definition: Dictionary = building_definitions.get(definition_id, {})
	var order_id := _next_id(world, "next_construction_serial", "BUILD-")
	var entity_id := _next_id(world, "next_entity_serial", "ENTITY-")
	var costs := _item_entries_to_dictionary(definition.get("construction_cost", []))
	world["construction_orders"][order_id] = {
		"id":order_id,
		"entity_id":entity_id,
		"definition_id":definition_id,
		"recipe_id":recipe_id,
		"footprint":placement.get("footprint", {}).duplicate(true),
		"resource_profile":placement.get("resource_profile", {}).duplicate(true),
		"required_items":costs,
		"delivered_items":{},
		"work_required":maxf(EPSILON, float(definition.get("construction_work", 1.0))),
		"work_done":0.0,
		"priority":clampi(priority, 0, 100),
		"status":"WAITING_MATERIALS" if not costs.is_empty() else "READY",
		"blocked_reason":"MISSING_MATERIALS" if not costs.is_empty() else "",
		"queued_at_ms":float(world.get("elapsed_ms", 0.0))
	}
	return {"ok":true, "order_id":order_id, "entity_id":entity_id}


func fund_construction_from_storage(world: Dictionary, order_id: String, storage_id: String) -> Dictionary:
	var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
	var storage: Dictionary = world.get("entities", {}).get(storage_id, {})
	if order.is_empty() or str(order.get("status", "")) in ["COMPLETE", "CANCELLED", "FAILED"]:
		return _failure("INVALID_CONSTRUCTION_ORDER", "Construction order is not fundable")
	if str(storage.get("kind", "")) != "STORAGE" or str(storage.get("status", "")) == "UNDER_CONSTRUCTION":
		return _failure("INVALID_STORAGE", "Construction materials must come from operational storage")
	var inventory: Dictionary = storage.get("inventory", {})
	var delivered: Dictionary = order.get("delivered_items", {})
	var moved := {}
	for item_id_value in _sorted_keys(order.get("required_items", {})):
		var item_id := str(item_id_value)
		var need := maxi(0, int(order.get("required_items", {}).get(item_id, 0)) - int(delivered.get(item_id, 0)))
		var quantity := mini(need, maxi(0, int(inventory.get(item_id, 0))))
		if quantity <= 0:
			continue
		inventory[item_id] = int(inventory.get(item_id, 0)) - quantity
		delivered[item_id] = int(delivered.get(item_id, 0)) + quantity
		moved[item_id] = quantity
		# Delivery only changes custody from storage to the construction order.
		# The material remains a physical asset until the order completes.
		_add_statistic(world, "construction_delivered", item_id, quantity)
	order["delivered_items"] = delivered
	if _construction_funded(order):
		order["status"] = "READY"
		order["blocked_reason"] = ""
	else:
		order["status"] = "WAITING_MATERIALS"
		order["blocked_reason"] = "MISSING_MATERIALS"
	return {"ok":true, "moved":moved, "fully_funded":_construction_funded(order)}


func connect_entities(world: Dictionary, kind: String, source_id: String, target_id: String, item_id: String = "", capacity_per_second: float = 1.0, priority: int = 1) -> Dictionary:
	if kind not in LINK_KINDS or source_id == target_id:
		return _failure("INVALID_LINK", "Link kind and endpoints must be valid")
	var source: Dictionary = world.get("entities", {}).get(source_id, {})
	var target: Dictionary = world.get("entities", {}).get(target_id, {})
	if source.is_empty() or target.is_empty():
		return _failure("MISSING_ENDPOINT", "Both link endpoints must exist")
	for link_value in world.get("links", {}).values():
		var existing := link_value as Dictionary
		if str(existing.get("kind", "")) == kind and str(existing.get("source_id", "")) == source_id and str(existing.get("target_id", "")) == target_id and str(existing.get("item_id", "")) == item_id:
			return _failure("DUPLICATE_LINK", "This link already exists")
	match kind:
		"CARGO":
			if item_id.is_empty() or capacity_per_second <= 0.0:
				return _failure("INVALID_CARGO_LINK", "Cargo links require an item and positive capacity")
			if not _entity_can_output(world, source, item_id) or not _entity_can_input(target, item_id):
				return _failure("CARGO_INCOMPATIBLE", "Cargo item is incompatible with an endpoint")
			for link_value in world.get("links", {}).values():
				var occupied := link_value as Dictionary
				if str(occupied.get("kind", "")) == "CARGO" and str(occupied.get("target_id", "")) == target_id and str(occupied.get("item_id", "")) == item_id:
					return _failure("CARGO_INPUT_OCCUPIED", "A target item port accepts one incoming cargo link")
		"POWER":
			item_id = ""
	var link_id := _next_id(world, "next_link_serial", "LINK-")
	world["links"][link_id] = {
		"id":link_id,
		"kind":kind,
		"source_id":source_id,
		"target_id":target_id,
		"item_id":item_id,
		"capacity_per_second":maxf(0.0, capacity_per_second),
		"capacity_progress":0.0,
		"priority":clampi(priority, 0, 2),
		"last_flow":0.0,
		"total_transferred":0
	}
	return {"ok":true, "link_id":link_id}


func remove_link(world: Dictionary, link_id: String) -> bool:
	return world.get("links", {}).erase(link_id)


func advance_world(world: Dictionary, elapsed_ms: float) -> Dictionary:
	var remaining_seconds := maxf(0.0, elapsed_ms) / 1000.0
	var step_limit := maxf(0.05, float(rules.get("simulation_step_seconds", DEFAULT_STEP_SECONDS)))
	var events: Array[Dictionary] = []
	var steps := 0
	while remaining_seconds > EPSILON:
		var step_seconds := minf(remaining_seconds, step_limit)
		_step(world, step_seconds, events)
		remaining_seconds -= step_seconds
		steps += 1
	world["elapsed_ms"] = float(world.get("elapsed_ms", 0.0)) + maxf(0.0, elapsed_ms)
	return {"simulated_ms":maxf(0.0, elapsed_ms), "steps":steps, "events":events}


func _step(world: Dictionary, seconds: float, events: Array[Dictionary]) -> void:
	for link_value in world.get("links", {}).values():
		var link := link_value as Dictionary
		link["last_flow"] = 0.0
		if str(link.get("kind", "")) == "CARGO":
			link["capacity_progress"] = float(link.get("capacity_progress", 0.0)) + maxf(0.0, float(link.get("capacity_per_second", 0.0))) * seconds
	_transfer_cargo(world, seconds)
	var power_factors := _calculate_power_factors(world)
	_run_extractors(world, seconds, power_factors)
	_run_machines(world, seconds, power_factors)
	_transfer_cargo(world, seconds)
	# Unused whole-unit throughput expires at the end of this simulation step.
	# Only sub-unit progress crosses a boundary, so a blocked belt cannot bank
	# hours of capacity and burst it after downstream space becomes available.
	for link_value in world.get("links", {}).values():
		var link := link_value as Dictionary
		if str(link.get("kind", "")) == "CARGO":
			var progress := maxf(0.0, float(link.get("capacity_progress", 0.0)))
			link["capacity_progress"] = progress - floorf(progress)
	_advance_construction(world, seconds, events)


func _calculate_power_factors(world: Dictionary) -> Dictionary:
	var parent := {}
	for entity_id_value in world.get("entities", {}).keys():
		var entity_id := str(entity_id_value)
		parent[entity_id] = entity_id
	for link_value in world.get("links", {}).values():
		var link := link_value as Dictionary
		if str(link.get("kind", "")) != "POWER":
			continue
		var source_id := str(link.get("source_id", ""))
		var target_id := str(link.get("target_id", ""))
		if parent.has(source_id) and parent.has(target_id):
			_union(parent, source_id, target_id)
	var supply := {}
	var demand := {}
	for entity_id_value in parent.keys():
		var entity_id := str(entity_id_value)
		var root := _find_root(parent, entity_id)
		var definition: Dictionary = building_definitions.get(str(world["entities"][entity_id].get("definition_id", "")), {})
		supply[root] = float(supply.get(root, 0.0)) + maxf(0.0, float(definition.get("power_generation_kw", 0.0)))
		demand[root] = float(demand.get(root, 0.0)) + maxf(0.0, float(definition.get("power_demand_kw", 0.0)))
	var factors := {}
	for entity_id_value in parent.keys():
		var entity_id := str(entity_id_value)
		var root := _find_root(parent, entity_id)
		var definition: Dictionary = building_definitions.get(str(world["entities"][entity_id].get("definition_id", "")), {})
		var entity_demand := maxf(0.0, float(definition.get("power_demand_kw", 0.0)))
		var factor := 1.0 if entity_demand <= EPSILON else clampf(float(supply.get(root, 0.0)) / maxf(EPSILON, float(demand.get(root, 0.0))), 0.0, 1.0)
		factors[entity_id] = factor
		world["entities"][entity_id]["power_factor"] = factor
	return factors


func _run_extractors(world: Dictionary, seconds: float, power_factors: Dictionary) -> void:
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		if str(entity.get("kind", "")) != "EXTRACTOR":
			continue
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		var resource_profile := resource_coverage_for_footprint(world, entity.get("footprint", {}), float(definition.get("resource_coverage_loss_per_missing_tile", 0.1)))
		_apply_extractor_resource_profile(entity, resource_profile)
		if int(resource_profile.get("covered_resource_tiles", 0)) <= 0 or bool(resource_profile.get("mixed_resource_types", false)):
			entity["status"] = "NO_RESOURCE"
			entity["actual_rate"] = 0.0
			continue
		var factor := float(power_factors.get(entity_id, 0.0))
		if factor <= EPSILON:
			entity["status"] = "NO_POWER"
			entity["actual_rate"] = 0.0
			continue
		var resource_id := str(resource_profile.get("resource_id", ""))
		var output_capacity := maxi(0, int(definition.get("output_capacity", 0)))
		var current := maxi(0, int(entity.get("outputs", {}).get(resource_id, 0)))
		var free := maxi(0, output_capacity - _dictionary_total(entity.get("outputs", {})))
		if free <= 0:
			entity["status"] = "OUTPUT_FULL"
			entity["actual_rate"] = 0.0
			continue
		var sustainable_rate := float(resource_profile.get("sustainable_rate_per_second", 0.0))
		var installed_rate := maxf(0.0, float(definition.get("mining_rate_per_second", 0.0)))
		var unconstrained_rate := installed_rate * maxf(EPSILON, float(resource_profile.get("average_grade", 1.0))) * float(resource_profile.get("coverage_efficiency", 0.0)) * factor
		var actual_rate := minf(unconstrained_rate, sustainable_rate)
		entity["progress"] = float(entity.get("progress", 0.0)) + actual_rate * seconds
		var produced := mini(free, maxi(0, floori(float(entity.get("progress", 0.0)) + EPSILON)))
		if produced > 0:
			entity["outputs"][resource_id] = current + produced
			entity["progress"] = 0.0 if produced >= free else maxf(0.0, float(entity.get("progress", 0.0)) - float(produced))
			_add_statistic(world, "produced", resource_id, produced)
		entity["actual_rate"] = actual_rate
		entity["status"] = "POWER_LIMITED" if factor < 0.999 else ("PARTIAL_COVERAGE" if float(resource_profile.get("coverage_efficiency", 0.0)) < 0.999 else "RUNNING")


func _run_machines(world: Dictionary, seconds: float, power_factors: Dictionary) -> void:
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		if str(entity.get("kind", "")) != "MACHINE":
			continue
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
		if recipe.is_empty():
			entity["status"] = "NO_RECIPE"
			entity["actual_rate"] = 0.0
			continue
		var factor := float(power_factors.get(entity_id, 0.0))
		if factor <= EPSILON:
			entity["status"] = "NO_POWER"
			entity["actual_rate"] = 0.0
			continue
		var available_cycles := _available_recipe_input_cycles(entity, recipe)
		if available_cycles <= 0:
			entity["status"] = "INPUT_SHORTAGE"
			entity["actual_rate"] = 0.0
			continue
		var output_cycles := _available_recipe_output_cycles(entity, definition, recipe)
		if output_cycles <= 0:
			entity["status"] = "OUTPUT_FULL"
			entity["actual_rate"] = 0.0
			continue
		var cycle_rate := maxf(EPSILON, float(definition.get("speed", 1.0))) / maxf(EPSILON, float(recipe.get("duration_seconds", 1.0))) * factor
		entity["progress"] = float(entity.get("progress", 0.0)) + cycle_rate * seconds
		var completed_cycles := mini(mini(available_cycles, output_cycles), maxi(0, floori(float(entity.get("progress", 0.0)) + EPSILON)))
		if completed_cycles > 0:
			for input_value in recipe.get("inputs", []):
				var input := input_value as Dictionary
				var item_id := str(input.get("item", ""))
				var quantity := int(input.get("quantity", 0)) * completed_cycles
				entity["inputs"][item_id] = int(entity.get("inputs", {}).get(item_id, 0)) - quantity
				_add_statistic(world, "consumed", item_id, quantity)
			for output_value in recipe.get("outputs", []):
				var output := output_value as Dictionary
				var item_id := str(output.get("item", ""))
				var quantity := int(output.get("quantity", 0)) * completed_cycles
				entity["outputs"][item_id] = int(entity.get("outputs", {}).get(item_id, 0)) + quantity
				_add_statistic(world, "produced", item_id, quantity)
			entity["progress"] = maxf(0.0, float(entity.get("progress", 0.0)) - float(completed_cycles))
		entity["actual_rate"] = cycle_rate
		entity["status"] = "POWER_LIMITED" if factor < 0.999 else "RUNNING"


func _transfer_cargo(world: Dictionary, seconds: float) -> void:
	var groups := {}
	for link_id_value in _sorted_keys(world.get("links", {})):
		var link_id := str(link_id_value)
		var link: Dictionary = world.get("links", {}).get(link_id, {})
		if str(link.get("kind", "")) != "CARGO":
			continue
		var allowance := maxi(0, floori(float(link.get("capacity_progress", 0.0)) + EPSILON))
		if allowance <= 0:
			continue
		var source: Dictionary = world.get("entities", {}).get(str(link.get("source_id", "")), {})
		var target: Dictionary = world.get("entities", {}).get(str(link.get("target_id", "")), {})
		var item_id := str(link.get("item_id", ""))
		var demand := mini(mini(allowance, _source_quantity(source, item_id)), _target_free_capacity(target, item_id))
		if demand <= 0:
			continue
		var group_key := "%s|%s" % [link.get("source_id", ""), item_id]
		if not groups.has(group_key):
			groups[group_key] = []
		groups[group_key].append({"link_id":link_id, "demand":demand, "priority":int(link.get("priority", 1))})
	for group_key_value in _sorted_keys(groups):
		var candidates: Array = groups[group_key_value]
		if candidates.is_empty():
			continue
		var link: Dictionary = world["links"][str(candidates[0].get("link_id", ""))]
		var source: Dictionary = world["entities"][str(link.get("source_id", ""))]
		var item_id := str(link.get("item_id", ""))
		var allocations := _fair_allocations(source, item_id, candidates, _source_quantity(source, item_id))
		for candidate_value in candidates:
			var candidate := candidate_value as Dictionary
			var link_id := str(candidate.get("link_id", ""))
			var quantity := int(allocations.get(link_id, 0))
			if quantity <= 0:
				continue
			var cargo_link: Dictionary = world["links"][link_id]
			var target: Dictionary = world["entities"][str(cargo_link.get("target_id", ""))]
			quantity = mini(mini(quantity, _source_quantity(source, item_id)), _target_free_capacity(target, item_id))
			if quantity <= 0:
				continue
			_remove_source_quantity(source, item_id, quantity)
			_add_target_quantity(target, item_id, quantity)
			cargo_link["capacity_progress"] = maxf(0.0, float(cargo_link.get("capacity_progress", 0.0)) - float(quantity))
			cargo_link["last_flow"] = float(cargo_link.get("last_flow", 0.0)) + float(quantity) / maxf(EPSILON, seconds)
			cargo_link["total_transferred"] = int(cargo_link.get("total_transferred", 0)) + quantity
			_add_statistic(world, "transferred", item_id, quantity)


func _fair_allocations(source: Dictionary, item_id: String, candidates: Array, available: int) -> Dictionary:
	var allocations := {}
	var remaining := maxi(0, available)
	for priority in [2, 1, 0]:
		var priority_candidates: Array = candidates.filter(func(candidate): return int((candidate as Dictionary).get("priority", 1)) == priority)
		if priority_candidates.is_empty() or remaining <= 0:
			continue
		var priority_allocations := _fair_priority_allocations(source, item_id, priority, priority_candidates, remaining)
		for link_id_value in priority_allocations.keys():
			var link_id := str(link_id_value)
			var quantity := int(priority_allocations.get(link_id, 0))
			allocations[link_id] = quantity
			remaining -= quantity
	return allocations


func _fair_priority_allocations(source: Dictionary, item_id: String, priority: int, candidates: Array, available: int) -> Dictionary:
	var allocations := {}
	var active := candidates.duplicate(true)
	active.sort_custom(func(a, b): return str(a.get("link_id", "")) < str(b.get("link_id", "")))
	var cursor_key := "%s:%d" % [item_id, priority]
	var cursor := posmod(int(source.get("routing_cursor", {}).get(cursor_key, 0)), maxi(1, active.size()))
	if cursor > 0:
		active = active.slice(cursor) + active.slice(0, cursor)
	var remaining := maxi(0, available)
	while remaining > 0 and not active.is_empty():
		var share := maxi(1, remaining / active.size())
		var next_active: Array = []
		var moved_this_round := 0
		for candidate_value in active:
			var candidate := candidate_value as Dictionary
			var link_id := str(candidate.get("link_id", ""))
			var unmet := maxi(0, int(candidate.get("demand", 0)) - int(allocations.get(link_id, 0)))
			var quantity := mini(mini(unmet, share), remaining)
			if quantity > 0:
				allocations[link_id] = int(allocations.get(link_id, 0)) + quantity
				remaining -= quantity
				moved_this_round += quantity
			if int(allocations.get(link_id, 0)) < int(candidate.get("demand", 0)):
				next_active.append(candidate)
			if remaining <= 0:
				break
		if moved_this_round <= 0:
			break
		active = next_active
	source["routing_cursor"][cursor_key] = cursor + 1
	return allocations


func _advance_construction(world: Dictionary, seconds: float, events: Array[Dictionary]) -> void:
	var capacity := maxf(0.0, float(rules.get("base_construction_capacity_per_second", 1.0)))
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		if str(entity.get("kind", "")) == "CONSTRUCTION":
			var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
			capacity += maxf(0.0, float(definition.get("construction_capacity_per_second", 0.0))) * float(entity.get("power_factor", 1.0))
	var available_work := capacity * seconds
	var orders: Array = world.get("construction_orders", {}).values()
	orders.sort_custom(func(a, b):
		var a_priority := int((a as Dictionary).get("priority", 50))
		var b_priority := int((b as Dictionary).get("priority", 50))
		return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")) if a_priority == b_priority else a_priority > b_priority
	)
	var completed: Array[String] = []
	for order_value in orders:
		var order := order_value as Dictionary
		if available_work <= EPSILON:
			break
		if not _construction_funded(order):
			order["status"] = "WAITING_MATERIALS"
			order["blocked_reason"] = "MISSING_MATERIALS"
			continue
		var required := maxf(EPSILON, float(order.get("work_required", 1.0)))
		var remaining := maxf(0.0, required - float(order.get("work_done", 0.0)))
		var applied := minf(available_work, remaining)
		order["work_done"] = float(order.get("work_done", 0.0)) + applied
		order["status"] = "BUILDING"
		order["blocked_reason"] = ""
		available_work -= applied
		if float(order.get("work_done", 0.0)) + EPSILON >= required:
			completed.append(str(order.get("id", "")))
	for order_id in completed:
		var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
		world["construction_orders"].erase(order_id)
		for item_id_value in _sorted_keys(order.get("delivered_items", {})):
			var item_id := str(item_id_value)
			_add_statistic(world, "consumed", item_id, maxi(0, int(order.get("delivered_items", {}).get(item_id, 0))))
		var origin_data: Dictionary = order.get("footprint", {}).get("origin", {})
		var entity := _create_entity(str(order.get("entity_id", "")), str(order.get("definition_id", "")), _point(origin_data), str(order.get("recipe_id", "")))
		var definition: Dictionary = building_definitions.get(str(order.get("definition_id", "")), {})
		if str(definition.get("kind", "")) == "EXTRACTOR":
			var profile := resource_coverage_for_footprint(world, order.get("footprint", {}), float(definition.get("resource_coverage_loss_per_missing_tile", 0.1)))
			_apply_extractor_resource_profile(entity, profile)
		world["entities"][str(entity.get("id", ""))] = entity
		world["statistics"]["construction_completed"] = int(world.get("statistics", {}).get("construction_completed", 0)) + 1
		events.append({"type":"FactoryConstructionCompleted", "world_id":world.get("world_id", ""), "order_id":order_id, "entity_id":entity.get("id", ""), "definition_id":entity.get("definition_id", "")})


func world_summary(world: Dictionary) -> Dictionary:
	var statuses := {}
	var entity_counts := {}
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		var kind := str(entity.get("kind", "UNKNOWN"))
		var status := str(entity.get("status", "UNKNOWN"))
		entity_counts[kind] = int(entity_counts.get(kind, 0)) + 1
		statuses[status] = int(statuses.get(status, 0)) + 1
	return {
		"world_id":world.get("world_id", ""),
		"location_id":world.get("location_id", ""),
		"resource_field_count":world.get("resource_fields", {}).size(),
		"entity_counts":entity_counts,
		"link_count":world.get("links", {}).size(),
		"construction_count":world.get("construction_orders", {}).size(),
		"statuses":statuses,
		"statistics":world.get("statistics", {}).duplicate(true)
	}


func _create_entity(entity_id: String, definition_id: String, origin: Vector2i, recipe_id: String) -> Dictionary:
	var definition: Dictionary = building_definitions.get(definition_id, {})
	var size_data: Dictionary = definition.get("footprint", {})
	return {
		"id":entity_id,
		"kind":str(definition.get("kind", "")),
		"definition_id":definition_id,
		"recipe_id":recipe_id,
		"footprint":_footprint(origin, Vector2i(maxi(1, int(size_data.get("width", 1))), maxi(1, int(size_data.get("height", 1))))),
		"status":"IDLE",
		"inputs":{},
		"outputs":{},
		"inventory":{},
		"routing_cursor":{},
		"progress":0.0,
		"power_factor":1.0,
		"actual_rate":0.0
	}


func _apply_extractor_resource_profile(entity: Dictionary, profile: Dictionary) -> void:
	if str(entity.get("kind", "")) != "EXTRACTOR" or profile.is_empty():
		return
	for field in ["resource_id", "resource_category", "resource_field_ids", "covered_tiles_by_field", "covered_resource_tiles", "footprint_tiles", "missing_resource_tiles", "coverage_efficiency", "average_grade", "sustainable_rate_per_second", "mixed_resource_types"]:
		if profile.has(field):
			entity[field] = profile.get(field)


func _entity_can_output(world: Dictionary, entity: Dictionary, item_id: String) -> bool:
	match str(entity.get("kind", "")):
		"STORAGE": return true
		"EXTRACTOR":
			return str(entity.get("resource_id", "")) == item_id
		"MACHINE":
			var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
			return _item_entries_to_dictionary(recipe.get("outputs", [])).has(item_id)
	return false


func _entity_can_input(entity: Dictionary, item_id: String) -> bool:
	match str(entity.get("kind", "")):
		"STORAGE": return true
		"MACHINE":
			var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
			return _item_entries_to_dictionary(recipe.get("inputs", [])).has(item_id)
	return false


func _source_quantity(entity: Dictionary, item_id: String) -> int:
	var buffer: Dictionary = entity.get("inventory", {}) if str(entity.get("kind", "")) == "STORAGE" else entity.get("outputs", {})
	return maxi(0, int(buffer.get(item_id, 0)))


func _remove_source_quantity(entity: Dictionary, item_id: String, quantity: int) -> void:
	var field := "inventory" if str(entity.get("kind", "")) == "STORAGE" else "outputs"
	entity[field][item_id] = maxi(0, int(entity.get(field, {}).get(item_id, 0)) - quantity)


func _add_target_quantity(entity: Dictionary, item_id: String, quantity: int) -> void:
	var field := "inventory" if str(entity.get("kind", "")) == "STORAGE" else "inputs"
	entity[field][item_id] = int(entity.get(field, {}).get(item_id, 0)) + quantity


func _target_free_capacity(entity: Dictionary, item_id: String) -> int:
	if not _entity_can_input(entity, item_id):
		return 0
	var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
	if str(entity.get("kind", "")) == "STORAGE":
		return maxi(0, int(definition.get("inventory_capacity", 0)) - _dictionary_total(entity.get("inventory", {})))
	return maxi(0, int(definition.get("input_capacity", 0)) - _dictionary_total(entity.get("inputs", {})))


func _available_recipe_input_cycles(entity: Dictionary, recipe: Dictionary) -> int:
	var cycles := 2147483647
	for input_value in recipe.get("inputs", []):
		var input := input_value as Dictionary
		var quantity := maxi(1, int(input.get("quantity", 1)))
		cycles = mini(cycles, maxi(0, int(entity.get("inputs", {}).get(str(input.get("item", "")), 0))) / quantity)
	return 0 if cycles == 2147483647 else cycles


func _available_recipe_output_cycles(entity: Dictionary, definition: Dictionary, recipe: Dictionary) -> int:
	var free := maxi(0, int(definition.get("output_capacity", 0)) - _dictionary_total(entity.get("outputs", {})))
	var output_per_cycle := 0
	for output_value in recipe.get("outputs", []):
		var output := output_value as Dictionary
		output_per_cycle += maxi(1, int(output.get("quantity", 1)))
	return free / maxi(1, output_per_cycle)


func _construction_funded(order: Dictionary) -> bool:
	for item_id_value in order.get("required_items", {}).keys():
		var item_id := str(item_id_value)
		if int(order.get("delivered_items", {}).get(item_id, 0)) < int(order.get("required_items", {}).get(item_id, 0)):
			return false
	return true


func _item_entries_to_dictionary(entries: Array) -> Dictionary:
	var result := {}
	for entry_value in entries:
		var entry := entry_value as Dictionary
		var item_id := str(entry.get("item", ""))
		if not item_id.is_empty():
			result[item_id] = int(result.get(item_id, 0)) + maxi(0, int(entry.get("quantity", 0)))
	return result


func _dictionary_total(values: Dictionary) -> int:
	var total := 0
	for value in values.values():
		total += maxi(0, int(value))
	return total


func _add_statistic(world: Dictionary, category: String, item_id: String, quantity: int) -> void:
	if quantity <= 0:
		return
	if not world.get("statistics", {}).has(category):
		world["statistics"][category] = {}
	world["statistics"][category][item_id] = int(world["statistics"][category].get(item_id, 0)) + quantity


func _tile_in_world(world: Dictionary, tile: Vector2i) -> bool:
	var bounds: Dictionary = world.get("bounds", {})
	var origin := _point(bounds.get("origin", {}))
	var size := _point(bounds.get("size", {}))
	return tile.x >= origin.x and tile.y >= origin.y and tile.x < origin.x + size.x and tile.y < origin.y + size.y


func _terrain_type_at(world: Dictionary, tile: Vector2i) -> String:
	var region_scale := maxi(4, int(rules.get("terrain_region_scale_tiles", 32)))
	var detail_scale := maxi(2, region_scale / 4)
	var seed := int(world.get("seed", 1)) + int(world.get("generator_version", 1)) * 104729
	var region_x := floori(float(tile.x) / float(region_scale))
	var region_y := floori(float(tile.y) / float(region_scale))
	var detail_x := floori(float(tile.x) / float(detail_scale))
	var detail_y := floori(float(tile.y) / float(detail_scale))
	var value := posmod(_coordinate_noise(seed, region_x, region_y), 100)
	value = clampi(value + posmod(_coordinate_noise(seed + 7919, detail_x, detail_y), 21) - 10, 0, 99)
	if value < 12:
		return "WATER"
	if value < 30:
		return "FOREST"
	if value < 66:
		return "PLAIN"
	if value < 84:
		return "DESERT"
	return "MOUNTAIN"


func _footprint_in_world(world: Dictionary, footprint: Dictionary) -> bool:
	var origin := _point(footprint.get("origin", {}))
	var size := _point(footprint.get("size", {}))
	return size.x > 0 and size.y > 0 and _tile_in_world(world, origin) and _tile_in_world(world, origin + size - Vector2i.ONE)


func _footprint(origin: Vector2i, size: Vector2i) -> Dictionary:
	return {"origin":_point_dict(origin), "size":_point_dict(Vector2i(maxi(1, size.x), maxi(1, size.y)))}


func _footprint_contains(entity: Dictionary, tile: Vector2i) -> bool:
	var footprint: Dictionary = entity.get("footprint", {})
	var origin := _point(footprint.get("origin", {}))
	var size := _point(footprint.get("size", {}))
	return tile.x >= origin.x and tile.y >= origin.y and tile.x < origin.x + size.x and tile.y < origin.y + size.y


func _footprints_overlap(a: Dictionary, b: Dictionary) -> bool:
	var a_origin := _point(a.get("origin", {}))
	var a_size := _point(a.get("size", {}))
	var b_origin := _point(b.get("origin", {}))
	var b_size := _point(b.get("size", {}))
	return a_origin.x < b_origin.x + b_size.x and a_origin.x + a_size.x > b_origin.x and a_origin.y < b_origin.y + b_size.y and a_origin.y + a_size.y > b_origin.y


func _resource_fields_share_extractor_span(a: Dictionary, b: Dictionary) -> bool:
	for definition_value in building_definitions.values():
		var definition := definition_value as Dictionary
		if str(definition.get("kind", "")) != "EXTRACTOR":
			continue
		var size_data: Dictionary = definition.get("footprint", {})
		var extractor_size := Vector2i(maxi(1, int(size_data.get("width", 1))), maxi(1, int(size_data.get("height", 1))))
		if _resource_fields_fit_one_footprint(a.get("footprint", {}), b.get("footprint", {}), extractor_size):
			return true
	return false


func _resource_fields_fit_one_footprint(a: Dictionary, b: Dictionary, cover_size: Vector2i) -> bool:
	var a_origin := _point(a.get("origin", {}))
	var a_size := _point(a.get("size", {}))
	var b_origin := _point(b.get("origin", {}))
	var b_size := _point(b.get("size", {}))
	return _minimum_joint_span(a_origin.x, a_size.x, b_origin.x, b_size.x) <= cover_size.x and _minimum_joint_span(a_origin.y, a_size.y, b_origin.y, b_size.y) <= cover_size.y


func _minimum_joint_span(a_start: int, a_size: int, b_start: int, b_size: int) -> int:
	var a_end := a_start + maxi(1, a_size) - 1
	var b_end := b_start + maxi(1, b_size) - 1
	if a_start <= b_end and b_start <= a_end:
		return 1
	if a_end < b_start:
		return b_start - a_end + 1
	return a_start - b_end + 1


func _point(value: Dictionary) -> Vector2i:
	return Vector2i(int(value.get("x", 0)), int(value.get("y", 0)))


func _point_dict(value: Vector2i) -> Dictionary:
	return {"x":value.x, "y":value.y}


func _tile_key(tile: Vector2i) -> String:
	return "%d:%d" % [tile.x, tile.y]


func _coordinate_noise(seed: int, x: int, y: int) -> int:
	var value := posmod(seed + x * 73856093 + y * 19349663, 2147483647)
	return posmod(value * 48271 + 1, 2147483647)


func _next_id(world: Dictionary, field: String, prefix: String) -> String:
	var serial := maxi(1, int(world.get(field, 1)))
	world[field] = serial + 1
	return "%s%06d" % [prefix, serial]


func _sorted_keys(dictionary: Dictionary) -> Array:
	var keys := dictionary.keys()
	keys.sort_custom(func(a, b): return str(a) < str(b))
	return keys


func _find_root(parent: Dictionary, entity_id: String) -> String:
	var current := entity_id
	while str(parent.get(current, current)) != current:
		current = str(parent.get(current, current))
	var root := current
	current = entity_id
	while str(parent.get(current, current)) != current:
		var next := str(parent.get(current, current))
		parent[current] = root
		current = next
	return root


func _union(parent: Dictionary, a: String, b: String) -> void:
	var a_root := _find_root(parent, a)
	var b_root := _find_root(parent, b)
	if a_root != b_root:
		parent[b_root] = a_root


func _failure(code: String, message: String) -> Dictionary:
	return {"ok":false, "reason_code":code, "reason":message}
