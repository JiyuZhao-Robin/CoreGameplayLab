extends Node

signal state_changed
signal domain_event(event: Dictionary)
signal command_rejected(reason: String)

const CONTENT_PATH := "res://data/content.json"
const AUTOSAVE_INTERVAL_MS := 15000.0
const SIMULATION_STEP_MS := 100.0
const MAX_TIME_ORCHESTRATION_STEPS := 500000
const MAX_ONLINE_FRAME_SIMULATION_MS := 15000.0
const MIN_TIME_ORCHESTRATION_STEP_MS := 0.01

var content := ContentDatabase.new()
var state: SpaceGameState
var simulation: SimulationEngine
var saves := LocalSaveRepository.new()
var offline_report := {}
var last_notice := ""
var last_saved_ship_design_id := ""
var last_created_formation_id := ""
var persistence_enabled := not OS.get_cmdline_user_args().has("--no-persistence")

var _simulation_accumulator_ms := 0.0
var _autosave_accumulator_ms := 0.0


func _ready() -> void:
	var persistence_audit_root := _persistence_audit_root()
	if not persistence_audit_root.is_empty() and not saves.configure_audit_root(persistence_audit_root):
		push_error("Rejected unsafe persistence audit root")
		persistence_enabled = false
	if not content.load_from_file(CONTENT_PATH):
		push_error("Content validation failed:\n%s" % "\n".join(content.errors))
	simulation = SimulationEngine.new(content)
	if persistence_enabled:
		_load_or_create_state()
	else:
		state = SpaceGameState.create_new(content.domains.keys(), content.regions)
	simulation.ensure_frontier_state(state)
	if last_notice.is_empty():
		last_notice = I18n.t("notice.frontier_ready", "Ships are persistent capital assets. Organize tactical formations for combat and exploration; factories own collection and production.")
	set_process(true)


func _persistence_audit_root() -> String:
	for argument_value in OS.get_cmdline_user_args():
		var argument := String(argument_value)
		if argument.begins_with("--ui-persistence-root="):
			var candidate := argument.trim_prefix("--ui-persistence-root=").simplify_path()
			if candidate.is_absolute_path() and candidate.get_file().begins_with("helios-ui-persistence-audit-"):
				return candidate
	return ""


func _process(delta: float) -> void:
	var elapsed_ms := delta * 1000.0
	_simulation_accumulator_ms += elapsed_ms
	_autosave_accumulator_ms += elapsed_ms
	if _simulation_accumulator_ms >= SIMULATION_STEP_MS:
		# Keep high-speed online play responsive when many short economic
		# boundaries are active. Any remainder stays as deterministic debt for the
		# following frames; no time is discarded and explicit/offline simulation
		# continues to use the full requested window.
		var frame_request := minf(_simulation_accumulator_ms, MAX_ONLINE_FRAME_SIMULATION_MS)
		var report := advance_game_time(frame_request)
		_simulation_accumulator_ms = maxf(0.0, _simulation_accumulator_ms - frame_request + float(report.get("unprocessed_ms", 0.0)))
		var events: Array = report.get("events", [])
		_publish_events(events)
		if not events.is_empty():
			state_changed.emit()
	if persistence_enabled and _autosave_accumulator_ms >= AUTOSAVE_INTERVAL_MS:
		save_game()
		_autosave_accumulator_ms = 0.0


func _notification(what: int) -> void:
	if persistence_enabled and (what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED):
		save_game()


func initialize_factory_world(world_id: String, location_id: String, size_tiles: Vector2i, seed: int = 1) -> bool:
	if world_id.is_empty() or not state.has_location(location_id) or size_tiles.x <= 0 or size_tiles.y <= 0:
		return _reject(I18n.t("notice.factory_world_invalid", "Invalid factory world identity, location or bounds"))
	if state.factory_worlds.has(world_id):
		return _reject(I18n.t("notice.factory_world_exists", "Factory world already exists"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.factory_worlds[world_id] = simulation.factory_grid.create_world(world_id, location_id, size_tiles, seed)
	transaction.record({"type":"FactoryWorldInitialized", "world_id":world_id, "location_id":location_id, "size_tiles":{"x":size_tiles.x, "y":size_tiles.y}, "seed":seed})
	last_notice = I18n.t("notice.factory_world_initialized", "Factory grid initialized: %s") % world_id
	_commit_transaction(transaction)
	return true


func register_factory_resource_field(world_id: String, resource_field_id: String, resource_id: String, origin: Vector2i, size: Vector2i, grade: float = 1.0, potential_density: float = 1.0, resource_category: String = "solid") -> bool:
	if not state.factory_worlds.has(world_id) or not content.items.has(resource_id):
		return _reject(I18n.t("notice.factory_resource_unknown", "Unknown factory world or resource"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var result: Dictionary = simulation.factory_grid.add_resource_field(transaction.working_state.factory_worlds[world_id], resource_field_id, resource_id, origin, size, grade, potential_density, resource_category)
	if not bool(result.get("ok", false)):
		return _reject(str(result.get("reason", I18n.t("notice.factory_resource_failed", "Resource-field generation failed"))))
	transaction.record({"type":"FactoryResourceFieldRegistered", "world_id":world_id, "resource_field_id":resource_field_id, "resource_id":resource_id})
	last_notice = I18n.t("notice.factory_resource_registered", "Tile resource field registered: %s") % resource_field_id
	_commit_transaction(transaction)
	return true


func queue_factory_construction(world_id: String, definition_id: String, origin: Vector2i, recipe_id: String = "", priority: int = 50) -> bool:
	if not state.factory_worlds.has(world_id) or not content.factory_buildings.has(definition_id):
		return _reject(I18n.t("notice.factory_building_unknown", "Unknown factory world or building"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var result: Dictionary = simulation.factory_grid.queue_construction(transaction.working_state.factory_worlds[world_id], definition_id, origin, recipe_id, priority)
	if not bool(result.get("ok", false)):
		return _reject(str(result.get("reason", I18n.t("notice.factory_construction_rejected", "Factory construction rejected"))))
	transaction.record({"type":"FactoryConstructionQueued", "world_id":world_id, "order_id":result.get("order_id", ""), "definition_id":definition_id, "origin":{"x":origin.x, "y":origin.y}})
	last_notice = I18n.t("notice.factory_construction_queued", "Factory construction queued: %s") % definition_id
	_commit_transaction(transaction)
	return true


func fund_factory_construction(world_id: String, order_id: String, storage_id: String) -> bool:
	if not state.factory_worlds.has(world_id):
		return _reject(I18n.t("notice.factory_world_unknown", "Unknown factory world"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var result: Dictionary = simulation.factory_grid.fund_construction_from_storage(transaction.working_state.factory_worlds[world_id], order_id, storage_id)
	if not bool(result.get("ok", false)):
		return _reject(str(result.get("reason", I18n.t("notice.factory_funding_failed", "Construction funding failed"))))
	transaction.record({"type":"FactoryConstructionFunded", "world_id":world_id, "order_id":order_id, "storage_id":storage_id, "moved":result.get("moved", {})})
	last_notice = I18n.t("notice.factory_materials_delivered", "Construction materials delivered: %s") % order_id
	_commit_transaction(transaction)
	return true


func connect_factory_entities(world_id: String, kind: String, source_id: String, target_id: String, item_id: String = "", capacity_per_second: float = 1.0, priority: int = 1) -> bool:
	if not state.factory_worlds.has(world_id):
		return _reject(I18n.t("notice.factory_world_unknown", "Unknown factory world"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var result: Dictionary = simulation.factory_grid.connect_entities(transaction.working_state.factory_worlds[world_id], kind, source_id, target_id, item_id, capacity_per_second, priority)
	if not bool(result.get("ok", false)):
		return _reject(str(result.get("reason", I18n.t("notice.factory_connection_rejected", "Factory connection rejected"))))
	transaction.record({"type":"FactoryEntitiesConnected", "world_id":world_id, "link_id":result.get("link_id", ""), "kind":kind, "source_id":source_id, "target_id":target_id, "item_id":item_id})
	last_notice = I18n.t("notice.factory_connection_created", "Factory connection created")
	_commit_transaction(transaction)
	return true


func factory_tile_snapshot(world_id: String, tile: Vector2i) -> Dictionary:
	if not state.factory_worlds.has(world_id):
		return {"valid":false, "reason_code":"UNKNOWN_FACTORY_WORLD"}
	return simulation.factory_grid.tile_snapshot(state.factory_worlds[world_id], tile)


func factory_tile_view_snapshot(world_id: String, tile: Vector2i, view_mode: String = "TERRAIN") -> Dictionary:
	if not state.factory_worlds.has(world_id):
		return {"valid":false, "reason_code":"UNKNOWN_FACTORY_WORLD"}
	return simulation.factory_grid.tile_view_snapshot(state.factory_worlds[world_id], tile, view_mode)


func factory_world_summary(world_id: String) -> Dictionary:
	if not state.factory_worlds.has(world_id):
		return {}
	return simulation.factory_grid.world_summary(state.factory_worlds[world_id])


func _reject_removed_aggregate_industry() -> bool:
	return _reject(I18n.t("notice.aggregate_industry_removed", "The location-level mining, Production Line and generic Construction runtime has been removed. Use the factory grid."))


func start_activity(domain_id: String, activity_id: String, formation_id: String = SpaceGameState.DEFAULT_FORMATION_ID) -> bool:
	if not state.domains.has(domain_id) or not content.activities.has(activity_id):
		return _reject(I18n.t("notice.unknown_activity", "Unknown activity command"))
	var activity: Dictionary = content.activities[activity_id]
	if str(activity.get("domain", "")) != domain_id:
		return _reject(I18n.t("notice.wrong_domain", "Activity does not belong to this operation type"))
	if domain_id == "industry" or simulation.is_construction_activity(activity):
		return _reject_removed_aggregate_industry()
	if domain_id != "expedition":
		return _reject(I18n.t("notice.unknown_domain", "Unknown operation type"))
	if not simulation.activity_available(state, activity):
		return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	if not simulation.costs_available(state, activity):
		return _reject(I18n.t("notice.resources", "Strategic Inventory cannot fund one cycle"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working := transaction.working_state
	if not _start_expedition(working, activity, formation_id):
		return false
	last_notice = I18n.t("notice.started", "%s started: %s") % [I18n.content(content.domains[domain_id]), I18n.content(activity)]
	transaction.record({"type":"OperationStarted", "domain":domain_id, "activity_id":activity_id})
	_commit_transaction(transaction)
	return true


func stop_activity(domain_id: String) -> bool:
	if not state.domains.has(domain_id):
		return _reject(I18n.t("notice.unknown_domain", "Unknown operation type"))
	if domain_id == "industry":
		return _reject_removed_aggregate_industry()
	if domain_id != "expedition":
		return _reject(I18n.t("notice.unknown_domain", "Unknown operation type"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime := simulation.runtime_for_domain(transaction.working_state, domain_id)
	if runtime.is_empty() or runtime.get("status", "IDLE") == "IDLE":
		return _reject(I18n.t("notice.no_active", "No active operation to pause"))
	_release_runtime_ships(transaction.working_state, runtime)
	runtime["activity_id"] = ""
	runtime["progress_ms"] = 0.0
	runtime["status"] = "IDLE"
	runtime["reserved_costs"] = {}
	if domain_id == "expedition":
		var active_formation_id := str(runtime.get("formation_id", SpaceGameState.DEFAULT_FORMATION_ID))
		simulation.unload_fleet_cargo(transaction.working_state, active_formation_id, SpaceGameState.MAIN_BASE_LOCATION_ID, false)
		runtime["phase"] = "IDLE"
		runtime["route_id"] = ""
		runtime["node_index"] = 0
		runtime["node_progress_ms"] = 0.0
		runtime["combat_state"] = {}
	last_notice = I18n.t("notice.paused", "%s operation recalled") % I18n.content(content.domains[domain_id])
	transaction.record({"type":"OperationStopped", "domain":domain_id})
	_commit_transaction(transaction)
	return true


func set_ship_maintenance_state(instance_id: String, maintenance_state: String) -> bool:
	var normalized := maintenance_state.to_upper()
	if normalized not in ["ACTIVE", "READY_RESERVE", "MOTHBALLED"]:
		return _reject(I18n.t("notice.maintenance_state_invalid", "Invalid maintenance state"))
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty() or str(ship.get("status", "")) != "DOCKED" or str(ship.get("condition", "")) != "OPERATIONAL":
		return _reject(I18n.t("notice.maintenance_state_locked", "The ship must be operational and docked before changing maintenance state"))
	var current := str(ship.get("maintenance_state", "ACTIVE"))
	if current == normalized:
		return true
	if current == "MOTHBALLED":
		return _reject(I18n.t("notice.maintenance_reactivation_required", "A mothballed ship must complete a Starport reactivation project"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	for formation_id in transaction.working_state.formation_ids():
		var roster := transaction.working_state.formation_ship_ids(formation_id)
		roster.erase(instance_id)
		transaction.working_state.set_formation_ship_ids(formation_id, roster)
	var working_ship := transaction.working_state.ship_by_id(instance_id)
	working_ship["maintenance_state"] = normalized
	working_ship["assignment"] = {}
	last_notice = I18n.t("notice.maintenance_state_changed", "Maintenance state changed: %s → %s") % [working_ship.get("name", instance_id), I18n.status(normalized)]
	transaction.record({"type":"ShipMaintenanceStateChanged", "ship_id":instance_id, "maintenance_state":normalized})
	_commit_transaction(transaction)
	return true


func start_ship_reactivation(instance_id: String) -> bool:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty() or str(ship.get("maintenance_state", "")) != "MOTHBALLED" or str(ship.get("status", "")) != "DOCKED":
		return _reject(I18n.t("notice.reactivation_ship_invalid", "Only a docked mothballed ship can be reactivated"))
	var running_projects := state.ship_service_projects.filter(func(project): return str(project.get("status", "")) == "RUNNING").size()
	if running_projects >= simulation.ship_service_capacity(state):
		return _reject(I18n.t("notice.ship_service_capacity_full", "Starport and repair-dock service capacity is fully committed"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working_ship := transaction.working_state.ship_by_id(instance_id)
	var costs := simulation.ship_reactivation_costs(working_ship)
	var location_id := str(working_ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	for item_id in costs:
		if transaction.working_state.available_item_quantity(str(item_id), location_id) < int(costs[item_id]):
			return _reject(I18n.t("notice.reactivation_materials", "Reactivation materials are insufficient: %s × %d") % [I18n.content(content.items.get(str(item_id), {"id":item_id, "name":item_id})), int(costs[item_id])])
	for item_id in costs:
		transaction.working_state.remove_item(str(item_id), int(costs[item_id]), location_id)
	var project_id := "SERVICE-%06d" % (transaction.working_state.ship_service_projects.size() + int(transaction.working_state.statistics.get("ships_reactivated", 0)) + 1)
	transaction.working_state.ship_service_projects.append({
		"project_id":project_id,
		"project_kind":"REACTIVATION",
		"ship_id":instance_id,
		"status":"RUNNING",
		"progress_ms":0.0,
		"duration_ms":simulation.ship_reactivation_duration_ms(transaction.working_state, working_ship),
		"consumed_materials":costs,
		"location_id":location_id,
		"started_at_ms":int(transaction.working_state.total_elapsed_ms)
	})
	working_ship["status"] = "REACTIVATING"
	working_ship["assignment"] = {"type":"STARPORT_REACTIVATION", "project_id":project_id}
	transaction.working_state.statistics["ships_reactivated"] = int(transaction.working_state.statistics.get("ships_reactivated", 0)) + 1
	last_notice = I18n.t("notice.reactivation_started", "Mothball reactivation started: %s") % working_ship.get("name", instance_id)
	transaction.record({"type":"ShipReactivationStarted", "project_id":project_id, "ship_id":instance_id, "costs":costs})
	_commit_transaction(transaction)
	return true


func set_ship_favorite(instance_id: String, favorite: bool) -> bool:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing"))
	if bool(ship.get("favorite", false)) == favorite:
		return true
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.ship_by_id(instance_id)["favorite"] = favorite
	last_notice = I18n.t("notice.ship_favorited" if favorite else "notice.ship_unfavorited") % str(ship.get("name", instance_id))
	transaction.record({"type":"ShipFavoriteChanged", "ship_id":instance_id, "favorite":favorite})
	_commit_transaction(transaction)
	return true


func set_ship_locked(instance_id: String, locked: bool) -> bool:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing"))
	if bool(ship.get("locked", false)) == locked:
		return true
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.ship_by_id(instance_id)["locked"] = locked
	last_notice = I18n.t("notice.ship_locked" if locked else "notice.ship_unlocked") % str(ship.get("name", instance_id))
	transaction.record({"type":"ShipLockChanged", "ship_id":instance_id, "locked":locked})
	_commit_transaction(transaction)
	return true


func ship_scrap_availability(instance_id: String) -> Dictionary:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return {"allowed":false, "reason_code":"SHIP_MISSING", "reason":I18n.t("notice.ship_missing"), "recovery":{}}
	if bool(ship.get("locked", false)):
		return {"allowed":false, "reason_code":"SHIP_LOCKED", "reason":I18n.t("notice.scrap_ship_locked"), "recovery":{}}
	if str(ship.get("status", "")) != "DOCKED":
		return {"allowed":false, "reason_code":"SHIP_NOT_DOCKED", "reason":I18n.t("notice.scrap_ship_invalid"), "recovery":{}}
	if not state.ship_formation_id(instance_id).is_empty() or state.refit_projects.any(func(project): return str(project.get("ship_id", "")) == instance_id) or state.ship_service_projects.any(func(project): return str(project.get("ship_id", "")) == instance_id):
		return {"allowed":false, "reason_code":"SHIP_ASSIGNED", "reason":I18n.t("notice.scrap_ship_assigned"), "recovery":{}}
	var recovered := simulation.ship_scrap_recovery(ship)
	var location_id := str(ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	if not simulation.storage_can_apply_transaction(state, location_id, recovered):
		return {"allowed":false, "reason_code":"STORAGE_FULL", "reason":I18n.t("notice.scrap_storage_full"), "recovery":recovered, "location_id":location_id}
	return {"allowed":true, "reason_code":"READY", "reason":"", "recovery":recovered, "location_id":location_id}


func scrap_ship(instance_id: String) -> bool:
	# Re-run the complete guard at commit time. UI disabled state and confirmation
	# previews are advisory; direct calls and stale dialogs use this same boundary.
	var availability := ship_scrap_availability(instance_id)
	if not bool(availability.get("allowed", false)):
		return _reject(str(availability.get("reason", I18n.t("notice.scrap_ship_invalid"))))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working_ship := transaction.working_state.ship_by_id(instance_id)
	var recovered: Dictionary = availability.get("recovery", {}).duplicate(true)
	var location_id := str(availability.get("location_id", working_ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)))
	var archive_entry := {
		"ship_id":instance_id,
		"name":str(working_ship.get("name", instance_id)),
		"blueprint_id":str(working_ship.get("blueprint_id", "")),
		"commissioned_at_ms":int(working_ship.get("commissioned_at_ms", 0)),
		"scrapped_at_ms":int(transaction.working_state.total_elapsed_ms),
		"current_loadout_id":str(working_ship.get("current_loadout_id", "")),
		"module_definitions":transaction.working_state.ship_module_definition_ids(working_ship),
		"service_record":working_ship.get("service_record", {}).duplicate(true),
		"recovered_materials":recovered.duplicate(true)
	}
	for module_value in working_ship.get("modules", []).duplicate():
		var equipment_id := str(module_value)
		if transaction.working_state.equipment_instances.has(equipment_id):
			transaction.working_state.store_equipment_instance(equipment_id)
	for index in range(transaction.working_state.ships.size() - 1, -1, -1):
		if str(transaction.working_state.ships[index].get("instance_id", "")) == instance_id:
			transaction.working_state.ships.remove_at(index)
			break
	for item_id in recovered:
		transaction.working_state.add_item(str(item_id), int(recovered[item_id]), location_id)
	for fleet_id in transaction.working_state.fleet_logistics:
		transaction.working_state.fleet_logistics_runtime(str(fleet_id)).get("formation", {}).get("ship_zones", {}).erase(instance_id)
	for field in ["fractional", "debt", "coverage"]:
		transaction.working_state.fleet_maintenance.get(field, {}).erase(instance_id)
	transaction.working_state.naval_archive.append(archive_entry)
	transaction.working_state.statistics["ships_scrapped"] = int(transaction.working_state.statistics.get("ships_scrapped", 0)) + 1
	last_notice = I18n.t("notice.ship_scrapped", "Ship scrapped and archived: %s") % archive_entry["name"]
	transaction.record({"type":"ShipScrapped", "ship_id":instance_id, "recovered":recovered})
	_commit_transaction(transaction)
	return true


func ship_formation_assignment_availability(instance_id: String, formation_id: String) -> Dictionary:
	if not formation_id.is_empty() and not state.fleet_formations.has(formation_id):
		return {"allowed":false, "reason_code":"UNKNOWN_ASSIGNMENT", "reason":I18n.t("notice.ship_assignment_unknown", "Unknown ship assignment")}
	var ship: Dictionary = state.ship_by_id(instance_id)
	if ship.is_empty():
		return {"allowed":false, "reason_code":"SHIP_MISSING", "reason":I18n.t("notice.ship_missing", "Ship instance was not found")}
	if not state.ship_is_docked(instance_id):
		return {"allowed":false, "reason_code":"SHIP_NOT_DOCKED", "reason":I18n.t("notice.ship_assignment_locked", "The ship must be operational and docked before changing assignment")}
	if not formation_id.is_empty() and (str(ship.get("maintenance_state", "ACTIVE")) != "ACTIVE" or float(ship.get("maintenance_coverage", 1.0)) <= 0.0):
		return {"allowed":false, "reason_code":"MAINTENANCE_REQUIRED", "reason":I18n.t("notice.fleet_ship_maintenance_required", "Only a fully maintained active ship can join an operational fleet")}
	var current_formation_id := state.ship_formation_id(instance_id)
	if current_formation_id == formation_id:
		return {"allowed":true, "reason_code":"ALREADY_ASSIGNED", "reason":""}
	if (not current_formation_id.is_empty() and formation_is_active(current_formation_id)) or (not formation_id.is_empty() and formation_is_active(formation_id)):
		return {"allowed":false, "reason_code":"FLEET_ACTIVE", "reason":I18n.t("notice.fleet_active", "Recall or stop the active fleet before changing its roster")}
	if not formation_id.is_empty():
		var projected_roster := state.formation_ship_ids(formation_id)
		projected_roster.erase(instance_id)
		projected_roster.append(instance_id)
		if simulation.fleet_command_usage(state, projected_roster) > simulation.fleet_command_capacity(state, formation_id):
			return {"allowed":false, "reason_code":"COMMAND_CAPACITY", "reason":I18n.t("notice.command_capacity", "Fleet Command Capacity would be exceeded")}
	return {"allowed":true, "reason_code":"READY", "reason":""}


func create_fleet_formation(formation_name: String) -> bool:
	var normalized_name := formation_name.strip_edges()
	if normalized_name.is_empty() or normalized_name.length() > 32:
		return _reject(I18n.t("notice.formation_name_invalid", "Formation name must contain 1–32 characters"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var serial := maxi(2, transaction.working_state.next_formation_serial)
	var formation_id := "task_force_%d" % serial
	while transaction.working_state.fleet_formations.has(formation_id):
		serial += 1
		formation_id = "task_force_%d" % serial
	transaction.working_state.next_formation_serial = serial + 1
	transaction.working_state.fleet_formations[formation_id] = {"id":formation_id, "name":normalized_name, "ship_ids":[]}
	transaction.working_state.fleet_logistics_runtime(formation_id)
	last_created_formation_id = formation_id
	last_notice = I18n.t("notice.formation_created", "Tactical formation created: %s") % normalized_name
	transaction.record({"type":"FleetFormationCreated", "formation_id":formation_id, "name":normalized_name})
	_commit_transaction(transaction)
	return true


func delete_fleet_formation(formation_id: String) -> bool:
	if formation_id == SpaceGameState.DEFAULT_FORMATION_ID or not state.fleet_formations.has(formation_id):
		return _reject(I18n.t("notice.formation_delete_invalid", "The primary formation cannot be deleted"))
	if formation_is_active(formation_id) or not state.formation_ship_ids(formation_id).is_empty():
		return _reject(I18n.t("notice.formation_delete_busy", "Recall the formation and move all ships to reserve before deleting it"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var formation_name := str(transaction.working_state.formation_runtime(formation_id).get("name", formation_id))
	transaction.working_state.fleet_formations.erase(formation_id)
	transaction.working_state.fleet_logistics.erase(formation_id)
	last_notice = I18n.t("notice.formation_deleted", "Tactical formation deleted: %s") % formation_name
	transaction.record({"type":"FleetFormationDeleted", "formation_id":formation_id})
	_commit_transaction(transaction)
	return true


func set_ship_formation_assignment(instance_id: String, formation_id: String) -> bool:
	var availability := ship_formation_assignment_availability(instance_id, formation_id)
	if not bool(availability.get("allowed", false)):
		return _reject(str(availability.get("reason", I18n.t("notice.ship_assignment_unknown", "Unknown ship assignment"))))
	var current_formation_id := state.ship_formation_id(instance_id)
	if current_formation_id == formation_id:
		return true
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	for candidate_formation_id in transaction.working_state.formation_ids():
		var roster := transaction.working_state.formation_ship_ids(candidate_formation_id)
		roster.erase(instance_id)
		transaction.working_state.set_formation_ship_ids(candidate_formation_id, roster)
	if not formation_id.is_empty():
		var target_roster := transaction.working_state.formation_ship_ids(formation_id)
		target_roster.append(instance_id)
		transaction.working_state.set_formation_ship_ids(formation_id, target_roster)
	var working_ship := transaction.working_state.ship_by_id(instance_id)
	working_ship["assignment"] = {} if formation_id.is_empty() else {"formation_id":formation_id}
	var assignment_name := I18n.t("ships.unassigned", "Unassigned") if formation_id.is_empty() else (I18n.t("ships.formation.primary", "First Task Force") if formation_id == SpaceGameState.DEFAULT_FORMATION_ID else str(transaction.working_state.formation_runtime(formation_id).get("name", formation_id)))
	last_notice = I18n.t("notice.ship_assignment_changed", "%s assignment changed to %s") % [I18n.content(content.ships.get(str(working_ship.get("blueprint_id", "")), {})), assignment_name]
	transaction.record({"type":"ShipFormationAssignmentChanged", "ship_id":instance_id, "formation_id":formation_id})
	_commit_transaction(transaction)
	return true


func formation_is_active(formation_id: String) -> bool:
	return state.active_expedition.get("status", "IDLE") == "RUNNING" and str(state.active_expedition.get("formation_id", SpaceGameState.DEFAULT_FORMATION_ID)) == formation_id


func formation_ready(formation_id: String = SpaceGameState.DEFAULT_FORMATION_ID) -> bool:
	var ship_ids := state.formation_ship_ids(formation_id)
	if ship_ids.is_empty():
		return false
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		if not state.ship_is_docked(str(ship_id)) or state.ship_formation_id(str(ship_id)) != formation_id or str(ship.get("maintenance_state", "ACTIVE")) != "ACTIVE" or float(ship.get("maintenance_coverage", 1.0)) <= 0.0:
			return false
	return true


func set_fleet_supply_plan(item_id: String, quantity: int, fleet_id: String = SpaceGameState.DEFAULT_FORMATION_ID) -> bool:
	if not content.items.has(item_id) or quantity < 0:
		return _reject(I18n.t("notice.supply_plan_invalid", "Invalid fleet supply plan"))
	var current_plan: Dictionary = state.fleet_logistics_runtime(fleet_id).get("supply_plan", {})
	if int(current_plan.get(item_id, 0)) == quantity:
		return _reject(I18n.t("notice.supply_plan_unchanged", "The fleet supply target is already set to this quantity"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var logistics := transaction.working_state.fleet_logistics_runtime(fleet_id)
	var plan: Dictionary = logistics.get("supply_plan", {})
	plan[item_id] = quantity
	logistics["supply_plan"] = plan
	transaction.record({"type":"FleetSupplyPlanChanged", "fleet_id":fleet_id, "item_id":item_id, "quantity":quantity})
	_commit_transaction(transaction)
	return true


func set_ship_combat_zone(ship_id: String, zone: String, fleet_id: String = SpaceGameState.DEFAULT_FORMATION_ID) -> bool:
	var normalized_zone := zone.to_upper()
	if normalized_zone not in ["FRONT", "MID", "REAR"] or state.ship_by_id(ship_id).is_empty() or state.ship_formation_id(ship_id) != fleet_id:
		return _reject(I18n.t("notice.combat_zone_invalid", "Invalid ship or combat zone"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var formation: Dictionary = transaction.working_state.fleet_logistics_runtime(fleet_id).get("formation", {})
	var ship_zones: Dictionary = formation.get("ship_zones", {})
	ship_zones[ship_id] = normalized_zone
	formation["ship_zones"] = ship_zones
	transaction.working_state.fleet_logistics_runtime(fleet_id)["formation"] = formation
	transaction.record({"type":"ShipCombatZoneChanged", "fleet_id":fleet_id, "ship_id":ship_id, "zone":normalized_zone})
	_commit_transaction(transaction)
	return true


func set_fleet_doctrine(doctrine: String, fleet_id: String = SpaceGameState.DEFAULT_FORMATION_ID) -> bool:
	var normalized := doctrine.to_upper()
	if normalized not in ["HOLD_FORMATION", "AGGRESSIVE_PUSH", "MISSILE_SATURATION", "LONG_RANGE_ENGAGEMENT"]:
		return _reject(I18n.t("notice.fleet_doctrine_invalid", "Invalid fleet doctrine"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var formation: Dictionary = transaction.working_state.fleet_logistics_runtime(fleet_id).get("formation", {})
	formation["doctrine"] = normalized
	transaction.working_state.fleet_logistics_runtime(fleet_id)["formation"] = formation
	transaction.record({"type":"FleetDoctrineChanged", "fleet_id":fleet_id, "doctrine":normalized})
	_commit_transaction(transaction)
	return true


func set_fleet_retreat_policy(mode: String, threshold: float = 0.25, fleet_id: String = SpaceGameState.DEFAULT_FORMATION_ID) -> bool:
	var normalized := mode.to_upper()
	if normalized not in ["HULL_THRESHOLD", "NEVER"]:
		return _reject(I18n.t("notice.retreat_policy_invalid", "Invalid retreat policy"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var formation: Dictionary = transaction.working_state.fleet_logistics_runtime(fleet_id).get("formation", {})
	formation["retreat_policy"] = {"mode":normalized, "threshold":clampf(threshold, 0.05, 0.95)}
	transaction.working_state.fleet_logistics_runtime(fleet_id)["formation"] = formation
	transaction.record({"type":"FleetRetreatPolicyChanged", "fleet_id":fleet_id, "mode":normalized, "threshold":clampf(threshold, 0.05, 0.95)})
	_commit_transaction(transaction)
	return true


func auto_resupply_fleet(fleet_id: String = SpaceGameState.DEFAULT_FORMATION_ID, ship_ids: Array = []) -> bool:
	var selected := ship_ids.duplicate()
	if selected.is_empty():
		selected = state.formation_ship_ids(fleet_id)
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	_auto_resupply_state(transaction.working_state, fleet_id, selected)
	last_notice = I18n.t("notice.fleet_resupplied", "Available supplies loaded according to the saved fleet plan")
	transaction.record({"type":"FleetResupplied", "fleet_id":fleet_id, "ship_ids":selected})
	_commit_transaction(transaction)
	return true


func start_survey_mission(target_location_id: String, target_state: String, ship_ids: Array = [], origin_location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> bool:
	simulation.ensure_frontier_state(state)
	var availability := survey_mission_availability(target_location_id, target_state, ship_ids, origin_location_id)
	if not bool(availability.get("allowed", false)):
		return _reject(I18n.t("notice.survey_mission_blocked", "The survey mission cannot start; verify survey state, vessel capability, fuel and maintenance supplies"))
	var selected: Array = availability.get("selected_ship_ids", []).duplicate()
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.start_survey_mission(transaction.working_state, target_location_id, target_state, selected, origin_location_id):
		return _reject(I18n.t("notice.survey_mission_blocked", "The survey mission cannot start; verify survey state, vessel capability, fuel and maintenance supplies"))
	last_notice = I18n.t("notice.survey_mission_started", "Survey mission started: %s → %s") % [I18n.content(content.regions.get(target_location_id, {"id":target_location_id, "name":target_location_id})), I18n.status(target_state)]
	transaction.record({"type":"SurveyMissionStarted", "target":target_location_id, "target_state":target_state, "origin":origin_location_id, "ship_ids":selected})
	_commit_transaction(transaction)
	return true


func _auto_resupply_state(working: SpaceGameState, fleet_id: String, ship_ids: Array) -> void:
	var logistics := working.fleet_logistics_runtime(fleet_id)
	var available_space := maxi(0, simulation.fleet_cargo_capacity(working, ship_ids) - simulation.fleet_cargo_used(working, fleet_id))
	for item_id in logistics.get("supply_plan", {}):
		if available_space <= 0:
			break
		var desired := maxi(0, int(logistics["supply_plan"].get(item_id, 0)))
		var missing := maxi(0, desired - working.fleet_supply_quantity(str(item_id), fleet_id))
		var transfer := working.transfer_inventory_to_fleet_supply(str(item_id), mini(missing, available_space), fleet_id)
		if transfer <= 0:
			continue
		available_space -= transfer


func stop_industry_operation(slot: int) -> bool:
	return _reject_removed_aggregate_industry()


func start_industry_operation(slot: int, activity_id: String) -> bool:
	return _reject_removed_aggregate_industry()


func add_production_line(location_id: String, facility_id: String, activity_id: String, capacity_allocation: int = 100, priority: int = 50) -> bool:
	return _reject_removed_aggregate_industry()


func configure_production_line(slot: int, capacity_allocation: int, priority: int) -> bool:
	return _reject_removed_aggregate_industry()


func set_production_line_control(slot: int, control_mode: String, manual_lock: bool = true) -> bool:
	return _reject_removed_aggregate_industry()


func add_automation_rule(condition: Dictionary, action: Dictionary, cooldown_ms: float = 30000.0, hysteresis: float = 0.05) -> bool:
	return _reject_removed_aggregate_industry()


func authorize_storage_guard(slot: int, location_id: String) -> bool:
	return _reject_removed_aggregate_industry()


func set_automation_rule_paused(rule_id: String, paused: bool) -> bool:
	return _reject_removed_aggregate_industry()


func revoke_automation_rule(rule_id: String) -> bool:
	return _reject_removed_aggregate_industry()


func run_automation_rules() -> int:
	return 0


func advance_game_time(elapsed_ms: float) -> Dictionary:
	var requested := maxf(0.0, elapsed_ms)
	var remaining := requested
	var simulated := 0.0
	var operations := 0
	var events: Array = []
	var steps := 0
	while remaining > 0.001 and steps < MAX_TIME_ORCHESTRATION_STEPS:
		var next_boundary := simulation.next_state_change_ms(state)
		# SimulationEngine treats windows <= 0.001 ms as settled tolerance. Passing
		# that exact value would process zero time and permanently retain the whole
		# caller window whenever a ready Cycle reports the minimum boundary.
		var step := remaining if next_boundary == INF else minf(remaining, maxf(MIN_TIME_ORCHESTRATION_STEP_MS, next_boundary))
		var partial := simulation.advance(state, step)
		var processed := float(partial.get("simulated_ms", 0.0))
		if processed <= 0.0:
			break
		simulated += processed
		remaining -= processed
		operations += int(partial.get("operations", 0))
		events.append_array(partial.get("events", []))
		steps += 1
	return {
		"simulated_ms":simulated,
		"unprocessed_ms":maxf(0.0, remaining),
		"operations":operations,
		"events":events,
		"orchestration_steps":steps,
		"operation_limit_reached":steps >= MAX_TIME_ORCHESTRATION_STEPS
	}


func expand_location_industry(location_id: String, facility_id: String, levels: int = 1) -> bool:
	return _reject_removed_aggregate_industry()


func queue_facility_expansion(location_id: String, facility_id: String, target_level: int, priority: int = 50) -> bool:
	return _reject_removed_aggregate_industry()


func queue_scale_stage_upgrade(location_id: String, facility_id: String, priority: int = 50) -> bool:
	return _reject_removed_aggregate_industry()


func queue_location_specialization(location_id: String, specialization_id: String, priority: int = 50) -> bool:
	return _reject_removed_aggregate_industry()


func queue_industrial_transformation(transformation_id: String, priority: int = 50) -> bool:
	return _reject_removed_aggregate_industry()


func queue_location_capacity_upgrade(location_id: String, project_type: String, target_value: int, priority: int = 50) -> bool:
	return _reject_removed_aggregate_industry()


func set_location_industry_infrastructure(location_id: String, power_capacity: float, cooling_capacity: float, structural_capacity: float) -> bool:
	return _reject_removed_aggregate_industry()


func select_megastructure_site(megastructure_id: String, location_id: String) -> bool:
	var definition: Dictionary = content.megastructures.get(megastructure_id, {})
	var phases: Array = definition.get("phases", [])
	if definition.is_empty() or phases.is_empty() or not definition.get("site_candidates", []).has(location_id) or not state.has_location(location_id):
		return _reject(I18n.t("notice.megastructure_site_invalid", "This Location is not a candidate for the Megastructure."))
	for requirement_value in (phases[0] as Dictionary).get("requirements", []):
		if not simulation.requirement_met(state, requirement_value as Dictionary):
			return _reject(I18n.t("notice.megastructure_research_required", "Complete the Megastructure engineering program before site commitment."))
	var required_survey := str((phases[0] as Dictionary).get("site_survey_required", LocationState.DEEP_SURVEYED))
	if simulation.survey_state_rank(str(state.location_state(location_id).get("survey_state", LocationState.UNKNOWN))) < simulation.survey_state_rank(required_survey):
		return _reject(I18n.t("notice.megastructure_deep_survey_required", "The candidate Location requires a Deep Survey."))
	var existing: Dictionary = state.megastructure_projects.get(megastructure_id, {})
	if not existing.is_empty() and int(existing.get("phase_index", 0)) > 0:
		return _reject(I18n.t("notice.megastructure_site_locked", "The Megastructure site is locked after construction preparation begins."))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	# Phase zero selects the surveyed site; it does not conjure an outpost. The
	# finite survey staging package must receive the Phase-one BOM through normal
	# freight, and the Forward Construction Base creates the first real capacity.
	transaction.working_state.megastructure_projects[megastructure_id] = {
		"id":megastructure_id, "site_location_id":location_id, "location_id":location_id,
		"phase_index":1, "stage_index":1, "stage_name":str((phases[1] as Dictionary).get("name", "READY")),
		"progress_percent":int(floor(100.0 / float(phases.size()))), "status":"READY", "material_flow_status":"AWAITING_NEXT_PHASE",
		"activity_id":"", "active_project_id":"", "delivered_materials":{}, "phase_history":[{"phase_index":0, "phase_id":(phases[0] as Dictionary).get("id", ""), "completed_at_ms":int(transaction.working_state.total_elapsed_ms), "materials_consumed":{}}],
		"total_materials_consumed":{}, "total_capital_goods":{}, "total_cargo_transported":0.0,
		"peak_construction_throughput":0.0, "peak_power_demand":0.0, "supplier_locations":{},
		"started_at_ms":int(transaction.working_state.total_elapsed_ms), "completed_at_ms":0
	}
	last_notice = I18n.t("notice.megastructure_site_selected", "Megastructure site selected: %s") % I18n.content(content.regions.get(location_id, {"id":location_id, "name":location_id}))
	transaction.record({"type":"MegastructureSiteSelected", "megastructure_id":megastructure_id, "location_id":location_id})
	_commit_transaction(transaction)
	return true


func start_megastructure_phase(megastructure_id: String, priority: int = 90) -> bool:
	return _reject_removed_aggregate_industry()


func start_construction_project(activity_id: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID, priority: int = 50) -> bool:
	return _reject_removed_aggregate_industry()


func stop_construction_project(slot: int) -> bool:
	return _reject_removed_aggregate_industry()


func set_construction_project_priority(project_id: String, priority: int) -> bool:
	return _reject_removed_aggregate_industry()


func survey_mission_availability(target_location_id: String, target_state: String, ship_ids: Array = [], origin_location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> Dictionary:
	var blockers: Array[Dictionary] = []
	var selected := ship_ids.duplicate()
	if str(state.survey_mission.get("status", "IDLE")) == "RUNNING":
		blockers.append({"code":"SURVEY_MISSION_ACTIVE"})
	var target := state.location_state(target_location_id)
	if target.is_empty():
		blockers.append({"code":"LOCATION_UNKNOWN"})
	else:
		var current_state := str(target.get("survey_state", LocationState.UNKNOWN))
		if simulation.survey_state_rank(target_state) != simulation.survey_state_rank(current_state) + 1:
			blockers.append({"code":"SURVEY_STATE_ORDER", "current":current_state, "required":target_state})
		if not simulation.survey_target_accessible(state, target_location_id):
			blockers.append({"code":"ROUTE_UNAVAILABLE", "location_id":target_location_id})
	var capability := str(content.survey_rules.get("required_capabilities", {}).get(target_state, ""))
	var inactive_candidate: Dictionary = {}
	if selected.is_empty():
		for ship_id_value in state.formation_ship_ids(SpaceGameState.DEFAULT_FORMATION_ID):
			var ship_id := str(ship_id_value)
			var ship := state.ship_by_id(ship_id)
			if not state.ship_is_docked(ship_id) or str(ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != origin_location_id or simulation.capability_value_for_ships(state, capability, [ship_id]) < 1.0:
				continue
			if state.ship_is_deployment_ready(ship_id):
				selected.append(ship_id)
				break
			if inactive_candidate.is_empty():
				inactive_candidate = ship
	if selected.is_empty():
		if not inactive_candidate.is_empty():
			blockers.append({
				"code":"SURVEY_VESSEL_UNAVAILABLE",
				"ship_id":str(inactive_candidate.get("instance_id", "")),
				"capability":capability,
				"maintenance_state":str(inactive_candidate.get("maintenance_state", "ACTIVE")),
				"maintenance_coverage":float(inactive_candidate.get("maintenance_coverage", 1.0))
			})
		else:
			blockers.append({"code":"SURVEY_VESSEL_REQUIRED", "capability":capability})
	else:
		for ship_id_value in selected:
			var ship_id := str(ship_id_value)
			var ship := state.ship_by_id(ship_id)
			if state.ship_formation_id(ship_id).is_empty() or not state.ship_is_deployment_ready(ship_id) or str(ship.get("location_id", "")) != origin_location_id or simulation.capability_value_for_ships(state, capability, [ship_id]) < 1.0:
				blockers.append({"code":"SURVEY_VESSEL_UNAVAILABLE", "ship_id":ship_id, "capability":capability, "maintenance_state":str(ship.get("maintenance_state", "ACTIVE")), "maintenance_coverage":float(ship.get("maintenance_coverage", 0.0))})
	var costs := simulation.survey_mission_costs(target_state)
	for item_id_value in costs.keys():
		var item_id := str(item_id_value)
		var required := int(costs[item_id])
		var available := state.available_item_quantity(item_id, origin_location_id)
		if available < required:
			blockers.append({"code":"INPUT_SHORTAGE", "item_id":item_id, "available":available, "required":required})
	return {"allowed":blockers.is_empty(), "blockers":blockers, "selected_ship_ids":selected, "costs":costs}


func set_construction_project_paused(project_id: String, paused: bool) -> bool:
	return _reject_removed_aggregate_industry()


func start_research_project(project_id: String, route_id: String = "") -> bool:
	if not content.research_projects.has(project_id):
		return _reject(I18n.t("notice.research_unknown", "Unknown research project"))
	if state.research.get("status", "IDLE") == "RUNNING":
		return _reject(I18n.t("notice.research_active", "A research project is already active"))
	var project: Dictionary = content.research_projects[project_id]
	var selected_route := route_id if not route_id.is_empty() else simulation.default_research_route_id(project)
	if not selected_route.is_empty() and simulation.research_route(project, selected_route).is_empty():
		return _reject(I18n.t("notice.research_route_unknown", "Unknown R&D engineering route"))
	if not simulation.research_project_available(state, project, selected_route if bool(state.completed_projects.get(project_id, false)) else ""):
		return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var existing: Dictionary = transaction.working_state.research
	if str(existing.get("project_id", "")) == project_id and str(existing.get("route_id", "")) == selected_route and existing.get("status", "") in ["PAUSED", "BLOCKED"]:
		existing["status"] = "RUNNING"
		existing["blocked_reason"] = ""
	else:
		if not str(existing.get("project_id", "")).is_empty():
			return _reject(I18n.t("notice.research_committed", "Pause does not cancel committed research; resume the current project"))
		simulation.initialize_research_program(transaction.working_state, project, selected_route, bool(transaction.working_state.completed_projects.get(project_id, false)))
	last_notice = I18n.t("notice.research_started", "Research started: %s") % I18n.content(project)
	transaction.record({"type":"ResearchStarted", "project_id":project_id, "route_id":selected_route, "supplemental_route":bool(transaction.working_state.research.get("supplemental_route", false))})
	_commit_transaction(transaction)
	return true


func stop_research() -> bool:
	if state.research.get("status", "IDLE") not in ["RUNNING", "BLOCKED"]:
		return _reject(I18n.t("notice.no_active", "No active operation to pause"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	# Already consumed materials remain committed to this project attempt.
	transaction.working_state.research["status"] = "PAUSED"
	last_notice = I18n.t("notice.research_paused", "Research paused")
	transaction.record({"type":"ResearchPaused", "project_id":transaction.working_state.research.get("project_id", "")})
	_commit_transaction(transaction)
	return true


func move_shipyard_project(plan_id: String, new_index: int) -> bool:
	var current_index := simulation.shipyard_queue_index(state, plan_id)
	if current_index < 0:
		return _reject(I18n.t("notice.shipyard_plan_missing", "Ship construction plan is not in the queue"))
	var target := clampi(new_index, 0, state.shipyard_queue.size() - 1)
	if target == current_index:
		return true
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = transaction.working_state.shipyard_queue.pop_at(current_index)
	transaction.working_state.shipyard_queue.insert(target, runtime)
	simulation.normalize_shipyard_queue(transaction.working_state)
	last_notice = I18n.t("notice.shipyard_reordered", "Shipyard priority updated: %s → %d") % [I18n.content(content.ship_construction_projects.get(plan_id, {"id":plan_id, "name":plan_id})), target + 1]
	transaction.record({"type":"ShipyardQueueReordered", "plan_id":plan_id, "from":current_index, "to":target})
	_commit_transaction(transaction)
	return true


func enqueue_unlocked_ship_plan(plan_id: String, quantity: int = 1) -> bool:
	if not content.ship_construction_projects.has(plan_id):
		return _reject(I18n.t("notice.shipyard_plan_unknown", "Unknown ship construction plan"))
	if quantity <= 0 or quantity > 100:
		return _reject(I18n.t("notice.shipyard_quantity_invalid", "Ship construction quantity must be between 1 and 100"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not transaction.working_state.enqueue_ship_plan(plan_id, quantity):
		return _reject(I18n.t("notice.shipyard_plan_unavailable", "Ship plan is locked, already queued, or already built"))
	simulation.normalize_shipyard_queue(transaction.working_state)
	last_notice = I18n.t("notice.shipyard_plan_queued", "%s × %d added to the Shipyard") % [I18n.content(content.ship_construction_projects[plan_id]), quantity]
	transaction.record({"type":"ShipyardPlanQueued", "plan_id":plan_id, "quantity":quantity})
	_commit_transaction(transaction)
	return true


func ship_design_validation(plan_id: String, nodes: Array, connections: Array, allow_locked_plan: bool = false) -> Dictionary:
	var plan := content.ship_construction_projects.get(plan_id, {}) as Dictionary
	if plan.is_empty():
		return {"allowed":false, "reason_code":"PLAN_UNKNOWN", "reason":I18n.t("notice.ship_design_plan_unknown", "Unknown hull plan")}
	if not allow_locked_plan and not bool(state.unlocked_ship_plans.get(plan_id, false)):
		return {"allowed":false, "reason_code":"PLAN_LOCKED", "reason":I18n.t("notice.ship_design_plan_locked", "The hull plan is still locked")}
	var hull_id := str(plan.get("ship_id", ""))
	var hull_nodes: Array = []
	var module_nodes := {}
	var sanitized_nodes: Array = []
	for node_value in nodes:
		if node_value is not Dictionary:
			continue
		var node := node_value as Dictionary
		var node_id := str(node.get("node_id", ""))
		var kind := str(node.get("kind", ""))
		var definition_id := str(node.get("definition_id", ""))
		if node_id.is_empty() or kind not in ["hull", "module"]:
			return {"allowed":false, "reason_code":"NODE_INVALID", "reason":I18n.t("notice.ship_design_node_invalid", "The design contains an invalid node")}
		var position := node.get("position", {}) as Dictionary
		var sanitized := {"node_id":node_id, "kind":kind, "definition_id":definition_id, "position":{"x":float(position.get("x", 0.0)), "y":float(position.get("y", 0.0))}}
		sanitized_nodes.append(sanitized)
		if kind == "hull":
			hull_nodes.append(sanitized)
		else:
			if not content.modules.has(definition_id) or module_nodes.has(node_id):
				return {"allowed":false, "reason_code":"MODULE_INVALID", "reason":I18n.t("notice.ship_design_module_invalid", "The design contains an unknown module")}
			if not simulation.definition_revealed(state, content.modules.get(definition_id, {})):
				return {"allowed":false, "reason_code":"MODULE_LOCKED", "reason":I18n.t("notice.ship_design_module_locked", "A module design is not unlocked")}
			module_nodes[node_id] = sanitized
	if hull_nodes.size() != 1 or str((hull_nodes[0] as Dictionary).get("definition_id", "")) != hull_id:
		return {"allowed":false, "reason_code":"HULL_INVALID", "reason":I18n.t("notice.ship_design_hull_invalid", "Place exactly one hull from the selected plan")}
	var hull := content.ships.get(hull_id, {}) as Dictionary
	var socket_slots := {}
	for socket_value in ship_design_socket_schema(plan_id):
		var socket := socket_value as Dictionary
		socket_slots[str(socket.get("id", ""))] = socket
	var used_modules := {}
	var used_sockets := {}
	var sanitized_connections: Array = []
	for connection_value in connections:
		if connection_value is not Dictionary:
			continue
		var connection := connection_value as Dictionary
		var module_node_id := str(connection.get("module_node_id", ""))
		var socket_id := str(connection.get("socket_id", ""))
		if not module_nodes.has(module_node_id) or not socket_slots.has(socket_id) or used_modules.has(module_node_id) or used_sockets.has(socket_id):
			return {"allowed":false, "reason_code":"CONNECTION_INVALID", "reason":I18n.t("notice.ship_design_connection_invalid", "A module connection is missing, duplicated or targets an unknown socket")}
		var module_id := str((module_nodes[module_node_id] as Dictionary).get("definition_id", ""))
		var module_slot := str(content.modules.get(module_id, {}).get("slot", "utility"))
		var module_mount := ship_module_mount_role(module_id)
		var socket := socket_slots[socket_id] as Dictionary
		var module_family := _ship_design_connection_family(module_slot, module_mount)
		var socket_family := str(socket.get("interface_family", _ship_design_connection_family(str(socket.get("slot", "")), str(socket.get("mount_role", "")))))
		if module_family != socket_family or _ship_design_port_shape(module_slot, module_mount) != str(socket.get("shape", "")):
			return {"allowed":false, "reason_code":"SOCKET_MISMATCH", "reason":I18n.t("notice.ship_design_socket_mismatch", "The connector shape does not match the hull socket")}
		var module_size := str(content.modules.get(module_id, {}).get("size", "S"))
		if _ship_module_size_rank(module_size) > int(socket.get("tier", 1)):
			return {"allowed":false, "reason_code":"SOCKET_SIZE_MISMATCH", "reason":I18n.t("notice.ship_design_socket_size_mismatch", "The module is physically larger than the selected hull socket")}
		used_modules[module_node_id] = true
		used_sockets[socket_id] = true
		sanitized_connections.append({"module_node_id":module_node_id, "socket_id":socket_id, "slot":module_slot, "mount_role":module_mount, "interface_family":module_family, "shape":_ship_design_port_shape(module_slot, module_mount), "max_size":str(socket.get("max_size", "S")), "tier":int(socket.get("tier", 1)), "diameter_m":float(socket.get("diameter_m", 5.0))})
	if used_modules.size() != module_nodes.size():
		return {"allowed":false, "reason_code":"MODULE_UNCONNECTED", "reason":I18n.t("notice.ship_design_module_unconnected", "Every placed module must be connected to one matching hull socket")}
	var modules: Array = []
	var installed_core_count := 0
	for node_value in sanitized_nodes:
		var node := node_value as Dictionary
		if str(node.get("kind", "")) == "module":
			var module_id := str(node.get("definition_id", ""))
			modules.append(module_id)
			if str(content.modules.get(module_id, {}).get("slot", "utility")) == "core":
				installed_core_count += 1
	if int(hull.get("slot_layout", {}).get("core", 0)) > 0 and installed_core_count <= 0:
		return {"allowed":false, "reason_code":"CORE_REQUIRED", "reason":I18n.t("notice.ship_design_core_required", "Install and connect an energy core in the central hull socket")}
	var loadout_error := content.ship_loadout_error(hull_id, modules)
	if not loadout_error.is_empty():
		return {"allowed":false, "reason_code":"FITTING_INVALID", "reason":I18n.t("notice.ship_design_fitting_invalid", "The assembled loadout is invalid: %s") % loadout_error}
	return {"allowed":true, "reason_code":"READY", "reason":I18n.t("notice.ship_design_ready", "All connectors and fitting limits are valid"), "plan_id":plan_id, "hull_id":hull_id, "modules":modules, "nodes":sanitized_nodes, "connections":sanitized_connections}


func ship_design_engineering_summary(plan_id: String, nodes: Array, connections: Array, allow_locked_plan: bool = false) -> Dictionary:
	var plan := content.ship_construction_projects.get(plan_id, {}) as Dictionary
	if plan.is_empty():
		return {}
	var hull_id := str(plan.get("ship_id", ""))
	var module_ids: Array = []
	for node_value in nodes:
		if node_value is Dictionary and str((node_value as Dictionary).get("kind", "")) == "module":
			var module_id := str((node_value as Dictionary).get("definition_id", ""))
			if content.modules.has(module_id):
				module_ids.append(module_id)
	var effective_plan := plan.duplicate(true)
	effective_plan["starting_modules"] = module_ids.duplicate()
	var construction_costs := simulation.ship_construction_material_totals(effective_plan)
	for cost_value in effective_plan.get("fixed_costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		construction_costs[item_id] = int(construction_costs.get(item_id, 0)) + int(cost.get("quantity", 0))
	var fabrication_time_ms := simulation.loadout_fabrication_time_ms(module_ids)
	var installation_time_ms := simulation.loadout_installation_time_ms(module_ids)
	var refit_runtime := {"cycle_time_ms":(fabrication_time_ms + installation_time_ms) / 100.0}
	var connection_capacity := {}
	for socket_value in ship_design_socket_schema(plan_id):
		var socket := socket_value as Dictionary
		var family_key := _ship_design_connection_family(str(socket.get("slot", "utility")), str(socket.get("mount_role", "")))
		connection_capacity[family_key] = int(connection_capacity.get(family_key, 0)) + 1
	var nodes_by_id := {}
	for node_value in nodes:
		if node_value is Dictionary:
			nodes_by_id[str((node_value as Dictionary).get("node_id", ""))] = node_value
	var connection_usage := {}
	for connection_value in connections:
		if connection_value is not Dictionary:
			continue
		var connection := connection_value as Dictionary
		var module_node := nodes_by_id.get(str(connection.get("module_node_id", "")), {}) as Dictionary
		var module := content.modules.get(str(module_node.get("definition_id", "")), {}) as Dictionary
		if module.is_empty():
			continue
		var family_key := _ship_design_connection_family(str(module.get("slot", "utility")), ship_module_mount_role(str(module.get("id", module_node.get("definition_id", "")))))
		connection_usage[family_key] = int(connection_usage.get(family_key, 0)) + 1
	var matching_hulls: Array[String] = []
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		var instance_id := str(ship.get("instance_id", ""))
		if str(ship.get("blueprint_id", "")) == hull_id and state.ship_can_refit(instance_id):
			matching_hulls.append(instance_id)
	return {
		"plan_id":plan_id,
		"hull_id":hull_id,
		"module_ids":module_ids,
		"module_count":module_ids.size(),
		"connected_count":connections.size(),
		"validation":ship_design_validation(plan_id, nodes, connections, allow_locked_plan),
		"plan_unlocked":bool(state.unlocked_ship_plans.get(plan_id, false)),
		"engineering":content.ship_loadout_engineering_summary(hull_id, module_ids),
		"connection_overview":{"usage":connection_usage, "capacity":connection_capacity},
		"construction_costs":construction_costs,
		"refit_costs":simulation.loadout_fabrication_costs(module_ids),
		"estimated_build_time_ms":simulation.shipyard_cycle_duration_ms(state, effective_plan) * 100.0,
		"estimated_fabrication_time_ms":fabrication_time_ms,
		"estimated_installation_time_ms":installation_time_ms,
		"estimated_refit_time_ms":simulation.refit_cycle_duration_ms(state, refit_runtime) * 100.0,
		"matching_refit_ship_ids":matching_hulls,
		"handoff_mode":"REFIT" if not matching_hulls.is_empty() else "BUILD_HULL"
	}


func _ship_design_connection_family(slot: String, mount_role: String) -> String:
	if mount_role == "STRUCTURAL":
		return "structure"
	if slot == "utility":
		return "utility"
	return slot


func save_ship_design(design_id: String, requested_name: String, plan_id: String, nodes: Array, connections: Array, allow_locked_plan: bool = false) -> bool:
	var validation := ship_design_validation(plan_id, nodes, connections, allow_locked_plan)
	if not bool(validation.get("allowed", false)):
		return _reject(str(validation.get("reason", I18n.t("notice.ship_design_invalid", "Ship design is invalid"))))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var target_id := design_id
	if target_id.is_empty():
		target_id = "DESIGN-%04d" % transaction.working_state.next_ship_design_serial
		transaction.working_state.next_ship_design_serial += 1
	elif not transaction.working_state.ship_designs.has(target_id):
		return _reject(I18n.t("notice.ship_design_missing", "Saved ship design was not found"))
	var plan := content.ship_construction_projects.get(plan_id, {}) as Dictionary
	var name := requested_name.strip_edges()
	if name.is_empty():
		name = I18n.t("format.ship_design_name", "%s Design %d") % [I18n.content(plan), transaction.working_state.ship_designs.size() + 1]
	transaction.working_state.ship_designs[target_id] = {
		"id":target_id,
		"name":name,
		"plan_id":plan_id,
		"hull_id":str(validation.get("hull_id", "")),
		"modules":validation.get("modules", []).duplicate(),
		"nodes":validation.get("nodes", []).duplicate(true),
		"connections":validation.get("connections", []).duplicate(true),
		"saved_at_ms":int(transaction.working_state.total_elapsed_ms)
	}
	last_saved_ship_design_id = target_id
	last_notice = I18n.t("notice.ship_design_saved", "Ship design saved: %s") % name
	transaction.record({"type":"ShipDesignSaved", "design_id":target_id, "plan_id":plan_id})
	_commit_transaction(transaction)
	return true


func delete_ship_design(design_id: String) -> bool:
	if not state.ship_designs.has(design_id):
		return _reject(I18n.t("notice.ship_design_missing", "Saved ship design was not found"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var name := str(transaction.working_state.ship_designs.get(design_id, {}).get("name", design_id))
	transaction.working_state.ship_designs.erase(design_id)
	last_notice = I18n.t("notice.ship_design_deleted", "Ship design deleted: %s") % name
	transaction.record({"type":"ShipDesignDeleted", "design_id":design_id})
	_commit_transaction(transaction)
	return true


func enqueue_saved_ship_design(design_id: String, quantity: int = 1) -> bool:
	if quantity <= 0 or quantity > 100:
		return _reject(I18n.t("notice.shipyard_quantity_invalid", "Ship construction quantity must be between 1 and 100"))
	var design := state.ship_designs.get(design_id, {}) as Dictionary
	if design.is_empty():
		return _reject(I18n.t("notice.ship_design_missing", "Saved ship design was not found"))
	var validation := ship_design_validation(str(design.get("plan_id", "")), design.get("nodes", []), design.get("connections", []))
	if not bool(validation.get("allowed", false)):
		return _reject(str(validation.get("reason", I18n.t("notice.ship_design_invalid", "Ship design is invalid"))))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not transaction.working_state.enqueue_ship_plan(str(design.get("plan_id", "")), quantity, design_id, validation.get("modules", [])):
		return _reject(I18n.t("notice.shipyard_plan_unavailable", "Ship plan is locked, already queued, or already built"))
	simulation.normalize_shipyard_queue(transaction.working_state)
	last_notice = I18n.t("notice.ship_design_queued", "%s × %d added to the Shipyard") % [str(design.get("name", design_id)), quantity]
	transaction.record({"type":"ShipDesignQueued", "design_id":design_id, "plan_id":design.get("plan_id", ""), "quantity":quantity})
	_commit_transaction(transaction)
	return true


func ship_design_refit_candidates(design_id: String) -> Array[String]:
	var result: Array[String] = []
	var design := state.ship_designs.get(design_id, {}) as Dictionary
	if design.is_empty():
		return result
	var hull_id := str(design.get("hull_id", ""))
	for ship_value in state.ships:
		var ship := ship_value as Dictionary
		if str(ship.get("blueprint_id", "")) == hull_id:
			result.append(str(ship.get("instance_id", "")))
	result.sort()
	return result


func ship_design_refit_availability(design_id: String, instance_id: String) -> Dictionary:
	var design := state.ship_designs.get(design_id, {}) as Dictionary
	if design.is_empty():
		return {"allowed":false, "reason_code":"DESIGN_MISSING", "reason":I18n.t("notice.ship_design_missing", "Saved ship design was not found")}
	var validation := ship_design_validation(str(design.get("plan_id", "")), design.get("nodes", []), design.get("connections", []))
	if not bool(validation.get("allowed", false)):
		return validation
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return {"allowed":false, "reason_code":"SHIP_MISSING", "reason":I18n.t("notice.ship_missing", "Ship instance was not found")}
	if str(ship.get("blueprint_id", "")) != str(validation.get("hull_id", "")):
		return {"allowed":false, "reason_code":"HULL_MISMATCH", "reason":I18n.t("notice.loadout_hull", "This blueprint belongs to a different hull model")}
	return ship_loadout_availability(instance_id, validation.get("modules", []))


func begin_ship_design_refit(design_id: String, instance_id: String) -> bool:
	var availability := ship_design_refit_availability(design_id, instance_id)
	if not bool(availability.get("allowed", false)):
		return _reject(str(availability.get("reason", I18n.t("notice.refit_locked", "The ship cannot enter refit"))))
	var design := state.ship_designs.get(design_id, {}) as Dictionary
	var validation := ship_design_validation(str(design.get("plan_id", "")), design.get("nodes", []), design.get("connections", []))
	return begin_ship_refit(instance_id, validation.get("modules", []), design_id)


func ship_module_mount_role(module_id: String) -> String:
	return content.ship_module_mount_role(module_id)


func ship_design_socket_schema(plan_id: String) -> Array[Dictionary]:
	var plan := content.ship_construction_projects.get(plan_id, {}) as Dictionary
	var hull_id := str(plan.get("ship_id", ""))
	var hull := content.ships.get(hull_id, {}) as Dictionary
	var slots := hull.get("slot_layout", {}) as Dictionary
	var interfaces := content.ship_installation_interface_layout(hull_id)
	var allowed_sizes := hull.get("allowed_sizes", ["S"]) as Array
	var hull_visual := hull.get("hull_visual", {}) as Dictionary
	var max_socket_size := str(hull_visual.get("socket_size", allowed_sizes.back() if not allowed_sizes.is_empty() else "S"))
	if _ship_module_size_rank(max_socket_size) <= 0:
		max_socket_size = "S"
	var shield_socket_count := mini(int(slots.get("shield", 0)), int(interfaces.get("structure", 0)))
	var structural_utility_count := maxi(0, int(interfaces.get("structure", 0)) - shield_socket_count)
	var special_utility_count := int(interfaces.get("utility", 0))
	var result: Array[Dictionary] = []
	for weapon_index in int(interfaces.get("weapon", 0)):
		result.append(_ship_design_socket_definition("socket_weapon_%d" % weapon_index, "weapon", "SPECIAL", "TRIANGLE", max_socket_size))
	for shield_index in shield_socket_count:
		result.append(_ship_design_socket_definition("socket_shield_%d" % shield_index, "shield", "STRUCTURAL", "SQUARE", max_socket_size))
	for drive_index in int(interfaces.get("drive", 0)):
		result.append(_ship_design_socket_definition("socket_drive_%d" % drive_index, "drive", "DRIVE", "DIAMOND", max_socket_size))
	for utility_index in special_utility_count:
		result.append(_ship_design_socket_definition("socket_utility_%d" % utility_index, "utility", "SPECIAL", "PENTAGON", max_socket_size))
	for structural_index in structural_utility_count:
		var utility_index := special_utility_count + structural_index
		result.append(_ship_design_socket_definition("socket_utility_%d" % utility_index, "utility", "STRUCTURAL", "SQUARE", max_socket_size))
	for core_index in int(interfaces.get("core", 0)):
		result.append(_ship_design_socket_definition("socket_core_%d" % core_index, "core", "CORE", "CIRCLE", max_socket_size))
	var family_counts := {}
	for socket in result:
		var family := _ship_design_connection_family(str(socket.get("slot", "")), str(socket.get("mount_role", "")))
		socket["interface_family"] = family
		socket["family_index"] = int(family_counts.get(family, 0))
		family_counts[family] = int(family_counts.get(family, 0)) + 1
	return result


func _ship_design_socket_definition(socket_id: String, slot: String, mount_role: String, shape: String, max_size: String) -> Dictionary:
	var tier := _ship_module_size_rank(max_size)
	var diameter: float = float({"S":5.0, "M":11.0, "L":22.0, "XL":44.0, "XXL":88.0}.get(max_size, 5.0))
	return {"id":socket_id, "slot":slot, "mount_role":mount_role, "shape":shape, "max_size":max_size, "tier":tier, "diameter_m":diameter}


func _ship_module_size_rank(size_id: String) -> int:
	return int({"S":1, "M":2, "L":3, "XL":4, "XXL":5}.get(size_id, 0))


func _ship_design_port_shape(slot: String, mount_role := "") -> String:
	if mount_role == "STRUCTURAL":
		return "SQUARE"
	if mount_role == "SPECIAL" and slot == "utility":
		return "PENTAGON"
	match slot:
		"weapon": return "TRIANGLE"
		"shield": return "SQUARE"
		"drive": return "DIAMOND"
		"core": return "CIRCLE"
		_: return "SQUARE"


func cancel_shipyard_project(project_id: String) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working := transaction.working_state
	var project_index := -1
	for index in working.shipyard_queue.size():
		if str(working.shipyard_queue[index].get("project_id", "")) == project_id:
			project_index = index
			break
	if project_index < 0:
		return _reject(I18n.t("notice.shipyard_project_unknown", "Shipyard project was not found"))
	var runtime: Dictionary = working.shipyard_queue[project_index]
	working.shipyard_queue.remove_at(project_index)
	simulation.normalize_shipyard_queue(working)
	last_notice = I18n.t("notice.shipyard_cancelled", "Shipyard project cancelled; committed construction materials are not recovered")
	transaction.record({"type":"ShipyardProjectCancelled", "project_id":project_id, "consumed_lost":runtime.get("consumed", {}).duplicate(true)})
	_commit_transaction(transaction)
	return true


func set_inventory_reserve(item_id: String, quantity: int, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> bool:
	if not content.items.has(item_id):
		return _reject(I18n.t("notice.item_unknown", "Unknown inventory item"))
	if not state.has_location(location_id):
		return _reject(I18n.t("notice.location_unknown", "Unknown location"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.set_item_reserve(item_id, quantity, location_id)
	transaction.record({"type":"InventoryReserveChanged", "location_id":location_id, "item_id":item_id, "quantity":maxi(0, quantity)})
	_commit_transaction(transaction)
	return true


func set_location_logistics_policy(location_id: String, item_id: String, mode: String, reserve: int = 0, target: int = 0, priority: int = 50, dispatch_threshold: int = 1, source_lock: String = "", route_lock: String = "") -> bool:
	if not state.has_location(location_id):
		return _reject(I18n.t("notice.location_unknown", "Unknown location"))
	if not content.items.has(item_id):
		return _reject(I18n.t("notice.item_unknown", "Unknown inventory item"))
	var previous_policy: Dictionary = state.location_state(location_id).get("logistics", {}).get("policies", {}).get(item_id, {}).duplicate(true)
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var policy := {
		"mode":mode,
		"reserve":reserve,
		"target":target,
		"priority":priority,
		"dispatch_threshold":dispatch_threshold,
		"source_lock":source_lock,
		"route_lock":route_lock
	}
	if not simulation.logistics.configure_policy(transaction.working_state, location_id, item_id, policy):
		return _reject(I18n.t("notice.logistics_policy_invalid", "Invalid logistics policy"))
	var configured_policy: Dictionary = transaction.working_state.location_state(location_id).get("logistics", {}).get("policies", {}).get(item_id, {}).duplicate(true)
	previous_policy.erase("blocker")
	configured_policy.erase("blocker")
	if not previous_policy.is_empty() and configured_policy == previous_policy:
		return _reject(I18n.t("notice.logistics_policy_unchanged", "This logistics policy already has the requested values"))
	_detach_template_policy(transaction.working_state, location_id, item_id)
	last_notice = I18n.t("notice.logistics_policy_updated", "Logistics policy updated: %s / %s / %s") % [I18n.content(content.regions.get(location_id, {"name":location_id})), I18n.content(content.items[item_id]), I18n.status(mode.to_upper())]
	transaction.record({"type":"LocationLogisticsPolicyChanged", "location_id":location_id, "item_id":item_id, "policy":policy})
	_commit_transaction(transaction)
	return true


func configure_logistics_service(route_id: String, transport_mode_id: String, ship_ids: Array = [], priority_strategy: String = "DEMAND_PRIORITY") -> bool:
	if not content.logistics_routes.has(route_id):
		return _reject(I18n.t("notice.logistics_route_unknown", "Unknown logistics route"))
	if not content.transport_modes.has(transport_mode_id):
		return _reject(I18n.t("notice.transport_mode_unknown", "Unknown transport mode"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.logistics.configure_service(transaction.working_state, route_id, transport_mode_id, ship_ids, priority_strategy):
		return _reject(I18n.t("notice.transport_service_blocked", "Transport mode requirements or assigned ships are not satisfied"))
	var route: Dictionary = content.logistics_routes[route_id]
	var mode: Dictionary = content.transport_modes[transport_mode_id]
	last_notice = I18n.t("notice.logistics_service_updated", "Logistics service updated: %s / %s") % [I18n.content(route), I18n.content(mode)]
	transaction.record({"type":"LogisticsServiceConfigured", "route_id":route_id, "transport_mode_id":transport_mode_id, "ship_ids":ship_ids.duplicate(), "priority_strategy":priority_strategy})
	_commit_transaction(transaction)
	return true


func set_logistics_service_paused(route_id: String, paused: bool) -> bool:
	if not content.logistics_routes.has(route_id):
		return _reject(I18n.t("notice.logistics_route_unknown", "Unknown logistics route"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.logistics.set_service_paused(transaction.working_state, route_id, paused):
		return _reject(I18n.t("notice.logistics_service_state_invalid", "The logistics service state could not be changed"))
	last_notice = I18n.t("notice.logistics_service_paused", "Logistics service paused: %s") % I18n.content(content.logistics_routes[route_id]) if paused else I18n.t("notice.logistics_service_resumed", "Logistics service resumed: %s") % I18n.content(content.logistics_routes[route_id])
	transaction.record({"type":"LogisticsServicePauseChanged", "route_id":route_id, "paused":paused})
	_commit_transaction(transaction)
	return true


func clear_location_logistics_policy(location_id: String, item_id: String) -> bool:
	if state.has_location(location_id):
		var policies: Dictionary = state.location_state(location_id).get("logistics", {}).get("policies", {})
		if not policies.has(item_id):
			return _reject(I18n.t("notice.logistics_policy_missing", "There is no logistics policy to clear for this item"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.logistics.clear_policy(transaction.working_state, location_id, item_id):
		return _reject(I18n.t("notice.logistics_policy_target_invalid", "Invalid logistics policy target"))
	_detach_template_policy(transaction.working_state, location_id, item_id)
	last_notice = I18n.t("notice.logistics_policy_cleared", "Logistics policy cleared: %s / %s") % [I18n.content(content.regions.get(location_id, {"id":location_id, "name":location_id})), I18n.content(content.items.get(item_id, {"id":item_id, "name":item_id}))]
	transaction.record({"type":"LocationLogisticsPolicyCleared", "location_id":location_id, "item_id":item_id})
	_commit_transaction(transaction)
	return true


func set_location_logistics_limits(location_id: String, storage_capacity: int, hub_throughput: int) -> bool:
	if not state.has_location(location_id):
		return _reject(I18n.t("notice.unknown_location", "Unknown location"))
	return _reject_removed_aggregate_industry()


func apply_location_industrial_template(location_id: String, template_id: String) -> bool:
	return _reject_removed_aggregate_industry()


func clear_location_industrial_template(location_id: String) -> bool:
	return _reject_removed_aggregate_industry()


func configure_location_industrial_automation(location_id: String, enabled: bool, target_level: int) -> bool:
	return _reject_removed_aggregate_industry()


func _detach_template_policy(working_state: SpaceGameState, location_id: String, item_id: String) -> void:
	var automation: Dictionary = working_state.location_state(location_id).get("automation", {})
	var managed_items: Array = automation.get("managed_policy_items", []).duplicate()
	managed_items.erase(item_id)
	automation["managed_policy_items"] = managed_items
	if not str(automation.get("industrial_template_id", "")).is_empty():
		automation["status"] = "CUSTOMIZED"


func set_advanced_power_priority(facility_id: String, priority: String) -> bool:
	return _reject_removed_aggregate_industry()


func install_facility_module(facility_id: String, module_id: String) -> bool:
	return _reject_removed_aggregate_industry()


func install_manufacturing_module(facility_id: String, module_id: String, module_kind: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> bool:
	return _reject_removed_aggregate_industry()


func uninstall_manufacturing_module(facility_id: String, module_id: String, module_kind: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> bool:
	return _reject_removed_aggregate_industry()


func toggle_pinned_item(item_id: String) -> bool:
	if not content.items.has(item_id):
		return _reject(I18n.t("notice.item_unknown", "Unknown inventory item"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var pins: Array = transaction.working_state.pinned_items.duplicate()
	if pins.has(item_id):
		pins.erase(item_id)
	else:
		pins.append(item_id)
	transaction.working_state.pinned_items = pins
	last_notice = I18n.t("notice.pin_changed", "Production tracking updated: %s") % I18n.content(content.items[item_id])
	transaction.record({"type":"PinnedItemChanged", "item_id":item_id, "pinned":pins.has(item_id)})
	_commit_transaction(transaction)
	return true


func _validate_loadout_modules(blueprint_id: String, module_ids: Array) -> String:
	var error := content.ship_loadout_error(blueprint_id, module_ids)
	if error.is_empty():
		return ""
	if error.begins_with("missing"):
		return I18n.t("notice.module_unknown", "Unknown ship module")
	if error.begins_with("retired"):
		return I18n.t("notice.module_retired", "This ship plugin has been retired; collection and production equipment now belongs to factory buildings")
	if "size" in error:
		return I18n.t("notice.module_size", "Module size is incompatible with this hull")
	if "slot limit" in error or "installation-interface limit" in error:
		return I18n.t("notice.module_full", "This ship has no free compatible module slot")
	return I18n.t("notice.module_budget", "Hull fitting budget exceeded: %s") % error


func start_expedition_route(route_id: String, ship_ids: Array = [], formation_id: String = SpaceGameState.DEFAULT_FORMATION_ID) -> bool:
	if not content.expedition_routes.has(route_id):
		return _reject(I18n.t("notice.route_unknown", "Unknown Expedition route"))
	if int(state.completed_activities.get("route:%s" % route_id, 0)) > 0:
		return _reject(I18n.t("notice.route_already_completed", "This Expedition route has already been completed"))
	if state.active_expedition.get("status", "IDLE") == "RUNNING":
		return _reject(I18n.t("notice.expedition_active", "The organization already has an active Expedition front"))
	var route: Dictionary = content.expedition_routes[route_id]
	for requirement in route.get("requirements", []):
		if not simulation.requirement_met(state, requirement):
			return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	var selected: Array = ship_ids.duplicate()
	if selected.is_empty():
		selected = state.formation_ship_ids(formation_id)
	if selected.is_empty():
		return _reject(I18n.t("notice.expedition_fleet_empty", "Assign ships to a tactical formation at Starport first"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	for ship_id in selected:
		if not transaction.working_state.ship_is_deployment_ready(str(ship_id)) or transaction.working_state.ship_formation_id(str(ship_id)) != formation_id:
			return _reject(I18n.t("notice.expedition_fleet_unavailable", "Every deployed formation ship must be operational and docked"))
	if simulation.fleet_command_usage(transaction.working_state, selected) > simulation.fleet_command_capacity(transaction.working_state, formation_id):
		return _reject(I18n.t("notice.command_capacity", "Fleet Command Capacity would be exceeded"))
	_auto_resupply_state(transaction.working_state, formation_id, selected)
	var fuel_cost := maxi(0, int(route.get("fuel_cost", 0)))
	if fuel_cost > 0 and not transaction.working_state.consume_fleet_supply("chemical_propellant", fuel_cost, formation_id):
		return _reject(I18n.t("notice.expedition_fuel", "Fleet supply cannot fund this route's fuel requirement"))
	var runtime: Dictionary = transaction.working_state.active_expedition
	runtime.merge({"status":"RUNNING", "route_id":route_id, "formation_id":formation_id, "activity_id":"", "node_index":0, "node_progress_ms":0.0, "safe_node_index":0, "assigned_ship_ids":selected, "phase":str(route.get("nodes", [{}])[0].get("phase", "PREPARE")), "combat_state":{}}, true)
	for ship_id in selected:
		var expedition_ship := transaction.working_state.ship_by_id(str(ship_id))
		expedition_ship["status"] = "EXPEDITION"
		expedition_ship["assignment"] = {"type":"EXPEDITION", "formation_id":formation_id, "route_id":route_id}
		expedition_ship["service_record"]["combat_deployments"] = int(expedition_ship.get("service_record", {}).get("combat_deployments", 0)) + 1
	last_notice = I18n.t("notice.route_started", "Expedition launched: %s") % I18n.content(route)
	transaction.record({"type":"ExpeditionRouteStarted", "route_id":route_id, "ship_ids":selected})
	_commit_transaction(transaction)
	return true


func begin_ship_refit(instance_id: String, desired_module_definitions: Array, target_loadout_id: String = "") -> bool:
	if not state.ship_can_refit(instance_id):
		return _reject(I18n.t("notice.refit_locked", "The ship must be operational and docked before refitting"))
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	var blueprint_id := str(ship.get("blueprint_id", ""))
	var desired: Array = []
	for value in desired_module_definitions:
		desired.append(str(value))
	var validation := _validate_loadout_modules(blueprint_id, desired)
	if not validation.is_empty():
		return _reject(validation)
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working := transaction.working_state
	var working_ship := working.ship_by_id(instance_id)
	var location_id := str(working_ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var original_modules: Array = working_ship.get("modules", []).duplicate()
	var available_special := {}
	for module_value in original_modules:
		var stored_value := str(module_value)
		if not working.equipment_instances.has(stored_value):
			continue
		var definition_id := working.equipment_definition_id(stored_value)
		if not available_special.has(definition_id):
			available_special[definition_id] = []
		available_special[definition_id].append(stored_value)
	var desired_modules: Array = []
	var reserved_equipment_ids: Array = []
	var outgoing_equipment_ids: Array = []
	for definition_value in desired:
		var definition_id := str(definition_value)
		var module_definition: Dictionary = content.modules.get(definition_id, {})
		if bool(module_definition.get("special_equipment", false)):
			var current_pool: Array = available_special.get(definition_id, [])
			var equipment_id := ""
			if not current_pool.is_empty():
				equipment_id = str(current_pool.pop_front())
				available_special[definition_id] = current_pool
			else:
				var stored := working.stored_equipment_ids(definition_id)
				for reserved_id in reserved_equipment_ids:
					stored.erase(reserved_id)
				if not stored.is_empty():
					equipment_id = str(stored[0])
			if equipment_id.is_empty():
				return _reject(I18n.t("notice.loadout_resources", "Unique equipment must be physically recovered before installation: %s") % I18n.content(module_definition))
			working.equipment_instances[equipment_id]["status"] = "RESERVED_REFIT"
			working.equipment_instances[equipment_id]["installed_ship_id"] = ""
			reserved_equipment_ids.append(equipment_id)
			desired_modules.append(equipment_id)
			continue
		if not simulation.module_design_available(working, definition_id):
			return _reject(I18n.t("notice.loadout_design_unavailable", "The plugin design or fabrication process is not available: %s") % I18n.content(module_definition))
		desired_modules.append(definition_id)
	for remaining_pool_value in available_special.values():
		for stored_value in (remaining_pool_value as Array):
			var equipment_id := str(stored_value)
			working.equipment_instances[equipment_id]["status"] = "RESERVED_REFIT"
			working.equipment_instances[equipment_id]["installed_ship_id"] = ""
			outgoing_equipment_ids.append(equipment_id)
	# Applying any Loadout is a fresh fabrication order. Matching ordinary
	# definitions do not reduce the cost because they are not persistent assets.
	var consumed_bom := simulation.loadout_fabrication_costs(desired)
	for item_id_value in consumed_bom.keys():
		var item_id := str(item_id_value)
		if working.available_item_quantity(item_id, location_id) < int(consumed_bom[item_id]):
			var missing_requirement := I18n.t("format.item_quantity", "%s × %d") % [I18n.content(content.items.get(item_id, {"name":item_id})), int(consumed_bom[item_id])]
			return _reject(I18n.t("notice.loadout_resources", "Missing full-loadout fabrication resources: %s") % missing_requirement)
	for item_id_value in consumed_bom.keys():
		var item_id := str(item_id_value)
		working.remove_item(item_id, int(consumed_bom[item_id]), location_id)
	var fabrication_time_ms := simulation.loadout_fabrication_time_ms(desired)
	var installation_time_ms := simulation.loadout_installation_time_ms(desired)
	var project_id := "REFIT-%06d" % (working.refit_projects.size() + int(working.statistics.get("refits_completed", 0)) + 1)
	working.refit_projects.append({
		"project_id":project_id,
		"ship_id":instance_id,
		"target_loadout_id":target_loadout_id,
		"desired_definitions":desired,
		"original_modules":original_modules,
		"desired_modules":desired_modules,
		"reserved_equipment_ids":reserved_equipment_ids,
		"outgoing_equipment_ids":outgoing_equipment_ids,
		"consumed_bom":consumed_bom,
		"loadout_semantics_version":1,
		"phase_mode":"COMBINED_FABRICATION_INSTALLATION",
		"fabrication_time_ms":fabrication_time_ms,
		"installation_time_ms":installation_time_ms,
		"completed_segments":0,
		"cycle_progress":0.0,
		"cycle_time_ms":(fabrication_time_ms + installation_time_ms) / 100.0,
		"status":"RUNNING",
		"location_id":location_id,
		"started_at_ms":int(working.total_elapsed_ms)
	})
	working_ship["modules"] = []
	working_ship["status"] = "REFITTING"
	working_ship["assignment"] = {"type":"STARPORT_REFIT", "project_id":project_id}
	last_notice = I18n.t("notice.refit_started", "Starport refit started: %s") % str(working_ship.get("name", instance_id))
	transaction.record({"type":"ShipRefitStarted", "project_id":project_id, "ship_id":instance_id})
	_commit_transaction(transaction)
	return true


func cancel_ship_refit(project_id: String) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working := transaction.working_state
	var project_index := -1
	for index in working.refit_projects.size():
		if str(working.refit_projects[index].get("project_id", "")) == project_id:
			project_index = index
			break
	if project_index < 0:
		return _reject(I18n.t("notice.refit_project_unknown", "Refit project was not found"))
	var runtime: Dictionary = working.refit_projects[project_index]
	var ship := working.ship_by_id(str(runtime.get("ship_id", "")))
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	for equipment_value in runtime.get("reserved_equipment_ids", []):
		var equipment_id := str(equipment_value)
		working.equipment_instances[equipment_id]["status"] = "STORAGE"
		working.equipment_instances[equipment_id]["installed_ship_id"] = ""
	ship["modules"] = runtime.get("original_modules", []).duplicate()
	for module_value in ship.get("modules", []):
		var equipment_id := str(module_value)
		if working.equipment_instances.has(equipment_id):
			working.equipment_instances[equipment_id]["status"] = "INSTALLED"
			working.equipment_instances[equipment_id]["installed_ship_id"] = str(ship.get("instance_id", ""))
	ship["status"] = "DOCKED"
	ship["assignment"] = {}
	working.refit_projects.remove_at(project_index)
	last_notice = I18n.t("notice.refit_cancelled", "Refit cancelled; the original loadout was restored, but committed fabrication materials were not recovered")
	transaction.record({"type":"ShipRefitCancelled", "project_id":project_id, "ship_id":runtime.get("ship_id", ""), "consumed_lost":runtime.get("consumed_bom", {}).duplicate(true)})
	_commit_transaction(transaction)
	return true


func ship_loadout_availability(instance_id: String, desired_module_definitions: Array) -> Dictionary:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return {"allowed":false, "reason_code":"SHIP_MISSING", "reason":I18n.t("notice.ship_missing", "Ship instance was not found")}
	if not state.ship_can_refit(instance_id):
		return {"allowed":false, "reason_code":"REFIT_LOCKED", "reason":I18n.t("notice.refit_locked", "The ship must be operational and docked before refitting")}
	var desired: Array = []
	for module_id_value in desired_module_definitions:
		var module_id := str(module_id_value)
		if not content.modules.has(module_id):
			return {"allowed":false, "reason_code":"MODULE_UNKNOWN", "reason":I18n.t("notice.module_unknown", "Unknown ship module")}
		if not bool(content.modules[module_id].get("special_equipment", false)) and not simulation.module_design_available(state, module_id):
			return {"allowed":false, "reason_code":"MODULE_DESIGN_LOCKED", "reason":I18n.t("notice.module_missing", "The module blueprint is unavailable")}
		desired.append(module_id)
	var validation := _validate_loadout_modules(str(ship.get("blueprint_id", "")), desired)
	if not validation.is_empty():
		return {"allowed":false, "reason_code":"INVALID_LOADOUT", "reason":validation, "desired_modules":desired}
	var available_special_counts := {}
	for installed_module_value in ship.get("modules", []):
		var installed_module_id := str(installed_module_value)
		if state.equipment_instances.has(installed_module_id):
			var installed_definition_id := state.equipment_definition_id(installed_module_id)
			available_special_counts[installed_definition_id] = int(available_special_counts.get(installed_definition_id, 0)) + 1
	var initialized_special_counts := {}
	for module_id_value in desired:
		var module_id := str(module_id_value)
		if not bool(content.modules[module_id].get("special_equipment", false)):
			continue
		if not initialized_special_counts.has(module_id):
			available_special_counts[module_id] = int(available_special_counts.get(module_id, 0)) + state.stored_equipment_ids(module_id).size()
			initialized_special_counts[module_id] = true
		available_special_counts[module_id] = int(available_special_counts[module_id]) - 1
		if int(available_special_counts[module_id]) < 0:
			return {"allowed":false, "reason_code":"EQUIPMENT_UNAVAILABLE", "reason":I18n.t("notice.equipment_unavailable", "The unique equipment asset is not available in storage"), "desired_modules":desired}
	var location_id := str(ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var fabrication_costs := simulation.loadout_fabrication_costs(desired)
	var missing_costs: Array = []
	for item_id_value in fabrication_costs.keys():
		var item_id := str(item_id_value)
		var required := int(fabrication_costs[item_id])
		var available := state.available_item_quantity(item_id, location_id)
		if available < required:
			missing_costs.append({"item_id":item_id, "required":required, "available":available, "missing":required - available})
	if not missing_costs.is_empty():
		var first_missing := missing_costs[0] as Dictionary
		var first_item_id := str(first_missing.get("item_id", ""))
		var missing_requirement := I18n.t("format.item_quantity", "%s × %d") % [I18n.content(content.items.get(first_item_id, {"name":first_item_id})), int(first_missing.get("missing", 0))]
		return {"allowed":false, "reason_code":"FABRICATION_INPUT_SHORTAGE", "reason":I18n.t("notice.loadout_resources", "Missing full-loadout fabrication resources: %s") % missing_requirement, "desired_modules":desired, "fabrication_costs":fabrication_costs, "missing_costs":missing_costs}
	return {
		"allowed":true,
		"reason_code":"READY",
		"reason":"",
		"desired_modules":desired,
		"fabrication_costs":fabrication_costs,
		"missing_costs":[]
	}


func _ship_fitting_valid(blueprint: Dictionary, module_ids: Array) -> bool:
	return content.ship_loadout_valid(str(blueprint.get("id", "")), module_ids)


func runtime_for_domain(domain_id: String) -> Dictionary:
	return simulation.runtime_for_domain(state, domain_id)


func activity_progress(domain_id: String) -> float:
	return simulation.progress_for_domain(state, domain_id)


func can_start_activity(domain_id: String, activity: Dictionary, formation_id: String = SpaceGameState.DEFAULT_FORMATION_ID) -> bool:
	if domain_id == "industry" or simulation.is_construction_activity(activity):
		return false
	return simulation.activity_available(state, activity) and simulation.costs_available(state, activity) and state.active_expedition.get("status", "IDLE") != "RUNNING" and formation_ready(formation_id) if domain_id == "expedition" else false


func can_start_construction_project(activity: Dictionary) -> bool:
	return false


func activity_duration(domain_id: String, activity: Dictionary, runtime: Dictionary = {}) -> float:
	if domain_id == "industry" or simulation.is_construction_activity(activity):
		return INF
	var actual_runtime := runtime if not runtime.is_empty() else simulation.runtime_for_domain(state, domain_id)
	return simulation.effective_duration_ms(state, domain_id, activity, actual_runtime)


func save_game() -> bool:
	if not persistence_enabled:
		return _reject(I18n.t("notice.persistence_unavailable", "Saving is unavailable in this session"))
	if state == null:
		return false
	return saves.save_state(state, content.version, [content.pack_metadata])


func reset_game() -> void:
	if persistence_enabled:
		saves.delete_save()
	state = SpaceGameState.create_new(content.domains.keys(), content.regions)
	simulation.ensure_frontier_state(state)
	offline_report = {}
	last_notice = I18n.t("notice.new_game", "New organization established in Earth Orbit.")
	state_changed.emit()


func guidance_snapshot() -> Dictionary:
	var bootstrap := _bootstrap_guidance_snapshot()
	if not bootstrap.is_empty():
		return bootstrap
	for goal_value in content.goals.values():
		var goal := goal_value as Dictionary
		if not simulation.definition_revealed(state, goal) or _requirements_met(goal.get("requirements", [])):
			continue
		for step_value in goal.get("steps", []):
			var step := step_value as Dictionary
			if _requirements_met(step.get("requirements", [])):
				continue
			var requirement := _first_actionable_requirement(step.get("requirements", []))
			var page := str(step.get("view", "overview"))
			if page == "infrastructure":
				page = "industry"
			var location_id := SpaceGameState.MAIN_BASE_LOCATION_ID
			if str(requirement.get("type", "")) in ["region", "survey_state"] and content.regions.has(str(requirement.get("id", ""))):
				location_id = str(requirement.get("id", ""))
			return {
				"goal_id":str(goal.get("id", "")),
				"step_id":str(step.get("id", "")),
				"page":page,
				"section":_guidance_section(page, requirement),
				"location_id":location_id,
				"focus_entity_id":str(requirement.get("id", step.get("id", ""))),
				"reason":requirement_text(requirement),
				"message":"%s\n%s" % [I18n.content(goal), I18n.goal_step(str(step.get("id", "continue")), str(step.get("id", "continue")).replace("_", " ").capitalize())],
				"requirement":requirement.duplicate(true),
				"acquisition_path":_guidance_acquisition_path(requirement)
			}
	return {
		"goal_id":"core_complete",
		"step_id":"economy_review",
		"page":"industry",
		"section":"diagnostics",
		"location_id":SpaceGameState.MAIN_BASE_LOCATION_ID,
		"focus_entity_id":"current_economy_analysis",
		"reason":I18n.t("guidance.core_complete", "Core progression is complete; review diagnostics and the industrial ledger."),
		"message":I18n.t("guidance.core_complete", "Core progression is complete; review diagnostics and the industrial ledger."),
		"requirement":{},
		"acquisition_path":[]
	}


func _bootstrap_guidance_snapshot() -> Dictionary:
	var base := {
		"goal_id":"establish_industry",
		"location_id":SpaceGameState.MAIN_BASE_LOCATION_ID,
		"acquisition_path":[]
	}
	if not _factory_grid_has_produced("iron_ore"):
		return _guidance_result(base, "operate_factory_grid", "industry", "factory", "earth_orbit", I18n.core("guidance.operate_factory_grid", "Build and connect the starter factory grid. Surface mines collect resources; factory machines handle every production step."))
	if int(state.completed_activities.get("assemble_frame", 0)) <= 0:
		var frame_progress := _guidance_material_progress("assemble_frame")
		if not _guidance_activity_materials_available("assemble_frame"):
			return _guidance_result(base, "prepare_first_frame", "industry", "production", "assemble_frame", I18n.core("guidance.prepare_first_frame", "3. Prepare 2 Iron Ingots and 1 Copper Ingot for the first Structural Frame.\nCurrent: %s\n\nThe workshop runs one method at a time; stop a completed separation or refining run before switching.") % frame_progress)
		return _guidance_result(base, "assemble_first_frame", "industry", "production", "assemble_frame", I18n.core("guidance.assemble_first_frame", "4. Materials are ready: %s. Start Structural Frame assembly in Production, then stop repeat production after one unit.") % frame_progress)
	if "orbital_foundry" not in state.facilities:
		var foundry_runtime := _guidance_construction_runtime("build_orbital_foundry")
		var foundry_progress := _guidance_material_progress("build_orbital_foundry", foundry_runtime)
		if not foundry_runtime.is_empty():
			var section := "production" if str(foundry_runtime.get("status", "")) == "BLOCKED" else "construction"
			return _guidance_result(base, "commission_foundry", "industry", section, "build_orbital_foundry", I18n.core("guidance.foundry_queued", "5. The Orbital Foundry is in the Construction queue (%s).\nMaterial progress: %s\n\nIf blocked, replenish the shortage in Production; Construction resumes automatically.") % [I18n.status(str(foundry_runtime.get("status", "QUEUED"))), foundry_progress])
		if not _guidance_activity_materials_available("build_orbital_foundry"):
			return _guidance_result(base, "supply_foundry", "industry", "production", "build_orbital_foundry", I18n.core("guidance.supply_foundry", "5. The Orbital Foundry needs 1 Structural Frame, 4 Iron Ingots and 2 Electronic Components.\nCurrent: %s\n\nKeep the completed frame, stop repeat assembly and refine the remaining inputs.") % foundry_progress)
		return _guidance_result(base, "commission_foundry", "industry", "construction", "build_orbital_foundry", I18n.core("guidance.commission_foundry", "5. Orbital Foundry materials are ready: %s. Open Construction and queue the facility.") % foundry_progress)
	var has_blocked_research := not str(state.research.get("project_id", "")).is_empty() and str(state.research.get("status", "")) == "BLOCKED"
	if ("electronics_facility" not in state.facilities or "research_complex" not in state.facilities) and not has_blocked_research:
		return _guidance_result(base, "commission_research", "industry", "construction", "build_research_complex", I18n.core("guidance.commission_research", "6. Build the High-Energy Systems Facility and Research Complex to open the industrial R&D chain."))
	if has_blocked_research:
		var blocker: Dictionary = state.research.get("blocker", {})
		if blocker.is_empty():
			blocker = simulation.blocker_diagnostic(state, "research", state.research)
		var requirement: Dictionary = blocker.get("requirement", {})
		var page := "research"
		var section := ""
		if str(blocker.get("primary_reason", "")) == "FIELD_TEST_REQUIRED" and str(requirement.get("type", "")) == "route_complete":
			page = "expedition"
		elif str(blocker.get("primary_reason", "")) in ["INPUT_SHORTAGE", "MISSING_CAPITAL_GOOD", "MISSING_FACILITY", "OPERATING_CONDITION", "RESEARCH_CAPACITY_SHORTAGE"] or str(requirement.get("type", "")) in ["activity_complete", "own_facility", "manufacturing_module_installed"]:
			page = "industry"
			section = "facilities" if str(requirement.get("type", "")) == "manufacturing_module_installed" else "production"
		var project_id := str(state.research.get("project_id", ""))
		var resolution := _guidance_research_blocker_resolution(blocker)
		var result := _guidance_result(base, "research_blocker", page, section, str(requirement.get("id", project_id)), I18n.core("guidance.research_blocker", "%s · %s\nNext step: %s") % [I18n.content(content.research_projects.get(project_id, {"id":project_id, "name":project_id})), requirement_text(requirement), resolution])
		result["requirement"] = requirement.duplicate(true)
		result["acquisition_path"] = _guidance_acquisition_path(requirement)
		return result
	return {}


func _guidance_result(base: Dictionary, step_id: String, page: String, section: String, focus_entity_id: String, message: String) -> Dictionary:
	var result := base.duplicate(true)
	result.merge({
		"step_id":step_id,
		"page":page,
		"section":section,
		"focus_entity_id":focus_entity_id,
		"reason":message,
		"message":message,
		"requirement":{}
	}, true)
	return result


func _guidance_ship_has_module(module_id: String) -> bool:
	for ship_value in state.ships:
		if module_id in state.ship_module_definition_ids(ship_value as Dictionary):
			return true
	return false


func _factory_grid_has_produced(item_id: String) -> bool:
	for world_value in state.factory_worlds.values():
		if int((world_value as Dictionary).get("statistics", {}).get("produced", {}).get(item_id, 0)) > 0:
			return true
	return false


func _guidance_activity_materials_available(activity_id: String) -> bool:
	var activity: Dictionary = content.activities.get(activity_id, {})
	return not activity.is_empty() and simulation.costs_available(state, activity)


func _guidance_construction_runtime(activity_id: String) -> Dictionary:
	return {}


func _guidance_material_progress(activity_id: String, runtime: Dictionary = {}) -> String:
	var activity: Dictionary = content.activities.get(activity_id, {})
	var consumed: Dictionary = runtime.get("consumed", {})
	var parts: Array[String] = []
	for cost_value in activity.get("costs", []):
		var cost := cost_value as Dictionary
		var item_id := str(cost.get("item", ""))
		var required := int(cost.get("quantity", 0))
		var available := state.item_quantity(item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
		parts.append(I18n.t("format.item_progress", "%s %d/%d") % [I18n.content(content.items.get(item_id, {"id":item_id, "name":item_id})), mini(required, int(consumed.get(item_id, 0)) + available), required])
	return ", ".join(parts)


func _guidance_research_blocker_resolution(blocker: Dictionary) -> String:
	var requirement: Dictionary = blocker.get("requirement", {})
	match str(requirement.get("type", "")):
		"activity_complete":
			var activity_id := str(requirement.get("id", ""))
			return I18n.core("guidance.research.activity_complete", "Manufacture %s in Production; the prototype must come from a real industrial line.") % I18n.content(content.activities.get(activity_id, {"id":activity_id, "name":activity_id}))
		"manufacturing_module_installed":
			var module_id := str(requirement.get("id", ""))
			var module: Dictionary = content.process_modules.get(module_id, content.universal_industry_plugins.get(module_id, {}))
			return I18n.core("guidance.research.install_module", "Install %s on the specified facility in Facility Configuration.") % I18n.content(module)
	match str(blocker.get("primary_reason", "")):
		"INPUT_SHORTAGE", "MISSING_CAPITAL_GOOD":
			var item_id := str(blocker.get("item_id", ""))
			return I18n.core("guidance.research.input_shortage", "Manufacture %s in Production; it is a physical industrial input.") % I18n.content(content.items.get(item_id, {"id":item_id, "name":item_id}))
		"FIELD_TEST_REQUIRED":
			if str(requirement.get("type", "")) == "route_complete":
				var route_id := str(requirement.get("id", ""))
				return I18n.core("guidance.research.field_test", "Run %s from Missions; elapsed time cannot substitute for this Field Test.") % I18n.content(content.expedition_routes.get(route_id, {"id":route_id, "name":route_id}))
			if str(requirement.get("type", "")) == "own_facility":
				var facility_id := str(requirement.get("id", ""))
				return I18n.core("guidance.research.build_facility", "Build and commission %s through Construction.") % I18n.content(content.facilities.get(facility_id, {"id":facility_id, "name":facility_id}))
		"MISSING_FACILITY": return I18n.core("guidance.research.missing_facility", "Install the required experimental or test module in Facility Configuration.")
		"OPERATING_CONDITION", "RESEARCH_CAPACITY_SHORTAGE": return I18n.core("guidance.research.operating_condition", "Expand research, power, cooling or Location logistics; the program resumes automatically.")
	return I18n.core("guidance.research.default", "Resolve the single primary requirement shown for this milestone; the program then resumes automatically.")


func research_blocker_resolution(blocker: Dictionary) -> String:
	return _guidance_research_blocker_resolution(blocker)


func ui_navigation_availability(page_id: String) -> Dictionary:
	# This read-only query is the single authority for progression-gated UI
	# navigation. Screens remain discoverable while the result explains why a
	# workspace is not yet actionable.
	var unlocked := true
	var condition_key := ""
	match page_id:
		"research":
			unlocked = simulation.facility_available(state, "research_complex") or not state.completed_projects.is_empty() or not str(state.research.get("project_id", "")).is_empty()
			condition_key = "unlock.research"
		"fleet":
			unlocked = not state.ships.is_empty() or simulation.facility_available(state, "orbital_starport")
			condition_key = "unlock.ships"
		"frontier":
			unlocked = not state.ships.is_empty()
			condition_key = "unlock.survey"
		"megastructure":
			unlocked = bool(state.completed_projects.get("research_megastructures", false)) or not state.megastructure_projects.is_empty()
			condition_key = "unlock.megastructure"
		_:
			unlocked = true
	return {
		"page_id":page_id,
		"unlocked":unlocked,
		"condition_key":condition_key
	}


func active_blockers(location_id: String = "") -> Array[Dictionary]:
	var raw_blockers: Array[Dictionary] = []
	for runtime_value in state.shipyard_queue:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("status", "")) in ["BLOCKED", "PAUSED"]:
			_append_blocker(raw_blockers, simulation.blocker_diagnostic(state, "shipyard", runtime), location_id)
	if str(state.research.get("status", "")) in ["BLOCKED", "PAUSED"]:
		_append_blocker(raw_blockers, simulation.blocker_diagnostic(state, "research", state.research), location_id)
	for location_id_value in state.locations.keys():
		var policy_location_id := str(location_id_value)
		for policy_value in state.location_state(policy_location_id).get("logistics", {}).get("policies", {}).values():
			var policy := policy_value as Dictionary
			var policy_blocker := policy.get("blocker", {}) as Dictionary
			if policy_blocker.is_empty():
				continue
			var policy_info: Dictionary = logistics_policy_blocker_info(policy_blocker)
			_append_blocker(raw_blockers, policy_info.get("raw", {}), location_id)
	for route_value in content.logistics_routes.values():
		var route := route_value as Dictionary
		var route_id := str(route.get("id", ""))
		var snapshot: Dictionary = simulation.logistics.service_snapshot(state, route_id)
		if float(snapshot.get("utilization", 0.0)) < 0.999:
			continue
		var route_location := str(route.get("to", SpaceGameState.MAIN_BASE_LOCATION_ID))
		_append_blocker(raw_blockers, {
			"status":"BLOCKED", "primary_reason":"ROUTE_CONGESTED", "domain":"logistics",
			"location_id":route_location, "route_id":route_id,
			"required":float(snapshot.get("demand_per_minute", snapshot.get("capacity_per_minute", 0.0))),
			"available":float(snapshot.get("capacity_per_minute", 0.0))
		}, location_id)
	var result: Array[Dictionary] = []
	var seen := {}
	for raw in raw_blockers:
		var info: Dictionary = blocker_info(raw)
		var signature := "%s|%s|%s|%s|%s" % [info.get("code", ""), info.get("domain", ""), info.get("location_id", ""), info.get("source_entity", {}).get("id", ""), info.get("missing_requirement", {}).get("item_id", "")]
		if seen.has(signature):
			continue
		seen[signature] = true
		result.append(info)
	result.sort_custom(func(a, b): return _blocker_severity_rank(str((a as Dictionary).get("severity", "INFO"))) > _blocker_severity_rank(str((b as Dictionary).get("severity", "INFO"))))
	return result


func blocker_info(raw_blocker: Dictionary) -> Dictionary:
	var code := str(raw_blocker.get("primary_reason", "UNKNOWN"))
	var domain_id := str(raw_blocker.get("domain", "unknown"))
	var location_id := str(raw_blocker.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	var item_id := str(raw_blocker.get("item_id", ""))
	var entity_id := str(raw_blocker.get("project_id", raw_blocker.get("activity_id", raw_blocker.get("route_id", raw_blocker.get("facility_id", "")))))
	if domain_id == "logistics" and not str(raw_blocker.get("route_id", "")).is_empty():
		entity_id = str(raw_blocker.get("route_id", ""))
	var target_screen := "industry"
	if code in ["ROUTE_UNAVAILABLE", "TRANSPORT_MODE_UNAVAILABLE", "ROUTE_CONGESTED", "HANDLING_CONGESTED"]:
		target_screen = "logistics"
	elif not item_id.is_empty():
		target_screen = "inventory"
	elif code in ["CONSTRUCTION_CAPACITY_FULL", "PROJECT_SLOT_FULL", "MISSING_CAPITAL_GOOD"]:
		target_screen = "construction"
	elif code in ["POWER_SHORTAGE", "COOLING_SHORTAGE", "MAINTENANCE_SHORTAGE", "STORAGE_FULL"]:
		target_screen = "location"
	elif domain_id == "research":
		target_screen = "research"
	elif domain_id == "shipyard":
		target_screen = "fleet"
	var severity := "CRITICAL"
	if code == "MANUALLY_PAUSED":
		severity = "INFO"
	elif code in ["POWER_SHORTAGE", "COOLING_SHORTAGE", "HANDLING_CONGESTED", "ROUTE_CONGESTED", "INPUT_IN_TRANSIT"]:
		severity = "WARNING"
	var upstream := _blocker_upstream_cause(location_id, item_id)
	return {
		"code":code,
		"primary_reason":code,
		"severity":severity,
		"title_key":"blocker.%s" % code,
		"description_key":"blocker.%s.description" % code,
		"domain":domain_id,
		"location_id":location_id,
		"source_entity":{"kind":domain_id, "id":entity_id},
		"missing_requirement":{"item_id":item_id, "requirement":raw_blocker.get("requirement", {}).duplicate(true)},
		"current_value":raw_blocker.get("available", 0),
		"required_value":raw_blocker.get("required", 0),
		"incoming_value":raw_blocker.get("incoming", 0),
		"freight_class":raw_blocker.get("freight_class", ""),
		"route_id":raw_blocker.get("route_id", ""),
		"transport_mode_id":raw_blocker.get("transport_mode_id", ""),
		"supported_freight_classes":raw_blocker.get("supported_freight_classes", []).duplicate() if raw_blocker.get("supported_freight_classes", null) is Array else [],
		"upstream_cause":upstream,
		"navigation_target":raw_blocker.get("navigation_target", {"screen":target_screen, "location_id":location_id, "entity_id":entity_id, "item_id":item_id}).duplicate(true),
		"raw":raw_blocker.duplicate(true)
	}


func logistics_policy_blocker_info(policy_blocker: Dictionary) -> Dictionary:
	var code_map := {
		"NO_SUPPLY_SOURCE":"INPUT_SHORTAGE",
		"ROUTE_LOCK_UNAVAILABLE":"ROUTE_UNAVAILABLE",
		"TRANSPORT_MODE_UNAVAILABLE":"TRANSPORT_MODE_UNAVAILABLE",
		"ROUTE_CONGESTION":"ROUTE_CONGESTED",
		"LOGISTICS_OPERATING_COST":"MAINTENANCE_SHORTAGE"
	}
	var raw := {
		"primary_reason":str(code_map.get(str(policy_blocker.get("code", "")), "ROUTE_UNAVAILABLE")),
		"domain":"logistics",
		"location_id":policy_blocker.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID),
		"item_id":policy_blocker.get("item_id", ""),
		"policy_code":policy_blocker.get("code", ""),
		"policy_message":policy_blocker.get("message", "")
	}
	return blocker_info(raw)


func _append_blocker(target: Array[Dictionary], blocker: Dictionary, location_filter: String) -> void:
	if blocker.is_empty():
		return
	if not location_filter.is_empty() and str(blocker.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) != location_filter:
		return
	target.append(blocker)


func _blocker_upstream_cause(location_id: String, item_id: String) -> Dictionary:
	if item_id.is_empty():
		return {}
	var transport_mode_blocker: Dictionary = simulation.logistics.demand_transport_mode_blocker(state, location_id, item_id)
	if not transport_mode_blocker.is_empty():
		return transport_mode_blocker
	for route_value in content.logistics_routes.values():
		var route := route_value as Dictionary
		if str(route.get("to", "")) != location_id:
			continue
		var source: Dictionary = state.location_state(str(route.get("from", "")))
		var policy := source.get("logistics", {}).get("policies", {}).get(item_id, {}) as Dictionary
		if str(policy.get("mode", "")) != "SUPPLY":
			continue
		var snapshot: Dictionary = simulation.logistics.service_snapshot(state, str(route.get("id", "")))
		if float(snapshot.get("utilization", 0.0)) >= 0.999:
			return {
				"code":"ROUTE_CONGESTED",
				"route_id":route.get("id", ""),
				"location_id":location_id,
				"navigation_target":{"screen":"logistics", "location_id":location_id, "entity_id":route.get("id", ""), "item_id":item_id}
			}
	return {}


func _blocker_severity_rank(severity: String) -> int:
	return {"INFO":1, "WARNING":2, "CRITICAL":3}.get(severity, 0)


func _requirements_met(requirements: Array) -> bool:
	return requirements.all(func(requirement): return simulation.requirement_met(state, requirement as Dictionary))


func _first_actionable_requirement(requirements: Array) -> Dictionary:
	for requirement_value in requirements:
		var requirement := requirement_value as Dictionary
		if simulation.requirement_met(state, requirement):
			continue
		if str(requirement.get("op", "")) in ["OR", "AND"]:
			var nested := _first_actionable_requirement(requirement.get("children", []))
			if not nested.is_empty():
				return nested
		return requirement
	return {}


func _guidance_section(page: String, requirement: Dictionary) -> String:
	if page == "location":
		return "overview"
	if page != "industry":
		return ""
	match str(requirement.get("type", "")):
		"own_facility", "facility_level", "infrastructure_site": return "construction"
		"manufacturing_module_installed": return "facilities"
		"activity_complete":
			var activity: Dictionary = content.activities.get(str(requirement.get("id", "")), {})
			return "construction" if simulation.is_construction_activity(activity) else "production"
	return "diagnostics"


func _guidance_acquisition_path(requirement: Dictionary) -> Array:
	var requirement_type := str(requirement.get("type", ""))
	var focus_item_id := ""
	var path_prefix: Array = []
	if requirement_type == "item":
		focus_item_id = str(requirement.get("id", ""))
	elif requirement_type == "activity_complete":
		var activity_id := str(requirement.get("id", ""))
		var activity: Dictionary = content.activities.get(activity_id, {})
		path_prefix.append({"kind":"ACTIVITY", "id":activity_id})
		for cost_value in activity.get("costs", []):
			var cost := cost_value as Dictionary
			var item_id := str(cost.get("item", ""))
			if state.available_item_quantity(item_id) < int(cost.get("quantity", 0)):
				focus_item_id = item_id
				break
	elif requirement_type in ["own_facility", "facility_level"]:
		var facility_id := str(requirement.get("id", ""))
		for activity_value in content.activities.values():
			var activity := activity_value as Dictionary
			if activity.get("effects", []).any(func(effect): return str((effect as Dictionary).get("type", "")) == "unlock_facility" and str((effect as Dictionary).get("facility", "")) == facility_id):
				path_prefix.append({"kind":"ACTIVITY", "id":str(activity.get("id", ""))})
				for cost_value in activity.get("costs", []):
					var cost := cost_value as Dictionary
					var item_id := str(cost.get("item", ""))
					if state.available_item_quantity(item_id) < int(cost.get("quantity", 0)):
						focus_item_id = item_id
						break
				break
	if focus_item_id.is_empty():
		return path_prefix
	var trace: Dictionary = simulation.shortest_bottleneck_chain(state, focus_item_id, SpaceGameState.MAIN_BASE_LOCATION_ID)
	path_prefix.append_array(trace.get("shortest_chain", []))
	return path_prefix


func requirement_text(requirement: Dictionary) -> String:
	var met := simulation.requirement_met(state, requirement)
	var marker := "✓" if met else "○"
	match str(requirement.get("type", "")):
		"item":
			var item_id := str(requirement.get("id", ""))
			return I18n.t("requirement.item", "%s %s  %d / %d") % [marker, I18n.content(content.items.get(item_id, {"id":item_id, "name":content.get_item_name(item_id)})), state.item_quantity(item_id), int(requirement.get("quantity", 1))]
		"region":
			var region_id := str(requirement.get("id", ""))
			return I18n.t("requirement.region", "%s Region: %s") % [marker, I18n.content(content.regions.get(region_id, {"id":region_id, "name":region_id}))]
		"domain_level":
			var domain_id := str(requirement.get("domain", ""))
			var current := int(state.domains.get(domain_id, {}).get("level", 0))
			return I18n.t("requirement.level", "%s %s Lv.%d  (%d / %d)") % [marker, I18n.domain_name(domain_id, content), int(requirement.get("level", 1)), current, int(requirement.get("level", 1))]
		"technology_domain":
			var domain_id := str(requirement.get("domain", ""))
			var current := int(state.technology_domains.get(domain_id, {}).get("level", 0))
			var domain_name := I18n.t("technology_domain.%s" % domain_id, domain_id.replace("_", " ").capitalize())
			return I18n.t("requirement.technology_domain", "%s Technology domain: %s Lv.%d (%d / %d)") % [marker, domain_name, int(requirement.get("level", 1)), current, int(requirement.get("level", 1))]
		"research_capacity":
			return I18n.t("requirement.research_capacity", "%s Research capacity %.1f / %.1f (continuous throughput, not inventory)") % [marker, simulation.research_capacity(state), float(requirement.get("value", 1.0))]
		"operating_condition":
			var condition_id := str(requirement.get("id", ""))
			var condition_name := I18n.t("operating_condition.%s" % condition_id, condition_id.replace("_", " ").capitalize())
			return I18n.t("requirement.operating_condition", "%s Operating condition: %s %.1f / %.1f") % [marker, condition_name, simulation.capability_value(state, condition_id), float(requirement.get("value", 1.0))]
		"experimental_maturity":
			var item_id := str(requirement.get("id", ""))
			return I18n.t("requirement.experimental_maturity", "%s Industrial maturity: %s (%s / %s)") % [marker, I18n.content(content.items.get(item_id, {"id":item_id, "name":item_id})), state.experimental_maturity.get(item_id, "THEORY"), requirement.get("level", "EXPERIMENTAL")]
		"spillover":
			return I18n.t("requirement.spillover", "%s Technology spillover: %s") % [marker, I18n.content(content.technologies.get(str(requirement.get("id", "")), requirement))]
		"activity_complete":
			var activity_id := str(requirement.get("id", ""))
			return I18n.t("requirement.activity", "%s Complete: %s") % [marker, I18n.content(content.activities.get(activity_id, {"id":activity_id, "name":activity_id}))]
		"route_complete":
			var route_id := str(requirement.get("id", ""))
			return I18n.t("requirement.route", "%s Expedition complete: %s") % [marker, I18n.content(content.expedition_routes.get(route_id, {"id":route_id, "name":route_id}))]
		"capability":
			var capability_id := str(requirement.get("id", ""))
			var current := simulation.capability_value(state, capability_id)
			return I18n.t("requirement.capability", "%s Capability: %s  %.0f / %.0f") % [marker, capability_id.replace("_", " ").capitalize(), current, float(requirement.get("value", 1))]
		"technology":
			return I18n.t("requirement.technology", "%s Technology: %s") % [marker, I18n.content(content.technologies.get(str(requirement.get("id", "")), requirement))]
		"project_complete":
			return I18n.t("requirement.project", "%s Project: %s") % [marker, I18n.content(content.research_projects.get(str(requirement.get("id", "")), requirement))]
		"own_ship":
			return I18n.t("requirement.ship", "%s Ship: %s") % [marker, I18n.content(content.ships.get(str(requirement.get("id", "")), requirement))]
		"own_facility", "facility_level":
			return I18n.t("requirement.facility", "%s Facility: %s Lv.%d") % [marker, I18n.content(content.facilities.get(str(requirement.get("id", "")), requirement)), int(requirement.get("level", 1))]
		"manufacturing_module_installed":
			var module_id := str(requirement.get("id", ""))
			var module: Dictionary = content.process_modules.get(module_id, content.universal_industry_plugins.get(module_id, requirement))
			var facility_id := str(requirement.get("facility", ""))
			return I18n.t("requirement.manufacturing_module", "%s Manufacturing module: %s → %s") % [marker, I18n.content(module), I18n.content(content.facilities.get(facility_id, {"id":facility_id, "name":facility_id}))]
		"survey_state":
			var location_id := str(requirement.get("id", ""))
			var current_state := str(state.location_state(location_id).get("survey_state", LocationState.UNKNOWN))
			var target_state := str(requirement.get("state", LocationState.SURVEYED))
			var location_name := I18n.content(content.regions.get(location_id, {"id":location_id, "name":location_id}))
			return I18n.t("requirement.survey_state", "%s Survey state: %s (%s / %s)") % [marker, location_name, I18n.status(current_state), I18n.status(target_state)]
		"infrastructure_site":
			return I18n.t("requirement.site", "%s Infrastructure Site: %s") % [marker, str(requirement.get("id", "")).replace("_", " ").capitalize()]
		"boss_defeated":
			return I18n.t("requirement.boss", "%s Boss defeated: %s") % [marker, I18n.content(content.enemies.get(str(requirement.get("id", "")), requirement))]
		"megastructure":
			return I18n.t("requirement.megastructure", "%s Megastructure: %s") % [marker, I18n.content(content.megastructures.get(str(requirement.get("id", "")), requirement))]
		"megastructure_phase":
			var megastructure_id := str(requirement.get("id", ""))
			var current_phase := int(state.megastructure_projects.get(megastructure_id, {}).get("phase_index", 0))
			var target_phase := int(requirement.get("phase", 0))
			return I18n.t("requirement.megastructure_phase", "%s Megastructure phase: %s %d / %d") % [marker, I18n.content(content.megastructures.get(megastructure_id, {"id":megastructure_id, "name":megastructure_id})), current_phase, target_phase]
		"game_complete":
			return I18n.t("requirement.game_complete", "%s Commission the Stellar Energy Megastructure") % marker
	return I18n.t("requirement.unknown", "%s Unknown requirement") % marker


func _start_expedition(working: SpaceGameState, activity: Dictionary, formation_id: String = SpaceGameState.DEFAULT_FORMATION_ID) -> bool:
	if working.active_expedition.get("status", "IDLE") == "RUNNING":
		return _reject(I18n.t("notice.expedition_active", "The organization already has an active Expedition front"))
	var ship_ids := working.formation_ship_ids(formation_id)
	if ship_ids.is_empty():
		return _reject(I18n.t("notice.expedition_fleet_empty", "Assign ships to a tactical formation at Starport first"))
	for ship_id in ship_ids:
		if not working.ship_is_deployment_ready(str(ship_id)):
			return _reject(I18n.t("notice.expedition_fleet_unavailable", "Every ship in the selected tactical formation must be operational and docked"))
	if simulation.fleet_command_usage(working, ship_ids) > simulation.fleet_command_capacity(working, formation_id):
		return _reject(I18n.t("notice.command_capacity", "Fleet Command Capacity would be exceeded"))
	_auto_resupply_state(working, formation_id, ship_ids)
	_assign_runtime(working.active_expedition, activity, ship_ids)
	working.active_expedition["formation_id"] = formation_id
	working.active_expedition["phase"] = str(activity.get("encounter_type", "TRAVEL"))
	for ship_id in ship_ids:
		var expedition_ship := working.ship_by_id(str(ship_id))
		expedition_ship["status"] = "EXPEDITION"
		expedition_ship["assignment"] = {"type":"EXPEDITION", "formation_id":formation_id, "activity_id":str(activity.get("id", ""))}
		expedition_ship["service_record"]["combat_deployments"] = int(expedition_ship.get("service_record", {}).get("combat_deployments", 0)) + 1
	return true


func _first_docked_ship(working: SpaceGameState) -> Dictionary:
	for ship in working.ships:
		if working.ship_is_unassigned_docked(str(ship.get("instance_id", ""))):
			return ship
	return {}


func _assign_runtime(runtime: Dictionary, activity: Dictionary, ship_ids: Array) -> void:
	runtime["activity_id"] = str(activity.get("id", ""))
	runtime["progress_ms"] = 0.0
	runtime["cycle_progress"] = 0.0
	runtime["productivity_progress"] = 0.0
	runtime["project_cycles_completed"] = 0
	runtime["paid_cycles"] = 0
	runtime["consumed"] = {}
	runtime["status"] = "RUNNING"
	runtime["assigned_ship_ids"] = ship_ids.duplicate()


func _cost_commitment(costs: Array) -> Dictionary:
	var result := {}
	for cost in costs:
		result[str(cost.get("item", ""))] = int(cost.get("quantity", 0))
	return result


func _release_runtime_ships(working: SpaceGameState, runtime: Dictionary) -> void:
	for ship_id in runtime.get("assigned_ship_ids", []):
		var ship := working.ship_by_id(str(ship_id))
		if ship.is_empty() or ship.get("status", "") == "REPAIRING":
			continue
		if float(ship.get("damage_taken", 0.0)) > 0.0 or ship.get("condition", "") == "DISABLED":
			ship["status"] = "REPAIRING"
			ship["repair_remaining_ms"] = clampf(float(ship.get("damage_taken", 0.0)) * 250.0, 1000.0, 120000.0)
			ship["assignment"] = {"type":"STARPORT_REPAIR", "source":"RECALLED_OPERATION"}
		else:
			ship["status"] = "DOCKED"
			var formation_id := working.ship_formation_id(str(ship_id))
			ship["assignment"] = {} if formation_id.is_empty() else {"formation_id":formation_id}
	runtime["assigned_ship_ids"] = []


func _load_or_create_state() -> void:
	var data := saves.load_data()
	if data.is_empty():
		state = SpaceGameState.create_new(content.domains.keys(), content.regions)
		return
	state = SpaceGameState.from_dictionary(data, content.domains.keys(), content.regions)
	var now_ms := int(Time.get_unix_time_from_system() * 1000.0)
	var elapsed := maxf(0.0, float(now_ms - state.saved_at_ms)) + state.offline_time_debt_ms
	if elapsed > 1000:
		var before_inventory: Dictionary = state.aggregate_inventory().duplicate(true)
		var before_research: Dictionary = state.research.duplicate(true)
		var before_ships: Array = state.ships.duplicate(true)
		var previous_reports := state.expedition_reports.size()
		offline_report = advance_game_time(float(elapsed))
		state.offline_time_debt_ms = maxf(0.0, float(offline_report.get("unprocessed_ms", 0.0)))
		_enrich_offline_report(offline_report, int(elapsed), before_inventory, before_research, before_ships)
		if state.expedition_reports.size() > previous_reports and state.expedition_reports[-1].get("result", "") == "FAILED":
			last_notice = I18n.t("notice.offline_failure", "Offline Expedition failed and the fleet returned to Starport for repair.")
		else:
			last_notice = I18n.t("notice.offline", "Offline operations processed %s across %d boundaries.") % [_format_duration(int(offline_report.get("simulated_ms", 0))), offline_report.get("operations", 0)]
	state.saved_at_ms = now_ms


func _enrich_offline_report(report: Dictionary, elapsed_ms: int, before_inventory: Dictionary, before_research: Dictionary, before_ships: Array) -> void:
	report["elapsed_ms"] = elapsed_ms
	var item_deltas := {}
	var item_ids: Array = before_inventory.keys()
	for item_id in state.aggregate_inventory().keys():
		if not item_ids.has(item_id):
			item_ids.append(item_id)
	for item_id in item_ids:
		var delta := state.aggregate_item_quantity(str(item_id)) - int(before_inventory.get(item_id, 0))
		if delta != 0:
			item_deltas[str(item_id)] = delta
	report["item_deltas"] = item_deltas
	report["research_before"] = before_research
	report["research_after"] = state.research.duplicate(true)
	var repaired: Array[String] = []
	for before_ship in before_ships:
		if str(before_ship.get("status", "")) != "REPAIRING":
			continue
		var after_ship := state.ship_by_id(str(before_ship.get("instance_id", "")))
		if not after_ship.is_empty() and str(after_ship.get("status", "")) == "DOCKED":
			repaired.append(str(after_ship.get("instance_id", "")))
	report["repaired_ships"] = repaired
	var problems: Array = []
	if str(state.research.get("status", "")) == "BLOCKED":
		problems.append(simulation.blocker_diagnostic(state, "research", state.research))
	if str(state.active_expedition.get("status", "")) == "FAILED":
		problems.append({"domain":"expedition", "reason":"FAILED"})
	report["problems"] = problems


func _publish_events(events: Array) -> void:
	for event in events:
		match str(event.get("type", "")):
			"DomainLeveledUp":
				last_notice = I18n.t("notice.level_up", "%s reached level %d") % [I18n.domain_name(str(event.get("domain", "")), content), int(event.get("level", 1))]
			"ExpeditionFailed":
				last_notice = I18n.t("notice.expedition_failed", "Expedition failed: fleet disabled, returned to Starport and entered automatic repair.")
			"ShipRepaired":
				last_notice = I18n.t("notice.ship_repaired", "%s completed repairs and is docked.") % str(event.get("ship_id", ""))
			"ResearchCompleted":
				var project_id := str(event.get("project_id", ""))
				last_notice = I18n.t("notice.research_completed", "Research completed: %s") % I18n.content(content.research_projects.get(project_id, {"id":project_id, "name":project_id}))
			"ExpeditionRouteCompleted":
				var route_id := str(event.get("route_id", ""))
				last_notice = I18n.t("notice.route_completed", "Expedition completed: %s") % I18n.content(content.expedition_routes.get(route_id, {"id":route_id, "name":route_id}))
			"GameCompleted":
				last_notice = I18n.t("notice.game_completed", "Stellar Energy commissioning complete. The Sol System industrial era is complete.")
		domain_event.emit(event)


func _reject(reason: String) -> bool:
	last_notice = reason
	command_rejected.emit(reason)
	state_changed.emit()
	return false


func _commit_transaction(transaction: GameStateTransaction) -> void:
	var committed_state := transaction.commit()
	simulation.refresh_demand_registry(committed_state)
	state = committed_state
	_publish_events(transaction.events)
	state_changed.emit()


func _format_duration(milliseconds: int) -> String:
	var seconds := milliseconds / 1000
	if seconds < 60:
		return I18n.t("format.duration_seconds", "%ds") % seconds
	if seconds < 3600:
		return I18n.t("format.duration_minutes", "%dm %02ds") % [seconds / 60, seconds % 60]
	return I18n.t("format.duration_hours", "%dh %02dm") % [seconds / 3600, (seconds % 3600) / 60]
