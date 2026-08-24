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


func set_ship_fleet_assignment(instance_id: String, domain_id: String) -> bool:
	if domain_id not in ["", "mining", "expedition"]:
		return _reject(I18n.t("notice.ship_assignment_unknown", "Unknown ship assignment"))
	var ship: Dictionary = state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	if not state.ship_is_docked(instance_id):
		return _reject(I18n.t("notice.ship_assignment_locked", "The ship must be operational and docked before changing assignment"))
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
		if not state.ship_is_docked(str(ship_id)) or state.ship_fleet_domain(str(ship_id)) != domain_id:
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
	if runtime.get("status", "IDLE") != "RUNNING":
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
	runtime["activity_id"] = ""
	runtime["progress_ms"] = 0.0
	runtime["status"] = "IDLE"
	runtime["reserved_costs"] = {}
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
	if not simulation.industry_recipe_capabilities_met(state, activity):
		return _reject(I18n.t("notice.process_capability_missing", "Install the required process module before starting this recipe"))
	if not simulation.activity_available(state, activity):
		return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	if not simulation.costs_available_for_industry_slot(state, activity, slot):
		return _reject(I18n.t("notice.resources", "Strategic Inventory cannot fund one cycle"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = transaction.working_state.industrial_operations[slot]
	_assign_runtime(runtime, activity, [])
	runtime["reserved_costs"] = _cost_commitment(activity.get("costs", []))
	last_notice = I18n.t("notice.industry_started", "%s started: %s") % [I18n.content(content.facilities[facility_id]), I18n.content(activity)]
	transaction.record({"type":"IndustrialOperationStarted", "slot":slot, "facility_id":facility_id, "activity_id":activity_id})
	_commit_transaction(transaction)
	return true


func start_construction_project(activity_id: String) -> bool:
	if not content.activities.has(activity_id):
		return _reject(I18n.t("notice.unknown_activity", "Unknown construction project"))
	var activity: Dictionary = content.activities[activity_id]
	if not simulation.is_construction_activity(activity):
		return _reject(I18n.t("notice.not_construction", "This activity is not an infrastructure project"))
	if not simulation.facility_available(state, "orbital_construction_yard"):
		return _reject(I18n.t("notice.construction_yard_missing", "The Orbital Construction Yard is not active"))
	if not simulation.activity_available(state, activity):
		return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	var queue_capacity := simulation.construction_queue_capacity(state)
	var slot := simulation.construction_queue_size(state)
	if slot >= queue_capacity:
		return _reject(I18n.t("notice.construction_queue_full", "The construction queue is full"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working_runtime: Dictionary = transaction.working_state.construction_operations[slot]
	_assign_runtime(working_runtime, activity, [])
	working_runtime["reserved_costs"] = {}
	working_runtime["consumed"] = {}
	simulation.normalize_construction_queue(transaction.working_state)
	last_notice = I18n.t("notice.construction_queued", "Added to construction queue at position %d: %s") % [slot + 1, I18n.content(activity)]
	transaction.record({"type":"ConstructionProjectStarted", "slot":slot, "activity_id":activity_id})
	_commit_transaction(transaction)
	return true


func stop_construction_project(slot: int) -> bool:
	if slot < 0 or slot >= state.construction_operations.size():
		return _reject(I18n.t("notice.unknown_construction_slot", "Unknown construction queue position"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var runtime: Dictionary = transaction.working_state.construction_operations[slot]
	if runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED", "QUEUED"]:
		return _reject(I18n.t("notice.no_active", "No construction project at this queue position"))
	runtime["activity_id"] = ""
	runtime["progress_ms"] = 0.0
	runtime["cycle_progress"] = 0.0
	runtime["productivity_progress"] = 0.0
	runtime["project_cycles_completed"] = 0
	runtime["paid_cycles"] = 0
	runtime["consumed"] = {}
	runtime["recovered_cargo"] = {}
	runtime["status"] = "IDLE"
	runtime["reserved_costs"] = {}
	simulation.normalize_construction_queue(transaction.working_state)
	last_notice = I18n.t("notice.construction_removed", "Removed construction queue position %d") % [slot + 1]
	transaction.record({"type":"ConstructionProjectStopped", "slot":slot})
	_commit_transaction(transaction)
	return true


func start_research_project(project_id: String) -> bool:
	if not content.research_projects.has(project_id):
		return _reject(I18n.t("notice.research_unknown", "Unknown research project"))
	if state.research.get("status", "IDLE") == "RUNNING":
		return _reject(I18n.t("notice.research_active", "A research project is already active"))
	var project: Dictionary = content.research_projects[project_id]
	if not simulation.research_project_available(state, project):
		return _reject(I18n.t("notice.requirements", "Progression requirements are not met"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var existing: Dictionary = transaction.working_state.research
	if str(existing.get("project_id", "")) == project_id and existing.get("status", "") in ["PAUSED", "BLOCKED"]:
		existing["status"] = "RUNNING"
		existing["blocked_reason"] = ""
	else:
		if not str(existing.get("project_id", "")).is_empty():
			return _reject(I18n.t("notice.research_committed", "Pause does not cancel committed research; resume the current project"))
		transaction.working_state.research = {
			"status":"RUNNING",
			"project_id":project_id,
			"progress_ms":0.0,
			"productivity_progress":0.0,
			"consumed":{},
			"reserved_costs":_cost_commitment(project.get("costs", [])),
			"blocked_reason":"",
			"location_id":SpaceGameState.MAIN_BASE_LOCATION_ID
		}
	last_notice = I18n.t("notice.research_started", "Research started: %s") % I18n.content(project)
	transaction.record({"type":"ResearchStarted", "project_id":project_id})
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


func enqueue_unlocked_ship_plan(plan_id: String) -> bool:
	if not content.ship_construction_projects.has(plan_id):
		return _reject(I18n.t("notice.shipyard_plan_unknown", "Unknown ship construction plan"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not transaction.working_state.enqueue_ship_plan(plan_id):
		return _reject(I18n.t("notice.shipyard_plan_unavailable", "Ship plan is locked, already queued, or already built"))
	simulation.normalize_shipyard_queue(transaction.working_state)
	last_notice = I18n.t("notice.shipyard_queued", "Ship construction plan added to the queue: %s") % I18n.content(content.ship_construction_projects[plan_id])
	transaction.record({"type":"ShipyardPlanQueued", "plan_id":plan_id})
	_commit_transaction(transaction)
	return true


func set_inventory_reserve(item_id: String, quantity: int) -> bool:
	if not content.items.has(item_id):
		return _reject(I18n.t("notice.item_unknown", "Unknown inventory item"))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.set_item_reserve(item_id, quantity)
	transaction.record({"type":"InventoryReserveChanged", "item_id":item_id, "quantity":maxi(0, quantity)})
	_commit_transaction(transaction)
	return true


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


func install_manufacturing_module(facility_id: String, module_id: String, module_kind: String) -> bool:
	if module_kind not in ["process", "plugin"]:
		return _reject(I18n.t("notice.facility_module_unknown", "Unknown manufacturing module type"))
	var runtime := simulation.industry_runtime_for_facility(state, facility_id)
	if runtime.is_empty() or runtime.get("status", "IDLE") in ["RUNNING", "BLOCKED"]:
		return _reject(I18n.t("notice.manufacturing_refit_busy", "Pause this facility before changing its manufacturing build"))
	if not simulation.manufacturing_module_available(state, facility_id, module_id, module_kind):
		return _reject(I18n.t("notice.facility_module_unavailable", "Module requirements, slot capacity, ownership or costs are not met"))
	var definition := simulation.manufacturing_module_definition(module_kind, module_id)
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	var working := transaction.working_state
	if int(working.manufacturing_module_inventory.get(module_id, 0)) <= 0:
		for cost in definition.get("costs", []):
			if not working.remove_item(str(cost.get("item", "")), int(cost.get("quantity", 0))):
				return _reject(I18n.t("notice.resources", "Strategic Inventory cannot fund this module"))
		working.manufacturing_modules_built[module_id] = int(working.manufacturing_modules_built.get(module_id, 0)) + 1
	if not working.install_manufacturing_module(facility_id, module_id, module_kind):
		return _reject(I18n.t("notice.facility_module_unavailable", "Manufacturing module could not be installed"))
	last_notice = I18n.t("notice.manufacturing_module_installed", "%s installed in %s") % [I18n.content(definition), I18n.content(content.facilities.get(facility_id, {}))]
	transaction.record({"type":"ManufacturingModuleInstalled", "facility_id":facility_id, "module_id":module_id, "module_kind":module_kind})
	_commit_transaction(transaction)
	return true


func uninstall_manufacturing_module(facility_id: String, module_id: String, module_kind: String) -> bool:
	if module_kind not in ["process", "plugin"]:
		return _reject(I18n.t("notice.facility_module_unknown", "Unknown manufacturing module type"))
	var runtime := simulation.industry_runtime_for_facility(state, facility_id)
	if runtime.is_empty() or runtime.get("status", "IDLE") in ["RUNNING", "BLOCKED"]:
		return _reject(I18n.t("notice.manufacturing_refit_busy", "Pause this facility before changing its manufacturing build"))
	var definition := simulation.manufacturing_module_definition(module_kind, module_id)
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	if not transaction.working_state.uninstall_manufacturing_module(facility_id, module_id, module_kind):
		return _reject(I18n.t("notice.module_not_installed", "The module is not installed"))
	last_notice = I18n.t("notice.manufacturing_module_removed", "%s returned to industrial module storage") % I18n.content(definition)
	transaction.record({"type":"ManufacturingModuleRemoved", "facility_id":facility_id, "module_id":module_id, "module_kind":module_kind})
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


func save_ship_loadout(instance_id: String) -> bool:
	var ship := state.ship_by_id(instance_id)
	if ship.is_empty():
		return _reject(I18n.t("notice.ship_missing", "Ship instance was not found"))
	var blueprint_id := str(ship.get("blueprint_id", ""))
	var transaction := GameStateTransaction.new(state, content.domains.keys())
	transaction.working_state.saved_loadouts[blueprint_id] = {
		"id":blueprint_id,
		"blueprint_id":blueprint_id,
		"modules":state.ship_module_definition_ids(ship),
		"saved_at_ms":int(state.total_elapsed_ms)
	}
	last_notice = I18n.t("notice.loadout_saved", "Loadout preset saved: %s") % I18n.content(content.ships.get(blueprint_id, {}))
	transaction.record({"type":"ShipLoadoutSaved", "ship_id":instance_id, "loadout_id":blueprint_id})
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
	return begin_ship_refit(instance_id, desired)


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


func begin_ship_refit(instance_id: String, desired_module_definitions: Array) -> bool:
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
	var available_current: Dictionary = {}
	for equipment_id in working_ship.get("modules", []):
		var definition_id := working.equipment_definition_id(str(equipment_id))
		if not available_current.has(definition_id):
			available_current[definition_id] = []
		available_current[definition_id].append(str(equipment_id))
	var reserved_equipment_ids: Array = []
	var pending_new_definitions: Array = []
	for definition_value in desired:
		var definition_id := str(definition_value)
		var current_pool: Array = available_current.get(definition_id, [])
		if not current_pool.is_empty():
			current_pool.pop_front()
			available_current[definition_id] = current_pool
			continue
		var stored := working.stored_equipment_ids(definition_id)
		for reserved_id in reserved_equipment_ids:
			stored.erase(reserved_id)
		if not stored.is_empty():
			var equipment_id := str(stored[0])
			working.equipment_instances[equipment_id]["status"] = "RESERVED_REFIT"
			reserved_equipment_ids.append(equipment_id)
			continue
		var module_definition: Dictionary = content.modules.get(definition_id, {})
		if bool(module_definition.get("special_equipment", false)):
			return _reject(I18n.t("notice.loadout_resources", "Unique equipment must be physically recovered before installation: %s") % I18n.content(module_definition))
		# Ordinary technology modules are definitions, not a permanent module inventory.
		# A legacy boxed item can shorten the flow, but a missing item is fabricated by
		# the starport as part of the refit instead of blocking the design.
		if working.item_quantity(definition_id) > 0:
			working.remove_item(definition_id, 1)
		pending_new_definitions.append(definition_id)
	var project_id := "REFIT-%06d" % (working.refit_projects.size() + int(working.statistics.get("refits_completed", 0)) + 1)
	working.refit_projects.append({
		"project_id":project_id,
		"ship_id":instance_id,
		"desired_definitions":desired,
		"reserved_equipment_ids":reserved_equipment_ids,
		"pending_new_definitions":pending_new_definitions,
		"completed_segments":0,
		"cycle_progress":0.0,
		# One hundred refit segments are settled by the simulation. This gives an
		# ordinary refit a 35 s baseline and adds 80 s for every fabricated module.
		"cycle_time_ms":350.0 + float(pending_new_definitions.size()) * 800.0,
		"status":"RUNNING",
		"started_at_ms":int(working.total_elapsed_ms)
	})
	working_ship["status"] = "REFITTING"
	working_ship["assignment"] = {"type":"STARPORT_REFIT", "project_id":project_id}
	last_notice = I18n.t("notice.refit_started", "Starport refit started: %s") % str(working_ship.get("name", instance_id))
	transaction.record({"type":"ShipRefitStarted", "project_id":project_id, "ship_id":instance_id})
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
			return not runtime.is_empty() and runtime.get("status", "IDLE") not in ["RUNNING", "BLOCKED"] and simulation.industry_recipe_capabilities_met(state, activity)
		"expedition":
			return state.active_expedition.get("status", "IDLE") != "RUNNING" and fleet_ready("expedition")
	return false


func can_start_construction_project(activity: Dictionary) -> bool:
	if not simulation.is_construction_activity(activity) or not simulation.activity_available(state, activity):
		return false
	if not simulation.facility_available(state, "orbital_construction_yard"):
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
		"infrastructure_site":
			return I18n.t("requirement.site", "%s Infrastructure Site: %s") % [marker, str(requirement.get("id", "")).replace("_", " ").capitalize()]
		"boss_defeated":
			return I18n.t("requirement.boss", "%s Boss defeated: %s") % [marker, I18n.content(content.enemies.get(str(requirement.get("id", "")), requirement))]
		"megastructure":
			return I18n.t("requirement.megastructure", "%s Megastructure: %s") % [marker, I18n.content(content.megastructures.get(str(requirement.get("id", "")), requirement))]
		"game_complete":
			return I18n.t("requirement.game_complete", "%s Complete the first Interstellar Launch") % marker
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
	if not simulation.industry_recipe_capabilities_met(working, activity):
		return _reject(I18n.t("notice.process_capability_missing", "Install the required process module before starting this recipe"))
	_assign_runtime(runtime, activity, [])
	runtime["reserved_costs"] = _cost_commitment(activity.get("costs", []))
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
	var elapsed := clampi(now_ms - state.saved_at_ms, 0, SimulationEngine.MAX_OFFLINE_MS)
	if elapsed > 1000:
		var before_inventory: Dictionary = state.aggregate_inventory().duplicate(true)
		var before_research: Dictionary = state.research.duplicate(true)
		var before_ships: Array = state.ships.duplicate(true)
		var previous_reports := state.expedition_reports.size()
		offline_report = simulation.advance(state, float(elapsed))
		_enrich_offline_report(offline_report, elapsed, before_inventory, before_research, before_ships)
		if state.expedition_reports.size() > previous_reports and state.expedition_reports[-1].get("result", "") == "FAILED":
			last_notice = I18n.t("notice.offline_failure", "Offline Expedition failed and the fleet returned to Starport for repair.")
		else:
			last_notice = I18n.t("notice.offline", "Offline operations processed %s across %d boundaries.") % [_format_duration(elapsed), offline_report.get("operations", 0)]
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
			problems.append({"domain":"industry", "slot":int(operation.get("slot", 0)), "reason":"NO_INPUT", "activity_id":str(operation.get("activity_id", ""))})
	if str(state.research.get("status", "")) == "BLOCKED":
		problems.append({"domain":"research", "reason":str(state.research.get("blocked_reason", "BLOCKED")), "project_id":str(state.research.get("project_id", ""))})
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
				last_notice = I18n.t("notice.game_completed", "Interstellar launch complete. The Sol System era is complete.")
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
