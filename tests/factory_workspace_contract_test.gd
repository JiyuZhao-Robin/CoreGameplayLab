extends SceneTree

var failures: Array[String] = []
var database: ContentDatabase
var factory: FactoryGridSimulation


func _initialize() -> void:
	database = ContentDatabase.new()
	_check(database.load_from_file("res://data/content.json"), "factory workspace contract loads content: %s" % str(database.errors))
	if not failures.is_empty():
		_finish()
		return
	factory = FactoryGridSimulation.new(database.factory_buildings, database.factory_recipes, database.factory_grid_rules)
	_test_stable_presentation_snapshot()
	_test_recipe_reconfiguration_contract()
	_test_bootstrap_guidance_uses_factory_authority()
	_test_versioned_application_intents()
	_test_zero_time_machine_operational_refresh()
	_test_legacy_game_mutators_refresh_immediately()
	_test_multi_world_event_order_is_deterministic()
	_test_factory_construction_intents()
	_test_fresh_factory_bootstrap_closure()
	_test_surveyed_world_initialization()
	_test_factory_progression_adapters()
	_test_multi_stage_research_boundaries()
	_test_remote_factory_facility_maintenance_custody()
	_test_maintenance_recovery_projection()
	_test_megastructure_phase_runtime()
	_test_megastructure_factory_storage_custody()
	_test_megastructure_runtime_service_interruption()
	_test_megastructure_same_tick_maintenance_boundary()
	_finish()


func _test_stable_presentation_snapshot() -> void:
	var world := factory.create_world("snapshot-grid", "earth_orbit", Vector2i(256, 256), 77)
	factory.add_resource_field(world, "z-field", "iron_ore", Vector2i(32, 32), Vector2i(12, 12), 1.25, 0.5, "solid")
	factory.add_resource_field(world, "a-field", "iron_ore", Vector2i(64, 32), Vector2i(12, 12), 1.0, 0.25, "solid")
	factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "z-power")
	factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(34, 34), "", "a-mine")
	var connected := factory.connect_entities(world, "POWER", "z-power", "a-mine")
	_check(bool(connected.get("ok", false)), "snapshot fixture creates an explicit power edge")
	factory.advance_world(world, 1000.0)
	var snapshot := factory.workspace_snapshot(world)
	_check(int(snapshot.get("protocol_version", 0)) == 1 and int(snapshot.get("world_schema_version", 0)) == 3, "workspace publishes explicit protocol and world-schema versions")
	var fields: Array = snapshot.get("resource_fields", [])
	var entities: Array = snapshot.get("entities", [])
	_check(fields.size() == 2 and str((fields[0] as Dictionary).get("id", "")) == "a-field" and str((fields[1] as Dictionary).get("id", "")) == "z-field", "resource-field projections are stable identifier-sorted arrays")
	_check(not bool((fields[0] as Dictionary).get("is_entity", true)) and (fields[0] as Dictionary).get("ports", {}).get("outputs", []).is_empty(), "resource fields cannot masquerade as connectable factory entities")
	_check(entities.size() == 2 and str((entities[0] as Dictionary).get("id", "")) == "a-mine" and str((entities[1] as Dictionary).get("id", "")) == "z-power", "entity projections are stable identifier-sorted arrays")
	_check((entities[0] as Dictionary).get("ports", {}).get("outputs", []).has("iron_ore"), "extractor projection exposes its actual physical output port")
	_check(not (entities[0] as Dictionary).has("routing_cursor") and not snapshot.has("tile_deltas"), "workspace snapshot hides mutable engine bookkeeping")
	_check(int(snapshot.get("topology_revision", 0)) == 5 and int(snapshot.get("runtime_revision", 0)) == 1, "topology and runtime revisions advance independently")
	var building_ids: Array[String] = []
	for building_value in snapshot.get("palette", {}).get("buildings", []):
		building_ids.append(str((building_value as Dictionary).get("id", "")))
	var sorted_building_ids := building_ids.duplicate()
	sorted_building_ids.sort()
	_check(building_ids == sorted_building_ids and building_ids.has("grid_arc_smelter") and building_ids.has("grid_advanced_alloy_cell"), "construction palette is deterministic and definition-backed")


func _test_recipe_reconfiguration_contract() -> void:
	var world := factory.create_world("recipe-grid", "earth_orbit", Vector2i(256, 256), 79)
	factory.add_resource_field(world, "iron-field", "iron_ore", Vector2i(32, 32), Vector2i(24, 24), 1.0, 0.25, "solid")
	factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(34, 34), "", "mine")
	factory.place_entity_immediate(world, "grid_engineering_works", Vector2i(70, 32), "grid_refine_iron", "machine")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(100, 32), "", "depot")
	factory.connect_entities(world, "CARGO", "mine", "machine", "iron_ore")
	factory.connect_entities(world, "CARGO", "machine", "depot", "iron_ingot")
	world["entities"]["machine"]["inputs"] = {"iron_ore":3}
	world["entities"]["machine"]["outputs"] = {"iron_ingot":2}
	world["entities"]["machine"]["progress"] = 0.5
	var before_revision := int(world.get("topology_revision", 0))
	var changed := factory.set_entity_recipe(world, "machine", "grid_refine_copper")
	_check(bool(changed.get("ok", false)) and str(world["entities"]["machine"].get("recipe_id", "")) == "grid_refine_copper", "physical machine recipe can be reconfigured without rebuilding the entity")
	_check(changed.get("removed_link_ids", []).size() == 2 and world.get("links", {}).is_empty() and int(world.get("topology_revision", 0)) == before_revision + 1, "recipe reconfiguration atomically removes cargo links whose ports became incompatible")
	_check(int(world["entities"]["machine"].get("inputs", {}).get("iron_ore", 0)) == 3 and int(world["entities"]["machine"].get("outputs", {}).get("iron_ingot", 0)) == 2 and float(world["entities"]["machine"].get("progress", 1.0)) == 0.0, "recipe changes preserve buffered assets while resetting only fractional work")
	var incompatible := factory.set_entity_recipe(world, "machine", "grid_fabricate_data_core")
	_check(not bool(incompatible.get("ok", true)) and str(incompatible.get("reason_code", "")) == "INCOMPATIBLE_RECIPE", "machine reconfiguration rejects a recipe outside its physical capability")


func _test_bootstrap_guidance_uses_factory_authority() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var world_id := "earth-surface-grid"
	var world: Dictionary = game.state.factory_worlds.get(world_id, {})
	var initial: Dictionary = game.guidance_snapshot()
	_check(str(initial.get("step_id", "")) == "operate_factory_grid" and str(initial.get("section", "")) == "factory", "fresh bootstrap guidance opens the authoritative Factory workspace")
	world["statistics"]["produced"]["iron_ore"] = 1
	var first_ore: Dictionary = game.guidance_snapshot()
	_check(str(first_ore.get("step_id", "")) == "prepare_first_frame" and str(first_ore.get("section", "")) == "factory" and str(first_ore.get("focus_entity_id", "")) == "grid_assemble_frame", "first-ore guidance reads the physical Factory recipe instead of retired Production")
	world["statistics"]["produced"]["structural_frame"] = 1
	var first_frame: Dictionary = game.guidance_snapshot()
	_check(str(first_frame.get("step_id", "")) == "supply_foundry" and str(first_frame.get("section", "")) == "factory" and str(first_frame.get("focus_entity_id", "")) == "grid_arc_smelter", "first-frame guidance targets the physical Macro Arc Smelter on the Factory canvas")
	var queued: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"guidance-foundry-order",
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":world_id,
		"base_topology_revision":int(world.get("topology_revision", 0)),
		"payload":{"definition_id":"grid_arc_smelter", "recipe_id":"grid_refine_iron", "origin":{"x":300, "y":100}, "priority":50}
	})
	_check(bool(queued.get("accepted", false)), "guidance fixture queues the foundry through the public Factory command")
	var queued_guidance: Dictionary = game.guidance_snapshot()
	_check(str(queued_guidance.get("step_id", "")) == "commission_foundry" and str(queued_guidance.get("section", "")) == "factory" and str(queued_guidance.get("focus_entity_id", "")) == str(queued.get("result", {}).get("entity_id", "")), "queued-foundry guidance reads the live Factory construction order identity")
	world = game.state.factory_worlds.get(world_id, {})
	world.get("construction_orders", {}).erase(str(queued.get("result", {}).get("order_id", "")))
	factory.place_entity_immediate(world, "grid_arc_smelter", Vector2i(300, 100), "grid_refine_iron", str(queued.get("result", {}).get("entity_id", "guidance-foundry")))
	var foundry_complete: Dictionary = game.guidance_snapshot()
	_check(str(foundry_complete.get("step_id", "")) == "commission_research" and str(foundry_complete.get("section", "")) == "factory" and str(foundry_complete.get("focus_entity_id", "")) == "grid_research_complex", "completed physical foundry advances guidance to Factory-backed research providers")
	for guidance_value in [initial, first_ore, first_frame, queued_guidance, foundry_complete]:
		_check(str((guidance_value as Dictionary).get("section", "")) not in ["production", "construction", "facilities"], "bootstrap guidance never emits a retired aggregate Industry section")


func _test_versioned_application_intents() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	var world := factory.create_world("intent-grid", "earth_orbit", Vector2i(256, 256), 88)
	factory.add_resource_field(world, "iron-field", "iron_ore", Vector2i(32, 32), Vector2i(24, 24), 1.0, 0.25, "solid")
	factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "power")
	factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(34, 34), "", "mine")
	factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(90, 32), "", "depot")
	factory.place_entity_immediate(world, "grid_engineering_works", Vector2i(120, 80), "grid_refine_iron", "machine")
	game.state.factory_worlds["intent-grid"] = world
	var before: Dictionary = game.factory_workspace_snapshot("intent-grid")
	_check(bool(before.get("valid", false)) and int(before.get("protocol_version", 0)) == 1, "Game exposes the versioned read-only factory snapshot")
	_check(str(before.get("transfer_contract", {}).get("export_command", "")) == "EXPORT_TO_LOCATION" and int(before.get("location_available_inventory", {}).get("scrap_metal", 0)) == 44, "workspace snapshot exposes copied same-location transfer availability")
	var connect_intent := {
		"protocol_version":1,
		"command_id":"contract-connect-1",
		"kind":"CONNECT_ENTITIES",
		"world_id":"intent-grid",
		"base_topology_revision":int(before.get("topology_revision", -1)),
		"base_runtime_revision":int(before.get("runtime_revision", -1)),
		"payload":{"link_kind":"power", "source_id":"power", "target_id":"mine", "item_id":"bogus-item"}
	}
	var connected: Dictionary = game.execute_factory_command(connect_intent)
	_check(bool(connected.get("accepted", false)) and str(connected.get("reason_code", "x")).is_empty(), "versioned intent creates a link through the application transaction boundary")
	_check(int(connected.get("topology_revision", 0)) == int(before.get("topology_revision", 0)) + 1 and connected.get("events", []).size() == 1, "accepted command returns the committed revision and one correlated domain event")
	var connected_snapshot: Dictionary = game.factory_workspace_snapshot("intent-grid")
	var connected_mine: Dictionary = {}
	for entity_value in connected_snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == "mine":
			connected_mine = entity
			break
	_check(
		float(connected_mine.get("power_factor", 0.0)) >= 0.999
		and str(connected_mine.get("status", "")) == "RUNNING"
		and float(connected_mine.get("actual_rate", 0.0)) > 0.0
		and int(connected_mine.get("outputs", {}).get("iron_ore", 0)) == 0
		and is_zero_approx(float(connected_snapshot.get("elapsed_ms", -1.0))),
		"accepted POWER topology refresh publishes a coherent running status and rate without advancing clocks or producing cargo: %s" % str(connected_mine)
	)
	var event: Dictionary = connected.get("events", [])[0]
	_check(str(event.get("command_id", "")) == "contract-connect-1" and int(event.get("protocol_version", 0)) == 1 and str(event.get("type", "")) == "FactoryEntitiesConnected" and str(event.get("kind", "")) == "POWER" and str(event.get("item_id", "x")).is_empty(), "factory event envelope preserves command correlation, protocol version and canonical POWER semantics")
	var canonical_power_replay := connect_intent.duplicate(true)
	canonical_power_replay["payload"] = (connect_intent.get("payload", {}) as Dictionary).duplicate(true)
	canonical_power_replay["payload"].erase("item_id")
	var canonical_replayed: Dictionary = game.execute_factory_command(canonical_power_replay)
	_check(bool(canonical_replayed.get("accepted", false)) and bool(canonical_replayed.get("replayed", false)) and str(canonical_replayed.get("request_fingerprint", "")) == str(connected.get("request_fingerprint", "")) and game.state.factory_worlds["intent-grid"].get("links", {}).size() == 1, "POWER retries omit ignored cargo fields without conflicting or mutating topology twice")
	var duplicate_power: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-connect-duplicate-item",
		"kind":"CONNECT_ENTITIES",
		"world_id":"intent-grid",
		"base_topology_revision":int(connected.get("topology_revision", -1)),
		"payload":{"link_kind":"POWER", "source_id":"power", "target_id":"mine", "item_id":"bogus-item"}
	})
	_check(not bool(duplicate_power.get("accepted", true)) and str(duplicate_power.get("reason_code", "")) == "DUPLICATE_LINK" and game.state.factory_worlds["intent-grid"].get("links", {}).size() == 1 and not game.state.factory_worlds["intent-grid"].get("command_receipts", {}).has("contract-connect-duplicate-item"), "versioned POWER duplicate canonicalizes ignored item payload and leaves topology/receipt unchanged")
	var replayed: Dictionary = game.execute_factory_command(connect_intent)
	_check(bool(replayed.get("accepted", false)) and bool(replayed.get("replayed", false)), "an exact command-id retry returns its durable receipt without repeating mutation")
	var conflicting_replay := connect_intent.duplicate(true)
	conflicting_replay["payload"] = {"link_kind":"POWER", "source_id":"mine", "target_id":"power"}
	var conflict: Dictionary = game.execute_factory_command(conflicting_replay)
	_check(not bool(conflict.get("accepted", true)) and str(conflict.get("reason_code", "")) == "COMMAND_ID_CONFLICT", "same-kind command-id reuse with a different payload fails closed instead of replaying an unrelated receipt")
	var stale_intent := connect_intent.duplicate(true)
	stale_intent["command_id"] = "contract-connect-stale"
	var stale: Dictionary = game.execute_factory_command(stale_intent)
	_check(not bool(stale.get("accepted", true)) and str(stale.get("reason_code", "")) == "STALE_TOPOLOGY", "a new stale layout intent is rejected before mutation")
	_check(game.state.factory_worlds["intent-grid"].get("links", {}).size() == 1, "replay and stale rejection leave authoritative topology unchanged")
	var refreshed: Dictionary = game.factory_workspace_snapshot("intent-grid")
	var link_id := str((refreshed.get("links", [])[0] as Dictionary).get("id", ""))
	var remove_intent := {
		"protocol_version":1,
		"command_id":"contract-remove-1",
		"kind":"REMOVE_LINK",
		"world_id":"intent-grid",
		"base_topology_revision":int(refreshed.get("topology_revision", -1)),
		"payload":{"link_id":link_id}
	}
	var removed: Dictionary = game.execute_factory_command(remove_intent)
	_check(bool(removed.get("accepted", false)) and game.state.factory_worlds["intent-grid"].get("links", {}).is_empty(), "remove-link intent commits through the same transaction boundary")
	var disconnected_snapshot: Dictionary = game.factory_workspace_snapshot("intent-grid")
	var disconnected_mine: Dictionary = {}
	for entity_value in disconnected_snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == "mine":
			disconnected_mine = entity
			break
	_check(
		is_zero_approx(float(disconnected_mine.get("power_factor", 1.0)))
		and str(disconnected_mine.get("status", "")) == "NO_POWER"
		and str(disconnected_mine.get("blocker_code", "")) == "NO_POWER"
		and is_zero_approx(float(disconnected_mine.get("actual_rate", 1.0)))
		and is_zero_approx(float(disconnected_snapshot.get("elapsed_ms", -1.0))),
		"accepted POWER removal immediately republishes the matching zero-rate NO_POWER blocker without advancing time: %s" % str(disconnected_mine)
	)
	var invalid_power_edges := [
		{"command_id":"contract-power-reverse", "source_id":"mine", "target_id":"power"},
		{"command_id":"contract-power-consumers", "source_id":"mine", "target_id":"machine"},
		{"command_id":"contract-power-no-target-port", "source_id":"power", "target_id":"depot"}
	]
	for invalid_edge_value in invalid_power_edges:
		var invalid_edge := invalid_edge_value as Dictionary
		var invalid_power_result: Dictionary = game.execute_factory_command({
			"protocol_version":1,
			"command_id":invalid_edge.get("command_id", ""),
			"kind":"CONNECT_ENTITIES",
			"world_id":"intent-grid",
			"base_topology_revision":int(removed.get("topology_revision", -1)),
			"payload":{"link_kind":"POWER", "source_id":invalid_edge.get("source_id", ""), "target_id":invalid_edge.get("target_id", "")}
		})
		_check(not bool(invalid_power_result.get("accepted", true)) and str(invalid_power_result.get("reason_code", "")) == "INVALID_LINK", "versioned Factory intent rejects incompatible power edge %s" % invalid_edge.get("command_id", ""))
	_check(
		game.state.factory_worlds["intent-grid"].get("links", {}).is_empty()
		and invalid_power_edges.all(func(edge): return not game.state.factory_worlds["intent-grid"].get("command_receipts", {}).has(str((edge as Dictionary).get("command_id", "")))),
		"rejected power edges leave topology and durable receipts unchanged"
	)
	var recipe_changed: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-set-recipe-1",
		"kind":"SET_RECIPE",
		"world_id":"intent-grid",
		"base_topology_revision":int(removed.get("topology_revision", -1)),
		"payload":{"entity_id":"machine", "recipe_id":"grid_refine_copper"}
	})
	_check(bool(recipe_changed.get("accepted", false)) and str(recipe_changed.get("events", [])[0].get("type", "")) == "FactoryRecipeChanged" and str(game.state.factory_worlds["intent-grid"].get("entities", {}).get("machine", {}).get("recipe_id", "")) == "grid_refine_copper", "versioned SET_RECIPE changes one completed machine through the application transaction boundary")
	var invalid_machine: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-set-recipe-invalid",
		"kind":"SET_RECIPE",
		"world_id":"intent-grid",
		"base_topology_revision":int(recipe_changed.get("topology_revision", -1)),
		"payload":{"entity_id":"power", "recipe_id":"grid_refine_iron"}
	})
	_check(not bool(invalid_machine.get("accepted", true)) and str(invalid_machine.get("reason_code", "")) == "INVALID_MACHINE", "SET_RECIPE fails closed for a non-machine entity")
	var transfer_topology := int(recipe_changed.get("topology_revision", -1))
	var total_scrap_before: int = int(game.state.item_quantity("scrap_metal", "earth_orbit")) + int(game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {}).get("scrap_metal", 0))
	var imported: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-import-1",
		"kind":"IMPORT_FROM_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":4}
	})
	_check(bool(imported.get("accepted", false)) and int(imported.get("result", {}).get("moved", 0)) == 4, "same-location import moves unreserved Location inventory into Factory storage")
	var exported: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-export-1",
		"kind":"EXPORT_TO_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":3}
	})
	_check(bool(exported.get("accepted", false)) and int(exported.get("result", {}).get("moved", 0)) == 3, "same-location export moves Factory storage cargo into Location inventory")
	var total_scrap_after: int = int(game.state.item_quantity("scrap_metal", "earth_orbit")) + int(game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {}).get("scrap_metal", 0))
	_check(total_scrap_after == total_scrap_before and int(exported.get("topology_revision", -1)) == transfer_topology, "atomic Factory boundary transfers conserve assets without changing topology")
	var transfer_replay: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-export-1",
		"kind":"EXPORT_TO_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":3}
	})
	_check(bool(transfer_replay.get("replayed", false)) and game.state.item_quantity("scrap_metal", "earth_orbit") + int(game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {}).get("scrap_metal", 0)) == total_scrap_before, "replayed transfer receipt cannot duplicate assets")
	for index in 130:
		var kind := "IMPORT_FROM_LOCATION" if index % 2 == 0 else "EXPORT_TO_LOCATION"
		var window_result: Dictionary = game.execute_factory_command({
			"protocol_version":1,
			"command_id":"contract-window-%03d" % index,
			"kind":kind,
			"world_id":"intent-grid",
			"base_topology_revision":transfer_topology,
			"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":1}
		})
		_check(bool(window_result.get("accepted", false)), "receipt retention window accepts transfer %03d" % index)
	var location_before_old_replay: int = int(game.state.item_quantity("scrap_metal", "earth_orbit"))
	var depot_before_old_replay: int = int(game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {}).get("scrap_metal", 0))
	var old_transfer_replay: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-import-1",
		"kind":"IMPORT_FROM_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":4}
	})
	_check(
		bool(old_transfer_replay.get("replayed", false))
		and game.state.item_quantity("scrap_metal", "earth_orbit") == location_before_old_replay
		and int(game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {}).get("scrap_metal", 0)) == depot_before_old_replay,
		"durable receipts prevent semantic replay after more than 128 later commands"
	)
	var serialized_state: Dictionary = game.state.to_dictionary()
	game.state = SpaceGameState.from_dictionary(serialized_state, database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var restored_location_before: int = int(game.state.item_quantity("scrap_metal", "earth_orbit"))
	var restored_depot_before: int = int(game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {}).get("scrap_metal", 0))
	var persisted_replay: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-import-1",
		"kind":"IMPORT_FROM_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":4}
	})
	_check(
		bool(persisted_replay.get("accepted", false)) and bool(persisted_replay.get("replayed", false))
		and int(game.state.item_quantity("scrap_metal", "earth_orbit")) == restored_location_before
		and int(game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {}).get("scrap_metal", 0)) == restored_depot_before,
		"accepted Factory receipts survive state serialization and prevent asset duplication after reload"
	)
	var persisted_receipt: Dictionary = game.state.factory_worlds["intent-grid"].get("command_receipts", {}).get("contract-import-1", {})
	_check(not persisted_receipt.has("message") and str(persisted_receipt.get("message_key", "")) == "factory.success.import_from_location", "durable Factory receipts persist a locale-neutral message key instead of translated presentation text")
	var localization: Variant = get_root().get_node("I18n")
	localization.call("_load_translations")
	var original_locale := str(localization.current_locale)
	localization.current_locale = "zh_CN"
	var localized_replay: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-import-1",
		"kind":"IMPORT_FROM_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":4}
	})
	localization.current_locale = original_locale
	_check(bool(localized_replay.get("replayed", false)) and str(localized_replay.get("message", "")) == "货物已转入工厂仓储。" and not game.state.factory_worlds["intent-grid"].get("command_receipts", {}).get("contract-import-1", {}).has("message"), "replayed Factory feedback resolves in the current locale without mutating durable state: %s" % str(localized_replay.get("message", "")))
	var persisted_conflict: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-import-1",
		"kind":"IMPORT_FROM_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":3}
	})
	_check(not bool(persisted_conflict.get("accepted", true)) and str(persisted_conflict.get("reason_code", "")) == "COMMAND_ID_CONFLICT", "persisted receipts retain their request fingerprint and reject conflicting reuse after reload")
	var unsupported: Dictionary = game.execute_factory_command({"protocol_version":99, "command_id":"bad-version", "kind":"REMOVE_LINK", "world_id":"intent-grid", "base_topology_revision":0, "payload":{}})
	_check(not bool(unsupported.get("accepted", true)) and str(unsupported.get("reason_code", "")) == "UNSUPPORTED_PROTOCOL", "unsupported workspace protocols fail closed")
	var missing_id: Dictionary = game.execute_factory_command({"protocol_version":1, "kind":"REMOVE_LINK", "world_id":"intent-grid", "base_topology_revision":transfer_topology, "payload":{}})
	_check(not bool(missing_id.get("accepted", true)) and str(missing_id.get("reason_code", "")) == "MISSING_COMMAND_ID", "Factory command envelope rejects missing durable command IDs")
	var invalid_payload: Dictionary = game.execute_factory_command({"protocol_version":1, "command_id":"bad-payload", "kind":"REMOVE_LINK", "world_id":"intent-grid", "base_topology_revision":transfer_topology, "payload":[]})
	_check(not bool(invalid_payload.get("accepted", true)) and str(invalid_payload.get("reason_code", "")) == "INVALID_PAYLOAD", "Factory command envelope rejects non-object payloads")
	var state_before_invalid_shapes: Dictionary = game.state.to_dictionary()
	var invalid_shape_intents := [
		{"protocol_version":1, "command_id":"bad-origin-shape", "kind":"QUEUE_CONSTRUCTION", "world_id":"intent-grid", "base_topology_revision":transfer_topology, "payload":{"definition_id":"grid_solar_array", "origin":"bad"}},
		{"protocol_version":1, "command_id":"bad-coordinate-shape", "kind":"QUEUE_CONSTRUCTION", "world_id":"intent-grid", "base_topology_revision":transfer_topology, "payload":{"definition_id":"grid_solar_array", "origin":{"x":{}, "y":1}}},
		{"protocol_version":1, "command_id":"bad-priority-shape", "kind":"QUEUE_CONSTRUCTION", "world_id":"intent-grid", "base_topology_revision":transfer_topology, "payload":{"definition_id":"grid_solar_array", "origin":{"x":1, "y":1}, "priority":{}}},
		{"protocol_version":1, "command_id":"bad-capacity-shape", "kind":"CONNECT_ENTITIES", "world_id":"intent-grid", "base_topology_revision":transfer_topology, "payload":{"link_kind":"POWER", "source_id":"power", "target_id":"mine", "capacity_per_second":{}}},
		{"protocol_version":1, "command_id":"bad-quantity-shape", "kind":"IMPORT_FROM_LOCATION", "world_id":"intent-grid", "base_topology_revision":transfer_topology, "payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":{}}}
	]
	for invalid_shape_intent_value in invalid_shape_intents:
		var invalid_shape_intent := invalid_shape_intent_value as Dictionary
		var invalid_shape_result: Dictionary = game.execute_factory_command(invalid_shape_intent)
		_check(not bool(invalid_shape_result.get("accepted", true)) and str(invalid_shape_result.get("reason_code", "")) == "INVALID_PAYLOAD", "Factory command envelope rejects malformed nested payload %s" % invalid_shape_intent.get("command_id", ""))
	_check(game.state.to_dictionary() == state_before_invalid_shapes, "malformed nested Factory payloads leave authoritative state, topology and receipts unchanged")
	var location_scrap_available: int = int(game.state.available_item_quantity("scrap_metal", "earth_orbit"))
	var state_before_short_import: Dictionary = game.state.to_dictionary()
	var short_import: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-import-short-source",
		"kind":"IMPORT_FROM_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":location_scrap_available + 1}
	})
	_check(not bool(short_import.get("accepted", true)) and str(short_import.get("reason_code", "")) == "LOCATION_INVENTORY_EMPTY", "Factory import rejects the whole request when same-location unreserved inventory is only partially sufficient")
	_check(game.state.to_dictionary() == state_before_short_import and not game.state.factory_worlds["intent-grid"].get("command_receipts", {}).has("contract-import-short-source"), "source-limited import rejection leaves both custody domains and durable receipts unchanged")
	var depot_scrap_on_hand := int(game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {}).get("scrap_metal", 0))
	var state_before_short_export: Dictionary = game.state.to_dictionary()
	var short_export: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-export-short-source",
		"kind":"EXPORT_TO_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":depot_scrap_on_hand + 1}
	})
	_check(not bool(short_export.get("accepted", true)) and str(short_export.get("reason_code", "")) == "STORAGE_EMPTY", "Factory export rejects the whole request when Factory storage holds only a partial quantity")
	_check(game.state.to_dictionary() == state_before_short_export and not game.state.factory_worlds["intent-grid"].get("command_receipts", {}).has("contract-export-short-source"), "source-limited export rejection leaves both custody domains and durable receipts unchanged")
	var depot_inventory: Dictionary = game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {})
	var depot_inventory_before_capacity_test: Dictionary = depot_inventory.duplicate(true)
	var depot_non_iron_total := 0
	for item_id_value in depot_inventory.keys():
		if str(item_id_value) != "iron_ore":
			depot_non_iron_total += int(depot_inventory.get(item_id_value, 0))
	depot_inventory["iron_ore"] = maxi(0, 999 - depot_non_iron_total)
	var state_before_partial_factory_capacity: Dictionary = game.state.to_dictionary()
	var partial_factory_capacity: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-import-partial-destination",
		"kind":"IMPORT_FROM_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":2}
	})
	_check(not bool(partial_factory_capacity.get("accepted", true)) and str(partial_factory_capacity.get("reason_code", "")) == "STORAGE_FULL", "Factory import rejects the whole request when destination storage can accept only part of it")
	_check(game.state.to_dictionary() == state_before_partial_factory_capacity and not game.state.factory_worlds["intent-grid"].get("command_receipts", {}).has("contract-import-partial-destination"), "capacity-limited import rejection leaves Location, Factory and durable receipts unchanged")
	game.state.factory_worlds["intent-grid"]["entities"]["depot"]["inventory"] = depot_inventory_before_capacity_test
	var earth_storage: Dictionary = game.state.location_state("earth_orbit").get("logistics", {}).get("storage_capacities", {})
	var bulk_used := float(game.simulation.location_storage_snapshot(game.state, "earth_orbit").get("classes", {}).get("BULK", {}).get("used", 0.0))
	var export_depot_inventory: Dictionary = game.state.factory_worlds["intent-grid"].get("entities", {}).get("depot", {}).get("inventory", {})
	var export_depot_inventory_before_capacity_test: Dictionary = export_depot_inventory.duplicate(true)
	export_depot_inventory["scrap_metal"] = maxi(2, int(export_depot_inventory.get("scrap_metal", 0)))
	earth_storage["BULK"] = bulk_used + 1.0
	var state_before_partial_export: Dictionary = game.state.to_dictionary()
	var partial_export: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-export-partial-destination",
		"kind":"EXPORT_TO_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":2}
	})
	_check(not bool(partial_export.get("accepted", true)) and str(partial_export.get("reason_code", "")) == "STORAGE_FULL", "Factory export rejects the whole request when Location storage can accept only part of it")
	_check(game.state.to_dictionary() == state_before_partial_export and not game.state.factory_worlds["intent-grid"].get("command_receipts", {}).has("contract-export-partial-destination"), "capacity-limited export rejection rolls back Factory withdrawal and leaves durable receipts unchanged")
	game.state.factory_worlds["intent-grid"]["entities"]["depot"]["inventory"] = export_depot_inventory_before_capacity_test
	earth_storage["BULK"] = bulk_used
	var state_before_full_export: Dictionary = game.state.to_dictionary()
	var full_export: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-export-full-destination",
		"kind":"EXPORT_TO_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":1}
	})
	_check(not bool(full_export.get("accepted", true)) and str(full_export.get("reason_code", "")) == "STORAGE_FULL", "Factory export fails closed when same-location destination storage cannot accept the full requested quantity")
	_check(game.state.to_dictionary() == state_before_full_export and not game.state.factory_worlds["intent-grid"].get("command_receipts", {}).has("contract-export-full-destination"), "rejected full-destination export leaves Factory cargo, Location inventory, topology and durable receipts unchanged")
	earth_storage["BULK"] = bulk_used + 1.0
	game.state.logistics_network["shipments"].append({"id":"SHIPMENT-CAPACITY-RESERVATION", "origin":"lunar_space", "destination":"earth_orbit", "cargo":{"scrap_metal":1}, "remaining_ms":100000.0})
	var state_before_reserved_export: Dictionary = game.state.to_dictionary()
	var reserved_export: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-export-reserved-destination",
		"kind":"EXPORT_TO_LOCATION",
		"world_id":"intent-grid",
		"base_topology_revision":transfer_topology,
		"payload":{"storage_id":"depot", "item_id":"scrap_metal", "quantity":1}
	})
	_check(not bool(reserved_export.get("accepted", true)) and str(reserved_export.get("reason_code", "")) == "STORAGE_FULL", "Factory export respects destination capacity already reserved by inbound Logistics cargo")
	_check(game.state.to_dictionary() == state_before_reserved_export and not game.state.factory_worlds["intent-grid"].get("command_receipts", {}).has("contract-export-reserved-destination"), "inbound-capacity export rejection leaves Factory cargo, Location inventory, Shipment and durable receipts unchanged")
	var unknown_world: Dictionary = game.execute_factory_command({"protocol_version":1, "command_id":"bad-world", "kind":"REMOVE_LINK", "world_id":"missing-world", "base_topology_revision":0, "payload":{"link_id":"missing"}})
	_check(not bool(unknown_world.get("accepted", true)) and str(unknown_world.get("reason_code", "")) == "UNKNOWN_FACTORY_WORLD", "Factory command envelope rejects unknown authoritative worlds")


func _test_zero_time_machine_operational_refresh() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	var world := factory.create_world("zero-time-machine-grid", "earth_orbit", Vector2i(160, 160), 89)
	_check(bool(factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "power").get("ok", false)), "zero-time machine fixture places physical generation")
	_check(bool(factory.place_entity_immediate(world, "grid_engineering_works", Vector2i(30, 30), "grid_refine_iron", "machine").get("ok", false)), "zero-time machine fixture places its physical production device")
	_check(bool(factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(70, 30), "", "depot").get("ok", false)), "zero-time machine fixture places physical output custody")
	var cargo_result: Dictionary = factory.connect_entities(world, "CARGO", "machine", "depot", "iron_ingot", 2.0)
	_check(bool(cargo_result.get("ok", false)), "zero-time machine fixture creates an existing cargo edge")
	world["entities"]["machine"]["inputs"] = {"iron_ore":2}
	world["entities"]["machine"]["outputs"] = {"iron_ingot":1}
	world["entities"]["machine"]["progress"] = 0.375
	world["entities"]["depot"]["inventory"] = {"scrap_metal":3}
	world["statistics"]["produced"]["sentinel"] = 7
	var cargo_id := str(cargo_result.get("link_id", ""))
	world["links"][cargo_id]["capacity_progress"] = 1.625
	world["links"][cargo_id]["last_flow"] = 0.75
	game.state.factory_worlds["zero-time-machine-grid"] = world
	var before_runtime := {
		"elapsed_ms":world.get("elapsed_ms", 0.0),
		"progress":world["entities"]["machine"].get("progress", 0.0),
		"inputs":world["entities"]["machine"].get("inputs", {}).duplicate(true),
		"outputs":world["entities"]["machine"].get("outputs", {}).duplicate(true),
		"depot_inventory":world["entities"]["depot"].get("inventory", {}).duplicate(true),
		"statistics":world.get("statistics", {}).duplicate(true),
		"capacity_progress":world["links"][cargo_id].get("capacity_progress", 0.0),
		"last_flow":world["links"][cargo_id].get("last_flow", 0.0),
		"runtime_revision":world.get("runtime_revision", 0)
	}
	var before_snapshot: Dictionary = game.factory_workspace_snapshot("zero-time-machine-grid")
	var connected: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"zero-time-machine-power",
		"kind":"CONNECT_ENTITIES",
		"world_id":"zero-time-machine-grid",
		"base_topology_revision":int(before_snapshot.get("topology_revision", -1)),
		"base_runtime_revision":int(before_snapshot.get("runtime_revision", -1)),
		"payload":{"link_kind":"POWER", "source_id":"power", "target_id":"machine"}
	})
	_check(bool(connected.get("accepted", false)), "zero-time machine fixture connects power through the application transaction boundary")
	var committed_world: Dictionary = game.state.factory_worlds.get("zero-time-machine-grid", {})
	var after_snapshot: Dictionary = game.factory_workspace_snapshot("zero-time-machine-grid")
	var machine_snapshot: Dictionary = {}
	for entity_value in after_snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == "machine":
			machine_snapshot = entity
			break
	_check(
		str(machine_snapshot.get("status", "")) == "RUNNING"
		and str(machine_snapshot.get("blocker_code", "x")).is_empty()
		and is_equal_approx(float(machine_snapshot.get("actual_rate", 0.0)), 0.5)
		and float(machine_snapshot.get("power_factor", 0.0)) >= 0.999,
		"accepted POWER topology refresh publishes a coherent runnable Machine snapshot: %s" % str(machine_snapshot)
	)
	var after_runtime := {
		"elapsed_ms":committed_world.get("elapsed_ms", 0.0),
		"progress":committed_world.get("entities", {}).get("machine", {}).get("progress", 0.0),
		"inputs":committed_world.get("entities", {}).get("machine", {}).get("inputs", {}).duplicate(true),
		"outputs":committed_world.get("entities", {}).get("machine", {}).get("outputs", {}).duplicate(true),
		"depot_inventory":committed_world.get("entities", {}).get("depot", {}).get("inventory", {}).duplicate(true),
		"statistics":committed_world.get("statistics", {}).duplicate(true),
		"capacity_progress":committed_world.get("links", {}).get(cargo_id, {}).get("capacity_progress", 0.0),
		"last_flow":committed_world.get("links", {}).get(cargo_id, {}).get("last_flow", 0.0),
		"runtime_revision":committed_world.get("runtime_revision", 0)
	}
	_check(after_runtime == before_runtime, "zero-time operational refresh preserves clocks, progress, buffers, inventory, statistics, cargo flow state and runtime revision")


func _test_legacy_game_mutators_refresh_immediately() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	var world := factory.create_world("legacy-refresh-grid", "earth_orbit", Vector2i(160, 160), 91)
	_check(bool(factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "power").get("ok", false)), "legacy refresh fixture places physical generation")
	_check(bool(factory.add_resource_field(world, "iron-field", "iron_ore", Vector2i(32, 32), Vector2i(24, 24), 1.0, 0.25, "solid").get("ok", false)), "legacy refresh fixture temporarily provides a legal extractor placement field")
	_check(bool(factory.place_entity_immediate(world, "grid_surface_mine", Vector2i(34, 34), "", "mine").get("ok", false)), "legacy refresh fixture places an extractor before registering its field")
	world.get("resource_fields", {}).erase("iron-field")
	game.state.factory_worlds["legacy-refresh-grid"] = world
	var elapsed_before := float(world.get("elapsed_ms", -1.0))
	var runtime_revision_before := int(world.get("runtime_revision", -1))
	_check(game.connect_factory_entities("legacy-refresh-grid", "POWER", "power", "mine"), "legacy public Game API accepts a physical power edge")
	var powered_snapshot: Dictionary = game.factory_workspace_snapshot("legacy-refresh-grid")
	var powered_mine := _workspace_entity(powered_snapshot, "mine")
	_check(
		float(powered_mine.get("power_factor", 0.0)) >= 0.999
		and str(powered_mine.get("status", "")) == "NO_RESOURCE"
		and str(powered_mine.get("blocker_code", "")) == "NO_RESOURCE"
		and is_zero_approx(float(powered_mine.get("actual_rate", -1.0))),
		"legacy public power connection immediately publishes coherent zero-time service and blocker state"
	)
	_check(game.register_factory_resource_field("legacy-refresh-grid", "iron-field", "iron_ore", Vector2i(32, 32), Vector2i(24, 24), 1.0, 0.25, "solid"), "legacy public Game API registers an overlapping physical resource field")
	var field_snapshot: Dictionary = game.factory_workspace_snapshot("legacy-refresh-grid")
	var runnable_mine := _workspace_entity(field_snapshot, "mine")
	_check(
		str(runnable_mine.get("status", "")) == "RUNNING"
		and str(runnable_mine.get("blocker_code", "x")).is_empty()
		and float(runnable_mine.get("power_factor", 0.0)) >= 0.999
		and float(runnable_mine.get("actual_rate", 0.0)) > 0.0,
		"legacy public resource-field registration immediately publishes a coherent runnable extractor snapshot"
	)
	var committed_world: Dictionary = game.state.factory_worlds.get("legacy-refresh-grid", {})
	_check(
		is_equal_approx(float(committed_world.get("elapsed_ms", -2.0)), elapsed_before)
		and int(committed_world.get("runtime_revision", -2)) == runtime_revision_before
		and int(committed_world.get("entities", {}).get("mine", {}).get("outputs", {}).get("iron_ore", 0)) == 0,
		"legacy public zero-time refresh does not advance clocks, runtime revision, or extraction output; before_elapsed=%s before_runtime=%d world=%s" % [str(elapsed_before), runtime_revision_before, JSON.stringify(committed_world)]
	)


func _test_multi_world_event_order_is_deterministic() -> void:
	var forward := _run_multi_world_completion_order(["alpha-grid", "zeta-grid"])
	var reverse := _run_multi_world_completion_order(["zeta-grid", "alpha-grid"])
	_check(
		forward.get("events", []) == reverse.get("events", [])
		and forward.get("events", []) == ["alpha-grid:alpha-grid-machine:grid_refine_iron", "zeta-grid:zeta-grid-machine:grid_refine_iron"],
		"simultaneous Factory completions publish in stable world-id order independent of save insertion history"
	)
	var state_difference := _first_value_difference(forward.get("state", {}), reverse.get("state", {}), "state")
	_check(state_difference.is_empty(), "multi-world insertion order produces the same authoritative state after an equal deterministic advance%s" % ([""] if state_difference.is_empty() else [": %s" % state_difference]))


func _run_multi_world_completion_order(world_ids: Array) -> Dictionary:
	var simulation := SimulationEngine.new(database)
	var state := SpaceGameState.create_new(database.domains.keys(), database.regions)
	state.save_id = "deterministic-multi-world"
	state.device_id = "deterministic-device"
	state.saved_at_ms = 0
	for world_id_value in world_ids:
		var world_id := str(world_id_value)
		var world := factory.create_world(world_id, "earth_orbit", Vector2i(256, 256), 99)
		var power_id := "%s-power" % world_id
		var machine_id := "%s-machine" % world_id
		factory.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", power_id)
		factory.place_entity_immediate(world, "grid_engineering_works", Vector2i(40, 40), "grid_refine_iron", machine_id)
		factory.connect_entities(world, "POWER", power_id, machine_id)
		world["entities"][machine_id]["inputs"] = {"iron_ore":2}
		state.factory_worlds[world_id] = world
	var report: Dictionary = simulation.advance(state, 2000.0)
	var event_fingerprints: Array[String] = []
	for event_value in report.get("events", []):
		var event := event_value as Dictionary
		if str(event.get("type", "")) == "FactoryRecipeCompleted":
			event_fingerprints.append("%s:%s:%s" % [event.get("world_id", ""), event.get("entity_id", ""), event.get("recipe_id", "")])
	return {"events":event_fingerprints, "state":state.to_dictionary()}


func _test_surveyed_world_initialization() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	_check(not game.initialize_surveyed_factory_world("lunar_space"), "an unsurveyed remote Location cannot create a factory grid")
	game.state.location_state("lunar_space")["survey_state"] = LocationState.SURVEYED
	game.state.region_states["lunar_space"]["survey_state"] = LocationState.SURVEYED
	game.simulation.ensure_frontier_state(game.state)
	_check(not bool(game.state.location_state("lunar_space").get("survey_staging_installed", false)), "survey knowledge alone does not grant a free deployment package")
	game.state.completed_activities["route:lunar_route"] = 1
	game.simulation.ensure_frontier_state(game.state)
	var staging: Dictionary = game.state.location_state("lunar_space")
	_check(
		bool(staging.get("survey_staging_installed", false))
		and float(staging.get("logistics", {}).get("storage_capacities", {}).get("BULK", 0.0)) == 20.0
		and float(staging.get("construction", {}).get("capacity", 0.0)) == 1.0,
		"the explicit Lunar founding route installs finite receiving and construction staging without granting industrial production"
	)
	game.simulation.ensure_frontier_state(game.state)
	_check(float(game.state.location_state("lunar_space").get("construction", {}).get("capacity", 0.0)) == 1.0, "Survey staging is reprojected idempotently after derived Location summaries are reset")
	var restored_state := SpaceGameState.from_dictionary(game.state.to_dictionary(), database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(restored_state)
	_check(
		bool(restored_state.location_state("lunar_space").get("survey_staging_installed", false))
		and float(restored_state.location_state("lunar_space").get("logistics", {}).get("storage_capacities", {}).get("BULK", 0.0)) == 20.0
		and float(restored_state.location_state("lunar_space").get("construction", {}).get("capacity", 0.0)) == 1.0,
		"Survey staging survives save/load normalization without stacking capacity"
	)
	var paid_site: Dictionary = game.state.location_state("asteroid_belt")
	paid_site["survey_state"] = LocationState.SURVEYED
	game.state.region_states["asteroid_belt"]["survey_state"] = LocationState.SURVEYED
	paid_site["survey_staging_installed"] = true
	game.simulation.ensure_frontier_state(game.state)
	var paid_restored := SpaceGameState.from_dictionary(game.state.to_dictionary(), database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(paid_restored)
	_check(
		bool(paid_restored.location_state("asteroid_belt").get("survey_staging_installed", false))
		and float(paid_restored.location_state("asteroid_belt").get("industry", {}).get("structural_capacity", 0.0)) == 5.0
		and float(paid_restored.location_state("asteroid_belt").get("construction", {}).get("capacity", 0.0)) == 1.0,
		"non-route Survey Mission staging marker survives save/load and reprojects finite site capacity"
	)
	_check(game.initialize_surveyed_factory_world("lunar_space"), "a surveyed remote Location can initialize its one canonical sparse factory grid")
	var world_ids: Array[String] = game.factory_world_ids_for_location("lunar_space")
	var world: Dictionary = game.state.factory_worlds.get(world_ids[0] if not world_ids.is_empty() else "", {})
	var revealed_resources: Array[String] = []
	for field_value in world.get("resource_fields", {}).values():
		revealed_resources.append(str((field_value as Dictionary).get("resource_id", "")))
	revealed_resources.sort()
	_check(world_ids.size() == 1 and revealed_resources == ["helium_3", "iron_ore", "rare_earth_concentrate", "thorium_ore", "titanium_ore", "water_ice"], "remote world deterministically projects every surveyed resource region without free buildings")
	_check(world.get("entities", {}).is_empty() and not game.initialize_surveyed_factory_world("lunar_space"), "remote factory bootstrap grants knowledge only and prevents duplicate worlds")


func _test_factory_construction_intents() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	var world := factory.create_world("construction-intent-grid", "earth_orbit", Vector2i(256, 256), 99)
	_check(bool(factory.place_entity_immediate(world, "grid_bulk_depot", Vector2i(80, 32), "", "funding-depot").get("ok", false)), "construction intent fixture places Factory storage")
	world["entities"]["funding-depot"]["inventory"] = {"scrap_metal":2}
	game.state.factory_worlds["construction-intent-grid"] = world
	var snapshot: Dictionary = game.factory_workspace_snapshot("construction-intent-grid")
	var queued_from_location: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-queue-location",
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":"construction-intent-grid",
		"base_topology_revision":int(snapshot.get("topology_revision", -1)),
		"payload":{"definition_id":"grid_solar_array", "recipe_id":"", "origin":{"x":0, "y":0}, "priority":50}
	})
	var location_order_id := str(queued_from_location.get("result", {}).get("order_id", ""))
	_check(bool(queued_from_location.get("accepted", false)) and not location_order_id.is_empty(), "queue-construction intent creates a material-backed physical order")
	var scrap_before_location: int = game.state.item_quantity("scrap_metal", "earth_orbit")
	var funded_from_location: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-fund-location",
		"kind":"FUND_CONSTRUCTION_FROM_LOCATION",
		"world_id":"construction-intent-grid",
		"base_topology_revision":int(queued_from_location.get("topology_revision", -1)),
		"payload":{"order_id":location_order_id}
	})
	var location_order: Dictionary = game.state.factory_worlds["construction-intent-grid"].get("construction_orders", {}).get(location_order_id, {})
	_check(bool(funded_from_location.get("accepted", false)) and str(location_order.get("status", "")) == "READY" and game.state.item_quantity("scrap_metal", "earth_orbit") == scrap_before_location - 2, "same-location funding intent atomically consumes the exact construction BOM")

	var queued_from_storage: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-queue-storage",
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":"construction-intent-grid",
		"base_topology_revision":int(funded_from_location.get("topology_revision", -1)),
		"payload":{"definition_id":"grid_solar_array", "recipe_id":"", "origin":{"x":20, "y":0}, "priority":50}
	})
	var storage_order_id := str(queued_from_storage.get("result", {}).get("order_id", ""))
	var funded_from_storage: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-fund-storage",
		"kind":"FUND_CONSTRUCTION",
		"world_id":"construction-intent-grid",
		"base_topology_revision":int(queued_from_storage.get("topology_revision", -1)),
		"payload":{"order_id":storage_order_id, "storage_id":"funding-depot"}
	})
	var storage_world: Dictionary = game.state.factory_worlds["construction-intent-grid"]
	var storage_order: Dictionary = storage_world.get("construction_orders", {}).get(storage_order_id, {})
	var depot_scrap := int(storage_world.get("entities", {}).get("funding-depot", {}).get("inventory", {}).get("scrap_metal", 0))
	_check(bool(funded_from_storage.get("accepted", false)) and str(storage_order.get("status", "")) == "READY" and depot_scrap == 0, "Factory-storage funding intent conserves assets and makes the order build-ready")
	var empty_funding: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-fund-empty",
		"kind":"FUND_CONSTRUCTION",
		"world_id":"construction-intent-grid",
		"base_topology_revision":int(funded_from_storage.get("topology_revision", -1)),
		"payload":{"order_id":storage_order_id, "storage_id":"funding-depot"}
	})
	_check(not bool(empty_funding.get("accepted", true)) and str(empty_funding.get("reason_code", "")) == "INPUT_SHORTAGE", "a zero-material funding attempt is rejected without a success receipt or event")
	var missing_order: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"contract-fund-missing",
		"kind":"FUND_CONSTRUCTION",
		"world_id":"construction-intent-grid",
		"base_topology_revision":int(funded_from_storage.get("topology_revision", -1)),
		"payload":{"order_id":"missing-order", "storage_id":"funding-depot"}
	})
	_check(not bool(missing_order.get("accepted", true)) and str(missing_order.get("reason_code", "")) == "INVALID_CONSTRUCTION_ORDER", "construction funding rejection is structured and leaves inventory unchanged")


func _test_fresh_factory_bootstrap_closure() -> void:
	var game: Variant = get_root().get_node("Game")
	var published_event_types: Array[String] = []
	var capture_event := func(event: Dictionary) -> void: published_event_types.append(str(event.get("type", "")))
	game.domain_event.connect(capture_event)
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var world_id := "earth-surface-grid"
	var plans := [
		{"definition_id":"grid_solar_array", "recipe_id":"", "origin":{"x":0, "y":0}, "label":"power"},
		{"definition_id":"grid_surface_mine", "recipe_id":"", "origin":{"x":32, "y":32}, "label":"iron_mine"},
		{"definition_id":"grid_surface_mine", "recipe_id":"", "origin":{"x":72, "y":32}, "label":"copper_mine"},
		{"definition_id":"grid_engineering_works", "recipe_id":"grid_refine_iron", "origin":{"x":0, "y":100}, "label":"iron_refinery"},
		{"definition_id":"grid_engineering_works", "recipe_id":"grid_refine_copper", "origin":{"x":20, "y":100}, "label":"copper_refinery"},
		{"definition_id":"grid_engineering_works", "recipe_id":"grid_fabricate_electronics", "origin":{"x":40, "y":100}, "label":"electronics"},
		{"definition_id":"grid_engineering_works", "recipe_id":"grid_assemble_frame", "origin":{"x":60, "y":100}, "label":"frames"}
	]
	var entity_ids := {}
	for plan_value in plans:
		var plan := plan_value as Dictionary
		var snapshot: Dictionary = game.factory_workspace_snapshot(world_id)
		var queued: Dictionary = game.execute_factory_command({
			"protocol_version":1,
			"command_id":"bootstrap-queue-%s" % str(plan.get("label", "")),
			"kind":"QUEUE_CONSTRUCTION",
			"world_id":world_id,
			"base_topology_revision":int(snapshot.get("topology_revision", -1)),
			"payload":{"definition_id":plan.get("definition_id", ""), "recipe_id":plan.get("recipe_id", ""), "origin":plan.get("origin", {}), "priority":50}
		})
		var order_id := str(queued.get("result", {}).get("order_id", ""))
		entity_ids[str(plan.get("label", ""))] = str(queued.get("result", {}).get("entity_id", ""))
		_check(bool(queued.get("accepted", false)) and not order_id.is_empty(), "fresh bootstrap queues %s" % str(plan.get("label", "")))
		if not bool(queued.get("accepted", false)):
			continue
		var funded: Dictionary = game.execute_factory_command({
			"protocol_version":1,
			"command_id":"bootstrap-fund-%s" % str(plan.get("label", "")),
			"kind":"FUND_CONSTRUCTION",
			"world_id":world_id,
			"base_topology_revision":int(queued.get("topology_revision", -1)),
			"payload":{"order_id":order_id, "storage_id":"starter-depot"}
		})
		_check(bool(funded.get("accepted", false)), "fresh bootstrap funds %s from the physical starter depot" % str(plan.get("label", "")))
	var funded_world: Dictionary = game.state.factory_worlds[world_id]
	var starter_inventory: Dictionary = funded_world.get("entities", {}).get("starter-depot", {}).get("inventory", {})
	_check(int(starter_inventory.get("scrap_metal", -1)) == 18 and int(starter_inventory.get("electronics", -1)) == 6, "44 scrap preserves the full Lunar and Asteroid remote-bootstrap reserve after funding the renewable starter chain")
	var construction_report: Dictionary = game.advance_game_time(240000.0)
	var completed_world: Dictionary = game.state.factory_worlds[world_id]
	_check(completed_world.get("construction_orders", {}).is_empty() and completed_world.get("entities", {}).size() == 8, "normal deterministic construction completes all seven funded starter entities")
	_check((construction_report.get("events", []) as Array).any(func(event): return str((event as Dictionary).get("type", "")) == "FactoryConstructionCompleted"), "fresh construction advance returns the observable FactoryConstructionCompleted event")
	var power_id := str(entity_ids.get("power", ""))
	for consumer_label in ["iron_mine", "copper_mine", "iron_refinery", "copper_refinery", "electronics", "frames"]:
		_connect_bootstrap(game, world_id, "POWER", power_id, str(entity_ids.get(consumer_label, "")), "", "bootstrap-power-%s" % consumer_label)
	_connect_bootstrap(game, world_id, "CARGO", str(entity_ids.get("iron_mine", "")), str(entity_ids.get("iron_refinery", "")), "iron_ore", "bootstrap-iron-ore")
	_connect_bootstrap(game, world_id, "CARGO", str(entity_ids.get("copper_mine", "")), str(entity_ids.get("copper_refinery", "")), "copper_ore", "bootstrap-copper-ore")
	for target_label in ["electronics", "frames"]:
		_connect_bootstrap(game, world_id, "CARGO", str(entity_ids.get("iron_refinery", "")), str(entity_ids.get(target_label, "")), "iron_ingot", "bootstrap-iron-%s" % target_label)
		_connect_bootstrap(game, world_id, "CARGO", str(entity_ids.get("copper_refinery", "")), str(entity_ids.get(target_label, "")), "copper_ingot", "bootstrap-copper-%s" % target_label)
	_connect_bootstrap(game, world_id, "CARGO", str(entity_ids.get("electronics", "")), "starter-depot", "electronics", "bootstrap-electronics-out")
	_connect_bootstrap(game, world_id, "CARGO", str(entity_ids.get("frames", "")), "starter-depot", "structural_frame", "bootstrap-frames-out")
	_connect_bootstrap(game, world_id, "CARGO", str(entity_ids.get("iron_refinery", "")), "starter-depot", "iron_ingot", "bootstrap-iron-out")
	_connect_bootstrap(game, world_id, "CARGO", str(entity_ids.get("copper_refinery", "")), "starter-depot", "copper_ingot", "bootstrap-copper-out")
	var production_report: Dictionary = game.advance_game_time(300000.0)
	var running_world: Dictionary = game.state.factory_worlds[world_id]
	var renewable_inventory: Dictionary = running_world.get("entities", {}).get("starter-depot", {}).get("inventory", {})
	_check(int(renewable_inventory.get("electronics", 0)) > 6 and int(renewable_inventory.get("structural_frame", 0)) > 0, "fresh physical grid reaches renewable electronics and structural-frame output")
	_check((production_report.get("events", []) as Array).any(func(event): return str((event as Dictionary).get("type", "")) == "FactoryRecipeCompleted"), "fresh production advance returns the observable FactoryRecipeCompleted event")
	_check((production_report.get("events", []) as Array).any(func(event): return str((event as Dictionary).get("type", "")) == "FactoryResourceExtracted") and int(game.state.completed_activities.get("separate_iron_ore", 0)) > 0 and int(game.state.completed_activities.get("separate_copper_ore", 0)) > 0, "physical resource extraction provides the persistent separation milestones used by later progression")
	_check(published_event_types.has("FactoryConstructionQueued") and published_event_types.has("FactoryConstructionFunded") and published_event_types.has("FactoryEntitiesConnected"), "public Factory commands publish the queued, funded, and connected event prefix")

	game.advance_game_time(1800000.0)
	var foundry := _queue_and_fund_bootstrap_building(game, world_id, "grid_arc_smelter", "grid_refine_iron", {"x":100, "y":100}, "foundry", false)
	var electronics_facility := _queue_and_fund_bootstrap_building(game, world_id, "grid_electronics_works", "grid_fabricate_data_core", {"x":130, "y":100}, "electronics-facility", false)
	var research_complex := _queue_and_fund_bootstrap_building(game, world_id, "grid_research_complex", "", {"x":160, "y":100}, "research-complex", true)
	var research_power := _queue_and_fund_bootstrap_building(game, world_id, "grid_solar_array", "", {"x":190, "y":100}, "research-power", false)
	_check(not foundry.is_empty() and not electronics_facility.is_empty() and not research_complex.is_empty() and not research_power.is_empty(), "renewable Factory output and reserved bootstrap scrap fund the physical Establish Industry facilities and dedicated Research power")
	game.advance_game_time(360000.0)
	_connect_bootstrap(game, world_id, "POWER", power_id, str(foundry.get("entity_id", "")), "", "bootstrap-power-foundry")
	_connect_bootstrap(game, world_id, "POWER", power_id, str(electronics_facility.get("entity_id", "")), "", "bootstrap-power-electronics-facility")
	_connect_bootstrap(game, world_id, "POWER", str(research_power.get("entity_id", "")), str(research_complex.get("entity_id", "")), "", "bootstrap-power-research-complex")
	game.advance_game_time(1000.0)
	_check(
		game.state.facilities.has("orbital_foundry") and str(game.state.facilities.get("orbital_foundry", {}).get("status", "")) == "ACTIVE"
		and game.state.facilities.has("electronics_facility") and str(game.state.facilities.get("electronics_facility", {}).get("status", "")) == "ACTIVE"
		and game.state.facilities.has("research_complex") and str(game.state.facilities.get("research_complex", {}).get("status", "")) == "ACTIVE",
		"completed and physically powered grid entities are the only runnable foundry, electronics, and research adapters"
	)
	var establish_goal: Dictionary = database.goals.get("establish_industry", {})
	var establish_complete := (establish_goal.get("requirements", []) as Array).all(func(requirement): return game.simulation.requirement_met(game.state, requirement as Dictionary))
	for step_value in establish_goal.get("steps", []):
		establish_complete = establish_complete and ((step_value as Dictionary).get("requirements", []) as Array).all(func(requirement): return game.simulation.requirement_met(game.state, requirement as Dictionary))
	_check(establish_complete, "a fresh save completes Establish Industry entirely through physical Factory milestones")

	_export_bootstrap_item(game, world_id, "iron_ingot", 4, "research-iron")
	_export_bootstrap_item(game, world_id, "electronics", 3, "research-electronics")
	_check(game.start_research_project("research_industrial_coordination"), "the physical research adapter starts the first real Research project")
	var research_report: Dictionary = game.advance_game_time(600000.0)
	_check(bool(game.state.completed_projects.get("research_industrial_coordination", false)) and bool(game.state.technologies.get("industrial_coordination", false)), "the first Research project consumes Factory output and unlocks Industrial Coordination")
	_check(published_event_types.has("ResearchStarted") and (research_report.get("events", []) as Array).any(func(event): return str((event as Dictionary).get("type", "")) == "ResearchCompleted"), "fresh progression observes ResearchStarted and ResearchCompleted across the public event boundaries")
	game.domain_event.disconnect(capture_event)


func _connect_bootstrap(game: Variant, world_id: String, kind: String, source_id: String, target_id: String, item_id: String, command_id: String) -> void:
	var snapshot: Dictionary = game.factory_workspace_snapshot(world_id)
	var payload := {"link_kind":kind, "source_id":source_id, "target_id":target_id}
	if not item_id.is_empty():
		payload["item_id"] = item_id
		payload["capacity_per_second"] = 4.0
	var result: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":command_id,
		"kind":"CONNECT_ENTITIES",
		"world_id":world_id,
		"base_topology_revision":int(snapshot.get("topology_revision", -1)),
		"payload":payload
	})
	_check(bool(result.get("accepted", false)), "%s connects %s to %s" % [kind, source_id, target_id])


func _queue_and_fund_bootstrap_building(game: Variant, world_id: String, definition_id: String, recipe_id: String, origin: Dictionary, label: String, include_location_inventory: bool) -> Dictionary:
	var snapshot: Dictionary = game.factory_workspace_snapshot(world_id)
	var queued: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"bootstrap-expand-queue-%s" % label,
		"kind":"QUEUE_CONSTRUCTION",
		"world_id":world_id,
		"base_topology_revision":int(snapshot.get("topology_revision", -1)),
		"payload":{"definition_id":definition_id, "recipe_id":recipe_id, "origin":origin, "priority":50}
	})
	_check(bool(queued.get("accepted", false)), "fresh progression queues %s" % label)
	if not bool(queued.get("accepted", false)):
		return {}
	var order_id := str(queued.get("result", {}).get("order_id", ""))
	var funded: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"bootstrap-expand-fund-%s" % label,
		"kind":"FUND_CONSTRUCTION",
		"world_id":world_id,
		"base_topology_revision":int(queued.get("topology_revision", -1)),
		"payload":{"order_id":order_id, "storage_id":"starter-depot"}
	})
	_check(bool(funded.get("accepted", false)), "renewable Factory inventory funds %s" % label)
	if include_location_inventory:
		var location_funded: Dictionary = game.execute_factory_command({
			"protocol_version":1,
			"command_id":"bootstrap-expand-location-%s" % label,
			"kind":"FUND_CONSTRUCTION_FROM_LOCATION",
			"world_id":world_id,
			"base_topology_revision":int(funded.get("topology_revision", -1)),
			"payload":{"order_id":order_id}
		})
		_check(bool(location_funded.get("accepted", false)), "same-location starter cargo completes funding for %s" % label)
	return {"order_id":order_id, "entity_id":str(queued.get("result", {}).get("entity_id", ""))}


func _export_bootstrap_item(game: Variant, world_id: String, item_id: String, quantity: int, command_suffix: String) -> void:
	var snapshot: Dictionary = game.factory_workspace_snapshot(world_id)
	var result: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"bootstrap-export-%s" % command_suffix,
		"kind":"EXPORT_TO_LOCATION",
		"world_id":world_id,
		"base_topology_revision":int(snapshot.get("topology_revision", -1)),
		"payload":{"storage_id":"starter-depot", "item_id":item_id, "quantity":quantity}
	})
	_check(bool(result.get("accepted", false)) and int(result.get("result", {}).get("moved", 0)) == quantity, "Factory exports %d %s into the same-location Research inventory" % [quantity, item_id])


func _test_factory_progression_adapters() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var world: Dictionary = game.state.factory_worlds.get("earth-surface-grid", {})
	_check(not game.state.facilities.has("makeshift_workshop"), "fresh state cannot unlock manufacturing from a retired aggregate facility record")
	var placed: Dictionary = game.simulation.factory_grid.place_entity_immediate(world, "grid_engineering_works", Vector2i(160, 32), "grid_refine_iron", "adapter-works")
	_check(bool(placed.get("ok", false)), "progression fixture places a physical engineering works")
	_check(is_zero_approx(float(world.get("entities", {}).get("adapter-works", {}).get("power_factor", 1.0))), "new power-consuming entities provide no transient service before their first physical power calculation")
	game.simulation.ensure_frontier_state(game.state)
	_check(game.state.facilities.has("makeshift_workshop") and str(game.state.facilities.get("makeshift_workshop", {}).get("status", "")) == "INACTIVE", "an unpowered physical entity is owned but unavailable through the compatibility facility view")
	_check(game.simulation.requirement_met(game.state, {"type":"own_facility", "id":"makeshift_workshop"}), "physical facility ownership remains stable while its runtime service is unpowered")
	world.get("entities", {}).erase("adapter-works")
	game.state.facilities["makeshift_workshop"] = {"level":99, "status":"ACTIVE"}
	game.simulation.ensure_frontier_state(game.state)
	_check(not game.state.facilities.has("makeshift_workshop"), "stale aggregate facility data cannot survive without its physical grid entity")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_research_complex", Vector2i(160, 32), "", "adapter-research").get("ok", false)), "service fixture places a physical Research Complex")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(300, 32), "", "adapter-power").get("ok", false)), "service fixture places physical generation")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(300, 50), "", "adapter-research-power").get("ok", false)), "service fixture places independent Research generation")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_cooling_service", Vector2i(330, 32), "", "adapter-cooling").get("ok", false)), "service fixture places a physical cooling unit")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_engineering_works", Vector2i(220, 100), "grid_refine_iron", "adapter-research-load").get("ok", false)), "service fixture places a competing physical power load")
	game.simulation.ensure_frontier_state(game.state)
	_check(game.state.facilities.has("research_complex") and is_zero_approx(game.simulation.research_capacity(game.state)), "an installed but unpowered Research Complex contributes zero runnable research capacity")
	var pre_heavy_palette: Array = game.factory_workspace_snapshot("earth-surface-grid").get("palette", {}).get("buildings", [])
	_check(not pre_heavy_palette.any(func(entry): return str((entry as Dictionary).get("id", "")) == "grid_research_complex_ii"), "Factory palette hides Research Complex II before Heavy Industry")
	game.state.technologies["heavy_industry"] = true
	var heavy_palette: Array = game.factory_workspace_snapshot("earth-surface-grid").get("palette", {}).get("buildings", [])
	_check(heavy_palette.any(func(entry): return str((entry as Dictionary).get("id", "")) == "grid_research_complex_ii"), "Heavy Industry plus the physical base Research Complex reveals Research Complex II")
	game.state.technologies.erase("heavy_industry")
	var unpowered_profile: Dictionary = game.simulation.location_industry_constraint_profile(game.state, "earth_orbit")
	_check(is_zero_approx(float(unpowered_profile.get("power_capacity", 0.0))) and is_zero_approx(float(unpowered_profile.get("cooling_capacity", 0.0))), "disconnected generation and unpowered services do not satisfy physical site constraints")
	_check(bool(game.simulation.factory_grid.connect_entities(world, "POWER", "adapter-power", "adapter-cooling").get("ok", false)), "service fixture creates a physical power edge")
	var research_power_link: Dictionary = game.simulation.factory_grid.connect_entities(world, "POWER", "adapter-research-power", "adapter-research")
	_check(bool(research_power_link.get("ok", false)), "Research Complex receives a physical power edge")
	_check(bool(game.simulation.factory_grid.connect_entities(world, "POWER", "adapter-research-power", "adapter-research-load").get("ok", false)), "Research grid receives a competing load that forces partial service")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	game.simulation.ensure_frontier_state(game.state)
	var powered_profile: Dictionary = game.simulation.location_industry_constraint_profile(game.state, "earth_orbit")
	_check(float(powered_profile.get("power_capacity", 0.0)) == 200.0 and float(powered_profile.get("cooling_capacity", 0.0)) == 1200.0, "connected powered services become available to site and research constraints")
	var partial_research_capacity: float = float(game.simulation.research_capacity(game.state))
	_check(partial_research_capacity > 0.0 and partial_research_capacity < 1.0, "partially powered Research Complex exposes proportional compatibility throughput")
	_check(game.simulation.factory_grid.remove_link(world, str(research_power_link.get("link_id", ""))), "powered Research Complex becomes runnable before its physical edge is removed")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	game.simulation.ensure_frontier_state(game.state)
	_check(game.state.facilities.has("research_complex") and is_zero_approx(game.simulation.research_capacity(game.state)), "removing Research power preserves ownership but immediately removes runnable capacity")
	var gas_giant_known_before := bool(game.state.regions.get("gas_giant_region", false))
	# This fixture isolates pause/resume eligibility from route progression: the
	# canonical Jovian project's top-level region prerequisite is already met,
	# while the physical Research-capacity gate below remains deliberately unmet.
	game.state.regions["gas_giant_region"] = true
	var idle_research_runtime: Dictionary = game.state.research.duplicate(true)
	game.state.research = SpaceGameState.empty_research_program()
	game.state.research.merge({
		"project_id":"research_jovian_operations",
		"status":"BLOCKED",
		"stage_index":4,
		"location_id":"earth_orbit",
		"blocked_reason":"FIELD_TEST:own_facility:energy_array"
	}, true)
	game.simulation.refresh_factory_dependent_runtime_state(game.state)
	var refreshed_research_runtime: Dictionary = game.state.research
	var refreshed_research_blocker: Dictionary = refreshed_research_runtime.get("blocker", {})
	_check(
		str(refreshed_research_runtime.get("status", "")) == "BLOCKED"
		and str(refreshed_research_runtime.get("stage_id", "")) == "field_test"
		and str(refreshed_research_runtime.get("blocked_reason", "")) == "RESEARCH_CAPACITY"
		and str(refreshed_research_blocker.get("primary_reason", "")) == "RESEARCH_CAPACITY_SHORTAGE"
		and is_zero_approx(float(refreshed_research_blocker.get("available", -1.0))),
		"zero-time Factory refresh replaces a stale Research gate reason and structured blocker with the current physical capacity shortage; runtime=%s blocker=%s capacity=%s" % [JSON.stringify(refreshed_research_runtime), JSON.stringify(refreshed_research_blocker), str(game.simulation.research_capacity(game.state))]
	)
	_check(game.stop_research(), "public Research pause accepts the physically capacity-blocked program")
	var paused_research_runtime: Dictionary = game.research_runtime_snapshot()
	_check(
		str(paused_research_runtime.get("status", "")) == "PAUSED"
		and str(paused_research_runtime.get("blocked_reason", "")) == "MANUALLY_PAUSED"
		and str(paused_research_runtime.get("blocker", {}).get("primary_reason", "")) == "MANUALLY_PAUSED"
		and game.simulation.research_gameplay_state(game.state) == "PAUSED",
		"public Research pause immediately publishes one coherent manual-pause projection; runtime=%s" % JSON.stringify(paused_research_runtime)
	)
	_check(game.start_research_project("research_jovian_operations"), "public Research resume accepts the committed capacity-blocked program")
	var resumed_research_runtime: Dictionary = game.research_runtime_snapshot()
	_check(
		str(resumed_research_runtime.get("status", "")) == "BLOCKED"
		and str(resumed_research_runtime.get("blocked_reason", "")) == "RESEARCH_CAPACITY"
		and str(resumed_research_runtime.get("blocker", {}).get("primary_reason", "")) == "RESEARCH_CAPACITY_SHORTAGE"
		and game.simulation.research_gameplay_state(game.state) == "WAITING_FACILITY",
		"public Research resume immediately revalidates physical Factory capacity instead of exposing a false ACTIVE state; runtime=%s" % JSON.stringify(resumed_research_runtime)
	)
	game.state.research = idle_research_runtime
	game.state.regions["gas_giant_region"] = gas_giant_known_before
	# Public Game commands commit a cloned transaction state, so refresh this
	# local fixture reference before continuing direct Factory-domain adapter
	# assertions against the authoritative committed world.
	world = game.state.factory_worlds.get("earth-surface-grid", {})
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_power_substation_ii", Vector2i(500, 100), "", "adapter-module-power").get("ok", false)), "module fixture places independent physical generation")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_research_complex_ii", Vector2i(400, 100), "", "adapter-research-ii").get("ok", false)), "progression fixture places the physical Research Complex II provider")
	var base_research_power_link: Dictionary = game.simulation.factory_grid.connect_entities(world, "POWER", "adapter-module-power", "adapter-research")
	_check(bool(base_research_power_link.get("ok", false)), "advanced Research fixture powers only the base Research Complex first")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	game.simulation.ensure_frontier_state(game.state)
	_check(int(game.state.facilities.get("research_complex", {}).get("level", 0)) == 2 and is_equal_approx(game.simulation.research_capacity(game.state), 1.0), "an owned but unpowered Research Complex II preserves level ownership without granting capacity 2")
	var advanced_research_power_link: Dictionary = game.simulation.factory_grid.connect_entities(world, "POWER", "adapter-module-power", "adapter-research-ii")
	_check(bool(advanced_research_power_link.get("ok", false)), "advanced Research fixture powers the Research Complex II provider")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	game.simulation.ensure_frontier_state(game.state)
	_check(is_equal_approx(game.simulation.research_capacity(game.state), 2.0), "a fully powered physical Research Complex II supplies the two units required by Megastructure Research")
	_check(game.simulation.factory_grid.remove_link(world, str(advanced_research_power_link.get("link_id", ""))), "advanced Research fixture disconnects its level-two provider")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	game.simulation.ensure_frontier_state(game.state)
	_check(is_equal_approx(game.simulation.research_capacity(game.state), 1.0), "disconnecting Research Complex II immediately falls back to the powered base complex")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_electronics_works", Vector2i(550, 100), "grid_fabricate_data_core", "adapter-electronics").get("ok", false)), "module fixture places the owning physical Electronics Works")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_fusion_test_rig", Vector2i(600, 100), "", "adapter-fusion-rig").get("ok", false)), "module fixture places a physical Fusion Test Rig")
	_check(bool(game.simulation.factory_grid.connect_entities(world, "POWER", "adapter-module-power", "adapter-electronics").get("ok", false)), "module fixture powers the owning Electronics Works separately")
	game.simulation.refresh_factory_runtime_views(game.state)
	var module_requirement := {"type":"manufacturing_module_installed", "facility":"electronics_facility", "id":"fusion_component_test_rig"}
	_check(game.state.facilities.has("electronics_facility") and not game.simulation.requirement_met(game.state, module_requirement), "an unpowered physical module cannot satisfy an active Research module gate")
	var module_power_link: Dictionary = game.simulation.factory_grid.connect_entities(world, "POWER", "adapter-module-power", "adapter-fusion-rig")
	_check(bool(module_power_link.get("ok", false)), "module fixture connects the Fusion Test Rig to physical power")
	game.simulation.refresh_factory_runtime_views(game.state)
	_check(game.simulation.requirement_met(game.state, module_requirement), "a powered physical module satisfies the active Research module gate")
	_check(game.simulation.factory_grid.remove_link(world, str(module_power_link.get("link_id", ""))), "module fixture removes only the Fusion Test Rig power edge")
	game.simulation.refresh_factory_runtime_views(game.state)
	_check(not game.simulation.requirement_met(game.state, module_requirement), "disconnecting the physical module immediately closes the Research gate without deleting its entity")
	var locked_snapshot: Dictionary = game.factory_workspace_snapshot("earth-surface-grid")
	var locked_buildings: Array = locked_snapshot.get("palette", {}).get("buildings", [])
	_check(not locked_buildings.any(func(entry): return str((entry as Dictionary).get("id", "")) == "grid_assembly_array"), "Factory palette hides buildings whose technology requirements are unmet")
	game.state.technologies["heavy_industry"] = true
	var unlocked_snapshot: Dictionary = game.factory_workspace_snapshot("earth-surface-grid")
	_check((unlocked_snapshot.get("palette", {}).get("buildings", []) as Array).any(func(entry): return str((entry as Dictionary).get("id", "")) == "grid_assembly_array"), "Factory palette reveals the same building after its technology requirement is met")


func _test_multi_stage_research_boundaries() -> void:
	var game: Variant = get_root().get_node("Game")
	var one_shot: Dictionary = _run_advanced_research_window(game, [36000.01])
	var split: Dictionary = _run_advanced_research_window(game, [8000.0, 9000.0, 7000.0, 0.01, 12000.0])
	_check(bool(one_shot.get("completed", false)) and bool(split.get("completed", false)), "one long advance and exact split advances both complete every stage of the same research program")
	_check(
		one_shot.get("event_types", []) == split.get("event_types", [])
		and (one_shot.get("event_types", []) as Array).count("ResearchStageCompleted") == 4
		and (one_shot.get("event_types", []) as Array).count("ResearchCompleted") == 1,
		"multi-stage Research preserves deterministic stage boundaries and event order in one-shot and split advances"
	)
	_check(int(one_shot.get("stage_index", -1)) == int(split.get("stage_index", -2)) and str(one_shot.get("status", "")) == str(split.get("status", "x")), "one-shot and split Research end in the same canonical runtime state")
	var provider_one_shot: Dictionary = _run_research_factory_gate_window(game, [45000.01])
	var provider_split: Dictionary = _run_research_factory_gate_window(game, [26000.0, 19000.01])
	_check(bool(provider_one_shot.get("completed", false)) and provider_one_shot == provider_split, "Research blocked on a physical Factory prototype gate is one-shot/split equivalent when production completes mid-window")
	_check(
		(provider_one_shot.get("event_types", []) as Array).find("FactoryRecipeCompleted") >= 0
		and (provider_one_shot.get("event_types", []) as Array).find("FactoryRecipeCompleted") < (provider_one_shot.get("event_types", []) as Array).find("ResearchCompleted"),
		"a Factory prototype completion becomes usable only after its own cross-domain boundary"
	)


func _run_advanced_research_window(game: Variant, chunks: Array) -> Dictionary:
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var world: Dictionary = game.state.factory_worlds["earth-surface-grid"]
	game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(260, 0), "", "boundary-research-power")
	game.simulation.factory_grid.place_entity_immediate(world, "grid_research_complex", Vector2i(260, 40), "", "boundary-research-complex")
	game.simulation.factory_grid.connect_entities(world, "POWER", "boundary-research-power", "boundary-research-complex")
	game.simulation.refresh_factory_runtime_views(game.state)
	game.state.technologies["industrial_coordination"] = true
	game.state.completed_projects["research_industrial_coordination"] = true
	game.state.completed_activities["fabricate_propulsion_test_article"] = 1
	game.state.completed_activities["route:propulsion_proving_route"] = 1
	game.state.add_item("electronics", 2, "earth_orbit")
	game.state.add_item("titanium_alloy", 3, "earth_orbit")
	game.state.add_item("data_core", 1, "earth_orbit")
	game.state.add_item("propulsion_test_article", 1, "earth_orbit")
	var started: bool = game.start_research_project("research_advanced_propulsion", "HIGH_THRUST")
	var public_runtime: Dictionary = game.research_runtime_snapshot()
	_check(started and str(public_runtime.get("project_id", "")) == "research_advanced_propulsion" and str(public_runtime.get("status", "")) == "RUNNING" and str(public_runtime.get("stage_id", "")) == "theory" and str(public_runtime.get("route_id", "")) == "HIGH_THRUST", "public Research runtime snapshot identifies the active project, route and stage without exposing mutable state")
	var event_types: Array[String] = []
	if started:
		for chunk_value in chunks:
			var report: Dictionary = game.advance_game_time(float(chunk_value))
			for event_value in report.get("events", []):
				event_types.append(str((event_value as Dictionary).get("type", "")))
	return {
		"completed":bool(game.state.completed_projects.get("research_advanced_propulsion", false)),
		"event_types":event_types,
		"stage_index":int(game.state.research.get("stage_index", -1)),
		"status":str(game.state.research.get("status", ""))
	}


func _run_research_factory_gate_window(game: Variant, chunks: Array) -> Dictionary:
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var world: Dictionary = game.state.factory_worlds["earth-surface-grid"]
	game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(260, 0), "", "gate-power-a")
	game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(280, 0), "", "gate-power-b")
	game.simulation.factory_grid.place_entity_immediate(world, "grid_research_complex", Vector2i(260, 40), "", "gate-research")
	game.simulation.factory_grid.place_entity_immediate(world, "grid_electronics_works", Vector2i(300, 40), "grid_fabricate_propulsion_test_article", "gate-prototype-machine")
	game.simulation.factory_grid.connect_entities(world, "POWER", "gate-power-a", "gate-research")
	game.simulation.factory_grid.connect_entities(world, "POWER", "gate-power-b", "gate-research")
	game.simulation.factory_grid.connect_entities(world, "POWER", "gate-power-a", "gate-prototype-machine")
	world["entities"]["gate-prototype-machine"]["inputs"] = {"titanium_alloy":2, "electronics":2}
	game.simulation.refresh_factory_runtime_views(game.state)
	game.state.technologies["industrial_coordination"] = true
	game.state.completed_projects["research_industrial_coordination"] = true
	game.state.completed_activities["route:propulsion_proving_route"] = 1
	game.state.add_item("electronics", 2, "earth_orbit")
	game.state.add_item("titanium_alloy", 3, "earth_orbit")
	game.state.add_item("data_core", 1, "earth_orbit")
	game.state.add_item("propulsion_test_article", 1, "earth_orbit")
	var started: bool = game.start_research_project("research_advanced_propulsion", "HIGH_THRUST")
	var event_types: Array[String] = []
	if started:
		for chunk_value in chunks:
			var report: Dictionary = game.advance_game_time(float(chunk_value))
			for event_value in report.get("events", []):
				event_types.append(str((event_value as Dictionary).get("type", "")))
	return {
		"completed":bool(game.state.completed_projects.get("research_advanced_propulsion", false)),
		"event_types":event_types,
		"elapsed_ms":float(game.state.total_elapsed_ms),
		"status":str(game.state.research.get("status", ""))
	}


func _test_remote_factory_facility_maintenance_custody() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var site_id := "earth_sun_lagrange"
	game.state.regions[site_id] = true
	game.state.region_states[site_id] = {"discovered":true, "survey_state":LocationState.DEEP_SURVEYED, "exploration_state":LocationState.DEEP_SURVEYED, "strategic_state":"OPEN", "development_state":"FRONTIER"}
	game.state.location_state(site_id)["survey_state"] = LocationState.DEEP_SURVEYED
	_check(game.initialize_surveyed_factory_world(site_id), "remote maintenance fixture initializes its surveyed Factory world")
	var world_id: String = game.factory_world_ids_for_location(site_id)[0]
	var world: Dictionary = game.state.factory_worlds[world_id]
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "remote-maintenance-power").get("ok", false)), "remote maintenance fixture places physical power")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_repair_dock", Vector2i(20, 0), "", "remote-maintenance-dock").get("ok", false)), "remote maintenance fixture places its physical Repair Dock")
	_check(bool(game.simulation.factory_grid.connect_entities(world, "POWER", "remote-maintenance-power", "remote-maintenance-dock").get("ok", false)), "remote Repair Dock receives a physical power edge")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	game.simulation.refresh_factory_runtime_views(game.state)
	game.simulation.refresh_demand_registry(game.state)
	var public_recovery: Dictionary = game.maintenance_recovery_snapshot(site_id, "repair_material", 1, 5000.0)
	var expected_recovery: Dictionary = game.simulation.maintenance_recovery_requirement(game.state, site_id, "repair_material", 1, 5000.0)
	_check(public_recovery == expected_recovery and int(public_recovery.get("gross_production_target", 0)) >= 1, "public maintenance recovery snapshot projects the gross physical reserve without exposing authoritative registries")
	public_recovery["gross_production_target"] = -1
	_check(int(game.maintenance_recovery_snapshot(site_id, "repair_material", 1, 5000.0).get("gross_production_target", 0)) == int(expected_recovery.get("gross_production_target", 0)), "public maintenance recovery snapshots are detached copies")
	var repair_runtime: Dictionary = game.state.facilities.get("repair_dock", {})
	var providers: Array = repair_runtime.get("factory_providers", [])
	_check(
		providers.size() == 1
		and str((providers[0] as Dictionary).get("location_id", "")) == site_id
		and (providers[0] as Dictionary).get("world_ids", []).has(world_id)
		and (providers[0] as Dictionary).get("entity_ids", []).has("remote-maintenance-dock"),
		"Factory facility adapter retains the powered provider's authoritative world, entity and remote Location"
	)
	var site_demands: Array = []
	var earth_demands: Array = []
	for demand_value in game.state.demand_registry.get("sources", {}).values():
		var demand := demand_value as Dictionary
		if str(demand.get("consumer_type", "")) != "facility_om" or str(demand.get("facility_id", "")) != "repair_dock":
			continue
		if str(demand.get("location_id", "")) == site_id:
			site_demands.append(demand)
		elif str(demand.get("location_id", "")) == "earth_orbit":
			earth_demands.append(demand)
	_check(site_demands.size() == 2 and earth_demands.is_empty(), "remote Repair Dock publishes both O&M item demands at its provider Location instead of Earth")
	game.state.add_item("repair_material", 10, "earth_orbit")
	game.state.add_item("electronics", 10, "earth_orbit")
	var earth_repair_before: int = int(game.state.item_quantity("repair_material", "earth_orbit"))
	var earth_electronics_before: int = int(game.state.item_quantity("electronics", "earth_orbit"))
	for demand_value in site_demands:
		var demand := demand_value as Dictionary
		game.state.operations_maintenance.get("fractional", {})[str(demand.get("demand_id", ""))] = 0.99999999
	game.advance_game_time(5000.0)
	var site_coverage: float = float(game.simulation.facility_operations_maintenance_coverage(game.state, site_id, "repair_dock"))
	var maintenance_only_phase := {"id":"maintenance-custody-check", "site_requirements":{"maintenance_coverage":1.0}}
	var missing_site_blocker: Dictionary = game.simulation.megastructure_site_requirement_blocker(game.state, maintenance_only_phase, site_id)
	_check(is_zero_approx(site_coverage) and str(missing_site_blocker.get("primary_reason", "")) == "MAINTENANCE_SHORTAGE", "Earth stock cannot satisfy remote Repair Dock O&M or the same-site Megastructure maintenance gate")
	_check(game.state.item_quantity("repair_material", "earth_orbit") == earth_repair_before and game.state.item_quantity("electronics", "earth_orbit") == earth_electronics_before, "remote O&M settlement never consumes the identically named Earth inventory")
	game.state.add_item("repair_material", 2, site_id)
	game.state.add_item("electronics", 2, site_id)
	for demand_value in site_demands:
		var demand := demand_value as Dictionary
		game.state.operations_maintenance.get("fractional", {})[str(demand.get("demand_id", ""))] = 0.99999999
	game.advance_game_time(5000.0)
	var restored_site_coverage: float = float(game.simulation.facility_operations_maintenance_coverage(game.state, site_id, "repair_dock"))
	_check(restored_site_coverage >= 0.999 and game.simulation.megastructure_site_requirement_blocker(game.state, maintenance_only_phase, site_id).is_empty(), "same-site maintenance cargo restores the remote Repair Dock and Megastructure maintenance gate")
	_check(game.state.item_quantity("repair_material", site_id) < 2 and game.state.item_quantity("electronics", site_id) < 2, "remote O&M settlement consumes both maintenance streams from the provider Location")


func _test_maintenance_recovery_projection() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var site_id := "earth_sun_lagrange"
	game.state.regions[site_id] = true
	game.state.region_states[site_id] = {"discovered":true, "survey_state":LocationState.DEEP_SURVEYED, "exploration_state":LocationState.DEEP_SURVEYED, "strategic_state":"OPEN", "development_state":"FRONTIER"}
	game.state.location_state(site_id)["survey_state"] = LocationState.DEEP_SURVEYED
	_check(game.initialize_surveyed_factory_world(site_id), "maintenance projection fixture initializes its surveyed Factory world")
	var world_id: String = game.factory_world_ids_for_location(site_id)[0]
	var world: Dictionary = game.state.factory_worlds[world_id]
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "projection-power").get("ok", false)), "maintenance projection fixture places physical power")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_repair_dock", Vector2i(20, 0), "", "projection-dock").get("ok", false)), "maintenance projection fixture places its Repair Dock")
	_check(bool(game.simulation.factory_grid.connect_entities(world, "POWER", "projection-power", "projection-dock").get("ok", false)), "maintenance projection Repair Dock receives a physical power edge")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	game.simulation.refresh_factory_runtime_views(game.state)
	var ship := game.state.ships[0] as Dictionary
	var ship_id := str(ship.get("instance_id", ""))
	ship["location_id"] = site_id
	game.simulation.refresh_demand_registry(game.state)
	var repair_demand_id := ""
	for demand_value in game.state.demand_registry.get("sources", {}).values():
		var demand := demand_value as Dictionary
		if str(demand.get("consumer_type", "")) == "facility_om" \
				and str(demand.get("location_id", "")) == site_id \
				and str(demand.get("product_id", "")) == "repair_material":
			repair_demand_id = str(demand.get("demand_id", ""))
			break
	_check(not repair_demand_id.is_empty(), "maintenance projection fixture exposes the remote Repair Dock repair-material stream")
	game.state.fleet_maintenance.get("fractional", {})[ship_id] = 0.99999999
	game.state.operations_maintenance.get("fractional", {})[repair_demand_id] = 0.99999999
	var projection: Dictionary = game.maintenance_recovery_snapshot(site_id, "repair_material", 1, 5000.0)
	_check(
		int(projection.get("recovery_quantity", -1)) == 2
		and int(projection.get("gross_production_target", -1)) == 3
		and int(projection.get("stream_count", -1)) >= 2,
		"public maintenance projection reserves each independent near-boundary fleet and facility stream: %s" % str(projection)
	)
	projection["gross_production_target"] = -1
	_check(int(game.maintenance_recovery_snapshot(site_id, "repair_material", 1, 5000.0).get("gross_production_target", 0)) == 3, "public maintenance recovery snapshots are detached from authoritative projection state")
	game.state.add_item("repair_material", 3, site_id)
	var report: Dictionary = game.advance_game_time(5000.0)
	_check(float(report.get("unprocessed_ms", 1.0)) <= 0.001, "maintenance projection fixture advances through both independent settlement boundaries")
	_check(game.state.available_item_quantity("repair_material", site_id) == 1, "stocking the projected gross target leaves the requested spendable unit after both maintenance streams settle")
	game.state.operations_maintenance.get("fractional", {})[repair_demand_id] = 0.0
	game.state.fleet_maintenance.get("debt", {})[ship_id] = 1.0
	game.state.fleet_maintenance.get("fractional", {})[ship_id] = 0.99999999
	var debt_projection: Dictionary = game.maintenance_recovery_snapshot(site_id, "repair_material", 1, 5000.0)
	_check(
		is_equal_approx(float(debt_projection.get("fleet_debt", 0.0)), 1.0)
		and int(debt_projection.get("recovery_quantity", -1)) == 2
		and int(debt_projection.get("gross_production_target", -1)) == 3,
		"public maintenance projection combines an existing fleet debt unit with the same stream's next fractional settlement: %s" % str(debt_projection)
	)
	game.state.facilities["energy_array"] = {"level":1, "status":"ACTIVE"}
	game.state.energy_system.get("maintenance_fractional", {})["energy_array"] = 0.99999999
	var energy_projection: Dictionary = game.maintenance_recovery_snapshot(SpaceGameState.MAIN_BASE_LOCATION_ID, "fusion_service_component", 1, 5000.0)
	_check(
		int(energy_projection.get("recovery_quantity", -1)) == 1
		and int(energy_projection.get("gross_production_target", -1)) == 2
		and int(energy_projection.get("stream_count", -1)) == 1,
		"public maintenance projection includes the Earth advanced-energy stream's near-boundary fractional settlement: %s" % str(energy_projection)
	)


func _test_megastructure_phase_runtime() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var site_id := "earth_sun_lagrange"
	game.state.regions[site_id] = true
	game.state.region_states[site_id] = {"discovered":true, "survey_state":LocationState.DEEP_SURVEYED, "exploration_state":LocationState.DEEP_SURVEYED, "strategic_state":"OPEN", "development_state":"FRONTIER"}
	game.state.location_state(site_id)["survey_state"] = LocationState.DEEP_SURVEYED
	game.state.completed_projects["research_megastructures"] = true
	game.state.technologies["megastructure_engineering"] = true
	game.simulation.ensure_frontier_state(game.state)
	_check(game.initialize_surveyed_factory_world(site_id), "deep-surveyed stellar site initializes a physical Factory world")
	var world_id: String = game.factory_world_ids_for_location(site_id)[0]
	var world: Dictionary = game.state.factory_worlds[world_id]
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "mega-power").get("ok", false)), "stellar site places physical power")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_construction_yard", Vector2i(20, 0), "", "mega-yard").get("ok", false)), "stellar site places physical construction capacity")
	_check(bool(game.simulation.factory_grid.connect_entities(world, "POWER", "mega-power", "mega-yard").get("ok", false)), "stellar site construction capacity has a physical power edge")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	_check(game.select_megastructure_site("stellar_energy", site_id), "researched deep-surveyed site can be selected for Stellar Energy")
	var definition: Dictionary = database.megastructures["stellar_energy"]
	var phase: Dictionary = (definition.get("phases", []) as Array)[1]
	var activity: Dictionary = database.activities[str(phase.get("activity_id", ""))]
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		game.state.add_item(str(cost.get("item", "")), int(cost.get("quantity", 0)), site_id)
	_check(game.start_megastructure_phase("stellar_energy", 90), "Stellar Energy phase consumes same-site inventory and starts its dedicated runtime: %s" % game.last_notice)
	var duration := float(activity.get("duration_ms", 1.0))
	var report: Dictionary = game.advance_game_time(duration)
	var project: Dictionary = game.state.megastructure_projects["stellar_energy"]
	_check(float(report.get("unprocessed_ms", 1.0)) <= 0.001 and int(project.get("phase_index", 0)) == 2 and str(project.get("status", "")) == "READY", "dedicated Megastructure runtime settles exactly at its deterministic boundary")
	_check(float(project.get("site_effects", {}).get("construction_capacity", 0.0)) == 12.0 and (project.get("phase_history", []) as Array).size() == 2, "phase completion persists cumulative site infrastructure and material history")
	game.simulation.ensure_frontier_state(game.state)
	var next_phase: Dictionary = (definition.get("phases", []) as Array)[2]
	_check(game.simulation.megastructure_site_requirement_blocker(game.state, next_phase, site_id).is_empty(), "next Megastructure phase reads persistent project-owned site effects after normalization")
	var restored := SpaceGameState.from_dictionary(game.state.to_dictionary(), database.domains.keys(), database.regions)
	var restored_project: Dictionary = restored.megastructure_projects.get("stellar_energy", {})
	_check(float(restored_project.get("site_effects", {}).get("construction_capacity", 0.0)) == 12.0 and restored_project.get("phase_runtime", {}) is Dictionary, "Megastructure runtime and site effects survive save/load normalization")


func _test_megastructure_factory_storage_custody() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var site_id := "earth_sun_lagrange"
	game.state.regions[site_id] = true
	game.state.region_states[site_id] = {"discovered":true, "survey_state":LocationState.DEEP_SURVEYED, "exploration_state":LocationState.DEEP_SURVEYED, "strategic_state":"OPEN", "development_state":"FRONTIER"}
	game.state.location_state(site_id)["survey_state"] = LocationState.DEEP_SURVEYED
	game.state.completed_projects["research_megastructures"] = true
	game.state.technologies["megastructure_engineering"] = true
	game.simulation.ensure_frontier_state(game.state)
	_check(game.initialize_surveyed_factory_world(site_id), "Factory-custody fixture initializes the deep-surveyed stellar workspace")
	var world_id: String = game.factory_world_ids_for_location(site_id)[0]
	var world: Dictionary = game.state.factory_worlds[world_id]
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(40, 0), "", "site-power").get("ok", false)), "Factory-custody fixture places physical construction power")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_construction_yard", Vector2i(60, 0), "", "site-yard").get("ok", false)), "Factory-custody fixture places physical construction capacity")
	_check(bool(game.simulation.factory_grid.connect_entities(world, "POWER", "site-power", "site-yard").get("ok", false)), "Factory-custody fixture powers the physical construction provider")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_component_depot", Vector2i(0, 0), "", "site-components").get("ok", false)), "Factory-custody fixture places the physical site component depot")
	_check(game.select_megastructure_site("stellar_energy", site_id), "Factory-custody fixture selects its researched deep-surveyed site")
	# Site selection commits a transaction and replaces Game.state, so refresh the
	# shared Dictionary reference before staging physical Factory custody.
	world = game.state.factory_worlds[world_id]
	var phase: Dictionary = (database.megastructures["stellar_energy"].get("phases", []) as Array)[1]
	var activity: Dictionary = database.activities[str(phase.get("activity_id", ""))]
	var total_cost := 0
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		var quantity := int(cost.get("quantity", 0))
		total_cost += quantity
		var factory_quantity := quantity
		if item_id == "electronics":
			game.state.add_item(item_id, 5, site_id)
			factory_quantity -= 5
		elif item_id == "industrial_machine_tools":
			factory_quantity -= 1
		if factory_quantity > 0:
			_check(bool(game.simulation.factory_grid.deposit_storage_inventory(world, "site-components", item_id, factory_quantity).get("ok", false)), "Factory-custody fixture stages %s in the same-site physical depot" % item_id)
	var phase_events: Array[Dictionary] = []
	var capture_event := func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "MegastructurePhaseStarted":
			phase_events.append(event.duplicate(true))
	game.domain_event.connect(capture_event)
	var rejected_state := JSON.stringify(game.state.to_dictionary())
	var rejected_consumed := int(game.state.statistics.get("items_consumed", 0))
	_check(not game.start_megastructure_phase("stellar_energy", 90), "Megastructure phase rejects a mixed-custody BOM with one missing unit")
	_check(JSON.stringify(game.state.to_dictionary()) == rejected_state and int(game.state.statistics.get("items_consumed", 0)) == rejected_consumed and phase_events.is_empty(), "Rejected Megastructure phase is fully atomic with no state, ledger, revision, or event mutation")
	_check(bool(game.simulation.factory_grid.deposit_storage_inventory(world, "site-components", "industrial_machine_tools", 1).get("ok", false)), "Factory-custody fixture stages the final missing capital-good unit")
	var available_before := {}
	var consumed_by_item_before := {}
	for cost_value in activity.get("costs", []):
		var item_id := str((cost_value as Dictionary).get("item", ""))
		available_before[item_id] = game.simulation.megastructure_site_available_item_quantity(game.state, item_id, site_id)
		consumed_by_item_before[item_id] = int(game.state.statistics.get("item_consumed_totals", {}).get(item_id, 0))
	var consumed_before := int(game.state.statistics.get("items_consumed", 0))
	_check(game.start_megastructure_phase("stellar_energy", 90), "Megastructure phase transaction consumes its oversized BOM from same-site Location and Factory custody: %s blocker=%s" % [game.last_notice, JSON.stringify(game.simulation.megastructure_phase_start_blocker(game.state, activity, site_id))])
	game.domain_event.disconnect(capture_event)
	var started_event: Dictionary = phase_events[0] if not phase_events.is_empty() else {}
	var sources: Array = started_event.get("source_breakdown", {}).get("electronics", [])
	_check(sources.size() == 2 and str((sources[0] as Dictionary).get("custody", "")) == "LOCATION" and str((sources[1] as Dictionary).get("custody", "")) == "FACTORY_STORAGE", "Megastructure phase event reports deterministic Location-first then Factory-storage custody")
	var committed_world: Dictionary = game.state.factory_worlds[world_id]
	_check(game.state.item_quantity("electronics", site_id) == 0 and int(committed_world.get("entities", {}).get("site-components", {}).get("inventory", {}).get("electronics", -1)) == 0, "Megastructure phase leaves no duplicate electronics across its two same-site custody stores")
	_check(int(game.state.statistics.get("items_consumed", 0)) - consumed_before == total_cost and int(game.state.statistics.get("item_consumed_totals", {}).get("industrial_machine_tools", 0)) == 20, "Megastructure Factory-storage debits remain visible in the global per-item consumption ledger")
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		var quantity := int(cost.get("quantity", 0))
		var live_delta: int = int(available_before.get(item_id, 0)) - game.simulation.megastructure_site_available_item_quantity(game.state, item_id, site_id)
		var ledger_delta: int = int(game.state.statistics.get("item_consumed_totals", {}).get(item_id, 0)) - int(consumed_by_item_before.get(item_id, 0))
		_check(live_delta == quantity and ledger_delta == quantity, "Megastructure phase conserves exact mixed-custody quantity for %s" % item_id)
	var restored := SpaceGameState.from_dictionary(game.state.to_dictionary(), database.domains.keys(), database.regions)
	var restored_runtime: Dictionary = restored.megastructure_projects.get("stellar_energy", {}).get("phase_runtime", {})
	_check(str(restored.megastructure_projects.get("stellar_energy", {}).get("status", "")) == "BUILDING" and not restored_runtime.get("source_breakdown", {}).is_empty(), "Active Megastructure mixed-custody runtime and provenance survive save/load normalization")


func _test_megastructure_runtime_service_interruption() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var site_id := "earth_sun_lagrange"
	game.state.regions[site_id] = true
	game.state.region_states[site_id] = {"discovered":true, "survey_state":LocationState.DEEP_SURVEYED, "exploration_state":LocationState.DEEP_SURVEYED, "strategic_state":"OPEN", "development_state":"FRONTIER"}
	game.state.location_state(site_id)["survey_state"] = LocationState.DEEP_SURVEYED
	game.state.completed_projects["research_megastructures"] = true
	game.state.technologies["megastructure_engineering"] = true
	game.simulation.ensure_frontier_state(game.state)
	_check(game.initialize_surveyed_factory_world(site_id), "commissioning interruption fixture initializes its physical site Factory")
	var world_id: String = game.factory_world_ids_for_location(site_id)[0]
	var world: Dictionary = game.state.factory_worlds[world_id]
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "commissioning-power").get("ok", false)), "commissioning fixture places physical power")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_repair_dock", Vector2i(20, 0), "", "commissioning-repair").get("ok", false)), "commissioning fixture places physical maintenance coverage")
	var service_link: Dictionary = game.simulation.factory_grid.connect_entities(world, "POWER", "commissioning-power", "commissioning-repair")
	_check(bool(service_link.get("ok", false)), "commissioning maintenance has a physical power edge")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	_check(game.select_megastructure_site("stellar_energy", site_id), "commissioning fixture selects the legal deep-surveyed site")
	var definition: Dictionary = database.megastructures["stellar_energy"]
	var phases: Array = definition.get("phases", [])
	var final_phase_index := phases.size() - 1
	var project: Dictionary = game.state.megastructure_projects["stellar_energy"]
	project["phase_index"] = final_phase_index
	project["stage_index"] = final_phase_index
	project["status"] = "READY"
	project["phase_runtime"] = {}
	project["site_effects"] = {"power_capacity":3400.0, "cooling_capacity":2800.0, "component_storage":3500.0, "logistics_capacity":320.0, "construction_capacity":50.0}
	var phase := phases[final_phase_index] as Dictionary
	var activity: Dictionary = database.activities[str(phase.get("activity_id", ""))]
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		game.state.add_item(str(cost.get("item", "")), int(cost.get("quantity", 0)), site_id)
	_check(game.start_megastructure_phase("stellar_energy", 90), "powered physical maintenance allows commissioning to start")
	project = game.state.megastructure_projects["stellar_energy"]
	var runtime_before: Dictionary = project.get("phase_runtime", {})
	var progress_before := float(runtime_before.get("progress_ms", 0.0))
	var snapshot: Dictionary = game.factory_workspace_snapshot(world_id)
	var removed: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"commissioning-remove-service",
		"kind":"REMOVE_LINK",
		"world_id":world_id,
		"base_topology_revision":int(snapshot.get("topology_revision", -1)),
		"payload":{"link_id":service_link.get("link_id", "")}
	})
	_check(bool(removed.get("accepted", false)), "commissioning fixture removes maintenance power through the public Factory command")
	project = game.state.megastructure_projects["stellar_energy"]
	_check(str(project.get("phase_runtime", {}).get("status", "")) == "BLOCKED" and game.simulation.megastructure_gameplay_state(game.state, "stellar_energy") == "WAITING_SITE_SERVICE", "paused topology command immediately refreshes dependent Megastructure blocker state")
	var blocked_report: Dictionary = game.advance_game_time(float(activity.get("duration_ms", 1.0)) * 1.5)
	project = game.state.megastructure_projects["stellar_energy"]
	var blocked_runtime: Dictionary = project.get("phase_runtime", {})
	_check(
		is_equal_approx(float(blocked_runtime.get("progress_ms", -1.0)), progress_before)
		and str(blocked_runtime.get("status", "")) == "BLOCKED"
		and str(blocked_runtime.get("blocker", {}).get("primary_reason", "")) == "MAINTENANCE_SHORTAGE",
		"Megastructure progress pauses when a required physical service loses power"
	)
	_check(str(project.get("material_flow_status", "")) == "MAINTENANCE_SHORTAGE", "blocked Megastructure keeps its physical site-service reason after Location summary refresh")
	_check(game.simulation.megastructure_gameplay_state(game.state, "stellar_energy") == "WAITING_SITE_SERVICE", "interrupted commissioning exposes the site-service wait state instead of a false active-stage state")
	_check(float(blocked_report.get("unprocessed_ms", 1.0)) <= 0.001, "a blocked Megastructure does not create a false completion boundary or leave requested time unprocessed")
	var reconnected: Dictionary = game.execute_factory_command({
		"protocol_version":1,
		"command_id":"commissioning-restore-service",
		"kind":"CONNECT_ENTITIES",
		"world_id":world_id,
		"base_topology_revision":int(removed.get("topology_revision", -1)),
		"payload":{"link_kind":"POWER", "source_id":"commissioning-power", "target_id":"commissioning-repair"}
	})
	_check(bool(reconnected.get("accepted", false)), "commissioning fixture restores the physical maintenance edge")
	_check(str(game.state.megastructure_projects.get("stellar_energy", {}).get("phase_runtime", {}).get("status", "")) == "BUILDING" and str(game.state.megastructure_projects.get("stellar_energy", {}).get("material_flow_status", "")) == "BUILDING", "paused reconnection immediately resumes the dependent Megastructure runtime and player-facing flow state")
	game.advance_game_time(float(activity.get("duration_ms", 1.0)))
	project = game.state.megastructure_projects["stellar_energy"]
	_check(bool(game.state.megastructures.get("stellar_energy", false)) and str(project.get("status", "")) == "COMPLETE", "Megastructure resumes and completes only after the required service is restored")


func _test_megastructure_same_tick_maintenance_boundary() -> void:
	var game: Variant = get_root().get_node("Game")
	game.persistence_enabled = false
	game.content = database
	game.simulation = SimulationEngine.new(database)
	game.state = SpaceGameState.create_new(database.domains.keys(), database.regions)
	game.simulation.ensure_frontier_state(game.state)
	var site_id := "earth_sun_lagrange"
	game.state.regions[site_id] = true
	game.state.region_states[site_id] = {"discovered":true, "survey_state":LocationState.DEEP_SURVEYED, "exploration_state":LocationState.DEEP_SURVEYED, "strategic_state":"OPEN", "development_state":"FRONTIER"}
	game.state.location_state(site_id)["survey_state"] = LocationState.DEEP_SURVEYED
	game.state.completed_projects["research_megastructures"] = true
	game.state.technologies["megastructure_engineering"] = true
	game.simulation.ensure_frontier_state(game.state)
	_check(game.initialize_surveyed_factory_world(site_id), "same-tick commissioning fixture initializes its physical site Factory")
	var world_id: String = game.factory_world_ids_for_location(site_id)[0]
	var world: Dictionary = game.state.factory_worlds[world_id]
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_solar_array", Vector2i(0, 0), "", "boundary-power").get("ok", false)), "same-tick commissioning fixture places physical power")
	_check(bool(game.simulation.factory_grid.place_entity_immediate(world, "grid_repair_dock", Vector2i(20, 0), "", "boundary-repair").get("ok", false)), "same-tick commissioning fixture places physical maintenance")
	_check(bool(game.simulation.factory_grid.connect_entities(world, "POWER", "boundary-power", "boundary-repair").get("ok", false)), "same-tick commissioning maintenance has a physical power edge")
	game.simulation.factory_grid.advance_world(world, 1000.0)
	_check(game.select_megastructure_site("stellar_energy", site_id), "same-tick commissioning fixture selects the legal site")
	var definition: Dictionary = database.megastructures["stellar_energy"]
	var phases: Array = definition.get("phases", [])
	var final_phase_index := phases.size() - 1
	var project: Dictionary = game.state.megastructure_projects["stellar_energy"]
	project["phase_index"] = final_phase_index
	project["stage_index"] = final_phase_index
	project["status"] = "READY"
	project["phase_runtime"] = {}
	project["site_effects"] = {"power_capacity":3400.0, "cooling_capacity":2800.0, "component_storage":3500.0, "logistics_capacity":320.0, "construction_capacity":50.0}
	var phase := phases[final_phase_index] as Dictionary
	var activity: Dictionary = database.activities[str(phase.get("activity_id", ""))]
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		game.state.add_item(str(cost.get("item", "")), int(cost.get("quantity", 0)), site_id)
	_check(game.start_megastructure_phase("stellar_energy", 90), "same-tick commissioning starts while site maintenance coverage is initially healthy")
	var phase_history_before := (game.state.megastructure_projects.get("stellar_energy", {}).get("phase_history", []) as Array).size()
	var duration := float(activity.get("duration_ms", 1.0))
	game.simulation.refresh_factory_runtime_views(game.state)
	game.simulation.refresh_demand_registry(game.state)
	var boundary_demands: Array = []
	for demand_value in game.state.demand_registry.get("sources", {}).values():
		var demand := demand_value as Dictionary
		if str(demand.get("consumer_type", "")) == "facility_om" and str(demand.get("facility_id", "")) == "repair_dock" and str(demand.get("location_id", "")) == site_id:
			boundary_demands.append(demand)
	_check(boundary_demands.size() == 2, "same-tick commissioning fixture exposes both site-local maintenance streams")
	for demand_value in boundary_demands:
		var demand := demand_value as Dictionary
		var rate := float(demand.get("rate_per_hour", 0.0))
		var boundary_fraction := 1.0 - rate * duration / 3600000.0
		_check(boundary_fraction > 0.0 and boundary_fraction < 1.0, "maintenance fractional state can place its next settlement exactly on commissioning completion")
		game.state.operations_maintenance.get("fractional", {})[str(demand.get("demand_id", ""))] = boundary_fraction
	var blocked_report: Dictionary = game.advance_game_time(duration)
	project = game.state.megastructure_projects["stellar_energy"]
	var blocked_runtime: Dictionary = project.get("phase_runtime", {})
	var blocked_event_types: Array[String] = []
	for event_value in blocked_report.get("events", []):
		blocked_event_types.append(str((event_value as Dictionary).get("type", "")))
	_check(
		str(blocked_runtime.get("status", "")) == "BLOCKED"
		and str(blocked_runtime.get("blocker", {}).get("primary_reason", "")) == "MAINTENANCE_SHORTAGE"
		and is_equal_approx(float(blocked_runtime.get("progress_ms", 0.0)), duration)
		and not blocked_event_types.has("MegastructureStageChanged")
		and not blocked_event_types.has("GameCompleted")
		and (project.get("phase_history", []) as Array).size() == phase_history_before
		and not bool(game.state.game_complete),
		"maintenance expiring on the exact completion tick atomically blocks commissioning instead of completing the game"
	)
	game.state.add_item("repair_material", 2, site_id)
	game.state.add_item("electronics", 2, site_id)
	var completion_report: Dictionary = game.advance_game_time(2.0)
	var completion_event_types: Array[String] = []
	for event_value in completion_report.get("events", []):
		completion_event_types.append(str((event_value as Dictionary).get("type", "")))
	project = game.state.megastructure_projects["stellar_energy"]
	_check(bool(game.state.game_complete) and str(project.get("status", "")) == "COMPLETE" and completion_event_types.count("MegastructureStageChanged") == 1 and completion_event_types.count("GameCompleted") == 1 and (project.get("phase_history", []) as Array).size() == phase_history_before + 1, "one post-replenishment time window commits the phase and completion events exactly once")


func _workspace_entity(snapshot: Dictionary, entity_id: String) -> Dictionary:
	for entity_value in snapshot.get("entities", []):
		var entity := entity_value as Dictionary
		if str(entity.get("id", "")) == entity_id:
			return entity
	return {}


func _check(condition: bool, message: String) -> void:
	if not condition and not failures.has(message):
		failures.append(message)


func _first_value_difference(left: Variant, right: Variant, path: String) -> String:
	if typeof(left) != typeof(right):
		return "%s type %s != %s" % [path, type_string(typeof(left)), type_string(typeof(right))]
	if left is Dictionary:
		var left_dictionary := left as Dictionary
		var right_dictionary := right as Dictionary
		if left_dictionary.size() != right_dictionary.size():
			return "%s dictionary size %d != %d" % [path, left_dictionary.size(), right_dictionary.size()]
		var keys: Array = left_dictionary.keys()
		keys.sort()
		for key_value in keys:
			if not right_dictionary.has(key_value):
				return "%s missing key %s" % [path, str(key_value)]
			var nested := _first_value_difference(left_dictionary[key_value], right_dictionary[key_value], "%s.%s" % [path, str(key_value)])
			if not nested.is_empty():
				return nested
		return ""
	if left is Array:
		var left_array := left as Array
		var right_array := right as Array
		if left_array.size() != right_array.size():
			return "%s array size %d != %d" % [path, left_array.size(), right_array.size()]
		for index in left_array.size():
			var nested := _first_value_difference(left_array[index], right_array[index], "%s[%d]" % [path, index])
			if not nested.is_empty():
				return nested
		return ""
	if left != right:
		return "%s %s != %s" % [path, str(left), str(right)]
	return ""


func _finish() -> void:
	if failures.is_empty():
		print("PASS: versioned Factory workspace snapshot, commands and events")
		quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	quit(1)
