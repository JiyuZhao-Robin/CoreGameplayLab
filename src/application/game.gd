extends Node

signal state_changed
signal domain_event(event: Dictionary)
signal command_rejected(reason: String)

const CONTENT_PATH := "res://data/content.json"
const AUTOSAVE_INTERVAL_MS := 15000.0
const SIMULATION_STEP_MS := 100.0

var content := ContentDatabase.new()
var state: SpaceGameState
var simulation: SimulationEngine
var saves := LocalSaveRepository.new()
var offline_report := {}
var last_notice := ""
var persistence_enabled := not OS.get_cmdline_user_args().has("--no-persistence")

var _simulation_accumulator_ms := 0.0
var _autosave_accumulator_ms := 0.0


func _ready() -> void:
	if not content.load_from_file(CONTENT_PATH):
		push_error("Content validation failed:\n%s" % "\n".join(content.errors))
	simulation = SimulationEngine.new(content)
	if persistence_enabled:
		_load_or_create_state()
	else:
		state = SpaceGameState.create_new(content.domains.keys(), content.regions)
	simulation.ensure_frontier_state(state)
	if last_notice.is_empty():
		last_notice = I18n.t("notice.frontier_ready", "Ships are persistent capital assets. Commit each available vessel to extraction or the active Expedition.")
	set_process(true)


func _process(delta: float) -> void:
	var elapsed_ms := delta * 1000.0
	_simulation_accumulator_ms += elapsed_ms
	_autosave_accumulator_ms += elapsed_ms
	if _simulation_accumulator_ms >= SIMULATION_STEP_MS:
		var report := simulation.advance(state, _simulation_accumulator_ms)
		_simulation_accumulator_ms = 0.0
		var events: Array = report.get("events", [])
		_publish_events(events)
		run_automation_rules()
		if not events.is_empty():
			state_changed.emit()
	if persistence_enabled and _autosave_accumulator_ms >= AUTOSAVE_INTERVAL_MS:
		save_game()
		_autosave_accumulator_ms = 0.0


func _notification(what: int) -> void:
	if persistence_enabled and (what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_APPLICATION_PAUSED):
		save_game()


func start_activity(domain_id: String, activity_id: String) -> bool:
	if not state.domains.has(domain_id) or not content.activities.has(activity_id):
		return _reject(I18n.t("notice.unknown_activity", "Unknown activity command"))
	var activity: Dictionary = content.activities[activity_id]
	if str(activity.get("domain", "")) != domain_id:
		return _reject(I18n.t("notice.wrong_domain", "Activity does not belong to this operation type"))
	if simulation.is_construction_activity(activity):
		return start_construction_project(activity_id)
	if not simulation.activity_available(state, activity):
		return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	if not simulation.costs_available(state, activity):
		return _reject(I18n.t("notice.resources", "Strategic Inventory cannot fund one cycle"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working := transaction.working_state
	match domain_id:
		"mining":
			if not _start_mining(working, activity):
				return false
		"industry":
			if not _start_industry(working, activity):
				return false
		"expedition":
			if not _start_expedition(working, activity):
				return false
		_:
			return _reject(I18n.t("notice.unknown_domain", "Unknown operation type"))
	last_notice = I18n.t("notice.started", "%s started: %s") % [I18n.content(content.domains[domain_id]), I18n.content(activity)]
	transaction.record({"type":"OperationStarted", "domain":domain_id, "activity_id":activity_id})
	_commit_transaction(transaction)
	return true


func stop_activity(domain_id: String) -> bool:
	if not state.domains.has(domain_id):
		return _reject(I18n.t("notice.unknown_domain", "Unknown operation type"))
	if domain_id == "mining":
		var active_slots: Array[int] = []
		for index in state.mining_operations.size():
			if state.mining_operations[index].get("status", "IDLE") == "RUNNING":
				active_slots.append(index)
		if active_slots.is_empty():
			return _reject(I18n.t("notice.no_active", "No active extraction operation to recall"))
		var transaction := GameStateTransaction.new(state, content.domains.keys())
		for slot in active_slots:
			var operation: Dictionary = transaction.working_state.mining_operations[slot]
			_release_runtime_ships(transaction.working_state, operation)
			_reset_extraction_runtime(operation)
		last_notice = I18n.t("notice.paused", "All active extraction ships were recalled")
		transaction.record({"type":"AllExtractionOperationsStopped", "count":active_slots.size()})
		_commit_transaction(transaction)
		return true
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
		transaction.working_state.unload_fleet_cargo("expedition", false)
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
		return _reject("Invalid maintenance state")
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty() or str(ship.get("status", "")) != "DOCKED" or str(ship.get("condition", "")) != "OPERATIONAL":
		return _reject("The ship must be operational and docked before changing maintenance state")
	var current := str(ship.get("maintenance_state", "ACTIVE"))
	if current == normalized:
		return true
	if current == "MOTHBALLED":
		return _reject("A Mothballed ship must complete a Starport reactivation project")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	for domain_id in ["mining", "expedition"]:
		var roster := transaction.working_state.fleet_ship_ids(domain_id)
		roster.erase(instance_id)
		transaction.working_state.set_fleet_ship_ids(domain_id, roster)
	var working_ship := transaction.working_state.ship_by_id(instance_id)
	working_ship["maintenance_state"] = normalized
	working_ship["assignment"] = {}
	last_notice = "Maintenance state changed: %s → %s" % [working_ship.get("name", instance_id), normalized]
	transaction.record({"type":"ShipMaintenanceStateChanged", "ship_id":instance_id, "maintenance_state":normalized})
	_commit_transaction(transaction)
	return true


func start_ship_reactivation(instance_id: String) -> bool:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty() or str(ship.get("maintenance_state", "")) != "MOTHBALLED" or str(ship.get("status", "")) != "DOCKED":
		return _reject("Only a docked Mothballed ship can be reactivated")
	var running_projects := state.ship_service_projects.filter(func(project): return str(project.get("status", "")) == "RUNNING").size()
	if running_projects >= simulation.ship_service_capacity(state):
		return _reject("Starport and repair-dock service capacity is fully committed")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working_ship := transaction.working_state.ship_by_id(instance_id)
	var costs := simulation.ship_reactivation_costs(working_ship)
	var location_id := str(working_ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	for item_id in costs:
		if transaction.working_state.available_item_quantity(str(item_id), location_id) < int(costs[item_id]):
			return _reject("Reactivation materials are insufficient: %s × %d" % [item_id, int(costs[item_id])])
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
	last_notice = "Mothball reactivation started: %s" % working_ship.get("name", instance_id)
	transaction.record({"type":"ShipReactivationStarted", "project_id":project_id, "ship_id":instance_id, "costs":costs})
	_commit_transaction(transaction)
	return true


func scrap_ship(instance_id: String) -> bool:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty() or str(ship.get("status", "")) != "DOCKED":
		return _reject("Only an idle docked ship can be scrapped")
	if not state.ship_fleet_domain(instance_id).is_empty() or state.refit_projects.any(func(project): return str(project.get("ship_id", "")) == instance_id) or state.ship_service_projects.any(func(project): return str(project.get("ship_id", "")) == instance_id):
		return _reject("Remove the ship from fleets and finish all service projects before scrapping")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working_ship := transaction.working_state.ship_by_id(instance_id)
	var recovered := simulation.ship_scrap_recovery(working_ship)
	var location_id := str(working_ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
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
	last_notice = "Ship scrapped and archived: %s" % archive_entry["name"]
	transaction.record({"type":"ShipScrapped", "ship_id":instance_id, "recovered":recovered})
	_commit_transaction(transaction)
	return true


func set_ship_fleet_assignment(instance_id: String, domain_id: String) -> bool:
	if domain_id not in ["", "mining", "expedition"]:
		return _reject(I18n.t("notice.ship_assignment_unknown", "Unknown ship assignment"))
	var ship: Dictionary = state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	if not state.ship_is_docked(instance_id):
		return _reject(I18n.t("notice.ship_assignment_locked", "The ship must be operational and docked before changing assignment"))
	if not domain_id.is_empty() and (str(ship.get("maintenance_state", "ACTIVE")) != "ACTIVE" or float(ship.get("maintenance_coverage", 1.0)) <= 0.0):
		return _reject("Only a fully maintained Active ship can join an operational fleet")
	var current_domain := state.ship_fleet_domain(instance_id)
	if current_domain == domain_id:
		return true
	if (current_domain == "expedition" and fleet_is_active("expedition")) or (domain_id == "expedition" and fleet_is_active("expedition")):
		return _reject(I18n.t("notice.fleet_active", "Recall or stop the active fleet before changing its roster"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	for candidate_domain in ["mining", "expedition"]:
		var roster := transaction.working_state.fleet_ship_ids(candidate_domain)
		roster.erase(instance_id)
		transaction.working_state.set_fleet_ship_ids(candidate_domain, roster)
	if not domain_id.is_empty():
		var target_roster := transaction.working_state.fleet_ship_ids(domain_id)
		target_roster.append(instance_id)
		if domain_id == "expedition" and simulation.fleet_command_usage(transaction.working_state, target_roster) > simulation.fleet_command_capacity(transaction.working_state):
			return _reject(I18n.t("notice.command_capacity", "Fleet Command Capacity would be exceeded"))
		transaction.working_state.set_fleet_ship_ids(domain_id, target_roster)
	var working_ship := transaction.working_state.ship_by_id(instance_id)
	working_ship["assignment"] = {} if domain_id.is_empty() else {"domain":domain_id, "fleet":"default"}
	var assignment_name := I18n.t("ships.unassigned", "Unassigned") if domain_id.is_empty() else I18n.t("ships.%s_fleet" % domain_id, "%s Fleet" % domain_id.capitalize())
	last_notice = I18n.t("notice.ship_assignment_changed", "%s assignment changed to %s") % [I18n.content(content.ships.get(str(working_ship.get("blueprint_id", "")), {})), assignment_name]
	transaction.record({"type":"ShipFleetAssignmentChanged", "ship_id":instance_id, "domain":domain_id})
	_commit_transaction(transaction)
	return true


func assign_ship_to_mining_fleet(instance_id: String) -> bool:
	return set_ship_fleet_assignment(instance_id, "mining")


func remove_ship_from_mining_fleet(instance_id: String) -> bool:
	return set_ship_fleet_assignment(instance_id, "")


func fleet_is_active(domain_id: String) -> bool:
	match domain_id:
		"mining":
			return state.mining_operations.any(func(operation): return operation.get("status", "IDLE") == "RUNNING")
		"expedition":
			return state.active_expedition.get("status", "IDLE") == "RUNNING"
	return false


func fleet_ready(domain_id: String) -> bool:
	var ship_ids := state.fleet_ship_ids(domain_id)
	if ship_ids.is_empty():
		return false
	for ship_id in ship_ids:
		var ship := state.ship_by_id(str(ship_id))
		if not state.ship_is_docked(str(ship_id)) or state.ship_fleet_domain(str(ship_id)) != domain_id or str(ship.get("maintenance_state", "ACTIVE")) != "ACTIVE" or float(ship.get("maintenance_coverage", 1.0)) <= 0.0:
			return false
	return true


func integrate_mining_site(site_id: String, network_id: String) -> bool:
	simulation.ensure_frontier_state(state)
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.integrate_mining_site(transaction.working_state, site_id, network_id):
		return _reject(I18n.t("notice.network_requirements", "Site mastery, extraction technology or material-grade requirements are not met"))
	last_notice = I18n.t("notice.network_integrated", "Permanent mining site integrated into the regional automation network")
	transaction.record({"type":"MiningSiteIntegrated", "network_id":network_id, "site_id":site_id})
	_commit_transaction(transaction)
	return true


func set_fleet_supply_plan(item_id: String, quantity: int, fleet_id: String = "expedition") -> bool:
	if not content.items.has(item_id) or quantity < 0:
		return _reject(I18n.t("notice.supply_plan_invalid", "Invalid fleet supply plan"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var logistics := transaction.working_state.fleet_logistics_runtime(fleet_id)
	var plan: Dictionary = logistics.get("supply_plan", {})
	plan[item_id] = quantity
	logistics["supply_plan"] = plan
	transaction.record({"type":"FleetSupplyPlanChanged", "fleet_id":fleet_id, "item_id":item_id, "quantity":quantity})
	_commit_transaction(transaction)
	return true


func set_ship_combat_zone(ship_id: String, zone: String, fleet_id: String = "expedition") -> bool:
	var normalized_zone := zone.to_upper()
	if normalized_zone not in ["FRONT", "MID", "REAR"] or state.ship_by_id(ship_id).is_empty():
		return _reject("Invalid ship or combat zone")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var formation: Dictionary = transaction.working_state.fleet_logistics_runtime(fleet_id).get("formation", {})
	var ship_zones: Dictionary = formation.get("ship_zones", {})
	ship_zones[ship_id] = normalized_zone
	formation["ship_zones"] = ship_zones
	transaction.working_state.fleet_logistics_runtime(fleet_id)["formation"] = formation
	transaction.record({"type":"ShipCombatZoneChanged", "fleet_id":fleet_id, "ship_id":ship_id, "zone":normalized_zone})
	_commit_transaction(transaction)
	return true


func set_fleet_doctrine(doctrine: String, fleet_id: String = "expedition") -> bool:
	var normalized := doctrine.to_upper()
	if normalized not in ["HOLD_FORMATION", "AGGRESSIVE_PUSH", "MISSILE_SATURATION", "LONG_RANGE_ENGAGEMENT"]:
		return _reject("Invalid fleet doctrine")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var formation: Dictionary = transaction.working_state.fleet_logistics_runtime(fleet_id).get("formation", {})
	formation["doctrine"] = normalized
	transaction.working_state.fleet_logistics_runtime(fleet_id)["formation"] = formation
	transaction.record({"type":"FleetDoctrineChanged", "fleet_id":fleet_id, "doctrine":normalized})
	_commit_transaction(transaction)
	return true


func set_fleet_retreat_policy(mode: String, threshold: float = 0.25, fleet_id: String = "expedition") -> bool:
	var normalized := mode.to_upper()
	if normalized not in ["HULL_THRESHOLD", "NEVER"]:
		return _reject("Invalid retreat policy")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var formation: Dictionary = transaction.working_state.fleet_logistics_runtime(fleet_id).get("formation", {})
	formation["retreat_policy"] = {"mode":normalized, "threshold":clampf(threshold, 0.05, 0.95)}
	transaction.working_state.fleet_logistics_runtime(fleet_id)["formation"] = formation
	transaction.record({"type":"FleetRetreatPolicyChanged", "fleet_id":fleet_id, "mode":normalized, "threshold":clampf(threshold, 0.05, 0.95)})
	_commit_transaction(transaction)
	return true


func auto_resupply_fleet(fleet_id: String = "expedition", ship_ids: Array = []) -> bool:
	var selected := ship_ids.duplicate()
	if selected.is_empty():
		selected = state.fleet_ship_ids(fleet_id)
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	_auto_resupply_state(transaction.working_state, fleet_id, selected)
	last_notice = I18n.t("notice.fleet_resupplied", "Available supplies loaded according to the saved fleet plan")
	transaction.record({"type":"FleetResupplied", "fleet_id":fleet_id, "ship_ids":selected})
	_commit_transaction(transaction)
	return true


func start_survey_mission(target_location_id: String, target_state: String, ship_ids: Array = [], origin_location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> bool:
	simulation.ensure_frontier_state(state)
	var selected := ship_ids.duplicate()
	var capability := str(content.survey_rules.get("required_capabilities", {}).get(target_state, ""))
	if selected.is_empty():
		for ship_value in state.ships:
			var ship := ship_value as Dictionary
			var ship_id := str(ship.get("instance_id", ""))
			if state.ship_is_docked(ship_id) and str(ship.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)) == origin_location_id and simulation.capability_value_for_ships(state, capability, [ship_id]) >= 1.0:
				selected.append(ship_id)
				break
	if selected.is_empty():
		return _reject("A docked Survey Vessel with the required Survey Module is required")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.start_survey_mission(transaction.working_state, target_location_id, target_state, selected, origin_location_id):
		return _reject("Survey Mission cannot start: verify Survey State, vessel capability, fuel and maintenance supplies")
	last_notice = "Survey Mission started: %s → %s" % [target_location_id, target_state]
	transaction.record({"type":"SurveyMissionStarted", "target":target_location_id, "target_state":target_state, "origin":origin_location_id, "ship_ids":selected})
	_commit_transaction(transaction)
	return true


func _auto_resupply_state(working: SpaceGameState, fleet_id: String, ship_ids: Array) -> void:
	var logistics := working.fleet_logistics_runtime(fleet_id)
	var supplies: Dictionary = logistics.get("supplies", {})
	var available_space := maxi(0, simulation.fleet_cargo_capacity(working, ship_ids) - simulation.fleet_cargo_used(working, fleet_id))
	for item_id in logistics.get("supply_plan", {}):
		if available_space <= 0:
			break
		var desired := maxi(0, int(logistics["supply_plan"].get(item_id, 0)))
		var missing := maxi(0, desired - int(supplies.get(item_id, 0)))
		var transfer := mini(missing, mini(working.item_quantity(str(item_id)), available_space))
		if transfer <= 0:
			continue
		working.remove_item(str(item_id), transfer)
		supplies[str(item_id)] = int(supplies.get(str(item_id), 0)) + transfer
		available_space -= transfer
	logistics["supplies"] = supplies


func start_extraction_operation(site_id: String, ship_ids: Array = [], preferred_slot: int = -1) -> bool:
	simulation.ensure_frontier_state(state)
	if not state.mining_site_available(site_id):
		return _reject(I18n.t("notice.mining_site_unavailable", "This permanent mining site is undiscovered, technology-locked or already automated"))
	var site: Dictionary = content.mining_sites.get(site_id, {})
	var location_id := str(site.get("location", ""))
	var location: Dictionary = content.mining_locations.get(location_id, {})
	var activity := content.get_mining_activity_for_site(site_id)
	if activity.is_empty() or not simulation.activity_available(state, activity):
		return _reject(I18n.t("notice.invalid_mining_site", "This permanent mining site is not available"))
	var selected: Array = ship_ids.duplicate()
	if selected.is_empty():
		for ship_id in state.fleet_ship_ids("mining"):
			if state.ship_is_docked(str(ship_id)):
				selected = [str(ship_id)]
				break
	if selected.is_empty():
		return _reject(I18n.t("notice.extraction_ship_required", "Choose at least one operational ship fitted with extraction equipment"))
	var unique_selected: Array = []
	for ship_id in selected:
		var id := str(ship_id)
		if unique_selected.has(id):
			continue
		if not state.ship_is_docked(id) or simulation.mining_power(state, [id]) <= 0.0:
			return _reject(I18n.t("notice.extraction_ship_unavailable", "Every selected ship must be operational, available and fitted with extraction equipment"))
		for requirement in activity.get("requirements", []):
			if requirement.get("type", "") == "capability" and simulation.capability_value_for_ships(state, str(requirement.get("id", "")), [id]) < float(requirement.get("value", 1)):
				return _reject(I18n.t("notice.requirements", "Each selected ship must satisfy the site's deterministic operating requirements"))
		unique_selected.append(id)
	selected = unique_selected
	var active_ids := simulation.active_extraction_ship_ids(state)
	var command_candidate := active_ids.duplicate()
	command_candidate.append_array(selected)
	if simulation.extraction_command_usage(state, command_candidate) > simulation.extraction_command_capacity(state):
		return _reject(I18n.t("notice.extraction_command_capacity", "Extraction Command Capacity would be exceeded"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = {}
	for operation in transaction.working_state.mining_operations:
		if str(operation.get("status", "IDLE")) == "RUNNING" and str(operation.get("site_id", "")) == site_id:
			runtime = operation
			break
	if runtime.is_empty() and preferred_slot >= 0 and preferred_slot < transaction.working_state.mining_operations.size():
		runtime = transaction.working_state.mining_operations[preferred_slot]
	elif runtime.is_empty() and preferred_slot < 0:
		runtime = _first_available_slot(transaction.working_state.mining_operations, transaction.working_state.mining_operations.size())
	if runtime.is_empty():
		var record_index := transaction.working_state.mining_operations.size()
		transaction.working_state.mining_operations.append(SpaceGameState.create_operation_record(record_index, "mining"))
		runtime = transaction.working_state.mining_operations[record_index]
	if runtime.get("status", "IDLE") == "RUNNING":
		var assigned: Array = runtime.get("assigned_ship_ids", [])
		assigned.append_array(selected)
		runtime["assigned_ship_ids"] = assigned
	else:
		runtime["location_id"] = location_id
		runtime["site_id"] = site_id
		runtime["raw_material_id"] = str(location.get("raw_material", ""))
		_assign_runtime(runtime, activity, selected)
	for ship_id in selected:
		_assign_ship(transaction.working_state.ship_by_id(str(ship_id)), "EXTRACTION_OPERATION", "mining", int(runtime.get("slot", 0)))
	last_notice = I18n.t("notice.extraction_started", "Permanent-site extraction started: %s") % I18n.content(site)
	transaction.record({"type":"ExtractionOperationStarted", "slot":runtime.get("slot", 0), "site_id":site_id, "location_id":location_id, "raw_material_id":location.get("raw_material", ""), "ship_ids":selected})
	_commit_transaction(transaction)
	return true


func stop_mining_operation(slot: int) -> bool:
	if slot < 0 or slot >= state.mining_operations.size():
		return _reject(I18n.t("notice.unknown_slot", "Unknown Mining Operation slot"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = transaction.working_state.mining_operations[slot]
	if runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED"]:
		return _reject(I18n.t("notice.no_active", "No active operation to recall"))
	_release_runtime_ships(transaction.working_state, runtime)
	_reset_extraction_runtime(runtime)
	last_notice = I18n.t("notice.extraction_stopped", "Extraction vessel recalled")
	transaction.record({"type":"MiningOperationStopped", "slot":slot})
	_commit_transaction(transaction)
	return true


func stop_industry_operation(slot: int) -> bool:
	if slot < 0 or slot >= state.industrial_operations.size():
		return _reject(I18n.t("notice.unknown_industry_slot", "Unknown production slot"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = transaction.working_state.industrial_operations[slot]
	if runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED"]:
		return _reject(I18n.t("notice.no_active", "No active operation to recall"))
	runtime["status"] = "PAUSED"
	runtime["control_mode"] = "OFF"
	runtime["manual_lock"] = true
	runtime["reserved_costs"] = {}
	runtime["input_commitments"] = {}
	runtime["actual_rate"] = 0.0
	last_notice = I18n.t("notice.industry_stopped", "Production slot %d paused") % [slot + 1]
	transaction.record({"type":"IndustrialOperationStopped", "slot":slot})
	_commit_transaction(transaction)
	return true


func start_industry_operation(slot: int, activity_id: String) -> bool:
	if slot < 0 or slot >= state.industrial_operations.size():
		return _reject(I18n.t("notice.unknown_industry_slot", "Unknown manufacturing facility"))
	if not content.activities.has(activity_id):
		return _reject(I18n.t("notice.unknown_activity", "Unknown activity command"))
	var activity: Dictionary = content.activities[activity_id]
	if str(activity.get("domain", "")) != "industry":
		return _reject(I18n.t("notice.wrong_domain", "Activity does not belong to Industry"))
	if simulation.is_construction_activity(activity):
		return start_construction_project(activity_id)
	var current: Dictionary = state.industrial_operations[slot]
	if current.get("status", "IDLE") in ["RUNNING", "BLOCKED"]:
		return _reject(I18n.t("notice.slot_running", "Pause the current operation before changing its recipe"))
	var facility_id := str(activity.get("facility", ""))
	if facility_id != str(current.get("facility_id", "")):
		return _reject(I18n.t("notice.wrong_manufacturing_facility", "This recipe belongs to a different manufacturing facility"))
	if not simulation.facility_available(state, facility_id):
		return _reject(I18n.t("notice.facility_missing", "Required Industrial Facility is not active"))
	var location_id := str(current.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	if not simulation.industry_recipe_capabilities_met(state, activity, location_id):
		return _reject(I18n.t("notice.process_capability_missing", "Install the required process module before starting this recipe"))
	if not bool(simulation.production_method_environment_eligibility(state, location_id, activity).get("eligible", false)):
		return _reject("This Production Method is incompatible with the selected Location environment")
	if not simulation.production_method_available_at_scale(state, location_id, facility_id, activity):
		return _reject("This Production Method requires a higher Industry Scale Stage")
	if not simulation.activity_available(state, activity, location_id):
		return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	if not simulation.costs_available_for_industry_slot(state, activity, slot):
		return _reject(I18n.t("notice.resources", "Strategic Inventory cannot fund one cycle"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = transaction.working_state.industrial_operations[slot]
	_assign_runtime(runtime, activity, [])
	runtime["method_id"] = activity_id
	runtime["product_family_id"] = simulation.production_family_id(activity)
	runtime["production_device_id"] = simulation.production_device_id(transaction.working_state, activity, location_id)
	runtime["control_mode"] = "PINNED"
	runtime["manual_lock"] = true
	runtime["allowed_method_group"] = str(activity.get("production_method_group", activity.get("production_family", "")))
	runtime["material_savings_fractional"] = {}
	runtime["waste_fractional"] = {}
	runtime["reserved_costs"] = simulation.industry_cycle_costs(transaction.working_state, runtime, activity, false)
	runtime["input_commitments"] = runtime["reserved_costs"].duplicate(true)
	transaction.working_state.ensure_location_industry(str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)), facility_id, 1)["production_method_id"] = activity_id
	last_notice = I18n.t("notice.industry_started", "%s started: %s") % [I18n.content(content.facilities[facility_id]), I18n.content(activity)]
	transaction.record({"type":"IndustrialOperationStarted", "slot":slot, "facility_id":facility_id, "activity_id":activity_id, "location_id":runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID)})
	_commit_transaction(transaction)
	return true


func add_production_line(location_id: String, facility_id: String, activity_id: String, capacity_allocation: int = 100, priority: int = 50) -> bool:
	if not state.has_location(location_id) or not content.facilities.has(facility_id) or not content.activities.has(activity_id):
		return _reject("Invalid Production Line configuration")
	var activity: Dictionary = content.activities[activity_id]
	if str(activity.get("domain", "")) != "industry" or simulation.is_construction_activity(activity) or str(activity.get("facility", "")) != facility_id:
		return _reject("This recipe cannot run on the selected Production Line")
	if not bool(simulation.production_method_environment_eligibility(state, location_id, activity).get("eligible", false)):
		return _reject("This Production Method is incompatible with the selected Location environment")
	if state.production_lines_for(location_id, facility_id).size() >= simulation.max_production_lines(state, location_id, facility_id):
		return _reject("The current Industry Scale Stage has no additional Production Line capacity")
	if not simulation.production_method_available_at_scale(state, location_id, facility_id, activity):
		return _reject("This Production Method requires a higher Industry Scale Stage")
	if not simulation.industry_recipe_capabilities_met(state, activity, location_id) or not simulation.activity_available(state, activity, location_id):
		return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime := transaction.working_state.create_production_line(location_id, facility_id)
	if runtime.is_empty():
		return _reject("Production Line limit reached")
	# Schema compatibility accepts the old argument, but a real Factory now shares
	# throughput automatically between its active Production Lines.
	runtime["capacity_allocation"] = 100.0
	runtime["priority"] = clampi(priority, 0, 100)
	if not simulation.costs_available_for_industry_slot(transaction.working_state, activity, int(runtime.get("slot", -1))):
		return _reject(I18n.t("notice.resources", "Strategic Inventory cannot fund one cycle"))
	_assign_runtime(runtime, activity, [])
	runtime["method_id"] = activity_id
	runtime["product_family_id"] = simulation.production_family_id(activity)
	runtime["production_device_id"] = simulation.production_device_id(transaction.working_state, activity, location_id)
	runtime["control_mode"] = "PINNED"
	runtime["manual_lock"] = true
	runtime["allowed_method_group"] = str(activity.get("production_method_group", activity.get("production_family", "")))
	runtime["reserved_costs"] = simulation.industry_cycle_costs(transaction.working_state, runtime, activity, false)
	runtime["input_commitments"] = runtime["reserved_costs"].duplicate(true)
	last_notice = "Production Line added: %s / %s" % [I18n.content(content.facilities[facility_id]), I18n.content(activity)]
	transaction.record({"type":"ProductionLineAdded", "line_id":runtime.get("line_id", ""), "slot":runtime.get("slot", -1), "location_id":location_id, "facility_id":facility_id, "activity_id":activity_id})
	_commit_transaction(transaction)
	return true


func configure_production_line(slot: int, capacity_allocation: int, priority: int) -> bool:
	if slot < 0 or slot >= state.industrial_operations.size() or capacity_allocation < 1 or capacity_allocation > 100 or priority < 0 or priority > 100:
		return _reject("Invalid Production Line allocation or priority")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = transaction.working_state.industrial_operations[slot]
	runtime["capacity_allocation"] = 100.0
	runtime["priority"] = priority
	runtime["theoretical_rate"] = 0.0
	runtime["actual_rate"] = 0.0
	last_notice = "Production Line priority configured: %d" % priority
	transaction.record({"type":"ProductionLineConfigured", "line_id":runtime.get("line_id", ""), "slot":slot, "control_mode":runtime.get("control_mode", "PINNED"), "priority":priority})
	_commit_transaction(transaction)
	return true


func set_production_line_control(slot: int, control_mode: String, manual_lock: bool = true) -> bool:
	if slot < 0 or slot >= state.industrial_operations.size() or control_mode not in ["PINNED", "AUTO", "OFF"]:
		return _reject("Invalid Production Line control mode")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = transaction.working_state.industrial_operations[slot]
	if str(runtime.get("activity_id", "")).is_empty():
		return _reject("Production Line has no Production Method")
	runtime["control_mode"] = control_mode
	runtime["manual_lock"] = manual_lock
	if control_mode == "OFF":
		runtime["status"] = "PAUSED"
		runtime["actual_rate"] = 0.0
	else:
		var activity: Dictionary = content.activities.get(str(runtime.get("activity_id", "")), {})
		var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
		if activity.is_empty() or not simulation.industry_recipe_capabilities_met(transaction.working_state, activity, location_id):
			return _reject("Production Method or Production Device is unavailable")
		if not bool(simulation.production_method_environment_eligibility(transaction.working_state, location_id, activity).get("eligible", false)):
			return _reject("This Production Method is incompatible with the selected Location environment")
		runtime["production_device_id"] = simulation.production_device_id(transaction.working_state, activity, location_id)
		runtime["status"] = "RUNNING"
		runtime["blocked_reason"] = ""
	last_notice = "Production Line control: %s" % control_mode
	transaction.record({"type":"ProductionLineControlChanged", "line_id":runtime.get("line_id", ""), "slot":slot, "control_mode":control_mode, "manual_lock":manual_lock})
	_commit_transaction(transaction)
	return true


func add_automation_rule(condition: Dictionary, action: Dictionary, cooldown_ms: float = 30000.0, hysteresis: float = 0.05) -> bool:
	var action_type := str(action.get("type", ""))
	if action_type not in ["PAUSE_FACTORY", "RESUME_FACTORY", "ADJUST_ROUTE_POLICY", "ADJUST_PROJECT_PRIORITY"] or condition.is_empty():
		return _reject("Automation supports only pre-authorized pause, resume, route policy and project priority actions")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var serial := int(transaction.working_state.next_automation_rule_serial)
	transaction.working_state.next_automation_rule_serial = serial + 1
	var rule := {
		"rule_id":"AUTOMATION-%06d" % serial, "enabled":true, "paused":false,
		"condition":condition.duplicate(true), "action":action.duplicate(true),
		"cooldown_ms":maxf(0.0, cooldown_ms), "hysteresis":maxf(0.0, hysteresis),
		"last_triggered_at_ms":-1, "last_condition_active":false, "authorized":true,
		"created_at_ms":int(transaction.working_state.total_elapsed_ms)
	}
	transaction.working_state.automation_rules.append(rule)
	last_notice = "Automation rule authorized: %s" % rule["rule_id"]
	transaction.record({"type":"AutomationRuleAuthorized", "rule_id":rule["rule_id"], "condition":condition, "action":action})
	_commit_transaction(transaction)
	return true


func set_automation_rule_paused(rule_id: String, paused: bool) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var found := false
	for rule_value in transaction.working_state.automation_rules:
		var rule := rule_value as Dictionary
		if str(rule.get("rule_id", "")) == rule_id:
			rule["paused"] = paused
			found = true
			break
	if not found:
		return _reject("Unknown Automation rule")
	last_notice = "Automation rule %s: %s" % [rule_id, "PAUSED" if paused else "ACTIVE"]
	transaction.record({"type":"AutomationRulePauseChanged", "rule_id":rule_id, "paused":paused})
	_commit_transaction(transaction)
	return true


func revoke_automation_rule(rule_id: String) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var found := false
	for index in range(transaction.working_state.automation_rules.size() - 1, -1, -1):
		if str(transaction.working_state.automation_rules[index].get("rule_id", "")) == rule_id:
			transaction.working_state.automation_rules.remove_at(index)
			found = true
			break
	if not found:
		return _reject("Unknown Automation rule")
	last_notice = "Automation authorization revoked: %s" % rule_id
	transaction.record({"type":"AutomationRuleRevoked", "rule_id":rule_id})
	_commit_transaction(transaction)
	return true


func run_automation_rules() -> int:
	var rule_ids: Array = []
	for rule_value in state.automation_rules:
		var rule := rule_value as Dictionary
		if bool(rule.get("enabled", true)) and not bool(rule.get("paused", false)) and bool(rule.get("authorized", false)):
			rule_ids.append(str(rule.get("rule_id", "")))
	var executed := 0
	for rule_id_value in rule_ids:
		var rule_id := str(rule_id_value)
		var rule := _automation_rule(rule_id)
		if rule.is_empty():
			continue
		var snapshot := _automation_condition_snapshot(rule.get("condition", {}))
		var last_active := bool(rule.get("last_condition_active", false))
		var active := _automation_condition_active_with_hysteresis(snapshot, rule, last_active)
		snapshot["active"] = active
		var last_triggered := int(rule.get("last_triggered_at_ms", -1))
		var cooldown_ready := last_triggered < 0 or state.total_elapsed_ms - last_triggered >= float(rule.get("cooldown_ms", 0.0))
		var result := {"executed":false, "reason":"CONDITION_FALSE"}
		if active and not last_active and cooldown_ready:
			result = _execute_automation_action(rule.get("action", {}))
			if bool(result.get("executed", false)):
				executed += 1
		_record_automation_evaluation(rule_id, snapshot, result, active)
	return executed


func _automation_rule(rule_id: String) -> Dictionary:
	for rule_value in state.automation_rules:
		var rule := rule_value as Dictionary
		if str(rule.get("rule_id", "")) == rule_id:
			return rule
	return {}


func _automation_condition_snapshot(condition: Dictionary) -> Dictionary:
	var condition_type := str(condition.get("type", "INVENTORY_STATE"))
	var operator := str(condition.get("operator", "LT"))
	var threshold := float(condition.get("threshold", 0.0))
	var value := 0.0
	var details := {}
	match condition_type:
		"INVENTORY_STATE", "STORAGE_UTILIZATION", "NET_PRODUCTION_RATE", "STOCK_COVERAGE":
			var location_id := str(condition.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
			var item_id := str(condition.get("product_id", ""))
			var analysis := simulation.current_economy_analysis(state, location_id)
			var row := {}
			for row_value in analysis.get("products", []):
				if str((row_value as Dictionary).get("product_id", "")) == item_id:
					row = row_value
					break
			var field := str(condition.get("field", {"STORAGE_UTILIZATION":"storage_utilization", "NET_PRODUCTION_RATE":"net_rate", "STOCK_COVERAGE":"stock_coverage_hours"}.get(condition_type, "stock")))
			value = float(row.get(field, 0.0))
			details = {"location_id":location_id, "product_id":item_id, "field":field, "status":row.get("status", "UNKNOWN")}
		"ROUTE_UTILIZATION":
			var route_id := str(condition.get("route_id", ""))
			value = float(simulation.logistics.service_for_route(state, route_id).get("last_utilization", 0.0))
			details = {"route_id":route_id}
		"POWER_RESERVE":
			value = float(simulation.civilization_power_state(state).get("available_capacity", 0.0))
		"PROJECT_STATE":
			var project_id := str(condition.get("project_id", ""))
			var expected := str(condition.get("state", "RUNNING"))
			var actual := "MISSING"
			for runtime_value in state.construction_operations:
				if str((runtime_value as Dictionary).get("project_id", "")) == project_id:
					actual = str((runtime_value as Dictionary).get("status", ""))
			value = 1.0 if actual == expected else 0.0
			threshold = 1.0
			operator = "GTE"
			details = {"project_id":project_id, "actual":actual, "expected":expected}
		"FACTORY_STATE":
			var slot := int(condition.get("slot", -1))
			var expected := str(condition.get("state", "BLOCKED"))
			var actual := str(state.industrial_operations[slot].get("status", "MISSING")) if slot >= 0 and slot < state.industrial_operations.size() else "MISSING"
			value = 1.0 if actual == expected else 0.0
			threshold = 1.0
			operator = "GTE"
			details = {"slot":slot, "actual":actual, "expected":expected}
	var active := _automation_compare(value, operator, threshold)
	return {"condition_type":condition_type, "value":value, "operator":operator, "threshold":threshold, "active":active, "details":details}


func _automation_compare(value: float, operator: String, threshold: float) -> bool:
	match operator:
		"LT": return value < threshold
		"LTE": return value <= threshold
		"GT": return value > threshold
		"GTE": return value >= threshold
		"EQ": return is_equal_approx(value, threshold)
	return false


func _automation_condition_active_with_hysteresis(snapshot: Dictionary, rule: Dictionary, was_active: bool) -> bool:
	var value := float(snapshot.get("value", 0.0))
	var threshold := float(snapshot.get("threshold", 0.0))
	var operator := str(snapshot.get("operator", "LT"))
	if not was_active:
		return _automation_compare(value, operator, threshold)
	var hysteresis := maxf(0.0, float(rule.get("hysteresis", 0.0)))
	match operator:
		"LT", "LTE":
			return value < threshold + hysteresis
		"GT", "GTE":
			return value > threshold - hysteresis
		"EQ":
			return absf(value - threshold) <= maxf(hysteresis, 0.000001)
	return false


func _execute_automation_action(action: Dictionary) -> Dictionary:
	var action_type := str(action.get("type", ""))
	match action_type:
		"PAUSE_FACTORY", "RESUME_FACTORY":
			var slot := int(action.get("slot", -1))
			if slot < 0 or slot >= state.industrial_operations.size():
				return {"executed":false, "reason":"INVALID_FACTORY"}
			if bool(state.industrial_operations[slot].get("manual_lock", true)):
				return {"executed":false, "reason":"MANUAL_LOCK"}
			var before := str(state.industrial_operations[slot].get("control_mode", "PINNED"))
			var target := "OFF" if action_type == "PAUSE_FACTORY" else "PINNED"
			var ok := set_production_line_control(slot, target, false)
			return {"executed":ok, "reason":"OK" if ok else "TRANSACTION_REJECTED", "before":before, "after":target}
		"ADJUST_ROUTE_POLICY":
			var policy_before: Dictionary = state.location_state(str(action.get("location_id", ""))).get("logistics", {}).get("policies", {}).get(str(action.get("product_id", "")), {}).duplicate(true)
			var ok := set_location_logistics_policy(str(action.get("location_id", "")), str(action.get("product_id", "")), str(action.get("mode", "STORAGE")), int(action.get("reserve", 0)), int(action.get("target", 0)), int(action.get("priority", 50)), int(action.get("dispatch_threshold", 1)), str(action.get("source_lock", "")), str(action.get("route_lock", "")))
			return {"executed":ok, "reason":"OK" if ok else "TRANSACTION_REJECTED", "before":policy_before, "after":action.duplicate(true)}
		"ADJUST_PROJECT_PRIORITY":
			var priority_before := -1
			for runtime_value in state.construction_operations:
				if str((runtime_value as Dictionary).get("project_id", "")) == str(action.get("project_id", "")):
					priority_before = int((runtime_value as Dictionary).get("priority", 50))
			var after := clampi(int(action.get("priority", 50)), 0, 100)
			var ok := set_construction_project_priority(str(action.get("project_id", "")), after)
			return {"executed":ok, "reason":"OK" if ok else "TRANSACTION_REJECTED", "before":priority_before, "after":after}
	return {"executed":false, "reason":"ACTION_NOT_ALLOWED"}


func _record_automation_evaluation(rule_id: String, snapshot: Dictionary, result: Dictionary, condition_active: bool) -> void:
	var current_rule := _automation_rule(rule_id)
	if current_rule.is_empty():
		return
	var condition_changed := bool(current_rule.get("last_condition_active", false)) != condition_active
	var executed := bool(result.get("executed", false))
	if not condition_changed and not executed:
		return
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	for rule_value in transaction.working_state.automation_rules:
		var rule := rule_value as Dictionary
		if str(rule.get("rule_id", "")) != rule_id:
			continue
		rule["last_condition_active"] = condition_active
		rule["last_evaluated_at_ms"] = int(transaction.working_state.total_elapsed_ms)
		rule["last_snapshot"] = snapshot.duplicate(true)
		if executed:
			rule["last_triggered_at_ms"] = int(transaction.working_state.total_elapsed_ms)
		break
	if executed or (condition_changed and str(result.get("reason", "")) == "MANUAL_LOCK"):
		var audit := {"rule_id":rule_id, "evaluated_at_ms":int(transaction.working_state.total_elapsed_ms), "condition":snapshot.duplicate(true), "result":result.duplicate(true)}
		transaction.working_state.automation_audit.append(audit)
		if transaction.working_state.automation_audit.size() > 250:
			transaction.working_state.automation_audit.pop_front()
	transaction.record({"type":"AutomationRuleEvaluated", "rule_id":rule_id, "executed":executed, "reason":result.get("reason", "")})
	_commit_transaction(transaction)


func expand_location_industry(location_id: String, facility_id: String, levels: int = 1) -> bool:
	if levels not in [1, 5, 10] or not state.has_location(location_id) or not content.facilities.has(facility_id):
		return _reject("Invalid Location Industry expansion")
	var current_level := int(state.location_industry(location_id, facility_id).get("level", 0))
	return queue_facility_expansion(location_id, facility_id, current_level + levels)


func queue_facility_expansion(location_id: String, facility_id: String, target_level: int, priority: int = 50) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.queue_facility_expansion(transaction.working_state, location_id, facility_id, target_level, priority):
		return _reject("Facility expansion cannot enter the Construction queue")
	last_notice = "Facility expansion queued: %s / %s → Lv.%d" % [location_id, I18n.content(content.facilities[facility_id]), target_level]
	transaction.record({"type":"ConstructionProjectQueued", "project_type":"FACILITY_EXPANSION", "location_id":location_id, "facility_id":facility_id, "target_level":target_level, "priority":priority})
	_commit_transaction(transaction)
	return true


func queue_scale_stage_upgrade(location_id: String, facility_id: String, priority: int = 50) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.queue_scale_stage_upgrade(transaction.working_state, location_id, facility_id, priority):
		return _reject("Scale Stage upgrade cannot enter the Construction queue")
	last_notice = "Scale Stage upgrade queued: %s / %s" % [location_id, I18n.content(content.facilities[facility_id])]
	transaction.record({"type":"ConstructionProjectQueued", "project_type":"SCALE_STAGE_UPGRADE", "location_id":location_id, "facility_id":facility_id, "priority":priority})
	_commit_transaction(transaction)
	return true


func queue_location_specialization(location_id: String, specialization_id: String, priority: int = 50) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.queue_location_specialization(transaction.working_state, location_id, specialization_id, priority):
		return _reject("Industry specialization requires an Industrial Complex and an open Construction slot")
	last_notice = "Industry specialization queued: %s / %s" % [location_id, specialization_id]
	transaction.record({"type":"ConstructionProjectQueued", "project_type":"INDUSTRY_SPECIALIZATION", "location_id":location_id, "specialization_id":specialization_id, "priority":priority})
	_commit_transaction(transaction)
	return true


func queue_industrial_transformation(transformation_id: String, priority: int = 50) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.queue_industrial_transformation(transaction.working_state, transformation_id, priority):
		return _reject("Industrial Transformation requires mastered SYSTEM technology, Capital Goods and an open Construction slot")
	last_notice = "Industrial Transformation queued: %s" % transformation_id
	transaction.record({"type":"ConstructionProjectQueued", "project_type":"INDUSTRIAL_TRANSFORMATION", "transformation_id":transformation_id, "priority":priority})
	_commit_transaction(transaction)
	return true


func queue_location_capacity_upgrade(location_id: String, project_type: String, target_value: int, priority: int = 50) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.queue_location_capacity_upgrade(transaction.working_state, location_id, project_type, target_value, priority):
		return _reject("Capacity upgrade cannot enter the Construction queue")
	last_notice = "Capacity project queued: %s / %s → %d" % [location_id, project_type, target_value]
	transaction.record({"type":"ConstructionProjectQueued", "project_type":project_type, "location_id":location_id, "target_value":target_value, "priority":priority})
	_commit_transaction(transaction)
	return true


func queue_site_development(site_id: String, extraction_method_id: String, priority: int = 50) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.queue_site_development(transaction.working_state, site_id, extraction_method_id, priority):
		return _reject("Site Development requires a Surveyed site, an eligible permanent Extraction Method and an open Construction slot")
	last_notice = "Site Development queued: %s / %s" % [site_id, extraction_method_id]
	transaction.record({"type":"ConstructionProjectQueued", "project_type":"SITE_DEVELOPMENT", "site_id":site_id, "extraction_method_id":extraction_method_id, "priority":priority})
	_commit_transaction(transaction)
	return true


func set_location_industry_infrastructure(location_id: String, power_capacity: float, cooling_capacity: float, structural_capacity: float) -> bool:
	if not state.has_location(location_id) or power_capacity < 0.0 or cooling_capacity < 0.0 or structural_capacity < 0.0:
		return _reject("Invalid Location Industry infrastructure")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var industry: Dictionary = transaction.working_state.location_state(location_id).get("industry", {})
	var requested := {
		"POWER_UPGRADE":ceili(power_capacity),
		"COOLING_UPGRADE":ceili(cooling_capacity),
		"STRUCTURE_UPGRADE":ceili(structural_capacity)
	}
	var current := {
		"POWER_UPGRADE":int(industry.get("power_capacity", 0)),
		"COOLING_UPGRADE":int(industry.get("cooling_capacity", 0)),
		"STRUCTURE_UPGRADE":int(industry.get("structural_capacity", 0))
	}
	var queued_types: Array = []
	for project_type_value in requested.keys():
		var project_type := str(project_type_value)
		if int(requested[project_type]) < int(current[project_type]):
			return _reject("Infrastructure capacity cannot be reduced by an upgrade command")
		if int(requested[project_type]) == int(current[project_type]):
			continue
		if not simulation.queue_location_capacity_upgrade(transaction.working_state, location_id, project_type, int(requested[project_type]), 50):
			return _reject("Infrastructure upgrade cannot enter the Construction queue")
		queued_types.append(project_type)
	if queued_types.is_empty():
		return _reject("No infrastructure capacity increase requested")
	last_notice = "Infrastructure capacity projects queued: %s" % location_id
	transaction.record({"type":"LocationCapacityProjectsQueued", "location_id":location_id, "project_types":queued_types})
	_commit_transaction(transaction)
	return true


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
	var definition: Dictionary = content.megastructures.get(megastructure_id, {})
	var project: Dictionary = state.megastructure_projects.get(megastructure_id, {})
	var phases: Array = definition.get("phases", [])
	var phase_index := int(project.get("phase_index", 0))
	if definition.is_empty() or project.is_empty() or phase_index <= 0 or phase_index >= phases.size():
		return _reject(I18n.t("notice.megastructure_phase_unavailable", "No Megastructure phase is ready to start."))
	var activity_id := str((phases[phase_index] as Dictionary).get("activity_id", ""))
	return start_construction_project(activity_id, str(project.get("site_location_id", "")), priority)


func start_construction_project(activity_id: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID, priority: int = 50) -> bool:
	if not content.activities.has(activity_id):
		return _reject(I18n.t("notice.unknown_activity", "Unknown construction project"))
	var activity: Dictionary = content.activities[activity_id]
	if not simulation.is_construction_activity(activity):
		return _reject(I18n.t("notice.not_construction", "This activity is not an infrastructure project"))
	if not simulation.facility_available(state, "orbital_construction_yard"):
		return _reject(I18n.t("notice.construction_yard_missing", "The Orbital Construction Yard is not active"))
	var sponsor_facility_id := str(activity.get("facility", ""))
	if not sponsor_facility_id.is_empty() and not simulation.facility_available(state, sponsor_facility_id):
		return _reject(I18n.t("notice.sponsor_facility", "Build the sponsoring facility first: %s") % I18n.content(content.facilities.get(sponsor_facility_id, {"id":sponsor_facility_id, "name":sponsor_facility_id})))
	if not simulation.activity_available(state, activity):
		return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	if not state.has_location(location_id):
		return _reject("Unknown construction Location")
	var megastructure_blocker := simulation.megastructure_phase_start_blocker(state, activity, location_id)
	if not megastructure_blocker.is_empty():
		return _reject(I18n.t("notice.megastructure_phase_blocked", "Megastructure phase is blocked: %s") % str(megastructure_blocker.get("primary_reason", "REQUIREMENTS")))
	var queue_capacity := simulation.construction_queue_capacity(state)
	var slot := simulation.construction_queue_size(state)
	if slot >= queue_capacity:
		return _reject(I18n.t("notice.construction_queue_full", "The construction queue is full"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working_runtime: Dictionary = transaction.working_state.construction_operations[slot]
	_assign_runtime(working_runtime, activity, [])
	simulation.initialize_construction_project(transaction.working_state, working_runtime, activity, location_id, priority)
	var construction_project_id := str(working_runtime.get("project_id", ""))
	var construction_project_type := str(working_runtime.get("project_type", ""))
	working_runtime["reserved_costs"] = {}
	working_runtime["consumed"] = {}
	simulation.begin_megastructure_project(transaction.working_state, working_runtime, activity)
	simulation.normalize_construction_queue(transaction.working_state)
	last_notice = I18n.t("notice.construction_queued", "Added to construction queue at position %d: %s") % [slot + 1, I18n.content(activity)]
	transaction.record({"type":"ConstructionProjectStarted", "slot":slot, "activity_id":activity_id, "project_id":construction_project_id, "project_type":construction_project_type, "location_id":location_id, "priority":priority})
	_commit_transaction(transaction)
	return true


func stop_construction_project(slot: int) -> bool:
	if slot < 0 or slot >= state.construction_operations.size():
		return _reject(I18n.t("notice.unknown_construction_slot", "Unknown construction queue position"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = transaction.working_state.construction_operations[slot]
	if runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED", "QUEUED"]:
		return _reject(I18n.t("notice.no_active", "No construction project at this queue position"))
	var cancellation_result := simulation.cancel_construction_project(transaction.working_state, runtime)
	last_notice = I18n.t("notice.construction_removed", "Removed construction queue position %d") % [slot + 1]
	transaction.record({"type":"ConstructionProjectStopped", "slot":slot, "cancellation_result":cancellation_result})
	_commit_transaction(transaction)
	return true


func set_construction_project_priority(project_id: String, priority: int) -> bool:
	if priority < 0 or priority > 100:
		return _reject("Construction priority must be between 0 and 100")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var found := false
	for runtime_value in transaction.working_state.construction_operations:
		var runtime := runtime_value as Dictionary
		if str(runtime.get("project_id", "")) != project_id or str(runtime.get("status", "")) not in ["RUNNING", "BLOCKED", "QUEUED"]:
			continue
		runtime["priority"] = priority
		found = true
		break
	if not found:
		return _reject("Unknown active Construction project")
	simulation.normalize_construction_queue(transaction.working_state)
	last_notice = "Construction priority updated: %s → %d" % [project_id, priority]
	transaction.record({"type":"ConstructionProjectPriorityChanged", "project_id":project_id, "priority":priority})
	_commit_transaction(transaction)
	return true


func start_research_project(project_id: String, route_id: String = "") -> bool:
	if not content.research_projects.has(project_id):
		return _reject(I18n.t("notice.research_unknown", "Unknown research project"))
	if state.research.get("status", "IDLE") == "RUNNING":
		return _reject(I18n.t("notice.research_active", "A research project is already active"))
	var project: Dictionary = content.research_projects[project_id]
	var selected_route := route_id if not route_id.is_empty() else simulation.default_research_route_id(project)
	if not selected_route.is_empty() and simulation.research_route(project, selected_route).is_empty():
		return _reject("Unknown R&D engineering route")
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
		return _reject("Ship construction quantity must be between 1 and 100")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not transaction.working_state.enqueue_ship_plan(plan_id, quantity):
		return _reject(I18n.t("notice.shipyard_plan_unavailable", "Ship plan is locked, already queued, or already built"))
	simulation.normalize_shipyard_queue(transaction.working_state)
	last_notice = "%s × %d added to the Shipyard" % [I18n.content(content.ship_construction_projects[plan_id]), quantity]
	transaction.record({"type":"ShipyardPlanQueued", "plan_id":plan_id, "quantity":quantity})
	_commit_transaction(transaction)
	return true


func cancel_shipyard_project(project_id: String) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working := transaction.working_state
	var project_index := -1
	for index in working.shipyard_queue.size():
		if str(working.shipyard_queue[index].get("project_id", "")) == project_id:
			project_index = index
			break
	if project_index < 0:
		return _reject("Shipyard project was not found")
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
		return _reject("Unknown Location")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.set_item_reserve(item_id, quantity, location_id)
	transaction.record({"type":"InventoryReserveChanged", "location_id":location_id, "item_id":item_id, "quantity":maxi(0, quantity)})
	_commit_transaction(transaction)
	return true


func set_location_logistics_policy(location_id: String, item_id: String, mode: String, reserve: int = 0, target: int = 0, priority: int = 50, dispatch_threshold: int = 1, source_lock: String = "", route_lock: String = "") -> bool:
	if not state.has_location(location_id):
		return _reject("Unknown Location")
	if not content.items.has(item_id):
		return _reject(I18n.t("notice.item_unknown", "Unknown inventory item"))
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
		return _reject("Invalid logistics policy")
	_detach_template_policy(transaction.working_state, location_id, item_id)
	last_notice = "Logistics policy updated: %s / %s / %s" % [I18n.content(content.regions.get(location_id, {"name":location_id})), I18n.content(content.items[item_id]), mode.to_upper()]
	transaction.record({"type":"LocationLogisticsPolicyChanged", "location_id":location_id, "item_id":item_id, "policy":policy})
	_commit_transaction(transaction)
	return true


func configure_logistics_service(route_id: String, transport_mode_id: String, ship_ids: Array = [], priority_strategy: String = "DEMAND_PRIORITY") -> bool:
	if not content.logistics_routes.has(route_id):
		return _reject("Unknown logistics route")
	if not content.transport_modes.has(transport_mode_id):
		return _reject("Unknown Transport Mode")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.logistics.configure_service(transaction.working_state, route_id, transport_mode_id, ship_ids, priority_strategy):
		return _reject("Transport Mode requirements or assigned ships are not satisfied")
	var route: Dictionary = content.logistics_routes[route_id]
	var mode: Dictionary = content.transport_modes[transport_mode_id]
	last_notice = "Logistics service updated: %s / %s" % [I18n.content(route), I18n.content(mode)]
	transaction.record({"type":"LogisticsServiceConfigured", "route_id":route_id, "transport_mode_id":transport_mode_id, "ship_ids":ship_ids.duplicate(), "priority_strategy":priority_strategy})
	_commit_transaction(transaction)
	return true


func clear_location_logistics_policy(location_id: String, item_id: String) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.logistics.clear_policy(transaction.working_state, location_id, item_id):
		return _reject("Invalid logistics policy target")
	_detach_template_policy(transaction.working_state, location_id, item_id)
	last_notice = "Logistics policy cleared: %s / %s" % [location_id, item_id]
	transaction.record({"type":"LocationLogisticsPolicyCleared", "location_id":location_id, "item_id":item_id})
	_commit_transaction(transaction)
	return true


func set_location_logistics_limits(location_id: String, storage_capacity: int, hub_throughput: int) -> bool:
	if not state.has_location(location_id):
		return _reject("Unknown Location")
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var logistics_state: Dictionary = transaction.working_state.location_state(location_id).get("logistics", {})
	var current_storage := int(logistics_state.get("storage_capacity", 0))
	var current_throughput := int(logistics_state.get("hub_throughput", 0))
	if storage_capacity < current_storage or hub_throughput < current_throughput:
		return _reject("Logistics capacity cannot be reduced by an upgrade command")
	var queued_types: Array = []
	if storage_capacity > current_storage:
		if not simulation.queue_location_capacity_upgrade(transaction.working_state, location_id, "STORAGE_UPGRADE", storage_capacity, 50):
			return _reject("Storage upgrade cannot enter the Construction queue")
		queued_types.append("STORAGE_UPGRADE")
	if hub_throughput > current_throughput:
		if not simulation.queue_location_capacity_upgrade(transaction.working_state, location_id, "LOGISTICS_HUB_UPGRADE", hub_throughput, 50):
			return _reject("Logistics Hub upgrade cannot enter the Construction queue")
		queued_types.append("LOGISTICS_HUB_UPGRADE")
	if queued_types.is_empty():
		return _reject("No Logistics capacity increase requested")
	last_notice = "Logistics capacity projects queued: %s" % location_id
	transaction.record({"type":"LocationCapacityProjectsQueued", "location_id":location_id, "project_types":queued_types})
	_commit_transaction(transaction)
	return true


func apply_location_industrial_template(location_id: String, template_id: String) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.apply_industrial_template(transaction.working_state, location_id, template_id):
		return _reject("Invalid Industrial Template or Location")
	last_notice = "Industrial Template applied: %s / %s" % [location_id, I18n.content(content.industrial_templates.get(template_id, {"name":template_id}))]
	transaction.record({"type":"LocationIndustrialTemplateApplied", "location_id":location_id, "template_id":template_id})
	_commit_transaction(transaction)
	return true


func clear_location_industrial_template(location_id: String) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.clear_industrial_template(transaction.working_state, location_id):
		return _reject("Unknown Location")
	last_notice = "Industrial Template cleared: %s" % location_id
	transaction.record({"type":"LocationIndustrialTemplateCleared", "location_id":location_id})
	_commit_transaction(transaction)
	return true


func configure_location_industrial_automation(location_id: String, enabled: bool, target_level: int) -> bool:
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not simulation.configure_location_industrial_automation(transaction.working_state, location_id, enabled, target_level):
		return _reject("Apply an Industrial Template with managed facilities first")
	last_notice = "Location industrial auto-expansion %s · target Lv.%d" % ["enabled" if enabled else "paused", target_level]
	transaction.record({"type":"LocationIndustrialAutomationChanged", "location_id":location_id, "enabled":enabled, "target_level":target_level})
	_commit_transaction(transaction)
	return true


func _detach_template_policy(working_state: SpaceGameState, location_id: String, item_id: String) -> void:
	var automation: Dictionary = working_state.location_state(location_id).get("automation", {})
	var managed_items: Array = automation.get("managed_policy_items", []).duplicate()
	managed_items.erase(item_id)
	automation["managed_policy_items"] = managed_items
	if not str(automation.get("industrial_template_id", "")).is_empty():
		automation["status"] = "CUSTOMIZED"


func set_background_target(item_id: String, quantity: int) -> bool:
	if not content.items.has(item_id):
		return _reject(I18n.t("notice.item_unknown", "Unknown inventory item"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.set_background_target(item_id, quantity)
	last_notice = I18n.t("notice.background_target", "Background target updated: %s → %d") % [I18n.content(content.items[item_id]), maxi(0, quantity)]
	transaction.record({"type":"BackgroundTargetChanged", "item_id":item_id, "quantity":maxi(0, quantity)})
	_commit_transaction(transaction)
	return true


func set_background_priority(item_id: String, priority: int) -> bool:
	if not content.items.has(item_id):
		return _reject(I18n.t("notice.item_unknown", "Unknown inventory item"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.set_background_priority(item_id, priority)
	last_notice = I18n.t("notice.background_priority", "Background priority updated: %s → %d") % [I18n.content(content.items[item_id]), clampi(priority, 0, 100)]
	transaction.record({"type":"BackgroundPriorityChanged", "item_id":item_id, "priority":clampi(priority, 0, 100)})
	_commit_transaction(transaction)
	return true


func set_advanced_power_priority(facility_id: String, priority: String) -> bool:
	if not content.facilities.has(facility_id):
		return _reject(I18n.t("notice.facility_missing", "Unknown infrastructure facility"))
	if priority not in ["CRITICAL", "HIGH", "NORMAL", "LOW"]:
		return _reject(I18n.t("notice.power_policy_invalid", "Invalid advanced power policy"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.set_advanced_power_priority(facility_id, priority)
	last_notice = I18n.t("notice.advanced_power_priority", "Advanced power policy updated: %s → %s") % [I18n.content(content.facilities[facility_id]), priority]
	transaction.record({"type":"AdvancedPowerPriorityChanged", "facility_id":facility_id, "priority":priority})
	_commit_transaction(transaction)
	return true


func install_facility_module(facility_id: String, module_id: String) -> bool:
	if not content.facilities.has(facility_id):
		return _reject(I18n.t("notice.facility_missing", "Unknown infrastructure facility"))
	var facility: Dictionary = content.facilities[facility_id]
	var module: Dictionary = facility.get("upgrade_modules", {}).get(module_id, {})
	if module.is_empty():
		return _reject(I18n.t("notice.facility_module_unknown", "Unknown infrastructure module"))
	if not simulation.facility_module_available(state, facility_id, module_id):
		return _reject(I18n.t("notice.facility_module_unavailable", "Module requirements, slot capacity or Strategic Inventory costs are not met"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var previous_construction_active := simulation.active_construction_count(transaction.working_state)
	var previous_construction_capacity := simulation.construction_capacity(transaction.working_state)
	for cost in module.get("costs", []):
		if not transaction.working_state.remove_item(str(cost.get("item", "")), int(cost.get("quantity", 0))):
			return _reject(I18n.t("notice.resources", "Strategic Inventory cannot fund this installation"))
	if not transaction.working_state.install_facility_module(facility_id, module_id):
		return _reject(I18n.t("notice.facility_module_unavailable", "Module requirements, slot capacity or Strategic Inventory costs are not met"))
	if facility_id == "orbital_construction_yard":
		simulation.rebalance_construction_progress(transaction.working_state, previous_construction_active, previous_construction_capacity)
	last_notice = I18n.t("notice.facility_module_installed", "Infrastructure module installed: %s → %s") % [I18n.content(facility), I18n.content(module)]
	transaction.record({"type":"FacilityModuleInstalled", "facility_id":facility_id, "module_id":module_id})
	_commit_transaction(transaction)
	return true


func install_manufacturing_module(facility_id: String, module_id: String, module_kind: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> bool:
	if module_kind not in ["process", "plugin"]:
		return _reject(I18n.t("notice.facility_module_unknown", "Unknown manufacturing module type"))
	var runtime := simulation.industry_runtime_for_facility(state, facility_id, location_id)
	if runtime.is_empty() or simulation.industry_facility_busy(state, facility_id, location_id):
		return _reject(I18n.t("notice.manufacturing_refit_busy", "Pause this facility before changing its manufacturing build"))
	if not simulation.manufacturing_module_available(state, facility_id, module_id, module_kind, location_id):
		return _reject(I18n.t("notice.facility_module_unavailable", "Module requirements, slot capacity, ownership or costs are not met"))
	var definition := simulation.manufacturing_module_definition(module_kind, module_id)
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working := transaction.working_state
	if int(working.manufacturing_module_inventory.get(module_id, 0)) <= 0:
		for cost in definition.get("costs", []):
			if not working.remove_item(str(cost.get("item", "")), int(cost.get("quantity", 0)), location_id):
				return _reject(I18n.t("notice.resources", "Strategic Inventory cannot fund this module"))
		working.manufacturing_modules_built[module_id] = int(working.manufacturing_modules_built.get(module_id, 0)) + 1
	if not working.install_manufacturing_module(facility_id, module_id, module_kind, location_id):
		return _reject(I18n.t("notice.facility_module_unavailable", "Manufacturing module could not be installed"))
	last_notice = I18n.t("notice.manufacturing_module_installed", "%s installed in %s") % [I18n.content(definition), I18n.content(content.facilities.get(facility_id, {}))]
	transaction.record({"type":"ManufacturingModuleInstalled", "facility_id":facility_id, "module_id":module_id, "module_kind":module_kind, "location_id":location_id})
	_commit_transaction(transaction)
	return true


func uninstall_manufacturing_module(facility_id: String, module_id: String, module_kind: String, location_id: String = SpaceGameState.MAIN_BASE_LOCATION_ID) -> bool:
	if module_kind not in ["process", "plugin"]:
		return _reject(I18n.t("notice.facility_module_unknown", "Unknown manufacturing module type"))
	var runtime := simulation.industry_runtime_for_facility(state, facility_id, location_id)
	if runtime.is_empty() or simulation.industry_facility_busy(state, facility_id, location_id):
		return _reject(I18n.t("notice.manufacturing_refit_busy", "Pause this facility before changing its manufacturing build"))
	var definition := simulation.manufacturing_module_definition(module_kind, module_id)
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not transaction.working_state.uninstall_manufacturing_module(facility_id, module_id, module_kind, location_id):
		return _reject(I18n.t("notice.module_not_installed", "The module is not installed"))
	last_notice = I18n.t("notice.manufacturing_module_removed", "%s returned to industrial module storage") % I18n.content(definition)
	transaction.record({"type":"ManufacturingModuleRemoved", "facility_id":facility_id, "module_id":module_id, "module_kind":module_kind, "location_id":location_id})
	_commit_transaction(transaction)
	return true


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


func save_ship_loadout(instance_id: String, requested_name: String = "") -> bool:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	var blueprint_id := str(ship.get("blueprint_id", ""))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var serial := transaction.working_state.next_loadout_serial
	transaction.working_state.next_loadout_serial = serial + 1
	var loadout_id := "LOADOUT-%04d" % serial
	var existing_count := transaction.working_state.saved_loadouts.values().filter(func(loadout): return str(loadout.get("blueprint_id", "")) == blueprint_id).size()
	var blueprint_name := I18n.content(content.ships.get(blueprint_id, {"name":blueprint_id}))
	transaction.working_state.saved_loadouts[loadout_id] = {
		"id":loadout_id,
		"name":requested_name if not requested_name.strip_edges().is_empty() else "%s Loadout %d" % [blueprint_name, existing_count + 1],
		"blueprint_id":blueprint_id,
		"modules":state.ship_module_definition_ids(ship),
		"saved_at_ms":int(state.total_elapsed_ms)
	}
	last_notice = I18n.t("notice.loadout_saved", "Loadout preset saved: %s") % transaction.working_state.saved_loadouts[loadout_id]["name"]
	transaction.record({"type":"ShipLoadoutSaved", "ship_id":instance_id, "loadout_id":loadout_id})
	_commit_transaction(transaction)
	return true


func delete_ship_loadout(loadout_id: String) -> bool:
	if not state.saved_loadouts.has(loadout_id):
		return _reject(I18n.t("notice.loadout_missing", "Saved loadout was not found"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.saved_loadouts.erase(loadout_id)
	last_notice = "Loadout deleted: %s" % loadout_id
	transaction.record({"type":"ShipLoadoutDeleted", "loadout_id":loadout_id})
	_commit_transaction(transaction)
	return true


func apply_ship_loadout(instance_id: String, loadout_id: String) -> bool:
	if not state.ship_can_refit(instance_id):
		return _reject(I18n.t("notice.refit_locked", "The ship must be operational and docked before refitting"))
	if not state.saved_loadouts.has(loadout_id):
		return _reject(I18n.t("notice.loadout_missing", "Saved loadout was not found"))
	var ship: Dictionary = state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	var loadout: Dictionary = state.saved_loadouts[loadout_id]
	var blueprint_id := str(ship.get("blueprint_id", ""))
	if str(loadout.get("blueprint_id", "")) != blueprint_id:
		return _reject(I18n.t("notice.loadout_hull", "This preset belongs to a different hull model"))
	var desired: Array = loadout.get("modules", []).duplicate()
	var validation: String = _validate_loadout_modules(blueprint_id, desired)
	if not validation.is_empty():
		return _reject(validation)
	return begin_ship_refit(instance_id, desired, loadout_id)


func _validate_loadout_modules(blueprint_id: String, module_ids: Array) -> String:
	var error := content.ship_loadout_error(blueprint_id, module_ids)
	if error.is_empty():
		return ""
	if error.begins_with("missing"):
		return I18n.t("notice.module_unknown", "Unknown ship module")
	if "size" in error:
		return I18n.t("notice.module_size", "Module size is incompatible with this hull")
	if "slot limit" in error:
		return I18n.t("notice.module_full", "This ship has no free compatible module slot")
	return I18n.t("notice.module_budget", "Hull fitting budget exceeded: %s") % error


func start_expedition_route(route_id: String, ship_ids: Array = []) -> bool:
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
		selected = state.fleet_ship_ids("expedition")
	if selected.is_empty():
		return _reject(I18n.t("notice.expedition_fleet_empty", "Assign ships to the Expedition Fleet at Starport first"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	for ship_id in selected:
		if not transaction.working_state.ship_is_docked(str(ship_id)) or transaction.working_state.ship_fleet_domain(str(ship_id)) != "expedition":
			return _reject(I18n.t("notice.expedition_fleet_unavailable", "Every Expedition Fleet ship must be operational and docked"))
	if simulation.fleet_command_usage(transaction.working_state, selected) > simulation.fleet_command_capacity(transaction.working_state):
		return _reject(I18n.t("notice.command_capacity", "Fleet Command Capacity would be exceeded"))
	_auto_resupply_state(transaction.working_state, "expedition", selected)
	var fuel_cost := maxi(0, int(route.get("fuel_cost", 0)))
	if fuel_cost > 0 and not transaction.working_state.consume_fleet_supply("chemical_propellant", fuel_cost):
		return _reject(I18n.t("notice.expedition_fuel", "Fleet supply cannot fund this route's fuel requirement"))
	var runtime: Dictionary = transaction.working_state.active_expedition
	runtime.merge({"status":"RUNNING", "route_id":route_id, "activity_id":"", "node_index":0, "node_progress_ms":0.0, "safe_node_index":0, "assigned_ship_ids":selected, "phase":str(route.get("nodes", [{}])[0].get("phase", "PREPARE")), "combat_state":{}}, true)
	for ship_id in selected:
		var expedition_ship := transaction.working_state.ship_by_id(str(ship_id))
		_assign_ship(expedition_ship, "EXPEDITION", "expedition", 0)
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
			var missing_requirement := "%s × %d" % [I18n.content(content.items.get(item_id, {"name":item_id})), int(consumed_bom[item_id])]
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
		return _reject("Refit project was not found")
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


func install_ship_module(instance_id: String, module_id: String) -> bool:
	if not content.modules.has(module_id):
		return _reject(I18n.t("notice.module_unknown", "Unknown ship module"))
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	var desired := state.ship_module_definition_ids(ship)
	desired.append(module_id)
	return begin_ship_refit(instance_id, desired)


func remove_ship_module(instance_id: String, module_id: String) -> bool:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	var desired := state.ship_module_definition_ids(ship)
	var index := desired.find(module_id)
	if index < 0:
		return _reject(I18n.t("notice.module_not_installed", "The module is not installed on this ship"))
	desired.remove_at(index)
	return begin_ship_refit(instance_id, desired)


func replace_ship_module(instance_id: String, old_module_id: String, new_module_id: String) -> bool:
	if old_module_id == new_module_id:
		return true
	if not content.modules.has(new_module_id):
		return _reject(I18n.t("notice.module_missing", "The module blueprint is unavailable"))
	var source_ship := state.ship_by_id(instance_id)
	if source_ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	var candidate: Array = state.ship_module_definition_ids(source_ship)
	if not old_module_id.is_empty():
		var old_index := candidate.find(old_module_id)
		if old_index < 0:
			return _reject(I18n.t("notice.module_not_installed", "The module is not installed on this ship"))
		candidate.remove_at(old_index)
	candidate.append(new_module_id)
	return begin_ship_refit(instance_id, candidate)


func _ship_fitting_valid(blueprint: Dictionary, module_ids: Array) -> bool:
	return content.ship_loadout_valid(str(blueprint.get("id", "")), module_ids)


func runtime_for_domain(domain_id: String) -> Dictionary:
	return simulation.runtime_for_domain(state, domain_id)


func activity_progress(domain_id: String) -> float:
	return simulation.progress_for_domain(state, domain_id)


func can_start_activity(domain_id: String, activity: Dictionary) -> bool:
	if simulation.is_construction_activity(activity):
		return can_start_construction_project(activity)
	if not simulation.activity_available(state, activity) or not simulation.costs_available(state, activity):
		return false
	match domain_id:
		"mining":
			if not state.mining_site_available(str(activity.get("site", ""))):
				return false
			for ship_id in state.fleet_ship_ids("mining"):
				if (
					state.ship_is_docked(str(ship_id))
					and simulation.mining_power(state, [ship_id]) > 0.0
					and simulation.extraction_command_usage(state, simulation.active_extraction_ship_ids(state) + [ship_id]) <= simulation.extraction_command_capacity(state)
				):
					return true
			return false
		"industry":
			var facility_id := str(activity.get("facility", ""))
			var runtime := simulation.industry_runtime_for_facility(state, facility_id)
			var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
			return not runtime.is_empty() and runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED"] and simulation.industry_recipe_capabilities_met(state, activity, location_id) and simulation.production_method_available_at_scale(state, location_id, facility_id, activity)
		"expedition":
			return state.active_expedition.get("status", "IDLE") != "RUNNING" and fleet_ready("expedition")
	return false


func can_start_construction_project(activity: Dictionary) -> bool:
	if not simulation.is_construction_activity(activity) or not simulation.activity_available(state, activity):
		return false
	if not simulation.facility_available(state, "orbital_construction_yard"):
		return false
	var sponsor_facility_id := str(activity.get("facility", ""))
	if not sponsor_facility_id.is_empty() and not simulation.facility_available(state, sponsor_facility_id):
		return false
	var queue_position := simulation.construction_queue_size(state)
	return queue_position < simulation.construction_queue_capacity(state)


func activity_duration(domain_id: String, activity: Dictionary, runtime: Dictionary = {}) -> float:
	var actual_runtime := runtime if not runtime.is_empty() else simulation.runtime_for_domain(state, domain_id)
	var runtime_domain := "construction" if simulation.is_construction_activity(activity) and not actual_runtime.is_empty() and str(actual_runtime.get("domain", "")) == "construction" else domain_id
	return simulation.effective_duration_ms(state, runtime_domain, activity, actual_runtime)


func save_game() -> bool:
	if not persistence_enabled:
		return true
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
		"infrastructure_site":
			return I18n.t("requirement.site", "%s Infrastructure Site: %s") % [marker, str(requirement.get("id", "")).replace("_", " ").capitalize()]
		"boss_defeated":
			return I18n.t("requirement.boss", "%s Boss defeated: %s") % [marker, I18n.content(content.enemies.get(str(requirement.get("id", "")), requirement))]
		"megastructure":
			return I18n.t("requirement.megastructure", "%s Megastructure: %s") % [marker, I18n.content(content.megastructures.get(str(requirement.get("id", "")), requirement))]
		"game_complete":
			return I18n.t("requirement.game_complete", "%s Commission the Stellar Energy Megastructure") % marker
	return I18n.t("requirement.unknown", "%s Unknown requirement") % marker


func _start_mining(working: SpaceGameState, activity: Dictionary) -> bool:
	var site_id := str(activity.get("site", ""))
	if not working.mining_site_available(site_id):
		return _reject(I18n.t("notice.mining_site_unavailable", "This permanent mining site is unavailable"))
	var selected_ship_id := ""
	for ship_id in working.fleet_ship_ids("mining"):
		var candidate_ids := simulation.active_extraction_ship_ids(working) + [ship_id]
		if working.ship_is_docked(str(ship_id)) and simulation.mining_power(working, [ship_id]) > 0.0 and simulation.extraction_command_usage(working, candidate_ids) <= simulation.extraction_command_capacity(working):
			selected_ship_id = str(ship_id)
			break
	if selected_ship_id.is_empty():
		return _reject(I18n.t("notice.extraction_ship_required", "Assign an available ship with extraction equipment within Command Capacity"))
	var runtime: Dictionary = {}
	for operation in working.mining_operations:
		if str(operation.get("status", "IDLE")) == "RUNNING" and str(operation.get("site_id", "")) == site_id:
			runtime = operation
			break
	if runtime.is_empty():
		runtime = _first_available_slot(working.mining_operations, working.mining_operations.size())
	if runtime.is_empty():
		var record_index := working.mining_operations.size()
		working.mining_operations.append(SpaceGameState.create_operation_record(record_index, "mining"))
		runtime = working.mining_operations[record_index]
	var location: Dictionary = content.mining_locations.get(str(activity.get("location", "")), {})
	if str(runtime.get("status", "IDLE")) == "RUNNING":
		var assigned: Array = runtime.get("assigned_ship_ids", [])
		assigned.append(selected_ship_id)
		runtime["assigned_ship_ids"] = assigned
	else:
		runtime["location_id"] = str(activity.get("location", ""))
		runtime["site_id"] = site_id
		runtime["raw_material_id"] = str(location.get("raw_material", ""))
		_assign_runtime(runtime, activity, [selected_ship_id])
	_assign_ship(working.ship_by_id(selected_ship_id), "EXTRACTION_OPERATION", "mining", int(runtime.get("slot", 0)))
	return true


func _start_industry(working: SpaceGameState, activity: Dictionary) -> bool:
	var facility_id := str(activity.get("facility", ""))
	var runtime := simulation.industry_runtime_for_facility(working, facility_id)
	if runtime.is_empty() or runtime.get("status", "IDLE") in ["RUNNING", "BLOCKED"]:
		return _reject(I18n.t("notice.operation_slots_full", "This manufacturing facility is already occupied"))
	if not simulation.facility_available(working, facility_id):
		return _reject(I18n.t("notice.facility_missing", "Required Industrial Facility is not active"))
	var location_id := str(runtime.get("location_id", SpaceGameState.MAIN_BASE_LOCATION_ID))
	if not simulation.industry_recipe_capabilities_met(working, activity, location_id):
		return _reject(I18n.t("notice.process_capability_missing", "Install the required process module before starting this recipe"))
	if not simulation.production_method_available_at_scale(working, location_id, facility_id, activity):
		return _reject("This Production Method requires a higher Industry Scale Stage")
	_assign_runtime(runtime, activity, [])
	runtime["method_id"] = str(activity.get("id", ""))
	runtime["product_family_id"] = simulation.production_family_id(activity)
	runtime["reserved_costs"] = _cost_commitment(activity.get("costs", []))
	runtime["input_commitments"] = runtime["reserved_costs"].duplicate(true)
	return true


func _start_expedition(working: SpaceGameState, activity: Dictionary) -> bool:
	if working.active_expedition.get("status", "IDLE") == "RUNNING":
		return _reject(I18n.t("notice.expedition_active", "The organization already has an active Expedition front"))
	var ship_ids := working.fleet_ship_ids("expedition")
	if ship_ids.is_empty():
		return _reject(I18n.t("notice.expedition_fleet_empty", "Assign ships to the Expedition Fleet at Starport first"))
	for ship_id in ship_ids:
		if not working.ship_is_docked(str(ship_id)):
			return _reject(I18n.t("notice.expedition_fleet_unavailable", "Every Expedition Fleet ship must be operational and docked"))
	if simulation.fleet_command_usage(working, ship_ids) > simulation.fleet_command_capacity(working):
		return _reject(I18n.t("notice.command_capacity", "Fleet Command Capacity would be exceeded"))
	_auto_resupply_state(working, "expedition", ship_ids)
	_assign_runtime(working.active_expedition, activity, ship_ids)
	working.active_expedition["phase"] = str(activity.get("encounter_type", "TRAVEL"))
	for ship_id in ship_ids:
		var expedition_ship := working.ship_by_id(str(ship_id))
		_assign_ship(expedition_ship, "EXPEDITION", "expedition", 0)
		expedition_ship["service_record"]["combat_deployments"] = int(expedition_ship.get("service_record", {}).get("combat_deployments", 0)) + 1
	return true


func _first_available_slot(operations: Array, unlocked: int) -> Dictionary:
	for index in mini(unlocked, operations.size()):
		if operations[index].get("status", "IDLE") in ["IDLE", "BLOCKED", "COMPLETE"]:
			return operations[index]
	return {}


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


func _assign_ship(ship: Dictionary, status: String, domain_id: String, slot: int) -> void:
	ship["status"] = status
	ship["assignment"] = {"domain":domain_id, "slot":slot}


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
			var fleet_domain := working.ship_fleet_domain(str(ship_id))
			ship["assignment"] = {} if fleet_domain.is_empty() else {"domain":fleet_domain, "fleet":"default"}
	runtime["assigned_ship_ids"] = []


func _reset_extraction_runtime(runtime: Dictionary) -> void:
	runtime["activity_id"] = ""
	runtime["progress_ms"] = 0.0
	runtime["cycle_progress"] = 0.0
	runtime["status"] = "IDLE"
	runtime["reserved_costs"] = {}
	runtime["location_id"] = ""
	runtime["site_id"] = ""
	runtime["raw_material_id"] = ""
	runtime["allocated_mining_power"] = 0.0
	runtime["effective_mining_power"] = 0.0


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
		offline_report = simulation.advance(state, float(elapsed))
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
	for operation in state.industrial_operations:
		if str(operation.get("status", "")) == "BLOCKED":
			problems.append(simulation.blocker_diagnostic(state, "industry", operation))
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
			"MiningSiteMasteryIncreased":
				last_notice = I18n.t("notice.mining_mastery", "Permanent mining site mastery increased to level %d.") % int(event.get("level", 1))
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
	state = transaction.commit()
	_publish_events(transaction.events)
	state_changed.emit()


func _format_duration(milliseconds: int) -> String:
	var seconds := milliseconds / 1000
	if seconds < 60:
		return "%ds" % seconds
	if seconds < 3600:
		return "%dm %02ds" % [seconds / 60, seconds % 60]
	return "%dh %02dm" % [seconds / 3600, (seconds % 3600) / 60]
