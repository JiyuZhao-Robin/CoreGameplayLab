class_name FactoryGridSimulation
extends RefCounted

## Authoritative square-grid factory simulation used by the post-1.29 gameplay
## rewrite. One tile is one square metre, but worlds are sparse address spaces:
## only resource-field descriptors, player structures, links, construction
## orders and modified tiles are persisted. Terrain and resources are tile
## attributes; they are never physical entities or network endpoints.

const WORLD_SCHEMA_VERSION := 4
const WORKSPACE_PROTOCOL_VERSION := 1
const DEFAULT_CHUNK_SIZE := 64
const DEFAULT_STEP_SECONDS := 1.0
const EPSILON := 0.000001
const DEFAULT_CARGO_LINK_TIER := "MK1"
const MAX_CARGO_LINK_LANES := 12
const ENTITY_KINDS := ["EXTRACTOR", "MACHINE", "STORAGE", "ROUTER", "POWER", "CONSTRUCTION"]
const LINK_KINDS := ["CARGO", "POWER"]
const Terrain = preload("res://src/core/factory_terrain.gd")
const DspProduction = preload("res://src/core/factory_dsp_production.gd")
const DspProjects = preload("res://src/core/factory_dsp_projects.gd")

var building_definitions: Dictionary = {}
var recipe_definitions: Dictionary = {}
var rules: Dictionary = {}
var _drone_context_cache: Dictionary = {}
var _dsp_power_plan: Dictionary = {}
var _power_allocation: Dictionary = {}
var _power_charge: Dictionary = {}


func _init(buildings: Dictionary = {}, recipes: Dictionary = {}, grid_rules: Dictionary = {}) -> void:
	configure(buildings, recipes, grid_rules)


func configure(buildings: Dictionary, recipes: Dictionary, grid_rules: Dictionary = {}) -> void:
	building_definitions = buildings.duplicate(true)
	recipe_definitions = recipes.duplicate(true)
	rules = grid_rules.duplicate(true)
	_drone_context_cache.clear()
	rules.merge({
		"chunk_size_tiles":DEFAULT_CHUNK_SIZE,
		"simulation_step_seconds":DEFAULT_STEP_SECONDS,
		"base_construction_capacity_per_second":1.0,
		"drone_radius_tiles":64.0,
		"drone_count":4,
		"drone_cargo_capacity":10,
		"drone_speed_tiles_per_second":12.0,
		"drone_input_batches":10,
		"drone_max_active_shipments":256
	}, false)


## Environment calculations are centralized here so Factory simulation and
## workspace projections cannot drift. The application layer copies canonical
## Location environment data into `world.environment`; absent legacy data is the
## neutral baseline.
func environment_effects(world: Dictionary) -> Dictionary:
	return FactoryEnvironmentEffects.snapshot(_world_environment(world))


func effective_generation_kw(world: Dictionary, definition: Dictionary) -> float:
	return FactoryEnvironmentEffects.effective_generation_kw(_world_environment(world), definition)


func effective_demand_kw(world: Dictionary, definition: Dictionary, entity: Dictionary = {}) -> float:
	if str(definition.get("kind", "")) == "EXTRACTOR" and not entity.is_empty():
		definition = _resource_definition(definition, entity)
	return FactoryEnvironmentEffects.effective_demand_kw(_world_environment(world), definition) * DspProduction.proliferation_power_multiplier(entity, recipe_definitions.get(str(entity.get("recipe_id", "")), {}))


func construction_capacity_per_second(world: Dictionary) -> float:
	var nominal_capacity := maxf(0.0, FactoryEnvironmentEffects.finite_number(rules.get("base_construction_capacity_per_second", 1.0), 1.0))
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		if str(entity.get("kind", "")) != "CONSTRUCTION":
			continue
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		nominal_capacity += FactoryEnvironmentEffects.nominal_construction_capacity_per_second(definition) * clampf(FactoryEnvironmentEffects.finite_number(entity.get("power_factor", 1.0), 1.0), 0.0, 1.0)
	return FactoryEnvironmentEffects.effective_construction_capacity_per_second(_world_environment(world), nominal_capacity)


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
		"environment":{},
		"dsp_effects":{},
		"logistics_mode":"PLANET_SHARED_DRONES",
		"drone_shipments":{},
		"resource_fields":{},
		"entities":{},
		"links":{},
		"construction_orders":{},
		"command_receipts":{},
		"command_receipt_order":[],
		"tile_deltas":{},
		"revealed_chunks":{},
		"terrain_enabled":false,
		"terrain_safe_rect":{},
		"landing_definition_id":"",
		"starter_package_delivered":false,
		"next_entity_serial":1,
		"next_link_serial":1,
		"next_construction_serial":1,
		"next_drone_shipment_serial":1,
		"statistics":{"produced":{}, "consumed":{}, "transferred":{}, "construction_delivered":{}, "construction_completed":0}
	}


func normalize_world(source: Dictionary) -> Dictionary:
	source = preload("res://src/core/factory_building_migration.gd").migrate_save(source)
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
	normalized["drone_dispatch_after"] = str(source.get("drone_dispatch_after", ""))
	normalized["terrain_enabled"] = bool(source.get("terrain_enabled", false))
	normalized["terrain_profile"] = str(source.get("terrain_profile", ""))
	normalized["terrain_safe_rect"] = source.get("terrain_safe_rect", {}).duplicate(true)
	# Optional generator inputs must survive a save round trip. Leave absent
	# terrain_seed absent so legacy worlds continue deriving it from world seed.
	for terrain_input in ["terrain_seed", "terrain_scale_tiles"]:
		if source.has(terrain_input):
			normalized[terrain_input] = source[terrain_input]
	normalized["landing_definition_id"] = str(source.get("landing_definition_id", ""))
	normalized["starter_package_delivered"] = bool(source.get("starter_package_delivered", false))
	normalized["resource_profile_unlocks"] = source.get("resource_profile_unlocks", {}).duplicate(true)
	normalized["topology_revision"] = maxi(0, int(source.get("topology_revision", 0)))
	normalized["runtime_revision"] = maxi(0, int(source.get("runtime_revision", 0)))
	# Factory worlds now use circular drone logistics and world-level power.
	# Legacy links are intentionally discarded: they contain no authoritative
	# cargo after migration and must not remain as an active parallel network.
	normalized["logistics_mode"] = "PLANET_SHARED_DRONES"
	# Preserve the old road layout as inert save history. It no longer blocks
	# placement, renders, conducts power or schedules transportation.
	normalized["legacy_roads_archive"] = source.get("legacy_roads_archive", source.get("roads", {})).duplicate(true)
	# Preserve the Location-owned environment record verbatim. Runtime effects
	# sanitize reads independently, while the application layer remains the sole
	# authority that reprojects canonical Location data into this copy.
	if source.get("environment", null) is Dictionary:
		normalized["environment"] = source.get("environment", {}).duplicate(true)
	for field in ["resource_fields", "entities", "links", "construction_orders", "command_receipts", "tile_deltas", "revealed_chunks", "statistics", "dsp_effects"]:
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
	for field in ["next_entity_serial", "next_link_serial", "next_construction_serial", "next_drone_shipment_serial"]:
		normalized[field] = maxi(1, int(source.get(field, 1)))
	var shipments: Dictionary = source.get("drone_shipments", {}).duplicate(true)
	# Legacy transit cargo already left its source; move custody exactly once.
	for legacy_id in source.get("road_shipments", {}):
		if not shipments.has(legacy_id):
			shipments[legacy_id] = source["road_shipments"][legacy_id].duplicate(true)
	normalized["drone_shipments"] = FactoryDroneTransport.normalize_shipments(shipments, normalized)
	for shipment_value in normalized.get("drone_shipments", {}).values():
		var shipment := shipment_value as Dictionary
		var shipment_id := str(shipment.get("id", ""))
		var serial_text := shipment_id.trim_prefix("DRONE-SHIP-")
		if serial_text.is_valid_int():
			normalized["next_drone_shipment_serial"] = maxi(int(normalized.get("next_drone_shipment_serial", 1)), int(serial_text) + 1)
	# Drone worlds have no live manual CARGO or POWER wires.
	normalized["links"] = {}
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
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		if not definition.is_empty():
			for field in ["drone_tower", "drone_radius_tiles", "drone_count"]:
				entity[field] = definition.get(field, false if field == "drone_tower" else 0)
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


func tile_snapshot(world: Dictionary, tile: Vector2i, candidate_field_ids: Variant = null) -> Dictionary:
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
	var field_ids: Array = _sorted_keys(world.get("resource_fields", {})) if candidate_field_ids == null else candidate_field_ids
	for field_id_value in field_ids:
		var resource_field: Dictionary = world.get("resource_fields", {}).get(field_id_value, {})
		if Terrain.field_contains(resource_field, tile):
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
		if delta.has("terrain_override") and not Terrain.FLAT_GROUND_ONLY:
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


func resource_coverage_for_footprint(world: Dictionary, footprint: Dictionary, loss_per_missing_tile: float = 0.1, mining_radius_tiles: float = 0.0) -> Dictionary:
	var origin := _point(footprint.get("origin", {}))
	var size := _point(footprint.get("size", {}))
	var footprint_tiles := maxi(0, size.x) * maxi(0, size.y)
	var radius := maxf(0.0, mining_radius_tiles)
	var circular_reach := radius > EPSILON
	var sample_origin := origin
	var sample_end := origin + Vector2i(maxi(0, size.x), maxi(0, size.y))
	if circular_reach:
		var center := Vector2(float(origin.x), float(origin.y)) + Vector2(float(size.x), float(size.y)) * 0.5
		var bounds: Dictionary = world.get("bounds", {})
		var world_origin := _point(bounds.get("origin", {}))
		var world_size := _point(bounds.get("size", {}))
		var world_end := world_origin + Vector2i(maxi(0, world_size.x), maxi(0, world_size.y))
		sample_origin = Vector2i(
			maxi(world_origin.x, floori(center.x - radius)),
			maxi(world_origin.y, floori(center.y - radius))
		)
		sample_end = Vector2i(
			mini(world_end.x, ceili(center.x + radius)),
			mini(world_end.y, ceili(center.y + radius))
		)
	var sample_footprint := _footprint(sample_origin, Vector2i(maxi(0, sample_end.x - sample_origin.x), maxi(0, sample_end.y - sample_origin.y)))
	var resource_ids := {}
	var field_ids := {}
	var covered_by_field := {}
	var covered_tiles := 0
	var mining_area_tiles := 0
	var grade_sum := 0.0
	var sustainable_rate := 0.0
	var resource_category := ""
	var candidate_fields: Array = []
	for field_id in _sorted_keys(world.get("resource_fields", {})):
		if _footprints_overlap(sample_footprint, world["resource_fields"][field_id].get("footprint", {})):
			candidate_fields.append(field_id)
	var circle_center := Vector2(float(origin.x), float(origin.y)) + Vector2(float(size.x), float(size.y)) * 0.5
	var radius_squared := radius * radius
	for y in range(sample_origin.y, sample_end.y):
		for x in range(sample_origin.x, sample_end.x):
			if circular_reach and Vector2(float(x) + 0.5, float(y) + 0.5).distance_squared_to(circle_center) > radius_squared + EPSILON:
				continue
			mining_area_tiles += 1
			var tile := tile_snapshot(world, Vector2i(x, y), candidate_fields)
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
	var missing_tiles := 0 if circular_reach else maxi(0, footprint_tiles - covered_tiles)
	# A circular reach is capacity, not a foundation requirement. Empty tiles in
	# the disc are unused reach, while any compatible resource tile is full
	# coverage and remains capped by its summed sustainable density below.
	var efficiency := 0.0 if covered_tiles <= 0 else (1.0 if circular_reach else clampf(1.0 - float(missing_tiles) * clampf(loss_per_missing_tile, 0.0, 1.0), 0.0, 1.0))
	return {
		"resource_id":"" if sorted_resources.is_empty() else str(sorted_resources[0]),
		"resource_ids":sorted_resources,
		"resource_category":resource_category,
		"resource_field_ids":sorted_fields,
		"covered_tiles_by_field":covered_by_field,
		"covered_resource_tiles":covered_tiles,
		"footprint_tiles":footprint_tiles,
		"mining_radius_tiles":radius,
		"mining_area_tiles":mining_area_tiles,
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


## Atomically adds/upgrades/removes sparse cardinal road tiles. Costs are
## returned for the application transaction: tier-one starter roads are free,
## while creating or upgrading tier two costs one iron ingot per tile.
func edit_roads(_world: Dictionary, _tiles: Array, _tier: int = 1, _remove: bool = false) -> Dictionary:
	return _failure("ROADS_RETIRED", "Roads have been replaced by drone towers")


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
	entity["deployment_item_id"] = str(building_definitions.get(definition_id, {}).get("deployment_item_id", ""))
	_apply_extractor_resource_profile(entity, placement.get("resource_profile", {}))
	world["entities"][entity_id] = entity
	_bump_topology_revision(world)
	return {"ok":true, "entity_id":entity_id}


func can_place_entity(world: Dictionary, definition_id: String, origin: Vector2i, recipe_id: String = "", ignored_order_id: String = "") -> Dictionary:
	var definition: Dictionary = building_definitions.get(definition_id, {})
	# ROUTER definitions remain available only to historical domain fixtures;
	# the application blocks them. Retired imported buildings cannot be deployed.
	if definition.is_empty() or str(definition.get("kind", "")) not in ENTITY_KINDS or (bool(definition.get("legacy_only", false)) and str(definition.get("kind", "")) != "ROUTER"):
		return _failure("UNKNOWN_BUILDING", "Unknown or invalid building definition")
	if definition_id in ["grid_dsp_time_warp_device", "grid_dsp_space_station_construction_launcher"]:
		for existing in world.get("entities", {}).values():
			if str(existing.get("definition_id", "")) == definition_id:
				return _failure("UNIQUE_BUILDING_EXISTS", "Only one of this planetary special building may be deployed")
	if str(definition.get("kind", "")) in ["MACHINE", "POWER"]:
		# A machine may be placed before its recipe is configured.  An explicitly
		# supplied recipe still has to exist and be declared compatible by the
		# building; the empty value is the intentional unconfigured state.
		var recipe: Dictionary = recipe_definitions.get(recipe_id, {})
		if not recipe_id.is_empty() and (recipe.is_empty() or bool(recipe.get("legacy_only", false)) or not definition.get("recipe_ids", []).has(recipe_id)):
			return _failure("INCOMPATIBLE_RECIPE", "Machine requires a compatible recipe")
	var size_data: Dictionary = definition.get("footprint", {})
	var footprint := _footprint(origin, Vector2i(maxi(1, int(size_data.get("width", 1))), maxi(1, int(size_data.get("height", 1)))))
	if not _footprint_in_world(world, footprint):
		return _failure("OUT_OF_BOUNDS", "Building footprint is outside the world")
	var footprint_size := _point(footprint.get("size", {}))
	for y in range(origin.y, origin.y + footprint_size.y):
		for x in range(origin.x, origin.x + footprint_size.x):
			if not Terrain.is_buildable(world, Vector2i(x, y)):
				return _failure("TERRAIN_BLOCKED", "Building footprint contains water or mountains")
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
		var resource_profile := resource_coverage_for_footprint(world, footprint, float(definition.get("resource_coverage_loss_per_missing_tile", 0.1)), float(definition.get("mining_radius_tiles", 0.0)))
		if int(resource_profile.get("covered_resource_tiles", 0)) <= 0:
			return _failure("RESOURCE_REQUIRED", "Extractor must cover at least one resource-bearing tile")
		if bool(resource_profile.get("mixed_resource_types", false)):
			return _failure("MIXED_RESOURCE_COVERAGE", "One extractor cannot cover different resource types")
		if not definition.get("resource_categories", []).has(str(resource_profile.get("resource_category", ""))):
			return _failure("RESOURCE_INCOMPATIBLE", "Extractor is incompatible with the covered tile resource")
		if not definition.get("allowed_resource_ids", []).is_empty() and not definition["allowed_resource_ids"].has(str(resource_profile.get("resource_id", ""))):
			return _failure("RESOURCE_INCOMPATIBLE", "Extractor cannot harvest this material")
		if not _resource_unlocked(world, definition, resource_profile):
			return _failure("BUILDING_LOCKED", "Research the technology required to extract this resource")
		result["resource_profile"] = resource_profile
	return result


## Compatibility name: queues a ghost, never on-site raw-material construction.
func queue_construction(world: Dictionary, definition_id: String, origin: Vector2i, recipe_id: String = "", priority: int = 50, _funding_policy: String = "MANUAL") -> Dictionary:
	var placement := can_place_entity(world, definition_id, origin, recipe_id)
	if not bool(placement.get("ok", false)):
		return placement
	var item_id := str(building_definitions.get(definition_id, {}).get("deployment_item_id", ""))
	if item_id.is_empty():
		return _failure("INVALID_DEPLOYMENT_ITEM", "This definition has no deployable building item")
	var order_id := _next_id(world, "next_construction_serial", "BUILD-")
	var entity_id := _next_id(world, "next_entity_serial", "ENTITY-")
	world["construction_orders"][order_id] = {
		"id":order_id, "entity_id":entity_id, "definition_id":definition_id,
		"deployment_item_id":item_id, "recipe_id":recipe_id,
		"footprint":placement.get("footprint", {}).duplicate(true),
		"resource_profile":placement.get("resource_profile", {}).duplicate(true),
		"required_items":{item_id:1}, "delivered_items":{},
		"priority":clampi(priority, 0, 100), "funding_policy":"FINISHED_BUILDING",
		"status":"WAITING_BUILDING", "blocked_reason":"MISSING_BUILDING",
		"queued_at_ms":float(world.get("elapsed_ms", 0.0))
	}
	_bump_topology_revision(world)
	return {"ok":true, "order_id":order_id, "entity_id":entity_id, "deployment_item_id":item_id}

func fund_construction_from_storage(_world: Dictionary, _order_id: String, _storage_id: String) -> Dictionary:
	return _failure("CONSTRUCTION_RETIRED", "Manufacture and deploy a finished building; material funding is retired")

func fund_construction_from_external(_world: Dictionary, _order_id: String, _available_items: Dictionary) -> Dictionary:
	return _failure("CONSTRUCTION_RETIRED", "Manufacture and deploy a finished building; material funding is retired")

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
	if str(entity.get("kind", "")) not in ["MACHINE", "POWER"]:
		return _failure("INVALID_MACHINE", "Only a completed Factory machine can change recipe")
	var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
	var recipe: Dictionary = recipe_definitions.get(recipe_id, {})
	if recipe.is_empty() or bool(recipe.get("legacy_only", false)) or not definition.get("recipe_ids", []).has(recipe_id):
		return _failure("INCOMPATIBLE_RECIPE", "The selected recipe is incompatible with this machine")
	var previous_recipe_id := str(entity.get("recipe_id", ""))
	if previous_recipe_id == recipe_id:
		return {"ok":true, "entity_id":entity_id, "previous_recipe_id":previous_recipe_id, "recipe_id":recipe_id, "removed_link_ids":[]}
	if float(entity.get("energy_debt_mj", 0.0)) > EPSILON or float(entity.get("energy_credit_mj", 0.0)) > EPSILON:
		return _failure("ENERGY_SETTLEMENT_PENDING", "Finish discharging the current cell before changing mode")
	if _is_drone_mode(world):
		# Retool without deleting material or stranding the previous ingredients
		# in a buffer the new recipe cannot consume. Drone return delivery drains
		# these returned goods; temporary output over-cap blocks new production.
		if not entity.has("drone_return_items"):
			entity["drone_return_items"] = {}
		for item_id in entity.get("inputs", {}):
			entity["drone_return_items"][item_id] = int(entity["drone_return_items"].get(item_id, 0)) + int(entity["inputs"][item_id])
			entity["outputs"][item_id] = int(entity.get("outputs", {}).get(item_id, 0)) + int(entity["inputs"][item_id])
		entity["inputs"] = {}
	entity["recipe_id"] = recipe_id
	if str(definition.get("runtime_metadata", {}).get("power_mode", "")) == "ENERGY_EXCHANGER":
		entity["energy_mode"] = "DISCHARGE" if str(recipe.get("source_id", "")) == "accumulator_discharge" else "CHARGE"
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
	if str(world.get("logistics_mode", "PLANET_SHARED_DRONES")) == "PLANET_SHARED_DRONES":
		return _failure("LEGACY_LINKS_RETIRED", "Road logistics replaces manual Cargo and Power wires")
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
	var road_shipment_ids: Array = []
	for shipment_id_value in world.get("drone_shipments", {}).keys():
		var shipment: Dictionary = world.get("drone_shipments", {}).get(shipment_id_value, {})
		if str(shipment.get("source_id", "")) == entity_id or str(shipment.get("target_id", "")) == entity_id or str(shipment.get("tower_id", "")) == entity_id:
			road_shipment_ids.append(str(shipment_id_value))
	if not road_shipment_ids.is_empty():
		road_shipment_ids.sort()
		return {
			"ok":false,
			"reason_code":"DRONE_SHIPMENT_REFERENCES_ENTITY",
			"reason":"Factory entities referenced by active drone flights cannot be removed",
			"entity_id":entity_id,
			"road_shipment_ids":road_shipment_ids
		}
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
	return {"ok":true, "entity_id":entity_id, "removed_link_ids":removed_link_ids, "returned_items":{str(entity["deployment_item_id"]):1} if not str(entity.get("deployment_item_id", "")).is_empty() else {}}


func advance_world(world: Dictionary, elapsed_ms: float, inventory_context: Dictionary = {}) -> Dictionary:
	var remaining_seconds := maxf(0.0, elapsed_ms) / 1000.0
	var step_limit := maxf(0.05, float(rules.get("simulation_step_seconds", DEFAULT_STEP_SECONDS)))
	var events: Array[Dictionary] = []
	var steps := 0
	while remaining_seconds > EPSILON:
		var step_seconds := minf(remaining_seconds, step_limit)
		_step(world, step_seconds, events, inventory_context)
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
	_dsp_power_plan = DspProduction.prepare_power(world, building_definitions, recipe_definitions, 1.0)
	var power_factors := _calculate_power_factors(world)
	_refresh_operational_status(world, power_factors)
	if _is_drone_mode(world):
		world["drone_logistics"] = FactoryDroneTransport.logistics_snapshot(world, rules, _drone_context(world))
	return power_factors


## Factory evaluates physical flow in fixed deterministic ticks. The top-level
## simulator uses the same tick as a cross-domain boundary whenever the world
## can produce, extract, or complete funded construction, so a result created at
## the end of a tick cannot be consumed retroactively during that tick.
func synchronization_boundary_ms(world: Dictionary) -> float:
	var result := INF
	if not world.get("construction_orders", {}).is_empty():
		result = maxf(0.05, float(rules.get("simulation_step_seconds", DEFAULT_STEP_SECONDS))) * 1000.0
	for entity_value in world.get("entities", {}).values():
		if str((entity_value as Dictionary).get("kind", "")) in ["EXTRACTOR", "MACHINE", "POWER"]:
			var tick_ms := maxf(0.05, float(rules.get("simulation_step_seconds", DEFAULT_STEP_SECONDS))) * 1000.0
			var tick_progress := fposmod(maxf(0.0, float(world.get("elapsed_ms", 0.0))), tick_ms)
			result = minf(result, tick_ms if tick_progress <= 0.001 else tick_ms - tick_progress)
			break
	return result


func _step(world: Dictionary, seconds: float, events: Array[Dictionary], inventory_context: Dictionary = {}) -> void:
	_advance_dyson(world, seconds)
	_refresh_spray_services(world, inventory_context)
	if _is_drone_mode(world):
		var road_graph := _drone_context(world)
		FactoryDroneTransport.advance(world, seconds, building_definitions, recipe_definitions, rules, inventory_context, road_graph)
	else:
		for link_value in world.get("links", {}).values():
			var link := link_value as Dictionary
			link["last_flow"] = 0.0
			if str(link.get("kind", "")) == "CARGO":
				link["blocked_reason"] = ""
				link["capacity_progress"] = float(link.get("capacity_progress", 0.0)) \
					+ maxf(0.0, float(link.get("capacity_per_second", 0.0))) * _cargo_link_power_factor(world, link) * seconds
			_transfer_cargo(world, seconds)
	_dsp_power_plan = DspProduction.prepare_power(world, building_definitions, recipe_definitions, seconds)
	var power_factors := _calculate_power_factors(world)
	var energy_settlement := DspProduction.settle_power(world, building_definitions, _power_allocation, _power_charge, seconds)
	_refresh_spray_services(world, inventory_context, false)
	for manifest in energy_settlement.get("fuel_consumed", {}).values():
		for item_id in manifest:
			_add_statistic(world, "consumed", str(item_id), int(manifest[item_id]))
	_run_extractors(world, seconds, power_factors, events)
	_run_machines(world, seconds, power_factors, events)
	if _is_drone_mode(world):
		FactoryDroneTransport.queue(world, building_definitions, recipe_definitions, rules, inventory_context, _drone_context(world))
		world["drone_logistics"] = FactoryDroneTransport.logistics_snapshot(world, rules, _drone_context(world))
	else:
		_transfer_cargo(world, seconds)
	# Unused whole-unit throughput expires at the end of this simulation step.
	# Only sub-unit progress crosses a boundary, so a blocked belt cannot bank
	# hours of capacity and burst it after downstream space becomes available.
	if not _is_drone_mode(world):
		for link_value in world.get("links", {}).values():
			var link := link_value as Dictionary
			if str(link.get("kind", "")) == "CARGO":
				var progress := maxf(0.0, float(link.get("capacity_progress", 0.0)))
				link["capacity_progress"] = progress - floorf(progress)
	events.append_array(deploy_pending_buildings(world, inventory_context))
	if not _is_drone_mode(world):
		_update_cargo_link_diagnostics(world)
	_refresh_router_operational_status(world)


func _advance_dyson(world: Dictionary, seconds: float) -> void:
	if not world.has("dsp_effects"):
		world["dsp_effects"] = {}
	var effects: Dictionary = world["dsp_effects"]
	effects["clock_seconds"] = float(effects.get("clock_seconds", 0.0)) + seconds
	var cohorts: Dictionary = effects.get("sail_cohorts", {})
	var sails := 0
	for expiry in cohorts.keys():
		if float(expiry) <= float(effects["clock_seconds"]):
			cohorts.erase(expiry)
		else:
			sails += int(cohorts[expiry])
	effects["sail_cohorts"] = cohorts
	effects["dyson_sails"] = sails
	effects["ray_available_kw"] = sails * 88.0 + float(effects.get("dyson_structure", 0.0)) * 960.0


func _refresh_spray_services(world: Dictionary, inventory_context: Dictionary, allow_enable: bool = true) -> void:
	world["spray_services"] = {}
	var coaters: Array = []
	for id in _sorted_keys(world.get("entities", {})):
		var entity: Dictionary = world["entities"][id]
		if str(entity.get("definition_id", "")) == "grid_dsp_spray_coater" and float(entity.get("power_factor", 0.0)) >= 1.0 - EPSILON:
			coaters.append(entity)
	if coaters.is_empty():
		for entity in world.get("entities", {}).values():
			if entity.has("proliferator"):
				_disable_spray_service(entity)
		return
	for id in _sorted_keys(world.get("entities", {})):
		var entity: Dictionary = world["entities"][id]
		var recipe: Dictionary = recipe_definitions.get(str(entity.get("recipe_id", "")), {})
		if recipe.get("inputs", []).is_empty() or str(recipe.get("id", "")) in ["dsp_accumulator_charge", "dsp_accumulator_discharge"]:
			if entity.has("proliferator"):
				_disable_spray_service(entity)
			continue
		var best := {}
		var distance := float(rules.get("drone_radius_tiles", 64.0)) + 1.0
		for coater in coaters:
			var separation := FactoryDroneTransport.center(coater).distance_to(FactoryDroneTransport.center(entity))
			if separation < distance:
				best = coater
				distance = separation
		if best.is_empty():
			if entity.has("proliferator"):
				_disable_spray_service(entity)
			continue
		var previous: Dictionary = entity.get("proliferator", {})
		# After this tick's power dispatch we may only disable a service. New
		# activation/tier changes wait until the next demand calculation.
		if not allow_enable:
			if str(previous.get("mode", "")) in ["EXTRA", "SPEED"]:
				world["spray_services"][id] = {"coater_id":str(best.get("id", "")), "enabled":true, "item_id":str(previous.get("item_id", ""))}
			continue
		var tier := 1
		for candidate in [3, 2, 1]:
			var item_id := "dsp_proliferator_mk%d" % candidate
			if int(entity.get("inputs", {}).get(item_id, 0)) > 0 or int(inventory_context.get("available", {}).get(item_id, 0)) > 0:
				tier = candidate
				break
		# Remaining spray points retain their original tier until exhausted.
		if int(previous.get("points", 0)) > 0:
			tier = int(previous.get("tier", tier))
		entity["proliferator"] = {"tier":tier, "mode":"SPEED" if str(recipe.get("runtime_metadata", {}).get("recipe_mode", "")) == "MATRIX" else "EXTRA", "item_id":"dsp_proliferator_mk%d" % tier, "spray_points_per_item":[12,24,60][tier-1], "extra_product_bonus":[0.125,0.2,0.25][tier-1], "speed_bonus":[0.25,0.5,1.0][tier-1], "points":int(previous.get("points", 0))}
		world["spray_services"][id] = {"coater_id":str(best.get("id", "")), "enabled":true, "item_id":entity["proliferator"]["item_id"]}


func _disable_spray_service(entity: Dictionary) -> void:
	# SPEED points settle on completed cycles. Do not retain accelerated,
	# unpaid partial work when the service is disconnected or loses power.
	if str(entity.get("proliferator", {}).get("mode", "")) == "SPEED":
		entity["progress"] = 0.0
	entity["proliferator"]["mode"] = "NORMAL"


func _calculate_power_factors(world: Dictionary) -> Dictionary:
	if _is_drone_mode(world):
		return _calculate_wireless_power_factors(world)
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
		supply[root] = float(supply.get(root, 0.0)) + effective_generation_kw(world, definition)
		demand[root] = float(demand.get(root, 0.0)) + effective_demand_kw(world, definition)
	var factors := {}
	for entity_id_value in parent.keys():
		var entity_id := str(entity_id_value)
		var root := _find_root(parent, entity_id)
		var definition: Dictionary = building_definitions.get(str(world["entities"][entity_id].get("definition_id", "")), {})
		var entity_demand := effective_demand_kw(world, definition)
		var factor := 1.0 if entity_demand <= EPSILON else clampf(float(supply.get(root, 0.0)) / maxf(EPSILON, float(demand.get(root, 0.0))), 0.0, 1.0)
		factors[entity_id] = factor
		world["entities"][entity_id]["power_factor"] = factor
	return factors


func _calculate_wireless_power_factors(world: Dictionary) -> Dictionary:
	_power_allocation.clear()
	_power_charge.clear()
	var supply := {}
	var demand := {}
	var components := {}
	var generators := {}
	world.get("dsp_effects", {})["time_warp_multiplier"] = 1
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		# Roads no longer constrain the planet's power network. Keep the existing
		# allocation/energy settlement below, so fuel and batteries still settle.
		var access := {"road_connected":true, "road_component_id":"PLANET_POWER"}
		entity["road_connected"] = bool(access.get("road_connected", false))
		entity["road_component_id"] = str(access.get("road_component_id", ""))
		entity["available_generation_kw"] = 0.0
		entity["warp_power_kw"] = 0.0
		var component_id := str(entity.get("road_component_id", ""))
		if component_id.is_empty():
			continue
		components[component_id] = true
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		var mode := str(definition.get("runtime_metadata", {}).get("power_mode", ""))
		var generation := effective_generation_kw(world, definition)
		if mode in ["FUEL_GENERATOR", "BATTERY", "ENERGY_EXCHANGER", "RAY_RECEIVER"]:
			generation = float(_dsp_power_plan.get("generation_capacity_kw", {}).get(entity_id, 0.0)) + float(_dsp_power_plan.get("ray_power_kw", {}).get(entity_id, 0.0))
		generators[entity_id] = generation
		entity["available_generation_kw"] = generation
		supply[component_id] = float(supply.get(component_id, 0.0)) + generation
		demand[component_id] = float(demand.get(component_id, 0.0)) + effective_demand_kw(world, definition, entity)
	# Deterministic source dispatch: renewables/core first, fuel second, stored
	# energy only for deficits. Charging uses renewable surplus, never batteries.
	for component_id in components:
		var needed := float(demand.get(component_id, 0.0))
		var renewable_surplus := 0.0
		for stage in range(3):
			for entity_id in _sorted_keys(generators):
				var entity: Dictionary = world["entities"][entity_id]
				if str(entity.get("road_component_id", "")) != component_id:
					continue
				var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
				var mode := str(definition.get("runtime_metadata", {}).get("power_mode", ""))
				var source_stage := 2 if mode in ["BATTERY", "ENERGY_EXCHANGER"] else (1 if mode == "FUEL_GENERATOR" else 0)
				if source_stage != stage:
					continue
				var capacity := float(generators[entity_id])
				var allocated := minf(needed, capacity)
				_power_allocation[entity_id] = allocated
				needed -= allocated
				if stage == 0:
					renewable_surplus += capacity - allocated
		for entity_id in _sorted_keys(world.get("entities", {})):
			if str(world["entities"][entity_id].get("road_component_id", "")) != component_id or float(_power_allocation.get(entity_id, 0.0)) > EPSILON:
				continue
			var charge := minf(renewable_surplus, float(_dsp_power_plan.get("charge_capacity_kw", {}).get(entity_id, 0.0)))
			_power_charge[entity_id] = charge
			renewable_surplus -= charge
		for entity_id in _sorted_keys(world.get("entities", {})):
			var entity: Dictionary = world["entities"][entity_id]
			if str(entity.get("definition_id", "")) != "grid_dsp_time_warp_device" or str(entity.get("road_component_id", "")) != component_id:
				continue
			var multiplier := DspProjects.stable_multiplier(renewable_surplus)
			world["dsp_effects"]["time_warp_multiplier"] = multiplier
			entity["warp_power_kw"] = pow(10.0, multiplier + 1) if multiplier > 1 else 0.0
			renewable_surplus -= float(entity["warp_power_kw"])
	var factors := {}
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		var entity_demand := effective_demand_kw(world, definition, entity)
		var component_id := str(entity.get("road_component_id", ""))
		var factor := 0.0 if component_id.is_empty() else 1.0
		if entity_demand > EPSILON:
			if component_id.is_empty():
				factor = 0.0
			else:
				factor = clampf(float(supply.get(component_id, 0.0)) / maxf(EPSILON, float(demand.get(component_id, 0.0))), 0.0, 1.0)
		factors[entity_id] = factor
		entity["power_factor"] = factor
		entity["generation_kw"] = float(_power_allocation.get(entity_id, 0.0))
		entity["charge_kw"] = float(_power_charge.get(entity_id, 0.0))
		entity["dsp_recipe_power_factor"] = float(_dsp_power_plan.get("recipe_power_factor", {}).get(entity_id, 1.0))
	return factors


func _is_drone_mode(world: Dictionary) -> bool:
	return str(world.get("logistics_mode", "PLANET_SHARED_DRONES")) == "PLANET_SHARED_DRONES"


func _drone_context(_world: Dictionary) -> Dictionary:
	return {"building_definitions":building_definitions}


func _refresh_operational_status(world: Dictionary, power_factors: Dictionary) -> void:
	for entity_id_value in _sorted_keys(world.get("entities", {})):
		var entity_id := str(entity_id_value)
		var entity: Dictionary = world.get("entities", {}).get(entity_id, {})
		match str(entity.get("kind", "")):
			"EXTRACTOR":
				_apply_operational_projection(entity, _extractor_operational_projection(world, entity_id, entity, power_factors))
			"POWER":
				if not str(entity.get("recipe_id", "")).is_empty():
					_apply_operational_projection(entity, _machine_operational_projection(entity_id, entity, power_factors))
				elif not bool(entity.get("road_connected", false)):
					entity["status"] = "NO_POWER"
				elif float(entity.get("generation_kw", 0.0)) > EPSILON:
					entity["status"] = "RUNNING"
				elif float(entity.get("charge_kw", 0.0)) > EPSILON:
					entity["status"] = "CHARGING"
				else:
					entity["status"] = str(_dsp_power_plan.get("blocked", {}).get(entity_id, "IDLE"))
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
	var resource_profile := resource_coverage_for_footprint(world, entity.get("footprint", {}), float(definition.get("resource_coverage_loss_per_missing_tile", 0.1)), float(definition.get("mining_radius_tiles", 0.0)))
	_apply_extractor_resource_profile(entity, resource_profile)
	var resource_unlocked := _resource_unlocked(world, definition, resource_profile)
	definition = _resource_definition(definition, resource_profile)
	resource_profile = resource_coverage_for_footprint(world, entity.get("footprint", {}), float(definition.get("resource_coverage_loss_per_missing_tile", 0.1)), float(definition.get("mining_radius_tiles", 0.0)))
	_apply_extractor_resource_profile(entity, resource_profile)
	var projection := {"status":"NO_RESOURCE", "actual_rate":0.0, "resource_profile":resource_profile, "resource_id":str(resource_profile.get("resource_id", "")), "free":0}
	if not resource_unlocked:
		projection["status"] = "BUILDING_LOCKED"
		return projection
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
	var continuing_legacy := bool(entity.get("legacy_recipe_continuation", false)) and not str(recipe.get("replacement_building_id", "")).is_empty()
	if recipe.is_empty() or (bool(recipe.get("legacy_only", false)) and not continuing_legacy):
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
	if str(recipe.get("runtime_metadata", {}).get("recipe_mode", "")) == "CRITICAL_PHOTON":
		projection["actual_rate"] *= float(entity.get("dsp_recipe_power_factor", 0.0))
		if float(projection["actual_rate"]) <= EPSILON:
			projection["status"] = "NO_DYSON_POWER"
			return projection
	if str(recipe.get("runtime_metadata", {}).get("recipe_mode", "")) == "RAY_POWER":
		projection["actual_rate"] = 0.0
		projection["status"] = "GENERATING"
		return projection
	projection["actual_rate"] *= DspProduction.proliferation_speed_multiplier(entity, recipe)
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
		if str(entity.get("kind", "")) not in ["MACHINE", "POWER"] or str(entity.get("recipe_id", "")).is_empty():
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
		var runtime_view := entity.duplicate(false)
		runtime_view["dsp_runtime_metadata"] = building_definitions.get(str(entity.get("definition_id", "")), {}).get("runtime_metadata", {})
		var special := DspProduction.finish_recipe(world, runtime_view, recipe, completed_cycles)
		completed_cycles = int(special.get("allowed_cycles", 0))
		var project := DspProjects.finish_recipe(world, entity, recipe, completed_cycles)
		completed_cycles = int(project.get("allowed_cycles", 0))
		if not str(project.get("blocked", "")).is_empty():
			special["blocked"] = project["blocked"]
		if not str(special.get("blocked", "")).is_empty():
			entity["status"] = str(special["blocked"])
			entity["progress"] = minf(1.0, float(entity["progress"]))
		if completed_cycles > 0:
			DspProjects.apply_effects(world, project.get("effects", {}))
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
			for item_id in special.get("extra_outputs", {}):
				var quantity := int(special["extra_outputs"][item_id])
				entity["outputs"][item_id] = int(entity["outputs"].get(item_id, 0)) + quantity
				produced_items[item_id] = int(produced_items.get(item_id, 0)) + quantity
				_add_statistic(world, "produced", str(item_id), quantity)
			var spray: Dictionary = special.get("spray", {})
			for item_id in spray.get("consumed_items", {}):
				var quantity := int(spray["consumed_items"][item_id])
				entity["inputs"][item_id] = int(entity["inputs"].get(item_id, 0)) - quantity
				_add_statistic(world, "consumed", str(item_id), quantity)
			if int(spray.get("sprayed_cycles", 0)) > 0:
				entity["proliferator"]["points"] = int(spray.get("points_after", 0))
				entity["proliferator_bonus_progress"] = spray.get("bonus_progress", {}).duplicate(true)
			var energy_key := "energy_debt_mj" if str(entity.get("energy_mode", "")) == "DISCHARGE" else "energy_credit_mj"
			entity[energy_key] = maxf(0.0, float(entity.get(energy_key, 0.0)) + float(special.get("energy_delta_mj", 0.0)))
			if not world.has("dsp_effects"):
				world["dsp_effects"] = {}
			for key in special.get("effects", {}):
				world["dsp_effects"][key] = float(world["dsp_effects"].get(key, 0.0)) + float(special["effects"][key])
			var launched_sails := int(special.get("effects", {}).get("dyson_sails", 0))
			if launched_sails > 0:
				var expiry := str(ceili(float(world["dsp_effects"].get("clock_seconds", 0.0)) + 1200.0))
				var cohorts: Dictionary = world["dsp_effects"].get("sail_cohorts", {})
				cohorts[expiry] = int(cohorts.get(expiry, 0)) + launched_sails
				world["dsp_effects"]["sail_cohorts"] = cohorts
			world["dsp_effects"]["ray_available_kw"] = float(world["dsp_effects"].get("dyson_sails", 0.0)) * 88.0 + float(world["dsp_effects"].get("dyson_structure", 0.0)) * 960.0
			entity["progress"] = maxf(0.0, float(entity.get("progress", 0.0)) - float(completed_cycles))
			events.append({
				"type":"FactoryRecipeCompleted",
				"world_id":str(world.get("world_id", "")),
				"entity_id":entity_id,
				"recipe_id":str(recipe.get("id", "")),
				"activity_id":str(recipe.get("activity_id", "")),
				"completed_cycles":completed_cycles,
				"dsp_effects":special.get("effects", {}).duplicate(true),
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
		# Warehouses arbitrate independent item slots. Machines and routers
		# still arbitrate a shared physical transit/input buffer.
		var target_key := str(candidate.get("target_id", ""))
		var candidate_target: Dictionary = world.get("entities", {}).get(target_key, {})
		if str(candidate_target.get("kind", "")) == "STORAGE":
			target_key += ":" + str(candidate.get("item_id", ""))
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
		var capacity_key := item_id if str(target.get("kind", "")) == "STORAGE" else "SHARED"
		var target_allocations := _fair_allocations(target, capacity_key, target_candidates, _target_free_capacity(target, item_id), "IN")
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


## Location inventory -> installed building is custody transfer, not consumption.
## No work timer. Context is ephemeral; resolve by priority then stable order ID.
func deploy_pending_buildings(world: Dictionary, inventory_context: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	if not inventory_context.get("inventory", null) is Dictionary or not inventory_context.get("available", null) is Dictionary:
		return events
	var inventory: Dictionary = inventory_context["inventory"]
	var available: Dictionary = inventory_context["available"]
	var orders: Array = world.get("construction_orders", {}).values()
	orders.sort_custom(func(a, b):
		var ap := int(a.get("priority", 50))
		var bp := int(b.get("priority", 50))
		return str(a.get("id", "")) < str(b.get("id", "")) if ap == bp else ap > bp
	)
	for order_value in orders:
		var order := order_value as Dictionary
		var item_id := str(order.get("deployment_item_id", ""))
		if item_id.is_empty() or not order.get("delivered_items", {}).is_empty():
			continue # Legacy staging must be returned by the Location owner.
		if mini(int(inventory.get(item_id, 0)), int(available.get(item_id, 0))) < 1:
			order["status"] = "WAITING_BUILDING"
			order["blocked_reason"] = "MISSING_BUILDING"
			continue
		var order_id := str(order.get("id", ""))
		var definition_id := str(order.get("definition_id", ""))
		var origin := _point(order.get("footprint", {}).get("origin", {}))
		var placement := can_place_entity(world, definition_id, origin, str(order.get("recipe_id", "")), order_id)
		if not bool(placement.get("ok", false)):
			order["blocked_reason"] = str(placement.get("reason_code", "INVALID_PLACEMENT"))
			continue
		var entity_id := str(order.get("entity_id", ""))
		if world.get("entities", {}).has(entity_id):
			continue
		var entity := _create_entity(entity_id, definition_id, origin, str(order.get("recipe_id", "")))
		entity["deployment_item_id"] = item_id
		_apply_extractor_resource_profile(entity, placement.get("resource_profile", {}))
		inventory[item_id] = int(inventory.get(item_id, 0)) - 1
		available[item_id] = int(available.get(item_id, 0)) - 1
		if inventory_context.get("free_capacity", null) is Dictionary:
			var free: Dictionary = inventory_context["free_capacity"]
			free[item_id] = int(free.get(item_id, 0)) + 1
		world["construction_orders"].erase(order_id)
		world["entities"][entity_id] = entity
		world["statistics"]["construction_completed"] = int(world.get("statistics", {}).get("construction_completed", 0)) + 1
		_bump_topology_revision(world)
		events.append({"type":"FactoryBuildingDeployed", "world_id":world.get("world_id", ""), "order_id":order_id, "entity_id":entity_id, "definition_id":definition_id, "item_id":item_id})
	return events


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
	var effects := environment_effects(world)
	var road_graph := _drone_context(world)
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
			"shape":str(resource_field.get("shape", "RECTANGLE")),
			"seed":int(resource_field.get("seed", 1)),
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
		var tower_ids := FactoryDroneTransport.covering_towers(world, entity, building_definitions, rules)
		var nominal_generation_kw := FactoryEnvironmentEffects.nominal_generation_kw(definition)
		var nominal_demand_kw := FactoryEnvironmentEffects.nominal_demand_kw(definition)
		var nominal_construction_capacity := FactoryEnvironmentEffects.nominal_construction_capacity_per_second(definition)
		var effective_generation := float(entity.get("available_generation_kw", effective_generation_kw(world, definition)))
		var effective_demand := effective_demand_kw(world, definition, entity)
		var effective_construction_capacity := FactoryEnvironmentEffects.effective_construction_capacity_per_second(_world_environment(world), nominal_construction_capacity * clampf(FactoryEnvironmentEffects.finite_number(entity.get("power_factor", 1.0), 1.0), 0.0, 1.0))
		entities.append({
			"id":entity_id,
			"node_kind":str(entity.get("kind", "UNKNOWN")),
			"is_entity":true,
			"definition_id":str(entity.get("definition_id", "")),
			"router_mode":str(definition.get("router_mode", "BIDIRECTIONAL")) if str(entity.get("kind", "")) == "ROUTER" else "",
			"name":str(definition.get("name", entity.get("definition_id", entity_id))),
			"recipe_id":str(entity.get("recipe_id", "")),
			"dsp":DspProduction.snapshot_metadata(definition, recipe_definitions.get(str(entity.get("recipe_id", "")), {}), entity),
			"generation_kw":float(entity.get("generation_kw", 0.0)),
			"charge_kw":float(entity.get("charge_kw", 0.0)),
			"footprint":entity.get("footprint", {}).duplicate(true),
			"status":status,
			"status_tone":_status_tone(status),
			"blocker_code":_entity_blocker_code(status),
			"inputs":entity.get("inputs", {}).duplicate(true),
			"outputs":entity.get("outputs", {}).duplicate(true),
			"inventory":{} if _is_drone_mode(world) and str(entity.get("kind", "")) == "STORAGE" else entity.get("inventory", {}).duplicate(true),
			"progress":maxf(0.0, float(entity.get("progress", 0.0))),
			"power_factor":clampf(float(entity.get("power_factor", 1.0)), 0.0, 1.0),
			"actual_rate":maxf(0.0, float(entity.get("actual_rate", 0.0))),
			"input_capacity":maxi(0, int(definition.get("input_capacity", 0))),
			"output_capacity":maxi(0, int(definition.get("output_capacity", 0))),
			"inventory_capacity":maxi(0, int(definition.get("inventory_capacity", 0))),
			"power_generation_kw":effective_generation,
			"power_demand_kw":effective_demand,
			"nominal_power_generation_kw":nominal_generation_kw,
			"nominal_power_demand_kw":nominal_demand_kw,
			"effective_power_generation_kw":effective_generation,
			"effective_power_demand_kw":effective_demand,
			"construction_capacity_per_second":effective_construction_capacity,
			"nominal_construction_capacity_per_second":nominal_construction_capacity,
			"effective_construction_capacity_per_second":effective_construction_capacity,
			"resource_id":str(entity.get("resource_id", "")),
			"coverage_efficiency":clampf(float(entity.get("coverage_efficiency", 0.0)), 0.0, 1.0),
			"average_grade":maxf(0.0, float(entity.get("average_grade", 0.0))),
			"sustainable_rate_per_second":maxf(0.0, float(entity.get("sustainable_rate_per_second", 0.0))),
			"covered_resource_tiles":maxi(0, int(entity.get("covered_resource_tiles", 0))),
			"footprint_tiles":maxi(0, int(entity.get("footprint_tiles", 0))),
			"mining_radius_tiles":maxf(0.0, float(entity.get("mining_radius_tiles", definition.get("mining_radius_tiles", 0.0)))),
			"mining_area_tiles":maxi(0, int(entity.get("mining_area_tiles", 0))),
			"missing_resource_tiles":maxi(0, int(entity.get("missing_resource_tiles", 0))),
			"ports":_entity_port_snapshot(entity_id, entity, port_connections),
			"drone_covered":not tower_ids.is_empty(),
			"drone_tower":bool(definition.get("drone_tower", false)),
			"drone_radius_tiles":float(definition.get("drone_radius_tiles", 0.0)),
			"drone_count":int(definition.get("drone_count", 0)),
			"drone_tower_ids":tower_ids,
			"input_targets":_drone_input_targets(entity)
		})

	var links: Array = []
	if not _is_drone_mode(world):
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
		var order_profile: Dictionary = order.get("resource_profile", {}) as Dictionary
		var order_definition: Dictionary = building_definitions.get(str(order.get("definition_id", "")), {}) as Dictionary
		var order_status := str(order.get("status", "WAITING_BUILDING"))
		construction_orders.append({
			"id":order_id,
			"entity_id":str(order.get("entity_id", "")),
			"definition_id":str(order.get("definition_id", "")),
			"recipe_id":str(order.get("recipe_id", "")),
			"footprint":order.get("footprint", {}).duplicate(true),
			"mining_radius_tiles":maxf(0.0, float(order_profile.get("mining_radius_tiles", order_definition.get("mining_radius_tiles", 0.0)))),
			"mining_area_tiles":maxi(0, int(order_profile.get("mining_area_tiles", 0))),
			"required_items":order.get("required_items", {}).duplicate(true),
			"delivered_items":order.get("delivered_items", {}).duplicate(true),
			"deployment_item_id":str(order.get("deployment_item_id", "")),
			"progress":0.0,
			"priority":clampi(int(order.get("priority", 50)), 0, 100),
			"funding_policy":str(order.get("funding_policy", "MANUAL")),
			"status":order_status,
			"status_tone":_status_tone(order_status),
			"blocker_code":str(order.get("blocked_reason", "")),
			"remaining_ms":-1.0
		})

	var production_rows := _production_rows(world, _production_route_index(world))
	var production_summary := _production_summary(production_rows)
	var drone_logistics := FactoryDroneTransport.logistics_snapshot(world, rules, road_graph)
	return {
		"protocol_version":WORKSPACE_PROTOCOL_VERSION,
		"terrain_enabled":bool(world.get("terrain_enabled", false)),
		"terrain_safe_rect":world.get("terrain_safe_rect", {}).duplicate(true),
		"seed":int(world.get("seed", 1)),
		"terrain_seed":Terrain._integer(world.get("terrain_seed", world.get("seed", 1)), 1),
		"generator_version":Terrain._integer(world.get("generator_version", 1), 1),
		"terrain_scale_tiles":Terrain._finite_number(world.get("terrain_scale_tiles", 48.0), 48.0),
		"terrain_profile":str(world.get("terrain_profile", "")),
		"tile_deltas":world.get("tile_deltas", {}).duplicate(true),
		"landing_definition_id":str(world.get("landing_definition_id", "")),
		"landing_required":not str(world.get("landing_definition_id", "")).is_empty() and not bool(world.get("starter_package_delivered", false)),
		"world_schema_version":int(world.get("schema_version", WORLD_SCHEMA_VERSION)),
		"world_id":str(world.get("world_id", "")),
		"location_id":str(world.get("location_id", "")),
		"topology_revision":maxi(0, int(world.get("topology_revision", 0))),
		"runtime_revision":maxi(0, int(world.get("runtime_revision", 0))),
		"elapsed_ms":maxf(0.0, float(world.get("elapsed_ms", 0.0))),
		"logistics_mode":str(world.get("logistics_mode", "PLANET_SHARED_DRONES")),
		"roads":[],
		"drone_logistics":drone_logistics,
		"dsp_effects":world.get("dsp_effects", {}).duplicate(true),
		"drone_shipments":FactoryDroneTransport.workspace_shipments(world, rules),
		"environment":_world_environment(world).duplicate(true),
		"environment_effects":effects,
		"construction_capacity_per_second":construction_capacity_per_second(world),
		"tile_size_m":maxi(1, int(world.get("tile_size_m", 1))),
		"chunk_size_tiles":maxi(1, int(world.get("chunk_size_tiles", DEFAULT_CHUNK_SIZE))),
		"bounds":world.get("bounds", {}).duplicate(true),
		"resource_fields":resource_fields,
		"entities":entities,
		"links":links,
		"construction_orders":construction_orders,
		"palette":_workspace_palette_snapshot(world),
		"power":_workspace_power_snapshot(world),
		"production":{"summary":production_summary, "rows":production_rows},
		"production_summary":production_summary.duplicate(true),
		"production_rows":production_rows.duplicate(true),
		"statistics":world.get("statistics", {}).duplicate(true),
		"summary":world_summary(world)
	}


func _workspace_palette_snapshot(world: Dictionary) -> Dictionary:
	var buildings: Array = []
	for definition_id_value in _sorted_keys(building_definitions):
		var definition_id := str(definition_id_value)
		var definition: Dictionary = building_definitions.get(definition_id, {})
		if bool(definition.get("legacy_only", false)):
			continue
		var nominal_generation_kw := FactoryEnvironmentEffects.nominal_generation_kw(definition)
		var nominal_demand_kw := FactoryEnvironmentEffects.nominal_demand_kw(definition)
		var effective_generation := effective_generation_kw(world, definition)
		var effective_demand := effective_demand_kw(world, definition)
		buildings.append({
			"id":definition_id,
			"name":str(definition.get("name", definition_id)),
			"kind":str(definition.get("kind", "")),
			"drone_tower":bool(definition.get("drone_tower", false)),
			"drone_radius_tiles":float(definition.get("drone_radius_tiles", 0.0)),
			"drone_count":int(definition.get("drone_count", 0)),
			"footprint":definition.get("footprint", {}).duplicate(true),
			"recipe_ids":definition.get("recipe_ids", []).duplicate(true),
			"resource_categories":definition.get("resource_categories", []).duplicate(true),
			"allowed_resource_ids":definition.get("allowed_resource_ids", []).duplicate(true),
			"mining_radius_tiles":maxf(0.0, float(definition.get("mining_radius_tiles", 0.0))),
			"deployment_item_id":str(definition.get("deployment_item_id", "")),
			"power_generation_kw":effective_generation,
			"power_demand_kw":effective_demand,
			"nominal_power_generation_kw":nominal_generation_kw,
			"nominal_power_demand_kw":nominal_demand_kw,
			"effective_power_generation_kw":effective_generation,
			"effective_power_demand_kw":effective_demand,
			"construction_capacity_per_second":FactoryEnvironmentEffects.effective_construction_capacity_per_second(_world_environment(world), FactoryEnvironmentEffects.nominal_construction_capacity_per_second(definition)),
			"nominal_construction_capacity_per_second":FactoryEnvironmentEffects.nominal_construction_capacity_per_second(definition)
		})
	var recipes: Array = []
	for recipe_id_value in _sorted_keys(recipe_definitions):
		var recipe_id := str(recipe_id_value)
		var recipe: Dictionary = recipe_definitions.get(recipe_id, {})
		if bool(recipe.get("legacy_only", false)):
			continue
		recipes.append({
			"id":recipe_id,
			"name":str(recipe.get("name", recipe_id)),
			"building_definition_id":str(recipe.get("building_definition_id", "")),
			"runtime_metadata":recipe.get("runtime_metadata", {}).duplicate(true),
			"duration_seconds":maxf(EPSILON, float(recipe.get("duration_seconds", 1.0))),
			"inputs":recipe.get("inputs", []).duplicate(true),
			"outputs":recipe.get("outputs", []).duplicate(true)
		})
	return {"buildings":buildings, "recipes":recipes}


func _workspace_power_snapshot(world: Dictionary) -> Dictionary:
	var generation_kw := 0.0
	var actual_generation_kw := 0.0
	var demand_kw := 0.0
	var served_kw := 0.0
	var nominal_generation_kw := 0.0
	var nominal_demand_kw := 0.0
	for entity_value in world.get("entities", {}).values():
		var entity := entity_value as Dictionary
		var definition: Dictionary = building_definitions.get(str(entity.get("definition_id", "")), {})
		var entity_generation := float(entity.get("available_generation_kw", effective_generation_kw(world, definition)))
		var entity_demand := effective_demand_kw(world, definition, entity)
		generation_kw += entity_generation
		actual_generation_kw += float(entity.get("generation_kw", 0.0))
		demand_kw += entity_demand
		nominal_generation_kw += FactoryEnvironmentEffects.nominal_generation_kw(definition)
		nominal_demand_kw += FactoryEnvironmentEffects.nominal_demand_kw(definition)
		served_kw += entity_demand * clampf(float(entity.get("power_factor", 1.0)), 0.0, 1.0)
	return {
		"generation_kw":generation_kw,
		"demand_kw":demand_kw,
		"served_kw":served_kw,
		"nominal_generation_kw":nominal_generation_kw,
		"nominal_demand_kw":nominal_demand_kw,
		"effective_generation_kw":generation_kw,
		"available_generation_kw":generation_kw,
		"actual_generation_kw":actual_generation_kw,
		"effective_demand_kw":demand_kw,
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
		definition = _resource_definition(definition, entity)
		var profile := resource_coverage_for_footprint(world, entity.get("footprint", {}), float(definition.get("resource_coverage_loss_per_missing_tile", 0.1)), float(definition.get("mining_radius_tiles", 0.0)))
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
		"drone_tower":bool(definition.get("drone_tower", false)),
		"drone_radius_tiles":float(definition.get("drone_radius_tiles", 0.0)),
		"drone_count":int(definition.get("drone_count", 0)),
		"recipe_id":recipe_id,
		"energy_mode":"DISCHARGE" if recipe_id == "dsp_accumulator_discharge" else "CHARGE",
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
	for field in ["resource_id", "resource_category", "resource_field_ids", "covered_tiles_by_field", "covered_resource_tiles", "footprint_tiles", "mining_radius_tiles", "mining_area_tiles", "missing_resource_tiles", "coverage_efficiency", "average_grade", "sustainable_rate_per_second", "mixed_resource_types"]:
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
	if str(entity.get("kind", "")) == "STORAGE":
		return maxi(0, int(definition.get("inventory_capacity", 0)) - int(entity.get("inventory", {}).get(item_id, 0)))
	if str(entity.get("kind", "")) == "ROUTER":
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
	return cycles if cycles != 2147483647 or str(recipe.get("runtime_metadata", {}).get("recipe_mode", "")) in ["CRITICAL_PHOTON", "RAY_POWER"] else 0


func _machine_output_capacity_reservation(entity: Dictionary, definition: Dictionary, recipe: Dictionary) -> Dictionary:
	var free := maxi(0, int(definition.get("output_capacity", 0)) - _dictionary_total(entity.get("outputs", {})))
	var output_per_cycle := 0
	for output_value in recipe.get("outputs", []):
		var output := output_value as Dictionary
		output_per_cycle += maxi(1, int(output.get("quantity", 1)))
	var cycles := free / maxi(1, output_per_cycle)
	if output_per_cycle == 0:
		cycles = 2147483647
	elif not entity.get("proliferator", {}).is_empty():
		# Reserve base plus bonus outputs before any ingredient is consumed.
		while cycles > 0 and _dictionary_total(DspProduction.planned_outputs(entity, recipe, cycles).get("total_outputs", {})) > free:
			cycles -= 1
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
	return Terrain.terrain_type(world, tile)


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
		# Circular reach is a placement choice, not a minimum spacing rule for
		# planetary geology. Enlarging a mine must not delete nearby authored ore
		# fields (including starter copper). Mixed circles are rejected at placement.
		if float(definition.get("mining_radius_tiles",0.0)) > EPSILON:
			continue
		if not definition.get("resource_categories", []).has(str(a.get("resource_category", "solid"))) or not definition.get("resource_categories", []).has(str(b.get("resource_category", "solid"))):
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


func _world_environment(world: Dictionary) -> Dictionary:
	var value: Variant = world.get("environment", {})
	if value is Dictionary:
		return value as Dictionary
	return {}


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


func _drone_input_targets(entity: Dictionary) -> Dictionary:
	var targets := {}
	for entry in recipe_definitions.get(str(entity.get("recipe_id", "")), {}).get("inputs", []):
		targets[str(entry.get("item", ""))] = int(entry.get("quantity", 0)) * int(rules.get("drone_input_batches", 10))
	return targets


func _resource_profile_index(definition: Dictionary, resource: Dictionary) -> int:
	var profiles: Array = definition.get("resource_profiles", [])
	var category := str(resource.get("resource_category", "solid"))
	if str(resource.get("resource_id", "")) in ["dsp_crude_oil", "dsp_water", "dsp_sulfuric_acid"]:
		category = "liquid"
	for index in range(profiles.size()):
		var profile: Dictionary = profiles[index]
		if not profile.get("resource_categories", []).has(category):
			continue
		var ids: Array = profile.get("allowed_resource_ids", [])
		if ids.is_empty() or ids.has(str(resource.get("resource_id", ""))):
			return index
	return -1

func _resource_definition(definition: Dictionary, resource: Dictionary) -> Dictionary:
	var index := _resource_profile_index(definition, resource)
	if index < 0:
		return definition
	var result := definition.duplicate(true)
	var profile: Dictionary = definition["resource_profiles"][index]
	for field in ["mining_rate_per_second", "resource_coverage_loss_per_missing_tile", "power_demand_kw"]:
		if profile.has(field):
			result[field] = profile[field]
	return result

func _resource_unlocked(world: Dictionary, definition: Dictionary, resource: Dictionary) -> bool:
	if definition.get("resource_profiles", []).is_empty():
		return true
	var index := _resource_profile_index(definition, resource)
	if index < 0:
		return false
	var profile: Dictionary = definition["resource_profiles"][index]
	if profile.get("requirements", []).is_empty() and profile.get("reveal_requirements", []).is_empty():
		return true
	return bool(world.get("resource_profile_unlocks", {}).get("%s:%d" % [definition.get("id", ""), index], false))
