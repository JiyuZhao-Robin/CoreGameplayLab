class_name FactoryGridSimulation
extends RefCounted

## Authoritative square-grid factory simulation used by the post-1.29 gameplay
## rewrite. One tile is one square metre, but worlds are sparse address spaces:
## only resource-field descriptors, player structures, links, construction
## orders and modified tiles are persisted. Terrain and resources are tile
## attributes; they are never physical entities or network endpoints.

const WORLD_SCHEMA_VERSION := 3
const WORKSPACE_PROTOCOL_VERSION := 1
const DEFAULT_CHUNK_SIZE := 64
const DEFAULT_STEP_SECONDS := 1.0
const EPSILON := 0.000001
const DEFAULT_CARGO_LINK_TIER := "MK1"
const MAX_CARGO_LINK_LANES := 12
const ENTITY_KINDS := ["EXTRACTOR", "MACHINE", "STORAGE", "ROUTER", "POWER", "CONSTRUCTION"]
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
		"topology_revision":0,
		"runtime_revision":0,
		"resource_fields":{},
		"entities":{},
		"links":{},
		"construction_orders":{},
		"command_receipts":{},
		"command_receipt_order":[],
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
	normalized["topology_revision"] = maxi(0, int(source.get("topology_revision", 0)))
	normalized["runtime_revision"] = maxi(0, int(source.get("runtime_revision", 0)))
	for field in ["resource_fields", "entities", "links", "construction_orders", "command_receipts", "tile_deltas", "revealed_chunks", "statistics"]:
		if source.get(field, null) is Dictionary:
			normalized[field] = source.get(field, {}).duplicate(true)
	# Command receipts are authoritative idempotency records, not presentation
	# snapshots. Strip legacy localized messages and retain a stable localization
	# key so loading a save under another locale stays deterministic.
	for command_id_value in normalized.get("command_receipts", {}).keys():
		var receipt_value = normalized.get("command_receipts", {}).get(command_id_value, null)
		if receipt_value is not Dictionary:
			continue
		var receipt := receipt_value as Dictionary
		receipt.erase("message")
		if str(receipt.get("message_key", "")).is_empty():
			var command_kind := str(receipt.get("command_kind", "")).to_lower()
			if not command_kind.is_empty():
				receipt["message_key"] = "factory.success.%s" % command_kind
	if source.get("command_receipt_order", null) is Array:
		normalized["command_receipt_order"] = source.get("command_receipt_order", []).duplicate(true)
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
	for link_id_value in _sorted_keys(world.get("links", {})):
		var link_value = world.get("links", {}).get(link_id_value, {})
		var link := link_value as Dictionary
		var kind := str(link.get("kind", "")).to_upper()
		var source_id := str(link.get("source_id", ""))
		var target_id := str(link.get("target_id", ""))
		if kind not in LINK_KINDS or not structures.has(source_id) or not structures.has(target_id):
			continue
		link["id"] = str(link.get("id", link_id_value))
		link["kind"] = kind
		link["source_id"] = source_id
		link["target_id"] = target_id
		link["capacity_progress"] = maxf(0.0, float(link.get("capacity_progress", 0.0)))
		link["last_flow"] = maxf(0.0, float(link.get("last_flow", 0.0)))
		link["total_transferred"] = maxi(0, int(link.get("total_transferred", 0)))
		link["priority"] = clampi(int(link.get("priority", 1)), 0, 2)
		if kind == "CARGO":
			var item_id := str(link.get("item_id", ""))
			var source: Dictionary = structures.get(source_id, {})
			var target: Dictionary = structures.get(target_id, {})
			# SpaceGameState performs schema-only save normalization with an empty
			# definition registry. Preserve structurally valid persisted links in
			# that pass; semantic endpoint validation resumes when the configured
			# simulation engine owns the world.
			if item_id.is_empty() or (not building_definitions.is_empty() and (not _entity_can_output(world, source, item_id) or not _entity_can_input(target, item_id))):
				continue
			link["item_id"] = item_id
			link["capacity_per_second"] = maxf(EPSILON, float(link.get("capacity_per_second", 1.0)))
			link["source_port_id"] = _cargo_port_id_for_entity(source, source_id, "OUTPUT", item_id)
			link["target_port_id"] = _cargo_port_id_for_entity(target, target_id, "INPUT", item_id)
			link["lane_count"] = clampi(maxi(1, int(link.get("lane_count", 1))), 1, MAX_CARGO_LINK_LANES)
			link["tier"] = _normalize_cargo_link_tier(str(link.get("tier", DEFAULT_CARGO_LINK_TIER)))
			link["congestion"] = clampf(float(link.get("congestion", 0.0)), 0.0, 1.0)
			link["blocked_reason"] = str(link.get("blocked_reason", ""))
			var path_tiles := _normalized_link_path_tiles(world, link.get("path_tiles", []), source, target, "CARGO")
			link["path_tiles"] = path_tiles
			if not _path_tiles_are_in_world(world, path_tiles):
				continue
		else:
			link["item_id"] = ""
			link["source_port_id"] = _power_port_id(source_id, "OUTPUT")
			link["target_port_id"] = _power_port_id(target_id, "INPUT")
			link["congestion"] = 0.0
			link["blocked_reason"] = ""
			link["path_tiles"] = _normalized_link_path_tiles(world, link.get("path_tiles", []), structures.get(source_id, {}), structures.get(target_id, {}), "POWER")
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
	_bump_topology_revision(world)
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
	_bump_topology_revision(world)
	return {"ok":true, "entity_id":entity_id}


func can_place_entity(world: Dictionary, definition_id: String, origin: Vector2i, recipe_id: String = "", ignored_order_id: String = "") -> Dictionary:
	var definition: Dictionary = building_definitions.get(definition_id, {})
	if definition.is_empty() or str(definition.get("kind", "")) not in ENTITY_KINDS:
		return _failure("UNKNOWN_BUILDING", "Unknown or invalid building definition")
	if str(definition.get("kind", "")) == "MACHINE":
		# A machine may be placed before its recipe is configured.  An explicitly
		# supplied recipe still has to exist and be declared compatible by the
		# building; the empty value is the intentional unconfigured state.
		var recipe: Dictionary = recipe_definitions.get(recipe_id, {})
		if not recipe_id.is_empty() and (recipe.is_empty() or not definition.get("recipe_ids", []).has(recipe_id)):
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


func queue_construction(world: Dictionary, definition_id: String, origin: Vector2i, recipe_id: String = "", priority: int = 50, funding_policy: String = "MANUAL") -> Dictionary:
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
		"funding_policy":"AUTO_SAME_LOCATION" if funding_policy == "AUTO_SAME_LOCATION" else "MANUAL",
		"status":"WAITING_MATERIALS" if not costs.is_empty() else "READY",
		"blocked_reason":"MISSING_MATERIALS" if not costs.is_empty() else "",
		"queued_at_ms":float(world.get("elapsed_ms", 0.0))
	}
	_bump_topology_revision(world)
	return {"ok":true, "order_id":order_id, "entity_id":entity_id}


func fund_construction_from_storage(world: Dictionary, order_id: String, storage_id: String) -> Dictionary:
	var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
	var storage: Dictionary = world.get("entities", {}).get(storage_id, {})
	if order.is_empty() or str(order.get("status", "")) in ["COMPLETE", "CANCELLED", "FAILED"]:
		return _failure("INVALID_CONSTRUCTION_ORDER", "Construction order is not fundable")
	if str(storage.get("kind", "")) != "STORAGE" or str(storage.get("status", "")) == "UNDER_CONSTRUCTION":
		return _failure("INVALID_STORAGE", "Construction materials must come from operational storage")
	var previous_status := str(order.get("status", ""))
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
	if moved.is_empty():
		return _failure("INPUT_SHORTAGE", "No required construction materials are available in this storage")
	order["delivered_items"] = delivered
	if _construction_funded(order):
		order["status"] = "READY"
		order["blocked_reason"] = ""
	else:
		order["status"] = "WAITING_MATERIALS"
		order["blocked_reason"] = "MISSING_MATERIALS"
	if not moved.is_empty() or previous_status != str(order.get("status", "")):
		_bump_runtime_revision(world)
	return {"ok":true, "moved":moved, "fully_funded":_construction_funded(order)}


## Stages materials offered by the same Location Inventory. The caller owns the
## matching removal from that inventory inside the same transaction.
func fund_construction_from_external(world: Dictionary, order_id: String, available_items: Dictionary) -> Dictionary:
	var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
	if order.is_empty() or str(order.get("status", "")) in ["COMPLETE", "CANCELLED", "FAILED"]:
		return _failure("INVALID_CONSTRUCTION_ORDER", "Construction order is not fundable")
	var previous_status := str(order.get("status", ""))
	var delivered: Dictionary = order.get("delivered_items", {})
	var moved := {}
	for item_id_value in _sorted_keys(order.get("required_items", {})):
		var item_id := str(item_id_value)
		var need := maxi(0, int(order.get("required_items", {}).get(item_id, 0)) - int(delivered.get(item_id, 0)))
		var quantity := mini(need, maxi(0, int(available_items.get(item_id, 0))))
		if quantity <= 0:
			continue
		delivered[item_id] = int(delivered.get(item_id, 0)) + quantity
		moved[item_id] = quantity
		_add_statistic(world, "construction_delivered", item_id, quantity)
	if moved.is_empty():
		return _failure("INPUT_SHORTAGE", "No required construction materials are available in this inventory")
	order["delivered_items"] = delivered
	if _construction_funded(order):
		order["status"] = "READY"
		order["blocked_reason"] = ""
	else:
		order["status"] = "WAITING_MATERIALS"
		order["blocked_reason"] = "MISSING_MATERIALS"
	if not moved.is_empty() or previous_status != str(order.get("status", "")):
		_bump_runtime_revision(world)
	return {"ok":true, "moved":moved, "fully_funded":_construction_funded(order)}


## Moves physical items across the FactoryWorld boundary without creating or
## destroying them. The application layer owns the matching Location Inventory
## mutation and wraps both sides in one GameStateTransaction.
func deposit_storage_inventory(world: Dictionary, storage_id: String, item_id: String, requested: int) -> Dictionary:
	if item_id.is_empty() or requested <= 0:
		return _failure("INVALID_TRANSFER", "Factory storage transfer requires an item and positive quantity")
	var storage: Dictionary = world.get("entities", {}).get(storage_id, {})
	if str(storage.get("kind", "")) != "STORAGE" or str(storage.get("status", "")) == "UNDER_CONSTRUCTION":
		return _failure("INVALID_STORAGE", "Factory transfer requires an operational storage entity")
	var free_capacity := _target_free_capacity(storage, item_id)
	if free_capacity < requested:
		return _failure("STORAGE_FULL", "Factory storage has insufficient capacity for the requested transfer")
	var moved := requested
	var inventory: Dictionary = storage.get("inventory", {})
	inventory[item_id] = int(inventory.get(item_id, 0)) + moved
	_add_statistic(world, "external_imported", item_id, moved)
	_bump_runtime_revision(world)
	return {"ok":true, "moved":moved, "storage_id":storage_id, "item_id":item_id}


func withdraw_storage_inventory(world: Dictionary, storage_id: String, item_id: String, requested: int) -> Dictionary:
	if item_id.is_empty() or requested <= 0:
		return _failure("INVALID_TRANSFER", "Factory storage transfer requires an item and positive quantity")
	var storage: Dictionary = world.get("entities", {}).get(storage_id, {})
	if str(storage.get("kind", "")) != "STORAGE" or str(storage.get("status", "")) == "UNDER_CONSTRUCTION":
		return _failure("INVALID_STORAGE", "Factory transfer requires an operational storage entity")
	var inventory: Dictionary = storage.get("inventory", {})
	var on_hand := maxi(0, int(inventory.get(item_id, 0)))
	if on_hand < requested:
		return _failure("STORAGE_EMPTY", "Factory storage does not contain the requested quantity")
	var moved := requested
	inventory[item_id] = int(inventory.get(item_id, 0)) - moved
	_add_statistic(world, "external_exported", item_id, moved)
	_bump_runtime_revision(world)
	return {"ok":true, "moved":moved, "storage_id":storage_id, "item_id":item_id}


## Consumes a fully preflighted quantity from physical Factory custody without
## pretending it crossed back into Location inventory. The application layer
## calls this only inside the same transaction that starts a Megastructure phase.
func consume_storage_inventory(world: Dictionary, storage_id: String, item_id: String, requested: int) -> Dictionary:
	if item_id.is_empty() or requested <= 0:
		return _failure("INVALID_TRANSFER", "Factory storage consumption requires an item and positive quantity")
	var storage: Dictionary = world.get("entities", {}).get(storage_id, {})
	if str(storage.get("kind", "")) != "STORAGE" or str(storage.get("status", "")) == "UNDER_CONSTRUCTION":
		return _failure("INVALID_STORAGE", "Factory consumption requires an operational storage entity")
	var inventory: Dictionary = storage.get("inventory", {})
	var on_hand := maxi(0, int(inventory.get(item_id, 0)))
	if on_hand < requested:
		return _failure("STORAGE_EMPTY", "Factory storage does not contain the requested quantity")
	inventory[item_id] = on_hand - requested
	_add_statistic(world, "consumed", item_id, requested)
	_bump_runtime_revision(world)
	return {"ok":true, "moved":requested, "storage_id":storage_id, "item_id":item_id}


## Reconfigures an existing physical machine without destroying buffered cargo.
## Cargo edges whose ports no longer exist are removed atomically so a stale
## route cannot continue feeding or draining an incompatible recipe.
func set_entity_recipe(world: Dictionary, entity_id: String, recipe_id: String) -> Dictionary:
	var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
	if entity.is_empty():
		return _failure("UNKNOWN_ENTITY", "The selected Factory entity does not exist")
	if str(entity.get("kind", "")) != "MACHINE":
		return _failure("INVALID_MACHINE", "Only a completed Factory machine can change recipe")
	var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
	var recipe: Dictionary = recipe_definitions.get(recipe_id, {})
	if recipe.is_empty() or not definition.get("recipe_ids", []).has(recipe_id):
		return _failure("INCOMPATIBLE_RECIPE", "The selected recipe is incompatible with this machine")
	var previous_recipe_id := str(entity.get("recipe_id", ""))
	if previous_recipe_id == recipe_id:
		return {"ok":true, "entity_id":entity_id, "previous_recipe_id":previous_recipe_id, "recipe_id":recipe_id, "removed_link_ids":[]}
	entity["recipe_id"] = recipe_id
	entity["progress"] = 0.0
	entity["actual_rate"] = 0.0
	entity["status"] = "READY"
	var removed_link_ids: Array[String] = []
	for link_id_value in _sorted_keys(world.get("links", {})):
		var link_id := str(link_id_value)
		var link: Dictionary = world.get("links", {}).get(link_id, {})
		if str(link.get("kind", "")) != "CARGO":
			continue
		var source: Dictionary = world.get("entities", {}).get(str(link.get("source_id", "")), {})
		var target: Dictionary = world.get("entities", {}).get(str(link.get("target_id", "")), {})
		var item_id := str(link.get("item_id", ""))
		if (str(link.get("source_id", "")) == entity_id and not _entity_can_output(world, source, item_id)) or (str(link.get("target_id", "")) == entity_id and not _entity_can_input(target, item_id)):
			removed_link_ids.append(link_id)
	for link_id in removed_link_ids:
		world.get("links", {}).erase(link_id)
	_bump_topology_revision(world)
	return {
		"ok":true,
		"entity_id":entity_id,
		"previous_recipe_id":previous_recipe_id,
		"recipe_id":recipe_id,
		"removed_link_ids":removed_link_ids
	}


func connect_entities(world: Dictionary, kind: String, source_id: String, target_id: String, item_id: String = "", capacity_per_second: float = 1.0, priority: int = 1, source_port_id: String = "", target_port_id: String = "", lane_count: int = 1, tier: String = DEFAULT_CARGO_LINK_TIER, path_tiles: Array = []) -> Dictionary:
	kind = kind.to_upper()
	if kind not in LINK_KINDS or source_id == target_id:
		return _failure("INVALID_LINK", "Link kind and endpoints must be valid")
	var source: Dictionary = world.get("entities", {}).get(source_id, {})
	var target: Dictionary = world.get("entities", {}).get(target_id, {})
	if source.is_empty() or target.is_empty():
		return _failure("MISSING_ENDPOINT", "Both link endpoints must exist")
	# POWER has no item channel. Canonicalize before duplicate detection so an
	# ignored payload item cannot create parallel copies of the same edge.
	if kind == "POWER":
		item_id = ""
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
			var expected_source_port_id := _cargo_port_id_for_entity(source, source_id, "OUTPUT", item_id)
			var expected_target_port_id := _cargo_port_id_for_entity(target, target_id, "INPUT", item_id)
			if not source_port_id.is_empty() and source_port_id != expected_source_port_id:
				return _failure("INVALID_SOURCE_PORT", "Cargo source port does not match the selected entity and item")
			if not target_port_id.is_empty() and target_port_id != expected_target_port_id:
				return _failure("INVALID_TARGET_PORT", "Cargo target port does not match the selected entity and item")
			if lane_count < 1 or lane_count > MAX_CARGO_LINK_LANES:
				return _failure("INVALID_LANE_COUNT", "Cargo link lane count is outside the supported range")
			if tier.strip_edges().is_empty():
				return _failure("INVALID_LINK_TIER", "Cargo link tier must be a stable non-empty identifier")
			var source_kind := str(source.get("kind", ""))
			var target_kind := str(target.get("kind", ""))
			var source_allows_fan_out := source_kind == "STORAGE" or (source_kind == "ROUTER" and _router_mode(source) != "MERGE")
			var target_allows_fan_in := target_kind == "ROUTER" and _router_mode(target) != "SPLIT"
			for link_value in world.get("links", {}).values():
				var occupied := link_value as Dictionary
				if str(occupied.get("kind", "")) != "CARGO" or str(occupied.get("item_id", "")) != item_id:
					continue
				if str(occupied.get("source_id", "")) == source_id and not source_allows_fan_out:
					return _failure("CARGO_OUTPUT_OCCUPIED", "A producer output needs a Cargo Splitter before it can fan out")
				if str(occupied.get("target_id", "")) == target_id and not target_allows_fan_in:
					return _failure("CARGO_INPUT_OCCUPIED", "A target item port accepts one incoming cargo link")
		"POWER":
			var source_definition: Dictionary = building_definitions.get(str(source.get("definition_id", "")), {})
			var target_definition: Dictionary = building_definitions.get(str(target.get("definition_id", "")), {})
			if float(source_definition.get("power_generation_kw", 0.0)) <= EPSILON or float(target_definition.get("power_demand_kw", 0.0)) <= EPSILON:
				return _failure("INVALID_LINK", "Power links require a generating source and a consuming target")
			if not source_port_id.is_empty() and source_port_id != _power_port_id(source_id, "OUTPUT"):
				return _failure("INVALID_SOURCE_PORT", "Power source port does not match the selected generator")
			if not target_port_id.is_empty() and target_port_id != _power_port_id(target_id, "INPUT"):
				return _failure("INVALID_TARGET_PORT", "Power target port does not match the selected consumer")
	var link_id := _next_id(world, "next_link_serial", "LINK-")
	var link := {
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
	if kind == "CARGO":
		link["source_port_id"] = _cargo_port_id_for_entity(source, source_id, "OUTPUT", item_id) if source_port_id.is_empty() else source_port_id
		link["target_port_id"] = _cargo_port_id_for_entity(target, target_id, "INPUT", item_id) if target_port_id.is_empty() else target_port_id
		link["lane_count"] = lane_count
		link["tier"] = _normalize_cargo_link_tier(tier)
		link["path_tiles"] = _orthogonal_link_path_tiles(world, source, target, "CARGO") if path_tiles.is_empty() else _path_tiles_from_value(path_tiles)
		link["congestion"] = 0.0
		link["blocked_reason"] = ""
		if not _path_tiles_are_valid_for_link(world, link.get("path_tiles", []), source, target, "CARGO"):
			return _failure("INVALID_LINK_PATH", "Cargo path must be orthogonal, endpoint-aligned and inside the Factory world")
	else:
		link["source_port_id"] = _power_port_id(source_id, "OUTPUT")
		link["target_port_id"] = _power_port_id(target_id, "INPUT")
		link["path_tiles"] = _orthogonal_link_path_tiles(world, source, target, "POWER")
		link["congestion"] = 0.0
		link["blocked_reason"] = ""
	world["links"][link_id] = link
	_bump_topology_revision(world)
	return {"ok":true, "link_id":link_id}


func remove_link(world: Dictionary, link_id: String) -> bool:
	var removed: bool = bool(world.get("links", {}).erase(link_id))
	if removed:
		_bump_topology_revision(world)
	return removed


## Reconfigures routing policy without granting free physical equipment. Cargo
## throughput, lanes, tier, and geometry require a future construction/economy
## transaction; callers cannot mutate those fields through this command.
func configure_link(world: Dictionary, link_id: String, configuration: Dictionary = {}) -> Dictionary:
	var link: Dictionary = world.get("links", {}).get(link_id, {})
	if link.is_empty():
		return _failure("UNKNOWN_LINK", "The selected Factory link does not exist")
	for physical_key in ["capacity_per_second", "lane_count", "tier", "path_tiles"]:
		if configuration.has(physical_key):
			return _failure("LINK_UPGRADE_REQUIRES_CONSTRUCTION", "Physical route changes require an authoritative construction transaction")
	var candidate := link.duplicate(true)
	var changed := false
	var kind := str(candidate.get("kind", "")).to_upper()
	if kind != "CARGO":
		return _failure("LINK_CONFIGURATION_UNSUPPORTED", "This link type has no configurable routing policy")
	if configuration.has("priority"):
		var requested_priority := int(configuration.get("priority", candidate.get("priority", 1)))
		if requested_priority < 0 or requested_priority > 2:
			return _failure("INVALID_LINK_PRIORITY", "Factory link priority must be between zero and two")
		if requested_priority != int(candidate.get("priority", 1)):
			candidate["priority"] = requested_priority
			changed = true
	if kind == "CARGO":
		var source: Dictionary = world.get("entities", {}).get(str(candidate.get("source_id", "")), {})
		var target: Dictionary = world.get("entities", {}).get(str(candidate.get("target_id", "")), {})
		if source.is_empty() or target.is_empty():
			return _failure("MISSING_ENDPOINT", "Cargo link endpoints must exist")
		var generated_path := _orthogonal_link_path_tiles(world, source, target, "CARGO")
		if not _path_tiles_are_valid_for_link(world, candidate.get("path_tiles", []), source, target, "CARGO"):
			candidate["path_tiles"] = generated_path
			changed = true
	if not changed:
		return {"ok":true, "link_id":link_id, "changed":false}
	world["links"][link_id] = candidate
	_bump_topology_revision(world)
	return {"ok":true, "link_id":link_id, "changed":true}


## Cancels an incomplete Factory order atomically. Delivered goods remain a
## staging manifest rather than being silently deleted; the application facade
## decides the valid physical destination inside its outer transaction.
func cancel_construction(world: Dictionary, order_id: String) -> Dictionary:
	var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
	if order.is_empty() or str(order.get("status", "")) in ["COMPLETE", "CANCELLED", "FAILED"]:
		return _failure("INVALID_CONSTRUCTION_ORDER", "The selected Factory construction order cannot be cancelled")
	var staging_manifest := _positive_item_manifest(order.get("delivered_items", {}))
	world["construction_orders"].erase(order_id)
	_bump_topology_revision(world)
	return {
		"ok":true,
		"order_id":order_id,
		"entity_id":str(order.get("entity_id", "")),
		"staging_manifest":staging_manifest,
		"returned_items":staging_manifest.duplicate(true)
	}


## Removes an empty completed entity and all of its incident links in one
## topology mutation. Buffered physical cargo is fail-closed so the application
## cannot accidentally destroy assets while using a visual demolition action.
func remove_entity(world: Dictionary, entity_id: String) -> Dictionary:
	var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
	if entity.is_empty():
		return _failure("UNKNOWN_ENTITY", "The selected Factory entity does not exist")
	var buffered_items := _entity_buffer_manifest(entity)
	if not buffered_items.is_empty():
		return {
			"ok":false,
			"reason_code":"ENTITY_BUFFER_NOT_EMPTY",
			"reason":"Factory entities with buffered physical cargo cannot be removed",
			"entity_id":entity_id,
			"buffered_items":buffered_items
		}
	var removed_link_ids: Array[String] = []
	for link_id_value in _sorted_keys(world.get("links", {})):
		var link_id := str(link_id_value)
		var link: Dictionary = world.get("links", {}).get(link_id, {})
		if str(link.get("source_id", "")) == entity_id or str(link.get("target_id", "")) == entity_id:
			removed_link_ids.append(link_id)
	for link_id in removed_link_ids:
		world["links"].erase(link_id)
	world["entities"].erase(entity_id)
	_bump_topology_revision(world)
	return {"ok":true, "entity_id":entity_id, "removed_link_ids":removed_link_ids}


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
	if elapsed_ms > 0.0:
		_bump_runtime_revision(world)
		if events.any(func(event): return str((event as Dictionary).get("type", "")) == "FactoryConstructionCompleted"):
			_bump_topology_revision(world)
	return {"simulated_ms":maxf(0.0, elapsed_ms), "steps":steps, "events":events}


## Recompute topology-derived power and the corresponding zero-time operational
## presentation without advancing clocks, moving cargo, or producing items.
## Application commands use this immediately after a topology change so UI and
## downstream availability checks observe one internally consistent graph.
func refresh_derived_state(world: Dictionary) -> Dictionary:
	var power_factors := _calculate_power_factors(world)
	_refresh_operational_status(world, power_factors)
	return power_factors


## Factory evaluates physical flow in fixed deterministic ticks. The top-level
## simulator uses the same tick as a cross-domain boundary whenever the world
## can produce, extract, or complete funded construction, so a result created at
## the end of a tick cannot be consumed retroactively during that tick.
func synchronization_boundary_ms(world: Dictionary) -> float:
	var result := INF
	var construction_capacity := _construction_capacity_per_second(world)
	var orders: Array = world.get("construction_orders", {}).values()
	orders.sort_custom(func(a, b):
		var a_priority := int((a as Dictionary).get("priority", 50))
		var b_priority := int((b as Dictionary).get("priority", 50))
		return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")) if a_priority == b_priority else a_priority > b_priority
	)
	for order_value in orders:
		var order := order_value as Dictionary
		if _construction_funded(order) and construction_capacity > EPSILON:
			var work_remaining := maxf(0.0, float(order.get("work_required", 1.0)) - float(order.get("work_done", 0.0)))
			result = minf(result, maxf(0.001, work_remaining / construction_capacity * 1000.0))
			break
	for entity_value in world.get("entities", {}).values():
		if str((entity_value as Dictionary).get("kind", "")) in ["EXTRACTOR", "MACHINE"]:
			var tick_ms := maxf(0.05, float(rules.get("simulation_step_seconds", DEFAULT_STEP_SECONDS))) * 1000.0
			var tick_progress := fposmod(maxf(0.0, float(world.get("elapsed_ms", 0.0))), tick_ms)
			result = minf(result, tick_ms if tick_progress <= 0.001 else tick_ms - tick_progress)
			break
	return result


func _step(world: Dictionary, seconds: float, events: Array[Dictionary]) -> void:
	var power_factors := _calculate_power_factors(world)
	for link_value in world.get("links", {}).values():
		var link := link_value as Dictionary
		link["last_flow"] = 0.0
		if str(link.get("kind", "")) == "CARGO":
			link["blocked_reason"] = ""
			link["capacity_progress"] = float(link.get("capacity_progress", 0.0)) \
				+ maxf(0.0, float(link.get("capacity_per_second", 0.0))) * _cargo_link_power_factor(world, link) * seconds
	_transfer_cargo(world, seconds)
	_run_extractors(world, seconds, power_factors, events)
	_run_machines(world, seconds, power_factors, events)
	_transfer_cargo(world, seconds)
	# Unused whole-unit throughput expires at the end of this simulation step.
	# Only sub-unit progress crosses a boundary, so a blocked belt cannot bank
	# hours of capacity and burst it after downstream space becomes available.
	for link_value in world.get("links", {}).values():
		var link := link_value as Dictionary
		if str(link.get("kind", "")) == "CARGO":
			var progress := maxf(0.0, float(link.get("capacity_progress", 0.0)))
			link["capacity_progress"] = progress - floorf(progress)
	_stage_automatic_construction_materials(world, events)
	_advance_construction(world, seconds, events)
	_update_cargo_link_diagnostics(world)
	_refresh_router_operational_status(world)


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


func _refresh_operational_status(world: Dictionary, power_factors: Dictionary) -> void:
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		match str(entity.get("kind", "")):
			"EXTRACTOR":
				_apply_operational_projection(entity, _extractor_operational_projection(world, entity_id, entity, power_factors))
			"MACHINE":
				_apply_operational_projection(entity, _machine_operational_projection(entity_id, entity, power_factors))
	_refresh_router_operational_status(world)


func _refresh_router_operational_status(world: Dictionary) -> void:
	var outbound_rate := {}
	var outbound_links := {}
	for link_value in world.get("links", {}).values():
		var link := link_value as Dictionary
		if str(link.get("kind", "")) == "CARGO":
			var source_id := str(link.get("source_id", ""))
			outbound_rate[source_id] = float(outbound_rate.get(source_id, 0.0)) + maxf(0.0, float(link.get("last_flow", 0.0)))
			var links: Array = outbound_links.get(source_id, [])
			links.append(link)
			outbound_links[source_id] = links
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		if str(entity.get("kind", "")) != "ROUTER":
			continue
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		var requires_power := float(definition.get("power_demand_kw", 0.0)) > EPSILON
		var factor := clampf(float(entity.get("power_factor", 1.0)), 0.0, 1.0)
		var actual_rate := maxf(0.0, float(outbound_rate.get(entity_id, 0.0)))
		entity["actual_rate"] = actual_rate
		if requires_power and factor <= EPSILON:
			entity["status"] = "NO_POWER"
		elif requires_power and factor < 1.0 - EPSILON:
			entity["status"] = "POWER_LIMITED"
		elif actual_rate > EPSILON:
			entity["status"] = "FLOWING"
		elif _dictionary_total(entity.get("inventory", {})) > 0 and not _router_has_available_output(world, entity, outbound_links.get(entity_id, [])):
			entity["status"] = "OUTPUT_FULL"
		else:
			entity["status"] = "READY"


func _router_has_available_output(world: Dictionary, entity: Dictionary, links: Array) -> bool:
	var inventory: Dictionary = entity.get("inventory", {})
	for item_id_value in _sorted_keys(inventory):
		var item_id := str(item_id_value)
		if int(inventory.get(item_id_value, 0)) <= 0:
			continue
		for link_value in links:
			var link := link_value as Dictionary
			if str(link.get("item_id", "")) != item_id or float(link.get("capacity_per_second", 0.0)) <= EPSILON:
				continue
			var target: Dictionary = world.get("entities", {}).get(str(link.get("target_id", "")), {})
			if not target.is_empty() and _target_free_capacity(target, item_id) > 0 and _cargo_link_power_factor(world, link) > EPSILON:
				return true
	return false


func _apply_operational_projection(entity: Dictionary, projection: Dictionary) -> void:
	entity["status"] = str(projection.get("status", "IDLE"))
	entity["actual_rate"] = maxf(0.0, float(projection.get("actual_rate", 0.0)))


func _extractor_operational_projection(world: Dictionary, entity_id: String, entity: Dictionary, power_factors: Dictionary) -> Dictionary:
	var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
	var resource_profile := resource_coverage_for_footprint(world, entity.get("footprint", {}), float(definition.get("resource_coverage_loss_per_missing_tile", 0.1)))
	_apply_extractor_resource_profile(entity, resource_profile)
	var projection := {"status":"NO_RESOURCE", "actual_rate":0.0, "resource_profile":resource_profile, "resource_id":str(resource_profile.get("resource_id", "")), "free":0}
	if int(resource_profile.get("covered_resource_tiles", 0)) <= 0 or bool(resource_profile.get("mixed_resource_types", false)):
		return projection
	var factor := float(power_factors.get(entity_id, 0.0))
	if factor <= EPSILON:
		projection["status"] = "NO_POWER"
		return projection
	var free := maxi(0, int(definition.get("output_capacity", 0)) - _dictionary_total(entity.get("outputs", {})))
	projection["free"] = free
	if free <= 0:
		projection["status"] = "OUTPUT_FULL"
		return projection
	var sustainable_rate := float(resource_profile.get("sustainable_rate_per_second", 0.0))
	var installed_rate := maxf(0.0, float(definition.get("mining_rate_per_second", 0.0)))
	projection["actual_rate"] = minf(installed_rate * maxf(EPSILON, float(resource_profile.get("average_grade", 1.0))) * float(resource_profile.get("coverage_efficiency", 0.0)) * factor, sustainable_rate)
	projection["status"] = "POWER_LIMITED" if factor < 0.999 else ("PARTIAL_COVERAGE" if float(resource_profile.get("coverage_efficiency", 0.0)) < 0.999 else "RUNNING")
	return projection


func _machine_operational_projection(entity_id: String, entity: Dictionary, power_factors: Dictionary) -> Dictionary:
	var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
	var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
	var projection := {"status":"NO_RECIPE", "actual_rate":0.0, "recipe":recipe, "available_cycles":0, "output_cycles":0}
	if recipe.is_empty():
		return projection
	var factor := float(power_factors.get(entity_id, 0.0))
	if factor <= EPSILON:
		projection["status"] = "NO_POWER"
		return projection
	var available_cycles := _available_recipe_input_cycles(entity, recipe)
	projection["available_cycles"] = available_cycles
	if available_cycles <= 0:
		projection["status"] = "INPUT_SHORTAGE"
		return projection
	# Reserve output buffer room before advancing cycle progress. This is the
	# physical backpressure boundary: a machine cannot complete into cargo space
	# it does not own, including recipes with several output stacks.
	var output_reservation := _machine_output_capacity_reservation(entity, definition, recipe)
	var output_cycles := maxi(0, int(output_reservation.get("cycles", 0)))
	projection["output_reservation"] = output_reservation
	projection["output_cycles"] = output_cycles
	if output_cycles <= 0:
		projection["status"] = "OUTPUT_FULL"
		return projection
	projection["actual_rate"] = maxf(EPSILON, float(definition.get("speed", 1.0))) / maxf(EPSILON, float(recipe.get("duration_seconds", 1.0))) * factor
	projection["status"] = "POWER_LIMITED" if factor < 0.999 else "RUNNING"
	return projection


func _run_extractors(world: Dictionary, seconds: float, power_factors: Dictionary, events: Array[Dictionary]) -> void:
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		if str(entity.get("kind", "")) != "EXTRACTOR":
			continue
		var projection := _extractor_operational_projection(world, entity_id, entity, power_factors)
		_apply_operational_projection(entity, projection)
		if str(projection.get("status", "")) in ["NO_RESOURCE", "NO_POWER", "OUTPUT_FULL"]:
			continue
		var resource_id := str(projection.get("resource_id", ""))
		var current := maxi(0, int(entity.get("outputs", {}).get(resource_id, 0)))
		var free := maxi(0, int(projection.get("free", 0)))
		var actual_rate := maxf(0.0, float(projection.get("actual_rate", 0.0)))
		entity["progress"] = float(entity.get("progress", 0.0)) + actual_rate * seconds
		var produced := mini(free, maxi(0, floori(float(entity.get("progress", 0.0)) + EPSILON)))
		if produced > 0:
			entity["outputs"][resource_id] = current + produced
			entity["progress"] = 0.0 if produced >= free else maxf(0.0, float(entity.get("progress", 0.0)) - float(produced))
			_add_statistic(world, "produced", resource_id, produced)
			events.append({
				"type":"FactoryResourceExtracted",
				"world_id":str(world.get("world_id", "")),
				"entity_id":entity_id,
				"resource_id":resource_id,
				"activity_id":str(rules.get("resource_activity_ids", {}).get(resource_id, "")),
				"quantity":produced
			})


func _run_machines(world: Dictionary, seconds: float, power_factors: Dictionary, events: Array[Dictionary]) -> void:
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		if str(entity.get("kind", "")) != "MACHINE":
			continue
		var projection := _machine_operational_projection(entity_id, entity, power_factors)
		_apply_operational_projection(entity, projection)
		if str(projection.get("status", "")) in ["NO_RECIPE", "NO_POWER", "INPUT_SHORTAGE", "OUTPUT_FULL"]:
			continue
		var recipe := projection.get("recipe", {}) as Dictionary
		var available_cycles := maxi(0, int(projection.get("available_cycles", 0)))
		var output_cycles := maxi(0, int(projection.get("output_cycles", 0)))
		var output_reservation: Dictionary = projection.get("output_reservation", {})
		var cycle_rate := maxf(0.0, float(projection.get("actual_rate", 0.0)))
		entity["progress"] = float(entity.get("progress", 0.0)) + cycle_rate * seconds
		var completed_cycles := mini(mini(available_cycles, output_cycles), maxi(0, floori(float(entity.get("progress", 0.0)) + EPSILON)))
		completed_cycles = mini(completed_cycles, maxi(0, int(output_reservation.get("cycles", output_cycles))))
		if completed_cycles > 0:
			var produced_items := {}
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
				produced_items[item_id] = int(produced_items.get(item_id, 0)) + quantity
			entity["progress"] = maxf(0.0, float(entity.get("progress", 0.0)) - float(completed_cycles))
			events.append({
				"type":"FactoryRecipeCompleted",
				"world_id":str(world.get("world_id", "")),
				"entity_id":entity_id,
				"recipe_id":str(recipe.get("id", "")),
				"activity_id":str(recipe.get("activity_id", "")),
				"completed_cycles":completed_cycles,
				"produced":produced_items
			})


func _transfer_cargo(world: Dictionary, seconds: float) -> void:
	var source_groups := {}
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
		if not source_groups.has(group_key):
			source_groups[group_key] = []
		source_groups[group_key].append({
			"link_id":link_id,
			"source_id":str(link.get("source_id", "")),
			"target_id":str(link.get("target_id", "")),
			"item_id":item_id,
			"demand":demand,
			"priority":int(link.get("priority", 1))
		})
	# First reserve each source's finite inventory fairly across its outgoing
	# routes. The second pass reserves each target's finite input space across
	# independent sources, preventing a merger's lexical-first source from
	# starving every other incoming route.
	var source_grants := {}
	var candidates_by_link := {}
	for group_key_value in _sorted_keys(source_groups):
		var candidates: Array = source_groups[group_key_value]
		if candidates.is_empty():
			continue
		var link: Dictionary = world["links"][str(candidates[0].get("link_id", ""))]
		var source: Dictionary = world["entities"][str(link.get("source_id", ""))]
		var item_id := str(link.get("item_id", ""))
		var allocations := _fair_allocations(source, item_id, candidates, _source_quantity(source, item_id), "OUT")
		for candidate_value in candidates:
			var candidate := candidate_value as Dictionary
			var candidate_link_id := str(candidate.get("link_id", ""))
			var granted := maxi(0, int(allocations.get(candidate_link_id, 0)))
			if granted > 0:
				source_grants[candidate_link_id] = granted
				candidates_by_link[candidate_link_id] = candidate

	var target_groups := {}
	for link_id_value in _sorted_keys(source_grants):
		var link_id := str(link_id_value)
		var candidate: Dictionary = candidates_by_link.get(link_id, {})
		# Input/inventory capacity is shared across item types, so all incoming
		# routes for one target participate in the same deterministic arbitration.
		var target_key := str(candidate.get("target_id", ""))
		var target_candidates: Array = target_groups.get(target_key, [])
		var target_candidate := candidate.duplicate(false)
		target_candidate["demand"] = int(source_grants.get(link_id, 0))
		target_candidates.append(target_candidate)
		target_groups[target_key] = target_candidates

	for target_key_value in _sorted_keys(target_groups):
		var target_candidates: Array = target_groups.get(target_key_value, [])
		if target_candidates.is_empty():
			continue
		var first_candidate := target_candidates[0] as Dictionary
		var target_id := str(first_candidate.get("target_id", ""))
		var item_id := str(first_candidate.get("item_id", ""))
		var target: Dictionary = world.get("entities", {}).get(target_id, {})
		var target_allocations := _fair_allocations(target, "SHARED", target_candidates, _target_free_capacity(target, item_id), "IN")
		for candidate_value in target_candidates:
			var candidate := candidate_value as Dictionary
			var link_id := str(candidate.get("link_id", ""))
			item_id = str(candidate.get("item_id", ""))
			var quantity := maxi(0, int(target_allocations.get(link_id, 0)))
			var cargo_link: Dictionary = world.get("links", {}).get(link_id, {})
			var source: Dictionary = world.get("entities", {}).get(str(cargo_link.get("source_id", "")), {})
			quantity = mini(mini(quantity, _source_quantity(source, item_id)), _target_free_capacity(target, item_id))
			if quantity <= 0:
				continue
			_remove_source_quantity(source, item_id, quantity)
			_add_target_quantity(target, item_id, quantity)
			cargo_link["capacity_progress"] = maxf(0.0, float(cargo_link.get("capacity_progress", 0.0)) - float(quantity))
			cargo_link["last_flow"] = float(cargo_link.get("last_flow", 0.0)) + float(quantity) / maxf(EPSILON, seconds)
			cargo_link["total_transferred"] = int(cargo_link.get("total_transferred", 0)) + quantity
			_add_statistic(world, "transferred", item_id, quantity)


func _cargo_link_power_factor(world: Dictionary, link: Dictionary) -> float:
	var result := 1.0
	for entity_id_value in [str(link.get("source_id", "")), str(link.get("target_id", ""))]:
		var entity: Dictionary = world.get("entities", {}).get(str(entity_id_value), {})
		if str(entity.get("kind", "")) == "ROUTER":
			result = minf(result, clampf(float(entity.get("power_factor", 0.0)), 0.0, 1.0))
	return result


## Cargo diagnostics are calculated after both deterministic transfer phases.
## This keeps a newly-produced item eligible in the second phase while still
## exposing downstream full-buffer backpressure on the final world state.
func _update_cargo_link_diagnostics(world: Dictionary) -> void:
	for link_id_value in _sorted_keys(world.get("links", {})):
		var link: Dictionary = world.get("links", {}).get(link_id_value, {})
		if str(link.get("kind", "")) != "CARGO":
			continue
		var source: Dictionary = world.get("entities", {}).get(str(link.get("source_id", "")), {})
		var target: Dictionary = world.get("entities", {}).get(str(link.get("target_id", "")), {})
		var item_id := str(link.get("item_id", ""))
		var capacity := maxf(0.0, float(link.get("capacity_per_second", 0.0)))
		var flow := maxf(0.0, float(link.get("last_flow", 0.0)))
		if source.is_empty() or target.is_empty() or item_id.is_empty() or not _entity_can_output(world, source, item_id) or not _entity_can_input(target, item_id):
			link["blocked_reason"] = "INCOMPATIBLE_ENDPOINT"
			link["congestion"] = 1.0
			continue
		var source_waiting := _source_quantity(source, item_id) > 0
		var target_full := _target_free_capacity(target, item_id) <= 0
		var transport_power := _cargo_link_power_factor(world, link)
		link["congestion"] = 1.0 if source_waiting and target_full else 0.0
		if transport_power <= EPSILON:
			link["blocked_reason"] = "NO_POWER"
			link["congestion"] = 1.0
		elif source_waiting and target_full:
			link["blocked_reason"] = "TARGET_FULL"
		elif flow > EPSILON:
			link["blocked_reason"] = ""
		elif capacity <= EPSILON:
			link["blocked_reason"] = "NO_CAPACITY"
		elif not source_waiting:
			link["blocked_reason"] = "SOURCE_EMPTY"
		else:
			link["blocked_reason"] = ""


func _fair_allocations(source: Dictionary, item_id: String, candidates: Array, available: int, cursor_namespace: String = "OUT") -> Dictionary:
	var allocations := {}
	var remaining := maxi(0, available)
	for priority in [2, 1, 0]:
		var priority_candidates: Array = candidates.filter(func(candidate): return int((candidate as Dictionary).get("priority", 1)) == priority)
		if priority_candidates.is_empty() or remaining <= 0:
			continue
		var priority_allocations := _fair_priority_allocations(source, item_id, priority, priority_candidates, remaining, cursor_namespace)
		for link_id_value in priority_allocations.keys():
			var link_id := str(link_id_value)
			var quantity := int(priority_allocations.get(link_id, 0))
			allocations[link_id] = quantity
			remaining -= quantity
	return allocations


func _fair_priority_allocations(source: Dictionary, item_id: String, priority: int, candidates: Array, available: int, cursor_namespace: String) -> Dictionary:
	var allocations := {}
	var active := candidates.duplicate(true)
	active.sort_custom(func(a, b): return str(a.get("link_id", "")) < str(b.get("link_id", "")))
	var cursor_key := "%s:%s:%d" % [cursor_namespace, item_id, priority]
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


## A queued automatic project remains a standing request for physical materials.
## This step follows cargo delivery, so new production can fund expansion without
## another UI click. Only STORAGE custody in this world is eligible: machine
## buffers and external Location inventories never become implicit supply.
func _stage_automatic_construction_materials(world: Dictionary, events: Array[Dictionary]) -> void:
	var orders: Array = world.get("construction_orders", {}).values().filter(func(order):
		return str((order as Dictionary).get("funding_policy", "MANUAL")) == "AUTO_SAME_LOCATION" and not _construction_funded(order)
	)
	if orders.is_empty():
		return
	orders.sort_custom(func(a, b):
		var a_priority := int((a as Dictionary).get("priority", 50))
		var b_priority := int((b as Dictionary).get("priority", 50))
		return str((a as Dictionary).get("id", "")) < str((b as Dictionary).get("id", "")) if a_priority == b_priority else a_priority > b_priority
	)
	var storage_ids: Array = []
	for storage_id in _sorted_keys(world.get("entities", {})):
		var storage: Dictionary = world.get("entities", {}).get(storage_id, {})
		if str(storage.get("kind", "")) == "STORAGE" and str(storage.get("status", "")) != "UNDER_CONSTRUCTION":
			storage_ids.append(storage_id)
	for order_value in orders:
		var order := order_value as Dictionary
		for storage_id in storage_ids:
			if _construction_funded(order):
				break
			var funded := fund_construction_from_storage(world, str(order.get("id", "")), str(storage_id))
			if bool(funded.get("ok", false)):
				events.append({
					"type":"FactoryConstructionFunded", "world_id":str(world.get("world_id", "")),
					"order_id":str(order.get("id", "")), "storage_id":str(storage_id),
					"automatic":true, "moved":funded.get("moved", {}).duplicate(true)
				})


func _advance_construction(world: Dictionary, seconds: float, events: Array[Dictionary]) -> void:
	var capacity := _construction_capacity_per_second(world)
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


func _construction_capacity_per_second(world: Dictionary) -> float:
	var capacity := maxf(0.0, float(rules.get("base_construction_capacity_per_second", 1.0)))
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		if str(entity.get("kind", "")) == "CONSTRUCTION":
			var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
			capacity += maxf(0.0, float(definition.get("construction_capacity_per_second", 0.0))) * float(entity.get("power_factor", 1.0))
	return capacity


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
		"topology_revision":int(world.get("topology_revision", 0)),
		"runtime_revision":int(world.get("runtime_revision", 0)),
		"resource_field_count":world.get("resource_fields", {}).size(),
		"entity_counts":entity_counts,
		"link_count":world.get("links", {}).size(),
		"construction_count":world.get("construction_orders", {}).size(),
		"statuses":statuses,
		"statistics":world.get("statistics", {}).duplicate(true)
	}


## Versioned, presentation-safe contract for the mining/production workspace.
## Arrays are identifier-sorted so a renderer never depends on Dictionary order.
## Resource fields intentionally have is_entity=false and expose no ports.
func workspace_snapshot(world: Dictionary) -> Dictionary:
	var resource_fields: Array = []
	for field_id_value in _sorted_keys(world.get("resource_fields", {})):
		var field_id := str(field_id_value)
		var resource_field: Dictionary = world.get("resource_fields", {}).get(field_id, {})
		var resource_id := str(resource_field.get("resource_id", ""))
		var field_footprint: Dictionary = resource_field.get("footprint", {})
		var field_size := _point(field_footprint.get("size", {}))
		resource_fields.append({
			"id":field_id,
			"node_kind":"RESOURCE_FIELD",
			"is_entity":false,
			"resource_id":resource_id,
			"resource_category":str(resource_field.get("resource_category", "solid")),
			"resource_color":str(rules.get("resource_colors", {}).get(resource_id, "#FFFFFF")),
			"footprint":field_footprint.duplicate(true),
			"grade":float(resource_field.get("grade", 1.0)),
			"potential_density":float(resource_field.get("potential_density", 1.0)),
			"mapped_potential_per_second":maxf(0.0, float(field_size.x * field_size.y) * float(resource_field.get("potential_density", 1.0))),
			"ports":{"inputs":[], "outputs":[], "accepts_power":false, "provides_power":false, "entries":[], "input_ports":[], "output_ports":[]}
		})

	var entities: Array = []
	var port_connections := _port_connection_index(world)
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		var status := str(entity.get("status", "IDLE"))
		entities.append({
			"id":entity_id,
			"node_kind":str(entity.get("kind", "UNKNOWN")),
			"is_entity":true,
			"definition_id":str(entity.get("definition_id", "")),
			"router_mode":str(definition.get("router_mode", "BIDIRECTIONAL")) if str(entity.get("kind", "")) == "ROUTER" else "",
			"name":str(definition.get("name", entity.get("definition_id", entity_id))),
			"recipe_id":str(entity.get("recipe_id", "")),
			"footprint":entity.get("footprint", {}).duplicate(true),
			"status":status,
			"status_tone":_status_tone(status),
			"blocker_code":_entity_blocker_code(status),
			"inputs":entity.get("inputs", {}).duplicate(true),
			"outputs":entity.get("outputs", {}).duplicate(true),
			"inventory":entity.get("inventory", {}).duplicate(true),
			"progress":maxf(0.0, float(entity.get("progress", 0.0))),
			"power_factor":clampf(float(entity.get("power_factor", 1.0)), 0.0, 1.0),
			"actual_rate":maxf(0.0, float(entity.get("actual_rate", 0.0))),
			"input_capacity":maxi(0, int(definition.get("input_capacity", 0))),
			"output_capacity":maxi(0, int(definition.get("output_capacity", 0))),
			"inventory_capacity":maxi(0, int(definition.get("inventory_capacity", 0))),
			"power_generation_kw":maxf(0.0, float(definition.get("power_generation_kw", 0.0))),
			"power_demand_kw":maxf(0.0, float(definition.get("power_demand_kw", 0.0))),
			"resource_id":str(entity.get("resource_id", "")),
			"coverage_efficiency":clampf(float(entity.get("coverage_efficiency", 0.0)), 0.0, 1.0),
			"average_grade":maxf(0.0, float(entity.get("average_grade", 0.0))),
			"sustainable_rate_per_second":maxf(0.0, float(entity.get("sustainable_rate_per_second", 0.0))),
			"covered_resource_tiles":maxi(0, int(entity.get("covered_resource_tiles", 0))),
			"footprint_tiles":maxi(0, int(entity.get("footprint_tiles", 0))),
			"missing_resource_tiles":maxi(0, int(entity.get("missing_resource_tiles", 0))),
			"ports":_entity_port_snapshot(entity_id, entity, port_connections)
		})

	var links: Array = []
	for link_id_value in _sorted_keys(world.get("links", {})):
		var link_id := str(link_id_value)
		var link: Dictionary = world.get("links", {}).get(link_id, {})
		var capacity := maxf(0.0, float(link.get("capacity_per_second", 0.0)))
		var last_flow := maxf(0.0, float(link.get("last_flow", 0.0)))
		var link_status := _link_status(world, link)
		var path_tiles: Array = link.get("path_tiles", []) if link.get("path_tiles", []) is Array else []
		links.append({
			"id":link_id,
			"kind":str(link.get("kind", "")),
			"source_id":str(link.get("source_id", "")),
			"target_id":str(link.get("target_id", "")),
			"item_id":str(link.get("item_id", "")),
			"source_port_id":str(link.get("source_port_id", "")),
			"target_port_id":str(link.get("target_port_id", "")),
			"capacity_per_second":capacity,
			"last_flow":last_flow,
			"utilization":0.0 if capacity <= EPSILON else clampf(last_flow / capacity, 0.0, 1.0),
			"lane_count":clampi(maxi(1, int(link.get("lane_count", 1))), 1, MAX_CARGO_LINK_LANES) if str(link.get("kind", "")) == "CARGO" else 0,
			"tier":str(link.get("tier", "")),
			"path_tiles":path_tiles.duplicate(true),
			"path_in_bounds":_path_tiles_are_in_world(world, path_tiles),
			"congestion":clampf(float(link.get("congestion", 0.0)), 0.0, 1.0),
			"blocked_reason":str(link.get("blocked_reason", "")),
			"priority":clampi(int(link.get("priority", 1)), 0, 2),
			"total_transferred":maxi(0, int(link.get("total_transferred", 0))),
			"status":link_status,
			"status_tone":_status_tone(link_status)
		})

	var construction_orders: Array = []
	for order_id_value in _sorted_keys(world.get("construction_orders", {})):
		var order_id := str(order_id_value)
		var order: Dictionary = world.get("construction_orders", {}).get(order_id, {})
		var work_required := maxf(EPSILON, float(order.get("work_required", 1.0)))
		var order_status := str(order.get("status", "WAITING_MATERIALS"))
		construction_orders.append({
			"id":order_id,
			"entity_id":str(order.get("entity_id", "")),
			"definition_id":str(order.get("definition_id", "")),
			"recipe_id":str(order.get("recipe_id", "")),
			"footprint":order.get("footprint", {}).duplicate(true),
			"required_items":order.get("required_items", {}).duplicate(true),
			"delivered_items":order.get("delivered_items", {}).duplicate(true),
			"work_required":work_required,
			"work_done":maxf(0.0, float(order.get("work_done", 0.0))),
			"progress":clampf(float(order.get("work_done", 0.0)) / work_required, 0.0, 1.0),
			"priority":clampi(int(order.get("priority", 50)), 0, 100),
			"funding_policy":str(order.get("funding_policy", "MANUAL")),
			"status":order_status,
			"status_tone":_status_tone(order_status),
			"blocker_code":str(order.get("blocked_reason", ""))
		})

	var production_rows := _production_rows(world, _production_route_index(world))
	var production_summary := _production_summary(production_rows)
	return {
		"protocol_version":WORKSPACE_PROTOCOL_VERSION,
		"world_schema_version":int(world.get("schema_version", WORLD_SCHEMA_VERSION)),
		"world_id":str(world.get("world_id", "")),
		"location_id":str(world.get("location_id", "")),
		"topology_revision":maxi(0, int(world.get("topology_revision", 0))),
		"runtime_revision":maxi(0, int(world.get("runtime_revision", 0))),
		"elapsed_ms":maxf(0.0, float(world.get("elapsed_ms", 0.0))),
		"tile_size_m":maxi(1, int(world.get("tile_size_m", 1))),
		"chunk_size_tiles":maxi(1, int(world.get("chunk_size_tiles", DEFAULT_CHUNK_SIZE))),
		"bounds":world.get("bounds", {}).duplicate(true),
		"resource_fields":resource_fields,
		"entities":entities,
		"links":links,
		"construction_orders":construction_orders,
		"palette":_workspace_palette_snapshot(),
		"power":_workspace_power_snapshot(world),
		"production":{"summary":production_summary, "rows":production_rows},
		"production_summary":production_summary.duplicate(true),
		"production_rows":production_rows.duplicate(true),
		"statistics":world.get("statistics", {}).duplicate(true),
		"summary":world_summary(world)
	}


func _workspace_palette_snapshot() -> Dictionary:
	var buildings: Array = []
	for definition_id_value in _sorted_keys(building_definitions):
		var definition_id := str(definition_id_value)
		var definition: Dictionary = building_definitions.get(definition_id, {})
		buildings.append({
			"id":definition_id,
			"name":str(definition.get("name", definition_id)),
			"kind":str(definition.get("kind", "")),
			"footprint":definition.get("footprint", {}).duplicate(true),
			"recipe_ids":definition.get("recipe_ids", []).duplicate(true),
			"resource_categories":definition.get("resource_categories", []).duplicate(true),
			"construction_cost":definition.get("construction_cost", []).duplicate(true),
			"construction_work":maxf(0.0, float(definition.get("construction_work", 0.0))),
			"power_generation_kw":maxf(0.0, float(definition.get("power_generation_kw", 0.0))),
			"power_demand_kw":maxf(0.0, float(definition.get("power_demand_kw", 0.0)))
		})
	var recipes: Array = []
	for recipe_id_value in _sorted_keys(recipe_definitions):
		var recipe_id := str(recipe_id_value)
		var recipe: Dictionary = recipe_definitions.get(recipe_id, {})
		recipes.append({
			"id":recipe_id,
			"name":str(recipe.get("name", recipe_id)),
			"duration_seconds":maxf(EPSILON, float(recipe.get("duration_seconds", 1.0))),
			"inputs":recipe.get("inputs", []).duplicate(true),
			"outputs":recipe.get("outputs", []).duplicate(true)
		})
	return {"buildings":buildings, "recipes":recipes}


func _workspace_power_snapshot(world: Dictionary) -> Dictionary:
	var generation_kw := 0.0
	var demand_kw := 0.0
	var served_kw := 0.0
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		generation_kw += maxf(0.0, float(definition.get("power_generation_kw", 0.0)))
		var entity_demand := maxf(0.0, float(definition.get("power_demand_kw", 0.0)))
		demand_kw += entity_demand
		served_kw += entity_demand * clampf(float(entity.get("power_factor", 1.0)), 0.0, 1.0)
	return {
		"generation_kw":generation_kw,
		"demand_kw":demand_kw,
		"served_kw":served_kw,
		"satisfaction":1.0 if demand_kw <= EPSILON else clampf(served_kw / demand_kw, 0.0, 1.0)
	}


func _entity_port_snapshot(entity_id: String, entity: Dictionary, port_connections: Dictionary) -> Dictionary:
	var kind := str(entity.get("kind", ""))
	var input_ids: Array = []
	var output_ids: Array = []
	match kind:
		"EXTRACTOR":
			var resource_id := str(entity.get("resource_id", ""))
			if not resource_id.is_empty():
				output_ids.append(resource_id)
		"MACHINE":
			var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
			input_ids = _item_entry_ids(recipe.get("inputs", []))
			output_ids = _item_entry_ids(recipe.get("outputs", []))
		"STORAGE", "ROUTER":
			input_ids = ["*"]
			output_ids = ["*"]
	var accepts_power := maxf(0.0, float(building_definitions.get(str(entity.get("definition_id", "")), {}).get("power_demand_kw", 0.0))) > 0.0
	var provides_power := maxf(0.0, float(building_definitions.get(str(entity.get("definition_id", "")), {}).get("power_generation_kw", 0.0))) > 0.0
	var input_ports: Array = []
	var output_ports: Array = []
	for item_id_value in input_ids:
		var item_id := str(item_id_value)
		input_ports.append(_port_snapshot(port_connections, entity_id, "INPUT", "ITEM", item_id))
	for item_id_value in output_ids:
		var item_id := str(item_id_value)
		output_ports.append(_port_snapshot(port_connections, entity_id, "OUTPUT", "ITEM", item_id))
	if accepts_power:
		input_ports.append(_port_snapshot(port_connections, entity_id, "INPUT", "POWER", ""))
	if provides_power:
		output_ports.append(_port_snapshot(port_connections, entity_id, "OUTPUT", "POWER", ""))
	var entries := input_ports.duplicate(true)
	entries.append_array(output_ports.duplicate(true))
	return {
		"inputs":input_ids,
		"outputs":output_ids,
		"accepts_power":accepts_power,
		"provides_power":provides_power,
		"entries":entries,
		"input_ports":input_ports,
		"output_ports":output_ports
	}


func _port_snapshot(port_connections: Dictionary, entity_id: String, direction: String, channel: String, item_id: String) -> Dictionary:
	var port_id := _power_port_id(entity_id, direction) if channel == "POWER" else _cargo_port_id(entity_id, direction, item_id)
	var connection: Dictionary = port_connections.get(port_id, {})
	var connected_link_ids: Array = connection.get("link_ids", []).duplicate()
	var connected_entity_ids: Array = connection.get("entity_ids", []).duplicate()
	return {
		"id":port_id,
		"direction":direction,
		"channel":channel,
		"item_id":item_id,
		"occupied":not connected_link_ids.is_empty(),
		"connected_link_ids":connected_link_ids,
		"connected_entity_ids":connected_entity_ids
	}


func _port_connection_index(world: Dictionary) -> Dictionary:
	var index := {}
	for link_id_value in _sorted_keys(world.get("links", {})):
		var link_id := str(link_id_value)
		var link: Dictionary = world.get("links", {}).get(link_id, {})
		for endpoint in [
			{"port_id":str(link.get("source_port_id", "")), "peer_id":str(link.get("target_id", ""))},
			{"port_id":str(link.get("target_port_id", "")), "peer_id":str(link.get("source_id", ""))}
		]:
			var port_id := str(endpoint.get("port_id", ""))
			if port_id.is_empty():
				continue
			var row: Dictionary = index.get(port_id, {"link_ids":[], "entity_ids":[]})
			row["link_ids"].append(link_id)
			var peer_id := str(endpoint.get("peer_id", ""))
			if not peer_id.is_empty() and not row["entity_ids"].has(peer_id):
				row["entity_ids"].append(peer_id)
			index[port_id] = row
	return index


func _cargo_port_id(entity_id: String, direction: String, item_id: String) -> String:
	return "%s:%s:ITEM:%s" % [entity_id, direction.to_upper(), item_id]


func _cargo_port_id_for_entity(entity: Dictionary, entity_id: String, direction: String, item_id: String) -> String:
	return _cargo_port_id(entity_id, direction, "*" if str(entity.get("kind", "")) in ["STORAGE", "ROUTER"] else item_id)


func _router_mode(entity: Dictionary) -> String:
	if str(entity.get("kind", "")) != "ROUTER":
		return ""
	var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
	var mode := str(definition.get("router_mode", "BIDIRECTIONAL")).to_upper()
	return mode if mode in ["SPLIT", "MERGE", "BIDIRECTIONAL"] else "BIDIRECTIONAL"


func _power_port_id(entity_id: String, direction: String) -> String:
	return "%s:%s:POWER" % [entity_id, direction.to_upper()]


func _production_rows(world: Dictionary, route_index: Dictionary = {}) -> Array:
	var rows: Array = []
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		var kind := str(entity.get("kind", ""))
		if kind not in ["EXTRACTOR", "MACHINE", "ROUTER"]:
			continue
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		var theoretical_rate := _theoretical_entity_rate(world, entity_id, entity, definition)
		var actual_rate := maxf(0.0, float(entity.get("actual_rate", 0.0)))
		var status := str(entity.get("status", "IDLE"))
		rows.append({
			"entity_id":entity_id,
			"definition_id":str(entity.get("definition_id", "")),
			"recipe_id":str(entity.get("recipe_id", "")),
			"kind":kind,
			"status":status,
			"theoretical_rate":theoretical_rate,
			"actual_rate":actual_rate,
			"utilization":0.0 if theoretical_rate <= EPSILON else clampf(actual_rate / theoretical_rate, 0.0, 1.0),
			"blocker":_entity_blocker_code(status),
			"is_transport_router":kind == "ROUTER",
			"upstream":_production_neighbors(route_index, entity_id, false),
			"downstream":_production_neighbors(route_index, entity_id, true)
		})
	return rows


func _production_summary(rows: Array) -> Dictionary:
	var theoretical_rate := 0.0
	var actual_rate := 0.0
	var blockers := {}
	var productive_row_count := 0
	var status_counts := {"running":0, "input_shortage":0, "output_full":0, "blocked":0, "idle":0}
	for row_value in rows:
		var row := row_value as Dictionary
		var kind := str(row.get("kind", ""))
		if kind in ["EXTRACTOR", "MACHINE"]:
			theoretical_rate += maxf(0.0, float(row.get("theoretical_rate", 0.0)))
			actual_rate += maxf(0.0, float(row.get("actual_rate", 0.0)))
			productive_row_count += 1
		elif kind != "ROUTER":
			continue
		var blocker := str(row.get("blocker", ""))
		var status := str(row.get("status", "IDLE")).to_upper()
		if status in ["RUNNING", "FLOWING", "POWER_LIMITED", "PARTIAL_COVERAGE"]:
			status_counts["running"] = int(status_counts.get("running", 0)) + 1
		elif status in ["NO_POWER", "INPUT_SHORTAGE"]:
			status_counts["input_shortage"] = int(status_counts.get("input_shortage", 0)) + 1
		elif status == "OUTPUT_FULL":
			status_counts["output_full"] = int(status_counts.get("output_full", 0)) + 1
		elif status in ["IDLE", "READY"]:
			status_counts["idle"] = int(status_counts.get("idle", 0)) + 1
		else:
			status_counts["blocked"] = int(status_counts.get("blocked", 0)) + 1
		if not blocker.is_empty():
			blockers[blocker] = int(blockers.get(blocker, 0)) + 1
	return {
		"theoretical_rate":theoretical_rate,
		"actual_rate":actual_rate,
		"utilization":0.0 if theoretical_rate <= EPSILON else clampf(actual_rate / theoretical_rate, 0.0, 1.0),
		"row_count":rows.size(),
		"productive_row_count":productive_row_count,
		"running_count":int(status_counts.get("running", 0)),
		"blocked_count":int(status_counts.get("input_shortage", 0)) + int(status_counts.get("output_full", 0)) + int(status_counts.get("blocked", 0)),
		"blockers":blockers,
		"running":int(status_counts.get("running", 0)),
		"input_shortage":int(status_counts.get("input_shortage", 0)),
		"output_full":int(status_counts.get("output_full", 0)),
		"blocked":int(status_counts.get("blocked", 0)),
		"idle":int(status_counts.get("idle", 0))
	}


func _theoretical_entity_rate(world: Dictionary, entity_id: String, entity: Dictionary, definition: Dictionary) -> float:
	if str(entity.get("kind", "")) == "EXTRACTOR":
		var profile := resource_coverage_for_footprint(world, entity.get("footprint", {}), float(definition.get("resource_coverage_loss_per_missing_tile", 0.1)))
		return minf(
			maxf(0.0, float(definition.get("mining_rate_per_second", 0.0))) * maxf(EPSILON, float(profile.get("average_grade", 1.0))) * clampf(float(profile.get("coverage_efficiency", 0.0)), 0.0, 1.0),
			maxf(0.0, float(profile.get("sustainable_rate_per_second", 0.0)))
		)
	if str(entity.get("kind", "")) == "MACHINE":
		var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
		return 0.0 if recipe.is_empty() else maxf(0.0, float(definition.get("speed", 1.0))) / maxf(EPSILON, float(recipe.get("duration_seconds", 1.0)))
	return 0.0


func _production_route_index(world: Dictionary) -> Dictionary:
	var upstream := {}
	var downstream := {}
	for link_id_value in _sorted_keys(world.get("links", {})):
		var link_id := str(link_id_value)
		var link: Dictionary = world.get("links", {}).get(link_id, {})
		if str(link.get("kind", "")) != "CARGO":
			continue
		var source_id := str(link.get("source_id", ""))
		var target_id := str(link.get("target_id", ""))
		var common := {
			"link_id":link_id,
			"item_id":str(link.get("item_id", "")),
			"status":_link_status(world, link),
			"blocked_reason":str(link.get("blocked_reason", ""))
		}
		var downstream_row := common.duplicate(true)
		downstream_row["entity_id"] = target_id
		downstream_row["port_id"] = str(link.get("source_port_id", ""))
		var downstream_rows: Array = downstream.get(source_id, [])
		downstream_rows.append(downstream_row)
		downstream[source_id] = downstream_rows
		var upstream_row := common.duplicate(true)
		upstream_row["entity_id"] = source_id
		upstream_row["port_id"] = str(link.get("target_port_id", ""))
		var upstream_rows: Array = upstream.get(target_id, [])
		upstream_rows.append(upstream_row)
		upstream[target_id] = upstream_rows
	return {"upstream":upstream, "downstream":downstream}


func _production_neighbors(route_index: Dictionary, entity_id: String, downstream: bool) -> Array:
	var direction_index: Dictionary = route_index.get("downstream" if downstream else "upstream", {})
	return direction_index.get(entity_id, []).duplicate(true)


func _item_entry_ids(entries: Array) -> Array:
	var ids: Array = []
	for entry_value in entries:
		var item_id := str((entry_value as Dictionary).get("item", ""))
		if not item_id.is_empty() and not ids.has(item_id):
			ids.append(item_id)
	ids.sort()
	return ids


func _entity_blocker_code(status: String) -> String:
	match status:
		"NO_RESOURCE", "NO_POWER", "INPUT_SHORTAGE", "OUTPUT_FULL", "NO_RECIPE":
			return status
	return ""


func _link_status(world: Dictionary, link: Dictionary) -> String:
	if str(link.get("kind", "")) == "POWER":
		return "CONNECTED"
	var blocked_reason := str(link.get("blocked_reason", ""))
	if not blocked_reason.is_empty():
		return blocked_reason
	if float(link.get("last_flow", 0.0)) > EPSILON:
		return "FLOWING"
	var source: Dictionary = world.get("entities", {}).get(str(link.get("source_id", "")), {})
	var target: Dictionary = world.get("entities", {}).get(str(link.get("target_id", "")), {})
	var item_id := str(link.get("item_id", ""))
	if _source_quantity(source, item_id) <= 0:
		return "SOURCE_EMPTY"
	if _target_free_capacity(target, item_id) <= 0:
		return "TARGET_FULL"
	return "IDLE"


func _status_tone(status: String) -> String:
	if status in ["RUNNING", "FLOWING", "CONNECTED", "COMPLETE"]:
		return "positive"
	if status in ["NO_RESOURCE", "NO_POWER", "OUTPUT_FULL", "FAILED", "INCOMPATIBLE_ENDPOINT", "NO_CAPACITY"]:
		return "danger"
	if status in ["POWER_LIMITED", "PARTIAL_COVERAGE", "INPUT_SHORTAGE", "NO_RECIPE", "WAITING_MATERIALS", "SOURCE_EMPTY", "TARGET_FULL"]:
		return "warning"
	return "muted"


func _create_entity(entity_id: String, definition_id: String, origin: Vector2i, recipe_id: String) -> Dictionary:
	var definition: Dictionary = building_definitions.get(definition_id, {})
	var size_data: Dictionary = definition.get("footprint", {})
	var kind := str(definition.get("kind", ""))
	var initial_status := "NO_RECIPE" if kind == "MACHINE" and recipe_id.is_empty() else "IDLE"
	return {
		"id":entity_id,
		"kind":kind,
		"definition_id":definition_id,
		"recipe_id":recipe_id,
		"footprint":_footprint(origin, Vector2i(maxi(1, int(size_data.get("width", 1))), maxi(1, int(size_data.get("height", 1))))),
		"status":initial_status,
		"inputs":{},
		"outputs":{},
		"inventory":{},
		"routing_cursor":{},
		"progress":0.0,
		"power_factor":0.0 if float(definition.get("power_demand_kw", 0.0)) > EPSILON else 1.0,
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
		"STORAGE", "ROUTER": return true
		"EXTRACTOR":
			return str(entity.get("resource_id", "")) == item_id
		"MACHINE":
			var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
			return _item_entries_to_dictionary(recipe.get("outputs", [])).has(item_id)
	return false


func _entity_can_input(entity: Dictionary, item_id: String) -> bool:
	match str(entity.get("kind", "")):
		"STORAGE", "ROUTER": return true
		"MACHINE":
			var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
			return _item_entries_to_dictionary(recipe.get("inputs", [])).has(item_id)
	return false


func _source_quantity(entity: Dictionary, item_id: String) -> int:
	var buffer: Dictionary = entity.get("inventory", {}) if str(entity.get("kind", "")) in ["STORAGE", "ROUTER"] else entity.get("outputs", {})
	return maxi(0, int(buffer.get(item_id, 0)))


func _remove_source_quantity(entity: Dictionary, item_id: String, quantity: int) -> void:
	var field := "inventory" if str(entity.get("kind", "")) in ["STORAGE", "ROUTER"] else "outputs"
	entity[field][item_id] = maxi(0, int(entity.get(field, {}).get(item_id, 0)) - quantity)


func _add_target_quantity(entity: Dictionary, item_id: String, quantity: int) -> void:
	var field := "inventory" if str(entity.get("kind", "")) in ["STORAGE", "ROUTER"] else "inputs"
	entity[field][item_id] = int(entity.get(field, {}).get(item_id, 0)) + quantity


func _target_free_capacity(entity: Dictionary, item_id: String) -> int:
	if not _entity_can_input(entity, item_id):
		return 0
	var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
	if str(entity.get("kind", "")) in ["STORAGE", "ROUTER"]:
		return maxi(0, int(definition.get("inventory_capacity", 0)) - _dictionary_total(entity.get("inventory", {})))
	return maxi(0, int(definition.get("input_capacity", 0)) - _dictionary_total(entity.get("inputs", {})))


func _orthogonal_link_path_tiles(world: Dictionary, source: Dictionary, target: Dictionary, kind: String) -> Array:
	var channel := "POWER" if kind == "POWER" else "ITEM"
	var start := _entity_port_tile(source, "OUTPUT", channel)
	var finish := _entity_port_tile(target, "INPUT", channel)
	# Persist route vertices, not every traversed tile. Very large planets can
	# therefore keep long belts without O(distance) save, culling, or draw work.
	var path_tiles: Array = [_point_dict(start)]
	if start.x != finish.x and start.y != finish.y:
		path_tiles.append(_point_dict(Vector2i(finish.x, start.y)))
	if finish != start:
		path_tiles.append(_point_dict(finish))
	# Both endpoints are valid entity-footprint tiles. The explicit check keeps
	# finite-world enforcement close to the generator for future port layouts.
	return path_tiles if _path_tiles_are_in_world(world, path_tiles) else []


func _entity_port_tile(entity: Dictionary, direction: String, channel: String) -> Vector2i:
	var footprint: Dictionary = entity.get("footprint", {})
	var origin := _point(footprint.get("origin", {}))
	var size := _point(footprint.get("size", {}))
	var width := maxi(1, size.x)
	var height := maxi(1, size.y)
	if channel == "POWER":
		return Vector2i(origin.x + floori(float(width) / 2.0), origin.y + height - 1) if direction == "OUTPUT" else Vector2i(origin.x + floori(float(width) / 2.0), origin.y)
	return Vector2i(origin.x + width - 1, origin.y + floori(float(height) / 2.0)) if direction == "OUTPUT" else Vector2i(origin.x, origin.y + floori(float(height) / 2.0))


func _normalized_link_path_tiles(world: Dictionary, value, source: Dictionary, target: Dictionary, kind: String) -> Array:
	var requested_path := _path_tiles_from_value(value)
	if _path_tiles_are_valid_for_link(world, requested_path, source, target, kind):
		return requested_path
	return _orthogonal_link_path_tiles(world, source, target, kind)


func _path_tiles_from_value(value) -> Array:
	var result: Array = []
	if value is not Array:
		return result
	for tile_value in value:
		if tile_value is not Dictionary:
			return []
		result.append(_point_dict(_point(tile_value as Dictionary)))
	return _compact_orthogonal_path_tiles(result)


func _compact_orthogonal_path_tiles(path_tiles: Array) -> Array:
	var result: Array = []
	for tile_value in path_tiles:
		var point := _point(tile_value as Dictionary)
		if not result.is_empty() and _point(result[-1] as Dictionary) == point:
			continue
		while result.size() >= 2:
			var before := _point(result[-2] as Dictionary)
			var previous := _point(result[-1] as Dictionary)
			var same_axis := (before.x == previous.x and previous.x == point.x) \
				or (before.y == previous.y and previous.y == point.y)
			if not same_axis:
				break
			result.pop_back()
		result.append(_point_dict(point))
	return result


func _path_tiles_are_in_world(world: Dictionary, path_tiles) -> bool:
	if path_tiles is not Array or path_tiles.is_empty():
		return false
	for tile_value in path_tiles:
		if tile_value is not Dictionary or not _tile_in_world(world, _point(tile_value as Dictionary)):
			return false
	return true


func _path_tiles_are_valid_for_link(world: Dictionary, path_tiles, source: Dictionary, target: Dictionary, kind: String) -> bool:
	if not _path_tiles_are_in_world(world, path_tiles):
		return false
	var channel := "POWER" if kind == "POWER" else "ITEM"
	var expected_start := _entity_port_tile(source, "OUTPUT", channel)
	var expected_finish := _entity_port_tile(target, "INPUT", channel)
	if _point(path_tiles[0] as Dictionary) != expected_start or _point(path_tiles[-1] as Dictionary) != expected_finish:
		return false
	for index in range(1, path_tiles.size()):
		var previous := _point(path_tiles[index - 1] as Dictionary)
		var current := _point(path_tiles[index] as Dictionary)
		if previous == current or (previous.x != current.x and previous.y != current.y):
			return false
	return true


func _normalize_cargo_link_tier(value: String) -> String:
	var normalized := value.strip_edges().to_upper()
	return DEFAULT_CARGO_LINK_TIER if normalized.is_empty() else normalized.left(32)


func _positive_item_manifest(source: Dictionary) -> Dictionary:
	var manifest := {}
	for item_id_value in _sorted_keys(source):
		var item_id := str(item_id_value)
		var quantity := maxi(0, int(source.get(item_id, 0)))
		if quantity > 0:
			manifest[item_id] = quantity
	return manifest


func _entity_buffer_manifest(entity: Dictionary) -> Dictionary:
	var manifest := {}
	for buffer_name in ["inputs", "outputs", "inventory"]:
		var buffer: Dictionary = entity.get(buffer_name, {}) if entity.get(buffer_name, {}) is Dictionary else {}
		for item_id_value in _sorted_keys(buffer):
			var item_id := str(item_id_value)
			var quantity := maxi(0, int(buffer.get(item_id, 0)))
			if quantity > 0:
				manifest[item_id] = int(manifest.get(item_id, 0)) + quantity
	return manifest


func _available_recipe_input_cycles(entity: Dictionary, recipe: Dictionary) -> int:
	var cycles := 2147483647
	for input_value in recipe.get("inputs", []):
		var input := input_value as Dictionary
		var quantity := maxi(1, int(input.get("quantity", 1)))
		cycles = mini(cycles, maxi(0, int(entity.get("inputs", {}).get(str(input.get("item", "")), 0))) / quantity)
	return 0 if cycles == 2147483647 else cycles


func _machine_output_capacity_reservation(entity: Dictionary, definition: Dictionary, recipe: Dictionary) -> Dictionary:
	var free := maxi(0, int(definition.get("output_capacity", 0)) - _dictionary_total(entity.get("outputs", {})))
	var output_per_cycle := 0
	for output_value in recipe.get("outputs", []):
		var output := output_value as Dictionary
		output_per_cycle += maxi(1, int(output.get("quantity", 1)))
	var cycles := free / maxi(1, output_per_cycle)
	var reserved_outputs := {}
	for output_value in recipe.get("outputs", []):
		var output := output_value as Dictionary
		var item_id := str(output.get("item", ""))
		if not item_id.is_empty():
			reserved_outputs[item_id] = maxi(1, int(output.get("quantity", 1))) * cycles
	return {
		"cycles":cycles,
		"free_capacity":free,
		"output_per_cycle":output_per_cycle,
		"reserved_outputs":reserved_outputs
	}


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


func _bump_topology_revision(world: Dictionary) -> void:
	world["topology_revision"] = maxi(0, int(world.get("topology_revision", 0))) + 1


func _bump_runtime_revision(world: Dictionary) -> void:
	world["runtime_revision"] = maxi(0, int(world.get("runtime_revision", 0))) + 1


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
