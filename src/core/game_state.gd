class_name SpaceGameState
extends RefCounted

const SAVE_VERSION := GameVersion.SAVE_SCHEMA_VERSION
const GAME_VERSION := GameVersion.PRODUCT_VERSION
const MAIN_BASE_LOCATION_ID := "earth_orbit"
const SYSTEM_ID := "sol"
const MAX_INDUSTRIAL_OPERATIONS := 6
const MAX_CONSTRUCTION_OPERATIONS := 6
const MANUFACTURING_FACILITY_IDS := [
	"makeshift_workshop",
	"orbital_foundry",
	"electronics_facility",
	"assembly_yard",
	"field_engineering_complex",
	"frontier_matterworks"
]

var save_id := ""
var revision := 0
var parent_revision := 0
var device_id := ""
var saved_at_ms := 0
var total_elapsed_ms := 0.0
var locations := {}
## Compatibility views only. Both maps directly reference the Main Base
## Location; neither field is serialized as a second inventory authority.
var inventory: Dictionary:
	get:
		return location_inventory(MAIN_BASE_LOCATION_ID)
	set(value):
		_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)
		locations[MAIN_BASE_LOCATION_ID]["inventory"] = value.duplicate(true)
var domains := {}
var ships: Array = []
var regions := {"earth_orbit": true}
var completed_activities := {}
var statistics := {"items_produced": 0, "items_consumed":0, "cycles_completed": 0, "enemies_defeated": 0, "bosses_defeated":0, "expeditions_failed": 0, "research_completed":0, "ships_developed":0}
var rng := {"algorithm_version":1, "master_seed":730201, "streams":{}}

var extraction_assets := {"ship_ids":[]}
var extraction_command := {"capacity":40}
var expedition_fleet := {"ship_ids":[]}
var mining_operations: Array = []
var industrial_operations: Array = []
var construction_operations: Array = []
var active_expedition := {}
var facilities := {}
var expedition_reports: Array = []
var research := {}
var technologies := {}
var completed_projects := {}
var unlocked_ship_plans := {}
var shipyard_queue: Array = []
var inventory_reserves: Dictionary:
	get:
		return location_reserves(MAIN_BASE_LOCATION_ID)
	set(value):
		_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)
		locations[MAIN_BASE_LOCATION_ID]["reserves"] = value.duplicate(true)
var infrastructure_sites := {"earth_orbit":true}
var megastructures := {}
var major_discoveries := {}
var game_complete := false
var completed_at_ms := 0
var combat_log: Array = []
var automation := {"rates":{}, "fractional":{}}
var progression_tier := 1
var resource_maturity := {}
var background_economy := {
	"mining_sources":{},
	"industry_networks":{},
	"targets":{},
	"priorities":{},
	"fractional":{},
	"production_totals":{},
	"consumption_totals":{}
}
var energy_system := {
	"advanced_priorities":{},
	"maintenance_fractional":{},
	"maintenance_coverage":{}
}
var manufacturing_module_inventory := {}
var manufacturing_modules_built := {}
var pinned_items: Array = []
var saved_loadouts := {}
var region_states := {}
var mining_site_states := {}
var combat_area_states := {}
var extraction_network_states := {}
var equipment_instances := {}
var next_equipment_serial := 1
var next_ship_serial := 1
var refit_projects: Array = []
var fleet_logistics := {
	"expedition":{
		"command_capacity":100,
		"supplies":{},
		"recovered":{},
		"supply_plan":{"kinetic_munitions":60, "chemical_propellant":20, "repair_supplies":10},
		"policies":{"ammunition_empty":"RETURN", "repair_empty":"RETURN", "cargo_full":"RETURN"}
	}
}


static func create_new(domain_ids: Array, location_definitions: Dictionary = {}) -> SpaceGameState:
	var state := SpaceGameState.new()
	state.initialize_locations(location_definitions)
	state.save_id = "local-%x" % int(Time.get_unix_time_from_system() * 1000.0)
	state.device_id = OS.get_unique_id()
	for domain_id in domain_ids:
		state.domains[domain_id] = {"level":1, "xp":0, "cycles":0}
	state.extraction_assets = {"ship_ids":[]}
	state.extraction_command = {"capacity":40}
	state.expedition_fleet = {"ship_ids":[]}
	for index in MAX_INDUSTRIAL_OPERATIONS:
		state.industrial_operations.append(_empty_industrial_operation(index, MANUFACTURING_FACILITY_IDS[index]))
	for index in MAX_CONSTRUCTION_OPERATIONS:
		state.construction_operations.append(_empty_operation(index, "construction"))
	state.active_expedition = _empty_operation(0, "expedition")
	state.active_expedition.merge({"phase":"IDLE", "route_id":"", "node_index":0, "node_progress_ms":0.0, "safe_node_index":0, "combat_state":{}}, true)
	state.research = {"status":"IDLE", "project_id":"", "progress_ms":0.0, "productivity_progress":0.0, "consumed":{}, "reserved_costs":{}, "blocked_reason":"", "location_id":MAIN_BASE_LOCATION_ID}
	state.facilities = {
		"makeshift_workshop":{"level":1, "status":"ACTIVE"},
		"fission_reactor":{"level":1, "status":"ACTIVE"},
		"orbital_construction_yard":{"level":1, "status":"ACTIVE", "installed_modules":[]},
		"orbital_starport":{"level":1, "status":"ACTIVE", "installed_modules":[]}
	}
	state.ships = []
	state._create_ship_instance("patchwork_prospector", ["light_autocannon", "civilian_shield", "basic_drive", "mining_laser", "civilian_reactor_core"], "ISS Pioneer")
	# The founding stockpile prevents an early circular dependency before basic
	# electronics production comes online.
	state.locations[MAIN_BASE_LOCATION_ID]["inventory"] = {"scrap_metal":12, "electronics":16, "data_core":2, "kinetic_munitions":120, "chemical_propellant":20, "repair_supplies":10}
	state.saved_at_ms = int(Time.get_unix_time_from_system() * 1000.0)
	return state


static func from_dictionary(data: Dictionary, domain_ids: Array, location_definitions: Dictionary = {}) -> SpaceGameState:
	var state := create_new(domain_ids, location_definitions)
	state.save_id = str(data.get("save_id", state.save_id))
	state.revision = int(data.get("revision", 0))
	state.parent_revision = int(data.get("parent_revision", maxi(0, state.revision - 1)))
	state.device_id = str(data.get("device_id", state.device_id))
	state.saved_at_ms = int(data.get("saved_at_ms", Time.get_unix_time_from_system() * 1000))
	state.total_elapsed_ms = float(data.get("total_elapsed_ms", 0.0))
	if data.get("locations", null) is Dictionary and not data.get("locations", {}).is_empty():
		state._load_locations(data.get("locations", {}), location_definitions)
	else:
		# Lab schema 24 stored one global stockpile. Schema 25 gives it exactly
		# one owner and omits the legacy fields on the next save.
		state.locations[MAIN_BASE_LOCATION_ID]["inventory"] = data.get("inventory", {}).duplicate(true)
		state.locations[MAIN_BASE_LOCATION_ID]["reserves"] = data.get("inventory_reserves", {}).duplicate(true)
	state.ships = data.get("ships", state.ships).duplicate(true)
	state.regions = data.get("regions", state.regions).duplicate(true)
	state.completed_activities = data.get("completed_activities", {}).duplicate(true)
	state.statistics = data.get("statistics", state.statistics).duplicate(true)
	state.rng = data.get("rng", state.rng).duplicate(true)
	state.extraction_assets = data.get("extraction_assets", state.extraction_assets).duplicate(true)
	state.extraction_command = data.get("extraction_command", state.extraction_command).duplicate(true)
	state.extraction_command["capacity"] = maxi(1, int(state.extraction_command.get("capacity", 40)))
	state.expedition_fleet = data.get("expedition_fleet", state.expedition_fleet).duplicate(true)
	state.mining_operations = _normalized_operations(data.get("mining_operations", []), 0, "mining", true)
	state.industrial_operations = _normalized_industrial_operations(data.get("industrial_operations", []))
	state.construction_operations = _normalized_operations(data.get("construction_operations", []), MAX_CONSTRUCTION_OPERATIONS, "construction")
	for operation in state.construction_operations:
		operation["productivity_progress"] = 0.0
	state.active_expedition = data.get("active_expedition", state.active_expedition).duplicate(true)
	state.facilities = data.get("facilities", state.facilities).duplicate(true)
	if not state.facilities.has("orbital_construction_yard"):
		state.facilities["orbital_construction_yard"] = {"level":1, "status":"ACTIVE", "installed_modules":[]}
	if not state.facilities.has("orbital_starport"):
		state.facilities["orbital_starport"] = {"level":1, "status":"ACTIVE", "installed_modules":[]}
	state.expedition_reports = data.get("expedition_reports", []).duplicate(true)
	state.research = data.get("research", state.research).duplicate(true)
	state.research["productivity_progress"] = 0.0
	state.research["location_id"] = str(state.research.get("location_id", MAIN_BASE_LOCATION_ID))
	state.technologies = data.get("technologies", {}).duplicate(true)
	state.completed_projects = data.get("completed_projects", {}).duplicate(true)
	state.unlocked_ship_plans = data.get("unlocked_ship_plans", {}).duplicate(true)
	state.shipyard_queue = _normalized_shipyard_queue(data.get("shipyard_queue", []))
	state.infrastructure_sites = data.get("infrastructure_sites", state.infrastructure_sites).duplicate(true)
	state.megastructures = data.get("megastructures", {}).duplicate(true)
	state.major_discoveries = data.get("major_discoveries", {}).duplicate(true)
	state.game_complete = bool(data.get("game_complete", false))
	state.completed_at_ms = int(data.get("completed_at_ms", 0))
	state.combat_log = data.get("combat_log", []).duplicate(true)
	state.automation = data.get("automation", state.automation).duplicate(true)
	state.progression_tier = maxi(1, int(data.get("progression_tier", 1)))
	state.resource_maturity = data.get("resource_maturity", {}).duplicate(true)
	state.background_economy = _normalized_background_economy(data.get("background_economy", {}))
	state.energy_system = _normalized_energy_system(data.get("energy_system", {}))
	state.manufacturing_module_inventory = data.get("manufacturing_module_inventory", {}).duplicate(true)
	state.manufacturing_modules_built = data.get("manufacturing_modules_built", {}).duplicate(true)
	state.pinned_items = data.get("pinned_items", []).duplicate()
	state.saved_loadouts = data.get("saved_loadouts", {}).duplicate(true)
	state.region_states = data.get("region_states", {}).duplicate(true)
	state.mining_site_states = data.get("mining_site_states", {}).duplicate(true)
	state.combat_area_states = data.get("combat_area_states", {}).duplicate(true)
	state.extraction_network_states = data.get("extraction_network_states", {}).duplicate(true)
	state.equipment_instances = data.get("equipment_instances", {}).duplicate(true)
	state.next_equipment_serial = maxi(1, int(data.get("next_equipment_serial", 1)))
	state.next_ship_serial = maxi(1, int(data.get("next_ship_serial", state.ships.size() + 1)))
	state.refit_projects = data.get("refit_projects", []).duplicate(true)
	state.fleet_logistics = _normalized_fleet_logistics(data.get("fleet_logistics", {}))
	var loaded_domains: Dictionary = data.get("domains", {})
	for domain_id in domain_ids:
		if loaded_domains.has(domain_id):
			var loaded: Dictionary = loaded_domains[domain_id]
			state.domains[domain_id] = {
				"level":int(loaded.get("level", 1)),
				"xp":int(loaded.get("xp", 0)),
				"cycles":int(loaded.get("cycles", 0))
			}
	state._enforce_unique_ships()
	state._normalize_ship_assignments()
	state._normalize_activity_fleets()
	state._normalize_location_ownership()
	return state


func to_dictionary() -> Dictionary:
	return {
		"save_version":SAVE_VERSION,
		"game_version":GAME_VERSION,
		"save_id":save_id,
		"revision":revision,
		"parent_revision":parent_revision,
		"device_id":device_id,
		"saved_at_ms":saved_at_ms,
		"total_elapsed_ms":total_elapsed_ms,
		"locations":locations,
		"domains":domains,
		"ships":ships,
		"regions":regions,
		"completed_activities":completed_activities,
		"statistics":statistics,
		"rng":rng,
		"extraction_assets":extraction_assets,
		"extraction_command":extraction_command,
		"expedition_fleet":expedition_fleet,
		"mining_operations":mining_operations,
		"industrial_operations":industrial_operations,
		"construction_operations":construction_operations,
		"active_expedition":active_expedition,
		"facilities":facilities,
		"expedition_reports":expedition_reports,
		"research":research,
		"technologies":technologies,
		"completed_projects":completed_projects,
		"unlocked_ship_plans":unlocked_ship_plans,
		"shipyard_queue":shipyard_queue,
		"infrastructure_sites":infrastructure_sites,
		"megastructures":megastructures,
		"major_discoveries":major_discoveries,
		"game_complete":game_complete,
		"completed_at_ms":completed_at_ms,
		"combat_log":combat_log,
		"automation":automation,
		"progression_tier":progression_tier,
		"resource_maturity":resource_maturity,
		"background_economy":background_economy,
		"energy_system":energy_system,
		"manufacturing_module_inventory":manufacturing_module_inventory,
		"manufacturing_modules_built":manufacturing_modules_built,
		"pinned_items":pinned_items,
		"saved_loadouts":saved_loadouts,
		"region_states":region_states,
		"mining_site_states":mining_site_states,
		"combat_area_states":combat_area_states,
		"extraction_network_states":extraction_network_states,
		"equipment_instances":equipment_instances,
		"next_equipment_serial":next_equipment_serial,
		"next_ship_serial":next_ship_serial,
		"refit_projects":refit_projects,
		"fleet_logistics":fleet_logistics
	}


func initialize_locations(location_definitions: Dictionary = {}) -> void:
	locations.clear()
	if location_definitions.is_empty():
		_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)
		return
	for location_value in location_definitions.keys():
		var location_id := str(location_value)
		var known := bool(regions.get(location_id, location_id == MAIN_BASE_LOCATION_ID))
		var location_type := LocationState.ARTIFICIAL if location_id == MAIN_BASE_LOCATION_ID else LocationState.NATURAL
		_ensure_location(location_id, location_type, known)
	_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)


func has_location(location_id: String) -> bool:
	return locations.has(location_id)


func ensure_location(location_id: String, location_type: String = LocationState.NATURAL, known: bool = false) -> void:
	_ensure_location(location_id, location_type, known)


func location_state(location_id: String) -> Dictionary:
	return locations.get(location_id, {})


func location_inventory(location_id: String = MAIN_BASE_LOCATION_ID) -> Dictionary:
	if not locations.has(location_id):
		return {}
	return locations[location_id].get("inventory", {})


func location_reserves(location_id: String = MAIN_BASE_LOCATION_ID) -> Dictionary:
	if not locations.has(location_id):
		return {}
	return locations[location_id].get("reserves", {})


func item_quantity(item_id: String, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	return int(location_inventory(location_id).get(item_id, 0))


func aggregate_item_quantity(item_id: String) -> int:
	var total := 0
	for location in locations.values():
		total += int(location.get("inventory", {}).get(item_id, 0))
	return total


func aggregate_inventory() -> Dictionary:
	var result := {}
	for location in locations.values():
		for item_id in location.get("inventory", {}):
			result[item_id] = int(result.get(item_id, 0)) + int(location["inventory"].get(item_id, 0))
	return result


func aggregate_reserved_quantity(item_id: String) -> int:
	var total := 0
	for location_id in locations:
		total += int(location_reserves(str(location_id)).get(item_id, 0))
	return total


func aggregate_committed_quantity(item_id: String) -> int:
	var total := 0
	for location_id in locations:
		var id := str(location_id)
		total += research_committed_quantity(item_id, id)
		total += industrial_committed_quantity(item_id, -1, id)
		total += construction_committed_quantity(item_id, -1, id)
		total += shipyard_committed_quantity(item_id, "", id)
	return total


func inventory_breakdown(item_id: String) -> Array:
	var result: Array = []
	for location_id in locations:
		var quantity := item_quantity(item_id, str(location_id))
		if quantity != 0:
			result.append({"location_id":str(location_id), "quantity":quantity})
	result.sort_custom(func(a, b): return int(a.get("quantity", 0)) > int(b.get("quantity", 0)))
	return result


func total_inventory_units(location_id: String = "") -> int:
	var source: Dictionary = aggregate_inventory() if location_id.is_empty() else location_inventory(location_id)
	var total := 0
	for quantity in source.values():
		total += int(quantity)
	return total


func add_item(item_id: String, quantity: int, location_id: String = MAIN_BASE_LOCATION_ID) -> void:
	_ensure_location(location_id, LocationState.ARTIFICIAL if location_id == MAIN_BASE_LOCATION_ID else LocationState.NATURAL, true)
	var owned_inventory := location_inventory(location_id)
	owned_inventory[item_id] = item_quantity(item_id, location_id) + quantity
	if quantity > 0:
		statistics["items_produced"] = int(statistics.get("items_produced", 0)) + quantity


func available_item_quantity(item_id: String, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	return maxi(0, available_item_quantity_for_research(item_id, location_id) - research_committed_quantity(item_id, location_id))


func available_item_quantity_for_research(item_id: String, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	return maxi(0, item_quantity(item_id, location_id) - int(location_reserves(location_id).get(item_id, 0)) - industrial_committed_quantity(item_id, -1, location_id) - construction_committed_quantity(item_id, -1, location_id) - shipyard_committed_quantity(item_id, "", location_id))


func available_item_quantity_for_industry(item_id: String, excluded_slot: int, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	return maxi(0, item_quantity(item_id, location_id) - int(location_reserves(location_id).get(item_id, 0)) - research_committed_quantity(item_id, location_id) - construction_committed_quantity(item_id, -1, location_id) - shipyard_committed_quantity(item_id, "", location_id) - industrial_committed_quantity(item_id, excluded_slot, location_id))


func available_item_quantity_for_construction(item_id: String, excluded_slot: int, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	return maxi(0, item_quantity(item_id, location_id) - int(location_reserves(location_id).get(item_id, 0)) - research_committed_quantity(item_id, location_id) - industrial_committed_quantity(item_id, -1, location_id) - shipyard_committed_quantity(item_id, "", location_id) - construction_committed_quantity(item_id, excluded_slot, location_id))


func available_item_quantity_for_shipyard(item_id: String, excluded_plan_id: String = "", location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	return maxi(0, item_quantity(item_id, location_id) - int(location_reserves(location_id).get(item_id, 0)) - research_committed_quantity(item_id, location_id) - industrial_committed_quantity(item_id, -1, location_id) - construction_committed_quantity(item_id, -1, location_id) - shipyard_committed_quantity(item_id, excluded_plan_id, location_id))


func research_committed_quantity(item_id: String, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	return maxi(0, int(research.get("reserved_costs", {}).get(item_id, 0))) if str(research.get("location_id", MAIN_BASE_LOCATION_ID)) == location_id else 0


func industrial_committed_quantity(item_id: String, excluded_slot: int = -1, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	var result := 0
	for operation in industrial_operations:
		if int(operation.get("slot", -1)) == excluded_slot or operation.get("status", "IDLE") not in ["RUNNING", "BLOCKED"] or str(operation.get("location_id", MAIN_BASE_LOCATION_ID)) != location_id:
			continue
		result += maxi(0, int(operation.get("reserved_costs", {}).get(item_id, 0)))
	return result


func construction_committed_quantity(item_id: String, excluded_slot: int = -1, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	var result := 0
	for operation in construction_operations:
		if int(operation.get("slot", -1)) == excluded_slot or operation.get("status", "IDLE") not in ["RUNNING", "BLOCKED", "QUEUED"] or str(operation.get("location_id", MAIN_BASE_LOCATION_ID)) != location_id:
			continue
		result += maxi(0, int(operation.get("reserved_costs", {}).get(item_id, 0)))
	return result


func shipyard_committed_quantity(item_id: String, excluded_project_id: String = "", location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	var total := 0
	for runtime in shipyard_queue:
		if str(runtime.get("project_id", "")) == excluded_project_id or runtime.get("status", "") not in ["RUNNING", "BLOCKED"] or str(runtime.get("location_id", MAIN_BASE_LOCATION_ID)) != location_id:
			continue
		total += maxi(0, int(runtime.get("reserved_costs", {}).get(item_id, 0)))
	return total


func unlock_ship_plan(plan_id: String) -> bool:
	if plan_id.is_empty() or bool(unlocked_ship_plans.get(plan_id, false)):
		return false
	unlocked_ship_plans[plan_id] = true
	return true


func ship_plan_queued(plan_id: String) -> bool:
	for runtime in shipyard_queue:
		if str(runtime.get("plan_id", "")) == plan_id:
			return true
	return false


func enqueue_ship_plan(plan_id: String) -> bool:
	if not bool(unlocked_ship_plans.get(plan_id, false)):
		return false
	var project_id := "SHIPBUILD-%06d" % (shipyard_queue.size() + int(statistics.get("ships_built", 0)) + 1)
	shipyard_queue.append({
		"project_id":project_id,
		"plan_id":plan_id,
		"completed_segments":0,
		"paid_cycles":0,
		"cycle_progress":0.0,
		"productivity_progress":0.0,
		"consumed":{},
		"reserved_costs":{},
		"status":"RUNNING",
		"blocked_reason":"",
		"location_id":MAIN_BASE_LOCATION_ID,
		"enqueued_at_ms":int(total_elapsed_ms)
	})
	return true


func set_item_reserve(item_id: String, quantity: int, location_id: String = MAIN_BASE_LOCATION_ID) -> void:
	_ensure_location(location_id, LocationState.ARTIFICIAL if location_id == MAIN_BASE_LOCATION_ID else LocationState.NATURAL, true)
	location_reserves(location_id)[item_id] = maxi(0, quantity)


func resource_maturity_state(item_id: String) -> String:
	return str(resource_maturity.get(item_id, "FRONTIER"))


func set_resource_maturity(item_id: String, maturity: String) -> void:
	var normalized := maturity.to_upper()
	if normalized not in ["FRONTIER", "MANAGED", "BACKGROUND"]:
		return
	resource_maturity[item_id] = normalized


func set_background_target(item_id: String, quantity: int) -> void:
	background_economy["targets"][item_id] = maxi(0, quantity)


func set_background_priority(item_id: String, priority: int) -> void:
	background_economy["priorities"][item_id] = clampi(priority, 0, 100)


func set_advanced_power_priority(facility_id: String, priority: String) -> void:
	if priority in ["CRITICAL", "HIGH", "NORMAL", "LOW"]:
		energy_system["advanced_priorities"][facility_id] = priority


func install_facility_module(facility_id: String, module_id: String) -> bool:
	if not facilities.has(facility_id) or str(facilities[facility_id].get("status", "")) != "ACTIVE":
		return false
	var installed: Array = facilities[facility_id].get("installed_modules", []).duplicate()
	if installed.has(module_id):
		return false
	installed.append(module_id)
	facilities[facility_id]["installed_modules"] = installed
	return true


func install_manufacturing_module(facility_id: String, module_id: String, module_kind: String) -> bool:
	if not facilities.has(facility_id) or str(facilities[facility_id].get("status", "")) != "ACTIVE":
		return false
	var field := "installed_process_modules" if module_kind == "process" else "installed_plugins"
	var installed: Array = facilities[facility_id].get(field, []).duplicate()
	if installed.has(module_id):
		return false
	installed.append(module_id)
	facilities[facility_id][field] = installed
	if int(manufacturing_module_inventory.get(module_id, 0)) > 0:
		manufacturing_module_inventory[module_id] = int(manufacturing_module_inventory[module_id]) - 1
	return true


func uninstall_manufacturing_module(facility_id: String, module_id: String, module_kind: String) -> bool:
	if not facilities.has(facility_id):
		return false
	var field := "installed_process_modules" if module_kind == "process" else "installed_plugins"
	var installed: Array = facilities[facility_id].get(field, []).duplicate()
	if not installed.has(module_id):
		return false
	installed.erase(module_id)
	facilities[facility_id][field] = installed
	manufacturing_module_inventory[module_id] = int(manufacturing_module_inventory.get(module_id, 0)) + 1
	return true


func remove_item(item_id: String, quantity: int, location_id: String = MAIN_BASE_LOCATION_ID) -> bool:
	if item_quantity(item_id, location_id) < quantity:
		return false
	location_inventory(location_id)[item_id] = item_quantity(item_id, location_id) - quantity
	statistics["items_consumed"] = int(statistics.get("items_consumed", 0)) + quantity
	return true


func owns_ship_model(blueprint_id: String) -> bool:
	for ship in ships:
		if str(ship.get("blueprint_id", "")) == blueprint_id:
			return true
	return false


func add_unique_ship(blueprint_id: String, modules: Array = []) -> bool:
	return not _create_ship_instance(blueprint_id, modules).is_empty()


func _create_ship_instance(blueprint_id: String, module_definitions: Array = [], requested_name: String = "") -> Dictionary:
	if blueprint_id.is_empty():
		return {}
	var instance_id := "SHIP-%03d" % next_ship_serial
	next_ship_serial += 1
	var ship := {
		"instance_id":instance_id,
		"name":requested_name if not requested_name.is_empty() else "ISS %03d" % (next_ship_serial - 1),
		"blueprint_id":blueprint_id,
		"status":"DOCKED",
		"condition":"OPERATIONAL",
		"assignment":{},
		"repair_remaining_ms":0.0,
		"modules":[],
		"built_at_ms":int(total_elapsed_ms),
		"lifetime_output":0,
		"lifetime_damage":0,
		"damage_taken":0.0,
		"service_record":{"extraction_cycles":0, "combat_deployments":0, "discoveries":0},
		"location_id":MAIN_BASE_LOCATION_ID
	}
	ships.append(ship)
	for definition_value in module_definitions:
		var equipment_id := create_equipment_instance(str(definition_value), "SHIP_CONSTRUCTION")
		install_equipment_instance(equipment_id, instance_id)
	return ship


func create_equipment_instance(definition_id: String, origin: String = "STARPORT") -> String:
	if definition_id.is_empty():
		return ""
	var instance_id := "EQUIP-%06d" % next_equipment_serial
	next_equipment_serial += 1
	equipment_instances[instance_id] = {
		"instance_id":instance_id,
		"definition_id":definition_id,
		"status":"STORAGE",
		"installed_ship_id":"",
		"origin":origin,
		"created_at_ms":int(total_elapsed_ms)
	}
	return instance_id


func equipment_definition_id(equipment_id: String) -> String:
	return str(equipment_instances.get(equipment_id, {}).get("definition_id", ""))


func ship_module_definition_ids(ship: Dictionary) -> Array:
	var result: Array = []
	for equipment_value in ship.get("modules", []):
		var equipment_id := str(equipment_value)
		var definition_id := equipment_definition_id(equipment_id)
		if not definition_id.is_empty():
			result.append(definition_id)
	return result


func stored_equipment_ids(definition_id: String = "") -> Array:
	var result: Array = []
	for equipment_id in equipment_instances:
		var instance: Dictionary = equipment_instances[equipment_id]
		if str(instance.get("status", "")) != "STORAGE":
			continue
		if definition_id.is_empty() or str(instance.get("definition_id", "")) == definition_id:
			result.append(str(equipment_id))
	result.sort()
	return result


func install_equipment_instance(equipment_id: String, ship_id: String) -> bool:
	var ship := ship_by_id(ship_id)
	var equipment: Dictionary = equipment_instances.get(equipment_id, {})
	if ship.is_empty() or equipment.is_empty() or str(equipment.get("status", "")) not in ["STORAGE", "RESERVED_REFIT"]:
		return false
	for other_ship in ships:
		if other_ship.get("modules", []).has(equipment_id):
			return false
	var installed: Array = ship.get("modules", []).duplicate()
	installed.append(equipment_id)
	ship["modules"] = installed
	equipment["status"] = "INSTALLED"
	equipment["installed_ship_id"] = ship_id
	return true


func store_equipment_instance(equipment_id: String) -> bool:
	var equipment: Dictionary = equipment_instances.get(equipment_id, {})
	if equipment.is_empty():
		return false
	var ship_id := str(equipment.get("installed_ship_id", ""))
	var ship := ship_by_id(ship_id)
	if not ship.is_empty():
		var installed: Array = ship.get("modules", []).duplicate()
		installed.erase(equipment_id)
		ship["modules"] = installed
	equipment["status"] = "STORAGE"
	equipment["installed_ship_id"] = ""
	return true


func ship_by_id(instance_id: String) -> Dictionary:
	for ship in ships:
		if str(ship.get("instance_id", "")) == instance_id:
			return ship
	return {}


func ship_is_docked(instance_id: String) -> bool:
	var ship := ship_by_id(instance_id)
	return not ship.is_empty() and ship.get("status", "") == "DOCKED" and ship.get("condition", "") == "OPERATIONAL"


func ship_is_unassigned_docked(instance_id: String) -> bool:
	var ship := ship_by_id(instance_id)
	return ship_is_docked(instance_id) and ship.get("assignment", {}).is_empty()


func ship_in_extraction_assets(instance_id: String) -> bool:
	return extraction_assets.get("ship_ids", []).has(instance_id)


func fleet_ship_ids(domain_id: String) -> Array:
	match domain_id:
		"mining":
			return extraction_assets.get("ship_ids", []).duplicate()
		"expedition":
			return expedition_fleet.get("ship_ids", []).duplicate()
	return []


func ship_fleet_domain(instance_id: String) -> String:
	for domain_id in ["mining", "expedition"]:
		if fleet_ship_ids(domain_id).has(instance_id):
			return domain_id
	return ""


func set_fleet_ship_ids(domain_id: String, ship_ids: Array) -> void:
	match domain_id:
		"mining":
			extraction_assets = {"ship_ids":ship_ids.duplicate()}
		"expedition":
			expedition_fleet = {"ship_ids":ship_ids.duplicate()}


func has_external_activity() -> bool:
	if active_expedition.get("status", "IDLE") == "RUNNING":
		return true
	for operation in mining_operations:
		if operation.get("status", "IDLE") == "RUNNING":
			return true
	return false


func ship_can_refit(instance_id: String) -> bool:
	return ship_is_docked(instance_id)


func mining_site_available(site_id: String) -> bool:
	var runtime: Dictionary = mining_site_states.get(site_id, {})
	return (
		bool(runtime.get("discovered", false))
		and bool(runtime.get("unlocked", true))
		and str(runtime.get("state", "AVAILABLE")) not in ["LOCKED", "INTEGRATED"]
		and str(runtime.get("integrated_network_id", "")).is_empty()
	)


func mastered_mining_site_count(region_id: String, required_level: int = 1) -> int:
	var count := 0
	for runtime in mining_site_states.values():
		if str(runtime.get("region", "")) == region_id and int(runtime.get("mastery_level", 0)) >= required_level:
			count += 1
	return count


func extraction_command_capacity() -> int:
	return maxi(1, int(extraction_command.get("capacity", 40)))


func fleet_logistics_runtime(fleet_id: String = "expedition") -> Dictionary:
	if not fleet_logistics.has(fleet_id):
		fleet_logistics[fleet_id] = {"command_capacity":100, "supplies":{}, "recovered":{}, "supply_plan":{}, "policies":{}}
	return fleet_logistics[fleet_id]


func fleet_supply_quantity(item_id: String, fleet_id: String = "expedition") -> int:
	return int(fleet_logistics_runtime(fleet_id).get("supplies", {}).get(item_id, 0))


func consume_fleet_supply(item_id: String, quantity: int, fleet_id: String = "expedition") -> bool:
	var runtime := fleet_logistics_runtime(fleet_id)
	var supplies: Dictionary = runtime.get("supplies", {})
	if int(supplies.get(item_id, 0)) < quantity:
		return false
	supplies[item_id] = int(supplies.get(item_id, 0)) - quantity
	runtime["supplies"] = supplies
	return true


func add_recovered_cargo(item_id: String, quantity: int, fleet_id: String = "expedition") -> void:
	var runtime := fleet_logistics_runtime(fleet_id)
	var recovered: Dictionary = runtime.get("recovered", {})
	recovered[item_id] = int(recovered.get(item_id, 0)) + quantity
	runtime["recovered"] = recovered


func unload_fleet_cargo(fleet_id: String = "expedition", unload_supplies: bool = false) -> void:
	var runtime := fleet_logistics_runtime(fleet_id)
	for item_id in runtime.get("recovered", {}):
		add_item(str(item_id), int(runtime["recovered"][item_id]))
	runtime["recovered"] = {}
	if unload_supplies:
		for item_id in runtime.get("supplies", {}):
			add_item(str(item_id), int(runtime["supplies"][item_id]))
		runtime["supplies"] = {}


static func _empty_operation(index: int, domain_id: String) -> Dictionary:
	return {
		"slot":index,
		"domain":domain_id,
		"activity_id":"",
		"progress_ms":0.0,
		"cycle_progress":0.0,
		"productivity_progress":0.0,
		"project_cycles_completed":0,
		"paid_cycles":0,
		"status":"IDLE",
		"assigned_ship_ids":[],
		"reserved_costs":{},
		"allocated_capacity":1.0,
		"location_id":MAIN_BASE_LOCATION_ID,
		"site_id":"",
		"raw_material_id":"",
		"allocated_mining_power":0.0,
		"effective_mining_power":0.0
	}


static func create_operation_record(index: int, domain_id: String) -> Dictionary:
	# A permanent site owns one runtime record and may bind multiple equipped ships.
	return _empty_operation(index, domain_id)


static func _empty_industrial_operation(index: int, facility_id: String) -> Dictionary:
	var operation := _empty_operation(index, "industry")
	operation["facility_id"] = facility_id
	operation.erase("allocated_capacity")
	return operation


static func _normalized_operations(source: Array, minimum: int, domain_id: String, preserve_extra: bool = false) -> Array:
	var result: Array = []
	var count := maxi(minimum, source.size()) if preserve_extra else minimum
	for index in count:
		var normalized := _empty_operation(index, domain_id)
		if index < source.size():
			var operation: Dictionary = source[index].duplicate(true)
			for key in operation:
				normalized[key] = operation[key]
		normalized["slot"] = index
		normalized["domain"] = domain_id
		if str(normalized.get("location_id", "")).is_empty():
			normalized["location_id"] = MAIN_BASE_LOCATION_ID
		result.append(normalized)
	return result


static func _normalized_industrial_operations(source: Array) -> Array:
	var result: Array = []
	for index in MAX_INDUSTRIAL_OPERATIONS:
		var normalized := _empty_industrial_operation(index, MANUFACTURING_FACILITY_IDS[index])
		if index < source.size():
			var operation: Dictionary = source[index].duplicate(true)
			for key in operation:
				normalized[key] = operation[key]
		normalized["slot"] = index
		normalized["domain"] = "industry"
		normalized["facility_id"] = MANUFACTURING_FACILITY_IDS[index]
		normalized.erase("allocated_capacity")
		if str(normalized.get("location_id", "")).is_empty():
			normalized["location_id"] = MAIN_BASE_LOCATION_ID
		result.append(normalized)
	return result


static func _normalized_shipyard_queue(source: Array) -> Array:
	var result: Array = []
	for value in source:
		if value is not Dictionary:
			continue
		var runtime: Dictionary = value.duplicate(true)
		if str(runtime.get("plan_id", "")).is_empty():
			continue
		if str(runtime.get("project_id", "")).is_empty():
			runtime["project_id"] = "SHIPBUILD-%06d" % (result.size() + 1)
		runtime["completed_segments"] = clampi(int(runtime.get("completed_segments", 0)), 0, 100)
		runtime["paid_cycles"] = maxi(0, int(runtime.get("paid_cycles", runtime.get("completed_segments", 0))))
		runtime["cycle_progress"] = clampf(float(runtime.get("cycle_progress", 0.0)), 0.0, 0.999999)
		# Kept in the schema for save compatibility only. Unique ship projects
		# cannot receive Productivity output.
		runtime["productivity_progress"] = 0.0
		runtime["consumed"] = runtime.get("consumed", {}).duplicate(true)
		runtime["reserved_costs"] = runtime.get("reserved_costs", {}).duplicate(true)
		runtime["status"] = str(runtime.get("status", "RUNNING"))
		if runtime["status"] == "QUEUED":
			runtime["status"] = "RUNNING"
		runtime["blocked_reason"] = str(runtime.get("blocked_reason", ""))
		runtime["location_id"] = str(runtime.get("location_id", MAIN_BASE_LOCATION_ID))
		if str(runtime["location_id"]).is_empty():
			runtime["location_id"] = MAIN_BASE_LOCATION_ID
		result.append(runtime)
	return result


func _ensure_location(location_id: String, location_type: String, known: bool) -> void:
	if location_id.is_empty():
		location_id = MAIN_BASE_LOCATION_ID
	if not locations.has(location_id):
		locations[location_id] = LocationState.create(location_id, location_type, SYSTEM_ID, known)


func _load_locations(source: Dictionary, location_definitions: Dictionary) -> void:
	initialize_locations(location_definitions)
	for location_value in source.keys():
		var location_id := str(location_value)
		var location_type := LocationState.ARTIFICIAL if location_id == MAIN_BASE_LOCATION_ID else LocationState.NATURAL
		var known := bool(regions.get(location_id, location_id == MAIN_BASE_LOCATION_ID))
		locations[location_id] = LocationState.normalize(source[location_value], location_id, location_type, SYSTEM_ID, known)
	_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)


func _normalize_location_ownership() -> void:
	_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)
	for operation in industrial_operations:
		operation["location_id"] = str(operation.get("location_id", MAIN_BASE_LOCATION_ID))
		if str(operation["location_id"]).is_empty():
			operation["location_id"] = MAIN_BASE_LOCATION_ID
	for operation in construction_operations:
		operation["location_id"] = str(operation.get("location_id", MAIN_BASE_LOCATION_ID))
		if str(operation["location_id"]).is_empty():
			operation["location_id"] = MAIN_BASE_LOCATION_ID
	for runtime in shipyard_queue:
		runtime["location_id"] = str(runtime.get("location_id", MAIN_BASE_LOCATION_ID))
		if str(runtime["location_id"]).is_empty():
			runtime["location_id"] = MAIN_BASE_LOCATION_ID
	research["location_id"] = str(research.get("location_id", MAIN_BASE_LOCATION_ID))
	if str(research["location_id"]).is_empty():
		research["location_id"] = MAIN_BASE_LOCATION_ID
	for ship in ships:
		ship["location_id"] = str(ship.get("location_id", MAIN_BASE_LOCATION_ID))
		if str(ship["location_id"]).is_empty():
			ship["location_id"] = MAIN_BASE_LOCATION_ID


static func _normalized_background_economy(source: Dictionary) -> Dictionary:
	var result := {
		"mining_sources":{},
		"industry_networks":{},
		"targets":{},
		"priorities":{},
		"fractional":{},
		"production_totals":{},
		"consumption_totals":{}
	}
	for key in result:
		if source.get(key, null) is Dictionary:
			result[key] = source[key].duplicate(true)
	return result


static func _normalized_energy_system(source: Dictionary) -> Dictionary:
	var result := {
		"advanced_priorities":{},
		"maintenance_fractional":{},
		"maintenance_coverage":{}
	}
	for key in result:
		if source.get(key, null) is Dictionary:
			result[key] = source[key].duplicate(true)
	return result


static func _normalized_fleet_logistics(source: Dictionary) -> Dictionary:
	var result := {
		"expedition":{
			"command_capacity":100,
			"supplies":{},
			"recovered":{},
			"supply_plan":{"kinetic_munitions":60, "chemical_propellant":20, "repair_supplies":10},
			"policies":{"ammunition_empty":"RETURN", "repair_empty":"RETURN", "cargo_full":"RETURN"}
		}
	}
	for fleet_id in source:
		if source[fleet_id] is not Dictionary:
			continue
		var normalized: Dictionary = result.get(fleet_id, {"command_capacity":100, "supplies":{}, "recovered":{}, "supply_plan":{}, "policies":{}}).duplicate(true)
		for field in ["command_capacity", "supplies", "recovered", "supply_plan", "policies"]:
			if source[fleet_id].has(field):
				normalized[field] = source[fleet_id][field].duplicate(true) if source[fleet_id][field] is Dictionary else source[fleet_id][field]
		result[fleet_id] = normalized
	return result


func _enforce_unique_ships() -> void:
	var seen := {}
	var unique: Array = []
	for ship in ships:
		var instance_id := str(ship.get("instance_id", ""))
		if instance_id.is_empty() or seen.has(instance_id):
			continue
		seen[instance_id] = true
		unique.append(ship)
	ships = unique


func _normalize_ship_assignments() -> void:
	for ship in ships:
		if not ship.has("name"):
			ship["name"] = "ISS %s" % str(ship.get("instance_id", "SHIP")).trim_prefix("SHIP-")
		if not ship.has("assignment"):
			ship["assignment"] = {}
		if not ship.has("repair_remaining_ms"):
			ship["repair_remaining_ms"] = 0.0
		if ship.get("status", "") in ["ACTIVE", "STARPORT"]:
			ship["status"] = "DOCKED"
		if not ship.has("condition"):
			ship["condition"] = "OPERATIONAL"
		if not ship.has("damage_taken"):
			ship["damage_taken"] = 0.0


func _normalize_activity_fleets() -> void:
	var claimed: Array[String] = []
	for domain_id in ["mining", "expedition"]:
		var normalized_ids: Array = []
		for ship_id in fleet_ship_ids(domain_id):
			var id := str(ship_id)
			if not id.is_empty() and not claimed.has(id) and not ship_by_id(id).is_empty():
				normalized_ids.append(id)
				claimed.append(id)
		set_fleet_ship_ids(domain_id, normalized_ids)
	for ship in ships:
		if ship.get("status", "") in ["REPAIRING", "DISABLED", "BUILDING", "REFITTING"]:
			continue
		var ship_id := str(ship.get("instance_id", ""))
		var domain_id := ship_fleet_domain(ship_id)
		ship["status"] = "DOCKED"
		ship["assignment"] = {} if domain_id.is_empty() else {"domain":domain_id, "fleet":"default"}
	for operation in mining_operations:
		if operation.get("status", "IDLE") != "RUNNING":
			continue
		for ship_id in operation.get("assigned_ship_ids", []):
			var ship := ship_by_id(str(ship_id))
			if not ship.is_empty() and ship.get("condition", "OPERATIONAL") == "OPERATIONAL":
				ship["status"] = "EXTRACTION_OPERATION"
				ship["assignment"] = {"domain":"mining", "slot":int(operation.get("slot", 0))}
	if active_expedition.get("status", "IDLE") == "RUNNING":
		for ship_id in active_expedition.get("assigned_ship_ids", []):
			var ship := ship_by_id(str(ship_id))
			if not ship.is_empty() and ship.get("condition", "OPERATIONAL") == "OPERATIONAL":
				ship["status"] = "EXPEDITION"
				ship["assignment"] = {"domain":"expedition", "fleet":"default"}
