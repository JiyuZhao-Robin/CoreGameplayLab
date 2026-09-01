class_name SpaceGameState
extends RefCounted

const WreckSiteSystemScript = preload("res://src/core/wreck_site_system.gd")
const SAVE_VERSION := GameVersion.SAVE_SCHEMA_VERSION
const GAME_VERSION := GameVersion.PRODUCT_VERSION
const MAIN_BASE_LOCATION_ID := "earth_orbit"
const SYSTEM_ID := "sol"
const DEFAULT_FORMATION_ID := "task_force_1"
const MAX_INDUSTRIAL_OPERATIONS := 6
const MAX_PRODUCTION_LINES := 24
const MAX_CONSTRUCTION_OPERATIONS := 6
const TECHNOLOGY_DOMAIN_IDS := [
	"materials_science", "manufacturing", "energy", "propulsion",
	"automation_computing", "ship_engineering", "logistics", "anomaly_science"
]
const MANUFACTURING_FACILITY_IDS := [
	"makeshift_workshop",
	"orbital_foundry",
	"electronics_facility",
	"assembly_yard",
	"field_engineering_complex",
	"frontier_matterworks"
]

# Godot 4.6 does not treat concatenating one Array constant into another as a
# constant expression. Keep this compatibility list explicit so the project
# can compile before any saved-state migration reads it.
const RETIRED_AGGREGATE_FACILITY_IDS := [
	"makeshift_workshop",
	"orbital_foundry",
	"electronics_facility",
	"assembly_yard",
	"field_engineering_complex",
	"frontier_matterworks",
	"fission_reactor", "energy_array", "orbital_construction_yard",
	"earth_extraction_network", "lunar_extraction_network"
]
const RETIRED_SHIP_WORK_MODULE_IDS := [
	"mining_laser", "deep_core_drill", "heavy_mining_array",
	"gas_collector", "exotic_containment", "construction_support_system"
]

var save_id := ""
var revision := 0
var parent_revision := 0
var device_id := ""
var saved_at_ms := 0
## Offline simulation never discards elapsed time when a safety boundary is hit.
## Any remainder is carried into the next load as an explicit time debt.
var offline_time_debt_ms := 0.0
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
var statistics := {"items_produced": 0, "items_consumed":0, "item_consumed_totals":{}, "cycles_completed": 0, "enemies_defeated": 0, "bosses_defeated":0, "expeditions_failed": 0, "research_completed":0, "ships_developed":0}
var rng := {"algorithm_version":1, "master_seed":730201, "streams":{}}

## Formations are operational groups, never work-type buckets. A formation may
## be dispatched to combat or exploration, while extraction and production are
## owned exclusively by factory worlds.
var fleet_formations := {
	DEFAULT_FORMATION_ID:{"id":DEFAULT_FORMATION_ID, "name":"First Task Force", "ship_ids":[]}
}
var next_formation_serial := 2
var industrial_operations: Array = []
var next_production_line_serial := 1
var construction_operations: Array = []
var construction_history: Array = []
var next_construction_project_serial := 1
var active_expedition := {}
var facilities := {}
var expedition_reports: Array = []
var research := {}
var technologies := {}
var completed_projects := {}
var technology_domains := {}
var completed_research_routes := {}
var research_program_history: Array = []
var technology_spillovers := {}
var experimental_maturity := {}
var unlocked_industrial_transformations := {}
var adopted_industrial_transformations := {}
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
var megastructure_projects := {}
var retired_megastructure_archive := {}
## Immutable migration evidence from the removed location-level mining,
## Production Line, extraction-network and generic Construction runtimes.
## Nothing in the live simulation may read this archive as operational state.
var retired_aggregate_industry_archive := {}
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
var next_loadout_serial := 1
var ship_designs := {}
var next_ship_design_serial := 1
var region_states := {}
var combat_area_states := {}
## Finite aftermath points created by future invasion events. These are not
## ship jobs: salvage and analysis systems consume a shared work budget and the
## active point is removed when that budget is exhausted.
var wreck_sites := {}
var wreck_site_history: Array = []
var next_wreck_site_serial := 1
## Schema 36 introduces the authoritative Factorio-style square-grid worlds.
## Removed aggregate records are never loaded into live runtime state.
var factory_worlds := {}
var equipment_instances := {}
var next_equipment_serial := 1
## v4 makes ordinary ship modules Loadout definitions rather than inventory
## assets. Applying a Loadout fabricates its complete ordinary-module BOM inside
## the refit project. Recovered, prototype and Boss equipment remains unique.
var asset_semantics_version := 4
var next_ship_serial := 1
var refit_projects: Array = []
var ship_service_projects: Array = []
var naval_archive: Array = []
var fleet_maintenance := {"fractional":{}, "debt":{}, "coverage":{}, "consumption_totals":{}}
var fleet_logistics := {
	DEFAULT_FORMATION_ID:{
		"command_capacity":100,
		"supplies":{},
		"recovered":{},
		"supply_plan":{"kinetic_munitions":60, "chemical_propellant":20, "repair_supplies":10},
		"policies":{"ammunition_empty":"RETURN", "repair_empty":"RETURN", "cargo_full":"RETURN"},
		"formation":{"doctrine":"HOLD_FORMATION", "ship_zones":{}, "retreat_policy":{"mode":"HULL_THRESHOLD", "threshold":0.25}}
	}
}
var logistics_network := {
	"dispatch_interval_ms":5000.0,
	"dispatch_progress_ms":0.0,
	"shipments":[],
	"next_shipment_serial":1,
	"services":{},
	"route_statistics":{},
	"item_statistics":{}
}
## Phase seven keeps demand, measured flows, analysis scenarios and rule audits as
## explicit save-owned state. None of these structures is an inventory authority.
var demand_registry := {"sources":{}, "history":[]}
var operations_maintenance := {"fractional":{}, "coverage":{}, "consumption_totals":{}}
var economy_telemetry := {"window_started_at_ms":0, "elapsed_ms":0.0, "flows":{}}
var planning_scenarios := {}
var automation_rules: Array = []
var automation_audit: Array = []
var next_automation_rule_serial := 1
## Phase-eight survey work is a real asset-backed mission, not a point pool.
var survey_mission := {"status":"IDLE", "mission_id":"", "formation_id":"", "origin":"", "target":"", "target_state":"", "survey_capability":"", "duration_ms":0.0, "progress_ms":0.0, "costs":{}, "assigned_ship_ids":[]}
var next_survey_mission_serial := 1


static func empty_research_program() -> Dictionary:
	return {
		"research_model_version":2,
		"status":"IDLE", "project_id":"", "route_id":"", "supplemental_route":false,
		"stage_index":0, "stage_id":"", "stage_kind":"", "stage_progress_ms":0.0,
		"progress_ms":0.0, "productivity_progress":0.0,
		"consumed":{}, "stage_consumed":{}, "reserved_costs":{},
		"applied_stage_effects":[], "blocked_reason":"", "blocker":{},
		"location_id":MAIN_BASE_LOCATION_ID
	}


static func create_new(domain_ids: Array, location_definitions: Dictionary = {}) -> SpaceGameState:
	var state := SpaceGameState.new()
	state.initialize_locations(location_definitions)
	state.save_id = "local-%x" % int(Time.get_unix_time_from_system() * 1000.0)
	state.device_id = OS.get_unique_id()
	for domain_id in domain_ids:
		state.domains[domain_id] = {"level":1, "xp":0, "cycles":0}
	state.fleet_formations = {DEFAULT_FORMATION_ID:{"id":DEFAULT_FORMATION_ID, "name":"First Task Force", "ship_ids":[]}}
	state.next_formation_serial = 2
	state.active_expedition = _empty_operation(0, "expedition")
	state.active_expedition.merge({"phase":"IDLE", "route_id":"", "node_index":0, "node_progress_ms":0.0, "safe_node_index":0, "combat_state":{}}, true)
	state.research = empty_research_program()
	for technology_domain_id in TECHNOLOGY_DOMAIN_IDS:
		state.technology_domains[technology_domain_id] = {"level":1, "xp":0.0}
	state.facilities = {"orbital_starport":{"level":1, "status":"ACTIVE", "installed_modules":[]}}
	state.ships = []
	state._create_ship_instance("patchwork_prospector", ["light_autocannon", "civilian_shield", "basic_drive", "sensor_array", "civilian_reactor_core"], "ISS Pioneer")
	# The founding stockpile prevents an early circular dependency before basic
	# electronics production comes online.
	state.locations[MAIN_BASE_LOCATION_ID]["inventory"] = {"scrap_metal":12, "electronics":16, "data_core":2, "kinetic_munitions":120, "chemical_propellant":20, "repair_supplies":10, "repair_material":10}
	state.saved_at_ms = int(Time.get_unix_time_from_system() * 1000.0)
	return state


## Save changes are intentionally applied one published schema at a time.  Each
## step owns one contract and can be covered by a fixed fixture without hiding a
## cross-version jump inside the runtime normalizers below.
static func migrate_save_dictionary(source: Dictionary) -> Dictionary:
	var migrated := source.duplicate(true)
	var version := int(migrated.get("save_version", GameVersion.MIN_MIGRATABLE_SAVE_SCHEMA_VERSION))
	while version < SAVE_VERSION:
		match version:
			24: migrated = _migrate_24_25(migrated)
			25: migrated = _migrate_25_26(migrated)
			26: migrated = _migrate_26_27(migrated)
			27: migrated = _migrate_27_28(migrated)
			28: migrated = _migrate_28_29(migrated)
			29: migrated = _migrate_29_30(migrated)
			30: migrated = _migrate_30_31(migrated)
			31: migrated = _migrate_31_32(migrated)
			32: migrated = _migrate_32_33(migrated)
			33: migrated = _migrate_33_34(migrated)
			34: migrated = _migrate_34_35(migrated)
			35: migrated = _migrate_35_36(migrated)
			36: migrated = _migrate_36_37(migrated)
			37: migrated = _migrate_37_38(migrated)
			_: break
		var next_version := int(migrated.get("save_version", version))
		if next_version <= version:
			break
		version = next_version
	return migrated


static func _stamp_schema(data: Dictionary, version: int) -> Dictionary:
	var migrated := data.duplicate(true)
	migrated["save_version"] = version
	return migrated


static func _migrate_24_25(data: Dictionary) -> Dictionary:
	return _stamp_schema(data, 25)


static func _migrate_25_26(data: Dictionary) -> Dictionary:
	return _stamp_schema(data, 26)


static func _migrate_26_27(data: Dictionary) -> Dictionary:
	return _stamp_schema(data, 27)


static func _migrate_27_28(data: Dictionary) -> Dictionary:
	return _stamp_schema(data, 28)


static func _migrate_28_29(data: Dictionary) -> Dictionary:
	return _stamp_schema(data, 29)


static func _migrate_29_30(data: Dictionary) -> Dictionary:
	return _stamp_schema(data, 30)


static func _migrate_30_31(data: Dictionary) -> Dictionary:
	return _stamp_schema(data, 31)


static func _migrate_31_32(data: Dictionary) -> Dictionary:
	return _stamp_schema(data, 32)


static func _migrate_32_33(data: Dictionary) -> Dictionary:
	return _stamp_schema(data, 33)


static func _migrate_33_34(data: Dictionary) -> Dictionary:
	var migrated := _stamp_schema(data, 34)
	var site_states: Dictionary = migrated.get("mining_site_states", {}).duplicate(true)
	for site_id_value in site_states.keys():
		var runtime := site_states[site_id_value] as Dictionary
		if bool(runtime.get("discovered", false)):
			runtime["developed"] = true
			runtime["extraction_method_id"] = str(runtime.get("extraction_method_id", "fixed_excavation"))
	migrated["mining_site_states"] = site_states
	return migrated


static func _migrate_34_35(data: Dictionary) -> Dictionary:
	var migrated := _stamp_schema(data, 35)
	migrated["offline_time_debt_ms"] = maxf(0.0, float(migrated.get("offline_time_debt_ms", 0.0)))
	var statistics: Dictionary = migrated.get("statistics", {}).duplicate(true)
	statistics["item_consumed_totals"] = statistics.get("item_consumed_totals", {}).duplicate(true) if statistics.get("item_consumed_totals", null) is Dictionary else {}
	migrated["statistics"] = statistics
	var completed: Dictionary = migrated.get("megastructures", {}).duplicate(true)
	var old_projects: Dictionary = migrated.get("megastructure_projects", {}).duplicate(true)
	var archive: Dictionary = migrated.get("retired_megastructure_archive", {}).duplicate(true)
	for retired_id in ["matter_extractor", "autonomous_industry", "deep_space_array"]:
		if completed.has(retired_id) or old_projects.has(retired_id):
			archive[retired_id] = {
				"completed":bool(completed.get(retired_id, false)),
				"project":old_projects.get(retired_id, {}).duplicate(true),
				"retired_in_schema":35
			}
		completed.erase(retired_id)
		old_projects.erase(retired_id)
	var stellar: Dictionary = old_projects.get("stellar_energy", {}).duplicate(true)
	var legacy_percent := clampi(int(stellar.get("progress_percent", 100 if bool(completed.get("stellar_energy", false)) else 0)), 0, 100)
	if not stellar.is_empty() or bool(completed.get("stellar_energy", false)):
		stellar["id"] = "stellar_energy"
		stellar["legacy_progress_percent"] = legacy_percent
		stellar["legacy_contributed_materials"] = stellar.get("delivered_materials", {}).duplicate(true)
		stellar["site_location_id"] = str(stellar.get("site_location_id", "earth_orbit"))
		stellar["phase_index"] = 8 if bool(completed.get("stellar_energy", false)) else clampi(int(floor(float(legacy_percent) * 8.0 / 100.0)), 0, 7)
		stellar["phase_history"] = stellar.get("phase_history", []).duplicate(true)
		stellar["total_materials_consumed"] = stellar.get("total_materials_consumed", stellar.get("delivered_materials", {})).duplicate(true)
		stellar["total_capital_goods"] = stellar.get("total_capital_goods", {}).duplicate(true)
		stellar["supplier_locations"] = stellar.get("supplier_locations", {}).duplicate(true)
		stellar["total_cargo_transported"] = maxf(0.0, float(stellar.get("total_cargo_transported", 0.0)))
		stellar["peak_construction_throughput"] = maxf(0.0, float(stellar.get("peak_construction_throughput", 0.0)))
		stellar["peak_power_demand"] = maxf(0.0, float(stellar.get("peak_power_demand", 0.0)))
		stellar["status"] = "COMPLETE" if bool(completed.get("stellar_energy", false)) else str(stellar.get("status", "READY"))
		old_projects["stellar_energy"] = stellar
	migrated["megastructures"] = completed
	migrated["megastructure_projects"] = old_projects
	migrated["retired_megastructure_archive"] = archive
	return migrated


static func _migrate_35_36(data: Dictionary) -> Dictionary:
	var migrated := _stamp_schema(data, 36)
	# Grid worlds are not synthesized from aggregate slots: doing so would invent
	# placement and duplicate ownership. The removed runtimes survive only as
	# immutable audit evidence and never resume after migration.
	var archive: Dictionary = migrated.get("retired_aggregate_industry_archive", {}).duplicate(true)
	archive.merge({
		"retired_in_schema":36,
		"mining_operations":migrated.get("mining_operations", []).duplicate(true),
		"industrial_operations":migrated.get("industrial_operations", []).duplicate(true),
		"construction_operations":migrated.get("construction_operations", []).duplicate(true),
		"extraction_network_states":migrated.get("extraction_network_states", {}).duplicate(true),
		"extraction_assets":migrated.get("extraction_assets", {}).duplicate(true),
		"extraction_command":migrated.get("extraction_command", {}).duplicate(true),
		"mining_site_states":migrated.get("mining_site_states", {}).duplicate(true),
		"automation":migrated.get("automation", {}).duplicate(true),
		"automation_rules":migrated.get("automation_rules", []).duplicate(true),
		"automation_audit":migrated.get("automation_audit", []).duplicate(true),
		"background_economy":migrated.get("background_economy", {}).duplicate(true)
	}, true)
	migrated["retired_aggregate_industry_archive"] = archive
	for field in ["mining_operations", "industrial_operations", "construction_operations"]:
		migrated[field] = []
	migrated["extraction_network_states"] = {}
	migrated["extraction_assets"] = {"ship_ids":[]}
	migrated["extraction_command"] = {"capacity":0}
	migrated["mining_site_states"] = {}
	migrated["automation"] = {"rates":{}, "fractional":{}, "rules":[], "next_rule_serial":1, "execution_log":[]}
	migrated["automation_rules"] = []
	migrated["automation_audit"] = []
	migrated["next_automation_rule_serial"] = 1
	migrated["background_economy"] = {}
	for ship_value in migrated.get("ships", []):
		var ship := ship_value as Dictionary
		var assignment: Dictionary = ship.get("assignment", {})
		if str(assignment.get("domain", "")) == "mining" or str(assignment.get("type", "")) == "CONSTRUCTION_SUPPORT" or str(ship.get("status", "")) in ["EXTRACTION_OPERATION", "CONSTRUCTION_SUPPORT"]:
			ship["assignment"] = {}
			ship["status"] = "DOCKED"
	for location_value in migrated.get("locations", {}).values():
		var location := location_value as Dictionary
		for industry_value in location.get("industry", {}).get("industries", {}).values():
			var industry := industry_value as Dictionary
			industry["production_method_id"] = ""
			industry["status"] = "IDLE"
	for project_value in migrated.get("megastructure_projects", {}).values():
		var project := project_value as Dictionary
		if not str(project.get("active_project_id", "")).is_empty():
			project["active_project_id"] = ""
			project["status"] = "MIGRATION_REQUIRED"
	migrated["factory_worlds"] = migrated.get("factory_worlds", {}).duplicate(true)
	return _retire_aggregate_industry_metadata_in_dictionary(migrated)


static func _migrate_36_37(data: Dictionary) -> Dictionary:
	var migrated := _stamp_schema(data, 37)
	var legacy_expedition: Dictionary = migrated.get("expedition_fleet", {})
	var legacy_ship_ids: Array = legacy_expedition.get("ship_ids", []).duplicate()
	var existing_formations: Dictionary = migrated.get("fleet_formations", {}).duplicate(true)
	if existing_formations.is_empty():
		existing_formations[DEFAULT_FORMATION_ID] = {
			"id":DEFAULT_FORMATION_ID,
			"name":"First Task Force",
			"ship_ids":legacy_ship_ids
		}
	migrated["fleet_formations"] = existing_formations
	migrated["next_formation_serial"] = maxi(2, int(migrated.get("next_formation_serial", 2)))
	var old_logistics: Dictionary = migrated.get("fleet_logistics", {}).duplicate(true)
	if old_logistics.has("expedition") and not old_logistics.has(DEFAULT_FORMATION_ID):
		old_logistics[DEFAULT_FORMATION_ID] = old_logistics["expedition"].duplicate(true)
	old_logistics.erase("expedition")
	migrated["fleet_logistics"] = old_logistics
	for retired_field in ["extraction_assets", "expedition_fleet"]:
		migrated.erase(retired_field)
	for ship_value in migrated.get("ships", []):
		var ship := ship_value as Dictionary
		var retained_modules: Array = []
		for module_value in ship.get("modules", []):
			if str(module_value) not in RETIRED_SHIP_WORK_MODULE_IDS:
				retained_modules.append(module_value)
		ship["modules"] = retained_modules
		var assignment: Dictionary = ship.get("assignment", {})
		if str(assignment.get("domain", "")) in ["mining", "expedition"] or str(assignment.get("type", "")) == "CONSTRUCTION_SUPPORT":
			ship["assignment"] = {}
			if str(ship.get("status", "")) in ["EXTRACTION_OPERATION", "CONSTRUCTION_SUPPORT"]:
				ship["status"] = "DOCKED"
	for loadout_value in migrated.get("saved_loadouts", {}).values():
		var loadout := loadout_value as Dictionary
		loadout["modules"] = (loadout.get("modules", []) as Array).filter(func(module_value): return str(module_value) not in RETIRED_SHIP_WORK_MODULE_IDS)
	for design_value in migrated.get("ship_designs", {}).values():
		var design := design_value as Dictionary
		design["modules"] = (design.get("modules", []) as Array).filter(func(module_value): return str(module_value) not in RETIRED_SHIP_WORK_MODULE_IDS)
	for queue_value in migrated.get("shipyard_queue", []):
		var queue_entry := queue_value as Dictionary
		queue_entry["custom_modules"] = (queue_entry.get("custom_modules", []) as Array).filter(func(module_value): return str(module_value) not in RETIRED_SHIP_WORK_MODULE_IDS)
	return _retire_aggregate_industry_metadata_in_dictionary(migrated)


static func _migrate_37_38(data: Dictionary) -> Dictionary:
	var migrated := _stamp_schema(data, 38)
	# Schema 38 is the hard ship-role cutover. Extraction equipment cannot remain
	# in a current-schema save, including projects that were mid-refit.
	var archive: Dictionary = migrated.get("retired_aggregate_industry_archive", {}).duplicate(true)
	var retired_assets := {"retired_in_schema":38, "locations":{}, "legacy_inventory":{}}
	var locations: Dictionary = migrated.get("locations", {}).duplicate(true)
	for location_id_value in locations.keys():
		var location := locations[location_id_value] as Dictionary
		var removed_at_location := {}
		for field in ["inventory", "reserves"]:
			var stock: Dictionary = location.get(field, {}).duplicate(true)
			for retired_id in RETIRED_SHIP_WORK_MODULE_IDS:
				var quantity := maxi(0, int(stock.get(retired_id, 0)))
				if quantity > 0:
					removed_at_location["%s:%s" % [field, retired_id]] = quantity
				stock.erase(retired_id)
			location[field] = stock
		if not removed_at_location.is_empty():
			retired_assets["locations"][str(location_id_value)] = removed_at_location
	migrated["locations"] = locations
	for field in ["inventory", "inventory_reserves"]:
		var legacy_stock: Dictionary = migrated.get(field, {}).duplicate(true)
		for retired_id in RETIRED_SHIP_WORK_MODULE_IDS:
			var quantity := maxi(0, int(legacy_stock.get(retired_id, 0)))
			if quantity > 0:
				retired_assets["legacy_inventory"]["%s:%s" % [field, retired_id]] = quantity
			legacy_stock.erase(retired_id)
		migrated[field] = legacy_stock
	if not retired_assets["locations"].is_empty() or not retired_assets["legacy_inventory"].is_empty():
		archive["ship_work_assets"] = retired_assets
	migrated["retired_aggregate_industry_archive"] = archive
	migrated["pinned_items"] = (migrated.get("pinned_items", []) as Array).filter(func(item_value): return str(item_value) not in RETIRED_SHIP_WORK_MODULE_IDS)
	for ship_value in migrated.get("ships", []):
		var ship := ship_value as Dictionary
		ship["modules"] = (ship.get("modules", []) as Array).filter(func(module_value): return str(module_value) not in RETIRED_SHIP_WORK_MODULE_IDS)
		if str(ship.get("blueprint_id", "")) == "ultimate_miner":
			ship["blueprint_id"] = "ultimate_transport"
		elif str(ship.get("blueprint_id", "")) == "mobile_constructor":
			ship["blueprint_id"] = "heavy_lift_transport"
	for loadout_value in migrated.get("saved_loadouts", {}).values():
		var loadout := loadout_value as Dictionary
		loadout["modules"] = (loadout.get("modules", []) as Array).filter(func(module_value): return str(module_value) not in RETIRED_SHIP_WORK_MODULE_IDS)
		if str(loadout.get("blueprint_id", "")) == "ultimate_miner":
			loadout["blueprint_id"] = "ultimate_transport"
		elif str(loadout.get("blueprint_id", "")) == "mobile_constructor":
			loadout["blueprint_id"] = "heavy_lift_transport"
	for design_value in migrated.get("ship_designs", {}).values():
		var design := design_value as Dictionary
		design["modules"] = (design.get("modules", []) as Array).filter(func(module_value): return str(module_value) not in RETIRED_SHIP_WORK_MODULE_IDS)
		if str(design.get("hull_id", "")) == "ultimate_miner":
			design["hull_id"] = "ultimate_transport"
		elif str(design.get("hull_id", "")) == "mobile_constructor":
			design["hull_id"] = "heavy_lift_transport"
	for queue_value in migrated.get("shipyard_queue", []):
		var queue_entry := queue_value as Dictionary
		queue_entry["custom_modules"] = (queue_entry.get("custom_modules", []) as Array).filter(func(module_value): return str(module_value) not in RETIRED_SHIP_WORK_MODULE_IDS)
		if str(queue_entry.get("plan_id", "")) == "construct_ultimate_miner":
			queue_entry["plan_id"] = "construct_ultimate_transport"
		elif str(queue_entry.get("plan_id", "")) == "construct_mobile_constructor":
			queue_entry["plan_id"] = "construct_heavy_lift_transport"
	for project_value in migrated.get("refit_projects", []):
		var project := project_value as Dictionary
		for field in ["desired_definitions", "original_modules", "desired_modules"]:
			project[field] = (project.get(field, []) as Array).filter(func(module_value): return str(module_value) not in RETIRED_SHIP_WORK_MODULE_IDS)
	var unlocked_plans: Dictionary = migrated.get("unlocked_ship_plans", {}).duplicate(true)
	if unlocked_plans.has("construct_ultimate_miner"):
		unlocked_plans["construct_ultimate_transport"] = unlocked_plans.get("construct_ultimate_miner", false)
		unlocked_plans.erase("construct_ultimate_miner")
	if unlocked_plans.has("construct_mobile_constructor"):
		unlocked_plans["construct_heavy_lift_transport"] = unlocked_plans.get("construct_mobile_constructor", false)
		unlocked_plans.erase("construct_mobile_constructor")
	migrated["unlocked_ship_plans"] = unlocked_plans
	var completed: Dictionary = migrated.get("completed_projects", {}).duplicate(true)
	if completed.has("develop_ultimate_miner"):
		completed["develop_ultimate_transport"] = completed.get("develop_ultimate_miner", false)
		completed.erase("develop_ultimate_miner")
	if completed.has("develop_mobile_constructor"):
		completed["develop_heavy_lift_transport"] = completed.get("develop_mobile_constructor", false)
		completed.erase("develop_mobile_constructor")
	migrated["completed_projects"] = completed
	var research: Dictionary = migrated.get("research", {}).duplicate(true)
	if str(research.get("project_id", "")) == "develop_ultimate_miner":
		research["project_id"] = "develop_ultimate_transport"
	elif str(research.get("project_id", "")) == "develop_mobile_constructor":
		research["project_id"] = "develop_heavy_lift_transport"
	migrated["research"] = research
	for history_value in migrated.get("research_program_history", []):
		var history_entry := history_value as Dictionary
		if str(history_entry.get("project_id", "")) == "develop_ultimate_miner":
			history_entry["project_id"] = "develop_ultimate_transport"
		elif str(history_entry.get("project_id", "")) == "develop_mobile_constructor":
			history_entry["project_id"] = "develop_heavy_lift_transport"
	migrated["wreck_sites"] = migrated.get("wreck_sites", {}).duplicate(true)
	migrated["wreck_site_history"] = migrated.get("wreck_site_history", []).duplicate(true)
	migrated["next_wreck_site_serial"] = maxi(1, int(migrated.get("next_wreck_site_serial", 1)))
	return _retire_aggregate_industry_metadata_in_dictionary(migrated)


static func _retire_aggregate_industry_metadata_in_dictionary(source: Dictionary) -> Dictionary:
	var migrated := source.duplicate(true)
	var archive: Dictionary = migrated.get("retired_aggregate_industry_archive", {}).duplicate(true)
	for field in ["extraction_command", "mining_site_states"]:
		var retired_value = migrated.get(field, {})
		if retired_value is Dictionary and not retired_value.is_empty() and not archive.has(field):
			archive[field] = retired_value.duplicate(true)
	migrated["extraction_command"] = {"capacity":0}
	migrated["mining_site_states"] = {}
	var facilities: Dictionary = migrated.get("facilities", {}).duplicate(true)
	var retired_facilities := {}
	for facility_id in RETIRED_AGGREGATE_FACILITY_IDS:
		if facilities.has(facility_id):
			retired_facilities[facility_id] = facilities[facility_id].duplicate(true)
			facilities.erase(facility_id)
	if not retired_facilities.is_empty() and not archive.has("facilities"):
		archive["facilities"] = retired_facilities
	var retired_locations := {}
	var locations: Dictionary = migrated.get("locations", {}).duplicate(true)
	for location_id_value in locations.keys():
		var location_id := str(location_id_value)
		var location := locations[location_id] as Dictionary
		var industry: Dictionary = location.get("industry", {})
		var construction: Dictionary = location.get("construction", {})
		var automation: Dictionary = location.get("automation", {})
		if not industry.get("industries", {}).is_empty() or not construction.get("active_project_ids", []).is_empty() or not str(automation.get("industrial_template_id", "")).is_empty():
			retired_locations[location_id] = {"industry":industry.duplicate(true), "construction":construction.duplicate(true), "automation":automation.duplicate(true)}
		location["industry"] = {"industries":{}, "specialization_id":"", "power_capacity":0.0, "cooling_capacity":0.0, "structural_capacity":0.0}
		location["construction"] = {"capacity":0.0, "active_project_ids":[]}
		location["automation"] = {"industrial_template_id":"", "managed_policy_items":[], "status":"RETIRED", "auto_expand_enabled":false, "target_industry_level":1, "expansion_progress_ms":0.0, "last_blocked_reason":"", "blocker":{}}
	if not retired_locations.is_empty() and not archive.has("location_industry"):
		archive["location_industry"] = retired_locations
	for field in ["manufacturing_module_inventory", "manufacturing_modules_built", "unlocked_industrial_transformations", "adopted_industrial_transformations"]:
		var retired_value = migrated.get(field, {})
		if retired_value is Dictionary and not retired_value.is_empty() and not archive.has(field):
			archive[field] = retired_value.duplicate(true)
		migrated[field] = {}
	migrated["facilities"] = facilities
	migrated["locations"] = locations
	migrated["retired_aggregate_industry_archive"] = archive
	return migrated


static func from_dictionary(data: Dictionary, domain_ids: Array, location_definitions: Dictionary = {}) -> SpaceGameState:
	data = migrate_save_dictionary(data)
	# Schema 38 was introduced on this feature branch before its content hard cut
	# was complete. Reapply the idempotent role invariant on load so an interim
	# schema-38 developer save cannot retain deleted work modules or hull IDs.
	if SAVE_VERSION == 38:
		data = _migrate_37_38(data)
	data = _retire_aggregate_industry_metadata_in_dictionary(data)
	var state := create_new(domain_ids, location_definitions)
	state.save_id = str(data.get("save_id", state.save_id))
	state.revision = int(data.get("revision", 0))
	state.parent_revision = int(data.get("parent_revision", maxi(0, state.revision - 1)))
	state.device_id = str(data.get("device_id", state.device_id))
	state.saved_at_ms = int(data.get("saved_at_ms", Time.get_unix_time_from_system() * 1000))
	state.offline_time_debt_ms = maxf(0.0, float(data.get("offline_time_debt_ms", 0.0)))
	state.total_elapsed_ms = float(data.get("total_elapsed_ms", 0.0))
	if data.get("locations", null) is Dictionary and not data.get("locations", {}).is_empty():
		state._load_locations(data.get("locations", {}), location_definitions)
	else:
		# Lab schema 24 stored one global stockpile. Newer schemas give it exactly
		# one owner and omit the legacy fields on the next save.
		state.locations[MAIN_BASE_LOCATION_ID]["inventory"] = data.get("inventory", {}).duplicate(true)
		state.locations[MAIN_BASE_LOCATION_ID]["reserves"] = data.get("inventory_reserves", {}).duplicate(true)
	state.ships = data.get("ships", state.ships).duplicate(true)
	state.regions = data.get("regions", state.regions).duplicate(true)
	state.completed_activities = data.get("completed_activities", {}).duplicate(true)
	state.statistics = data.get("statistics", state.statistics).duplicate(true)
	state.statistics["item_consumed_totals"] = state.statistics.get("item_consumed_totals", {}).duplicate(true) if state.statistics.get("item_consumed_totals", null) is Dictionary else {}
	state.rng = data.get("rng", state.rng).duplicate(true)
	state.fleet_formations = _normalized_fleet_formations(data.get("fleet_formations", {}))
	state.next_formation_serial = maxi(2, int(data.get("next_formation_serial", 2)))
	state.industrial_operations = []
	state.next_production_line_serial = 1
	state.construction_operations = []
	state.construction_history = data.get("construction_history", []).duplicate(true)
	state.next_construction_project_serial = 1
	state.active_expedition = data.get("active_expedition", state.active_expedition).duplicate(true)
	state.facilities = data.get("facilities", state.facilities).duplicate(true)
	if not state.facilities.has("orbital_starport"):
		state.facilities["orbital_starport"] = {"level":1, "status":"ACTIVE", "installed_modules":[]}
	state.expedition_reports = data.get("expedition_reports", []).duplicate(true)
	state.research = data.get("research", state.research).duplicate(true)
	state.research["productivity_progress"] = 0.0
	state.research["location_id"] = str(state.research.get("location_id", MAIN_BASE_LOCATION_ID))
	state.research["blocker"] = state.research.get("blocker", {}).duplicate(true) if state.research.get("blocker", null) is Dictionary else {}
	var loaded_research_model_version := int(state.research.get("research_model_version", 1))
	state.research.merge(empty_research_program(), false)
	# Schema 31 and earlier stored one linear project bar. Preserve that paid work
	# as the first stage until SimulationEngine can map it against the project.
	if loaded_research_model_version < 2:
		state.research["legacy_project_progress_ms"] = float(state.research.get("progress_ms", 0.0))
		state.research["stage_progress_ms"] = float(state.research.get("progress_ms", 0.0))
		state.research["stage_consumed"] = state.research.get("consumed", {}).duplicate(true)
		state.research["research_model_version"] = 2
	state.technologies = data.get("technologies", {}).duplicate(true)
	state.completed_projects = data.get("completed_projects", {}).duplicate(true)
	state.technology_domains = data.get("technology_domains", state.technology_domains).duplicate(true)
	for technology_domain_id in TECHNOLOGY_DOMAIN_IDS:
		var technology_domain: Dictionary = state.technology_domains.get(technology_domain_id, {})
		technology_domain["level"] = maxi(1, int(technology_domain.get("level", 1)))
		technology_domain["xp"] = maxf(0.0, float(technology_domain.get("xp", 0.0)))
		state.technology_domains[technology_domain_id] = technology_domain
	state.completed_research_routes = data.get("completed_research_routes", {}).duplicate(true)
	state.research_program_history = data.get("research_program_history", []).duplicate(true)
	state.technology_spillovers = data.get("technology_spillovers", {}).duplicate(true)
	state.experimental_maturity = data.get("experimental_maturity", {}).duplicate(true)
	state.unlocked_industrial_transformations = data.get("unlocked_industrial_transformations", {}).duplicate(true)
	state.adopted_industrial_transformations = data.get("adopted_industrial_transformations", {}).duplicate(true)
	state.unlocked_ship_plans = data.get("unlocked_ship_plans", {}).duplicate(true)
	state.shipyard_queue = _normalized_shipyard_queue(data.get("shipyard_queue", []))
	state.infrastructure_sites = data.get("infrastructure_sites", state.infrastructure_sites).duplicate(true)
	state.megastructures = data.get("megastructures", {}).duplicate(true)
	state.megastructure_projects = _normalized_megastructure_projects(data.get("megastructure_projects", {}), state.megastructures)
	state.retired_megastructure_archive = data.get("retired_megastructure_archive", {}).duplicate(true)
	state.retired_aggregate_industry_archive = data.get("retired_aggregate_industry_archive", {}).duplicate(true)
	state.major_discoveries = data.get("major_discoveries", {}).duplicate(true)
	state.game_complete = bool(data.get("game_complete", false))
	state.completed_at_ms = int(data.get("completed_at_ms", 0))
	state.combat_log = data.get("combat_log", []).duplicate(true)
	state.automation = {"rates":{}, "fractional":{}, "rules":[], "next_rule_serial":1, "execution_log":[]}
	state.progression_tier = maxi(1, int(data.get("progression_tier", 1)))
	state.resource_maturity = data.get("resource_maturity", {}).duplicate(true)
	state.background_economy = _normalized_background_economy({})
	state.energy_system = _normalized_energy_system(data.get("energy_system", {}))
	state.manufacturing_module_inventory = data.get("manufacturing_module_inventory", {}).duplicate(true)
	state.manufacturing_modules_built = data.get("manufacturing_modules_built", {}).duplicate(true)
	state.pinned_items = data.get("pinned_items", []).duplicate()
	state.saved_loadouts = _normalized_saved_loadouts(data.get("saved_loadouts", {}))
	state.next_loadout_serial = _serial_after_identifiers(int(data.get("next_loadout_serial", 1)), state.saved_loadouts.keys(), "LOADOUT-")
	state.ship_designs = _normalized_ship_designs(data.get("ship_designs", {}))
	state.next_ship_design_serial = _serial_after_identifiers(int(data.get("next_ship_design_serial", 1)), state.ship_designs.keys(), "DESIGN-")
	state.region_states = data.get("region_states", {}).duplicate(true)
	state.combat_area_states = data.get("combat_area_states", {}).duplicate(true)
	state.wreck_sites = WreckSiteSystemScript.normalize_sites(data.get("wreck_sites", {}))
	state.wreck_site_history = WreckSiteSystemScript.normalize_history(data.get("wreck_site_history", []))
	state.next_wreck_site_serial = _serial_after_identifiers(int(data.get("next_wreck_site_serial", 1)), state.wreck_sites.keys(), "WRECK-")
	state.factory_worlds = {}
	var factory_world_normalizer := FactoryGridSimulation.new()
	for world_id_value in data.get("factory_worlds", {}).keys():
		var world_id := str(world_id_value)
		var world_value = data.get("factory_worlds", {}).get(world_id)
		if world_value is Dictionary:
			state.factory_worlds[world_id] = factory_world_normalizer.normalize_world(world_value)
	state.equipment_instances = data.get("equipment_instances", {}).duplicate(true)
	state.next_equipment_serial = _serial_after_identifiers(int(data.get("next_equipment_serial", 1)), state.equipment_instances.keys(), "EQUIP-")
	state.asset_semantics_version = maxi(1, int(data.get("asset_semantics_version", 1)))
	var loaded_ship_ids: Array = []
	for loaded_ship_value in state.ships:
		loaded_ship_ids.append(str((loaded_ship_value as Dictionary).get("instance_id", "")))
	state.next_ship_serial = _serial_after_identifiers(int(data.get("next_ship_serial", 1)), loaded_ship_ids, "SHIP-")
	state.refit_projects = data.get("refit_projects", []).duplicate(true)
	state.ship_service_projects = _normalized_ship_service_projects(data.get("ship_service_projects", []))
	state.naval_archive = data.get("naval_archive", []).duplicate(true)
	state.fleet_maintenance = _normalized_fleet_maintenance(data.get("fleet_maintenance", {}))
	state.fleet_logistics = _normalized_fleet_logistics(data.get("fleet_logistics", {}))
	state.logistics_network = _normalized_logistics_network(data.get("logistics_network", {}))
	state.demand_registry = _normalized_demand_registry(data.get("demand_registry", {}))
	state.operations_maintenance = _normalized_operations_maintenance(data.get("operations_maintenance", {}))
	state.economy_telemetry = _normalized_economy_telemetry(data.get("economy_telemetry", {}))
	state.planning_scenarios = data.get("planning_scenarios", {}).duplicate(true)
	state.automation_rules = []
	state.automation_audit = []
	state.next_automation_rule_serial = 1
	state.survey_mission = _normalized_survey_mission(data.get("survey_mission", {}))
	state.next_survey_mission_serial = _serial_after_identifiers(int(data.get("next_survey_mission_serial", 1)), [str(state.survey_mission.get("mission_id", ""))], "SURVEY-")
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
	state._reconcile_fleet_maintenance()
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
		"offline_time_debt_ms":offline_time_debt_ms,
		"total_elapsed_ms":total_elapsed_ms,
		"locations":locations,
		"domains":domains,
		"ships":ships,
		"regions":regions,
		"completed_activities":completed_activities,
		"statistics":statistics,
		"rng":rng,
		"fleet_formations":fleet_formations,
		"next_formation_serial":next_formation_serial,
		"construction_history":construction_history,
		"active_expedition":active_expedition,
		"facilities":facilities,
		"expedition_reports":expedition_reports,
		"research":research,
		"technologies":technologies,
		"completed_projects":completed_projects,
		"technology_domains":technology_domains,
		"completed_research_routes":completed_research_routes,
		"research_program_history":research_program_history,
		"technology_spillovers":technology_spillovers,
		"experimental_maturity":experimental_maturity,
		"unlocked_ship_plans":unlocked_ship_plans,
		"shipyard_queue":shipyard_queue,
		"infrastructure_sites":infrastructure_sites,
		"megastructures":megastructures,
		"megastructure_projects":megastructure_projects,
		"retired_megastructure_archive":retired_megastructure_archive,
		"retired_aggregate_industry_archive":retired_aggregate_industry_archive,
		"major_discoveries":major_discoveries,
		"game_complete":game_complete,
		"completed_at_ms":completed_at_ms,
		"combat_log":combat_log,
		"progression_tier":progression_tier,
		"resource_maturity":resource_maturity,
		"energy_system":energy_system,
		"pinned_items":pinned_items,
		"saved_loadouts":saved_loadouts,
		"next_loadout_serial":next_loadout_serial,
		"ship_designs":ship_designs,
		"next_ship_design_serial":next_ship_design_serial,
		"region_states":region_states,
		"combat_area_states":combat_area_states,
		"wreck_sites":wreck_sites,
		"wreck_site_history":wreck_site_history,
		"next_wreck_site_serial":next_wreck_site_serial,
		"factory_worlds":factory_worlds,
		"equipment_instances":equipment_instances,
		"next_equipment_serial":next_equipment_serial,
		"asset_semantics_version":asset_semantics_version,
		"next_ship_serial":next_ship_serial,
		"refit_projects":refit_projects,
		"ship_service_projects":ship_service_projects,
		"naval_archive":naval_archive,
		"fleet_maintenance":fleet_maintenance,
		"fleet_logistics":fleet_logistics,
		"logistics_network":logistics_network,
		"demand_registry":demand_registry,
		"operations_maintenance":operations_maintenance,
		"economy_telemetry":economy_telemetry,
		"planning_scenarios":planning_scenarios,
		"survey_mission":survey_mission,
		"next_survey_mission_serial":next_survey_mission_serial
	}


func initialize_locations(location_definitions: Dictionary = {}) -> void:
	locations.clear()
	if location_definitions.is_empty():
		_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)
		return
	for location_value in location_definitions.keys():
		var location_id := str(location_value)
		var definition: Dictionary = location_definitions.get(location_id, {})
		var known := bool(regions.get(location_id, location_id == MAIN_BASE_LOCATION_ID))
		var location_type := str(definition.get("location_type", LocationState.ARTIFICIAL if location_id == MAIN_BASE_LOCATION_ID else LocationState.NATURAL))
		var system_id := str(definition.get("system_id", SYSTEM_ID))
		_ensure_location(location_id, location_type, known, system_id)
	_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)


func has_location(location_id: String) -> bool:
	return locations.has(location_id)


func ensure_location(location_id: String, location_type: String = LocationState.NATURAL, known: bool = false, system_id: String = SYSTEM_ID) -> void:
	_ensure_location(location_id, location_type, known, system_id)


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


func location_industries(location_id: String = MAIN_BASE_LOCATION_ID) -> Dictionary:
	return {}


func location_industry(location_id: String, facility_id: String) -> Dictionary:
	return location_industries(location_id).get(facility_id, {})


func ensure_location_industry(location_id: String, facility_id: String, initial_level: int = 1) -> Dictionary:
	return {}


func ensure_main_location_industries() -> void:
	return


func industrial_operation_for(location_id: String, facility_id: String) -> Dictionary:
	return {}


func production_lines_for(location_id: String, facility_id: String) -> Array:
	return []


func production_line_by_id(line_id: String) -> Dictionary:
	return {}


func ensure_industrial_operation(location_id: String, facility_id: String) -> Dictionary:
	return {}


func create_production_line(location_id: String, facility_id: String) -> Dictionary:
	return {}


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


## Physical items owned by square-grid factory worlds. This is intentionally
## separate from aggregate_inventory(), whose compatibility contract remains
## Location Inventory only. Entity buffers and delivered construction materials
## are disjoint custody domains and therefore safe to add together.
func factory_world_item_ledger() -> Dictionary:
	var all_items := {}
	var all_entity_buffers := {}
	var all_construction_staging := {}
	var all_produced := {}
	var all_consumed := {}
	var by_world := {}
	for world_id_value in factory_worlds.keys():
		var world_id := str(world_id_value)
		var world_value = factory_worlds.get(world_id_value)
		if world_value is not Dictionary:
			continue
		var world := world_value as Dictionary
		var entity_buffers := {}
		var construction_staging := {}
		var entities := {}
		var orders := {}
		for entity_id_value in world.get("entities", {}).keys():
			var entity_id := str(entity_id_value)
			var entity_value = world.get("entities", {}).get(entity_id_value)
			if entity_value is not Dictionary:
				continue
			var entity := entity_value as Dictionary
			var entity_items := {}
			for field in ["inputs", "outputs", "inventory"]:
				var item_map_value = entity.get(field, {})
				if item_map_value is not Dictionary:
					continue
				for item_id_value in (item_map_value as Dictionary).keys():
					var item_id := str(item_id_value)
					var quantity := maxi(0, int((item_map_value as Dictionary).get(item_id_value, 0)))
					_ledger_add(entity_items, item_id, quantity)
					_ledger_add(entity_buffers, item_id, quantity)
					_ledger_add(all_entity_buffers, item_id, quantity)
			if not entity_items.is_empty():
				entities[entity_id] = entity_items
		for order_id_value in world.get("construction_orders", {}).keys():
			var order_id := str(order_id_value)
			var order_value = world.get("construction_orders", {}).get(order_id_value)
			if order_value is not Dictionary:
				continue
			var delivered_value = (order_value as Dictionary).get("delivered_items", {})
			if delivered_value is not Dictionary:
				continue
			var order_items := {}
			for item_id_value in (delivered_value as Dictionary).keys():
				var item_id := str(item_id_value)
				var quantity := maxi(0, int((delivered_value as Dictionary).get(item_id_value, 0)))
				_ledger_add(order_items, item_id, quantity)
				_ledger_add(construction_staging, item_id, quantity)
				_ledger_add(all_construction_staging, item_id, quantity)
			if not order_items.is_empty():
				orders[order_id] = order_items
		var world_items := entity_buffers.duplicate(true)
		for item_id_value in construction_staging.keys():
			_ledger_add(world_items, str(item_id_value), int(construction_staging.get(item_id_value, 0)))
		for item_id_value in world_items.keys():
			_ledger_add(all_items, str(item_id_value), int(world_items.get(item_id_value, 0)))
		var produced: Dictionary = world.get("statistics", {}).get("produced", {}).duplicate(true) if world.get("statistics", {}).get("produced", null) is Dictionary else {}
		var consumed: Dictionary = world.get("statistics", {}).get("consumed", {}).duplicate(true) if world.get("statistics", {}).get("consumed", null) is Dictionary else {}
		for item_id_value in produced.keys():
			_ledger_add(all_produced, str(item_id_value), maxi(0, int(produced.get(item_id_value, 0))))
		for item_id_value in consumed.keys():
			_ledger_add(all_consumed, str(item_id_value), maxi(0, int(consumed.get(item_id_value, 0))))
		by_world[world_id] = {
			"Items":world_items,
			"EntityBuffers":entity_buffers,
			"ConstructionStaging":construction_staging,
			"Entities":entities,
			"Orders":orders,
			"Produced":produced,
			"Consumed":consumed
		}
	return {
		"Items":all_items,
		"EntityBuffers":all_entity_buffers,
		"ConstructionStaging":all_construction_staging,
		"Produced":all_produced,
		"Consumed":all_consumed,
		"ByWorld":by_world
	}


func factory_world_item_holdings() -> Dictionary:
	return factory_world_item_ledger().get("Items", {}).duplicate(true)


## Read-only ownership view used by integrity tests, diagnostics and completion
## statistics. Reservations remain claims on Inventory rather than duplicated
## assets; ProjectStaging is an explicitly bounded subset of Reserved. FactoryWorld
## is a separate physical ownership domain and includes its construction staging.
func asset_ledger_snapshot() -> Dictionary:
	var inventory_on_hand := {}
	var inventory_available := {}
	var inventory_reserved := {}
	var inventory_reserved_requested := {}
	var inventory_by_location := {}
	var project_staging_items := {}
	var project_staging_requested := {}
	var projects := {}
	for location_id_value in locations.keys():
		var location_id := str(location_id_value)
		var item_ids: Array = location_inventory(location_id).keys()
		for item_id_value in location_reserves(location_id).keys():
			if not item_ids.has(item_id_value):
				item_ids.append(item_id_value)
		for collection in [shipyard_queue]:
			for runtime_value in collection:
				var runtime := runtime_value as Dictionary
				if str(runtime.get("location_id", MAIN_BASE_LOCATION_ID)) != location_id:
					continue
				for item_id_value in runtime.get("reserved_costs", {}).keys():
					if not item_ids.has(item_id_value):
						item_ids.append(item_id_value)
		if str(research.get("location_id", MAIN_BASE_LOCATION_ID)) == location_id:
			for item_id_value in research.get("reserved_costs", {}).keys():
				if not item_ids.has(item_id_value):
					item_ids.append(item_id_value)
		var location_on_hand := {}
		var location_available := {}
		var location_reserved := {}
		var location_requested := {}
		for item_id_value in item_ids:
			var item_id := str(item_id_value)
			var on_hand := maxi(0, item_quantity(item_id, location_id))
			var available := mini(on_hand, available_item_quantity(item_id, location_id))
			var requested := maxi(0, int(location_reserves(location_id).get(item_id, 0)) + research_committed_quantity(item_id, location_id) + industrial_committed_quantity(item_id, -1, location_id) + construction_committed_quantity(item_id, -1, location_id) + shipyard_committed_quantity(item_id, "", location_id))
			var reserved := on_hand - available
			_ledger_add(location_on_hand, item_id, on_hand)
			_ledger_add(location_available, item_id, available)
			_ledger_add(location_reserved, item_id, reserved)
			_ledger_add(location_requested, item_id, requested)
			_ledger_add(inventory_on_hand, item_id, on_hand)
			_ledger_add(inventory_available, item_id, available)
			_ledger_add(inventory_reserved, item_id, reserved)
			_ledger_add(inventory_reserved_requested, item_id, requested)
		inventory_by_location[location_id] = {
			"OnHand":location_on_hand,
			"Available":location_available,
			"Reserved":location_reserved,
			"ReservedRequested":location_requested
		}
	var in_transit_items := {}
	var shipments := {}
	for shipment_value in logistics_network.get("shipments", []):
		var shipment := shipment_value as Dictionary
		var cargo: Dictionary = shipment.get("cargo", {}).duplicate(true) if shipment.get("cargo", null) is Dictionary else {}
		shipments[str(shipment.get("id", ""))] = {
			"Origin":str(shipment.get("origin", "")),
			"Destination":str(shipment.get("destination", "")),
			"Items":cargo
		}
		for item_id_value in cargo.keys():
			_ledger_add(in_transit_items, str(item_id_value), maxi(0, int(cargo.get(item_id_value, 0))))
	var installed_modules := {}
	for location_value in locations.values():
		var location := location_value as Dictionary
		for industry_value in location.get("industry", {}).get("industries", {}).values():
			var industry := industry_value as Dictionary
			for field in ["installed_process_modules", "installed_plugins"]:
				for module_id_value in industry.get(field, []):
					_ledger_add(installed_modules, str(module_id_value), 1)
	var special_equipment := {}
	for equipment_value in equipment_instances.values():
		var equipment := equipment_value as Dictionary
		if str(equipment.get("status", "STORAGE")) not in ["INSTALLED", "RESERVED_REFIT"]:
			continue
		_ledger_add(special_equipment, str(equipment.get("definition_id", "")), 1)
	var assigned_ships := {}
	for ship_value in ships:
		var ship := ship_value as Dictionary
		if ship.get("assignment", {}).is_empty() and str(ship.get("status", "DOCKED")) == "DOCKED":
			continue
		_ledger_add(assigned_ships, str(ship.get("blueprint_id", "")), 1)
	var lost_items := {}
	var lost_projects := {}
	for history_value in construction_history:
		var history := history_value as Dictionary
		var lost: Dictionary = history.get("cancellation_result", {}).get("consumed_lost", {}).duplicate(true) if history.get("cancellation_result", {}).get("consumed_lost", null) is Dictionary else {}
		if lost.is_empty():
			continue
		lost_projects[str(history.get("project_id", ""))] = lost
		for item_id_value in lost.keys():
			_ledger_add(lost_items, str(item_id_value), maxi(0, int(lost.get(item_id_value, 0))))
	return {
		"Inventory":{"OnHand":inventory_on_hand, "Available":inventory_available, "Reserved":inventory_reserved, "ReservedRequested":inventory_reserved_requested, "ByLocation":inventory_by_location},
		"FactoryWorld":factory_world_item_ledger(),
		"InTransit":{"Items":in_transit_items, "Shipments":shipments},
		"ProjectStaging":{"Items":project_staging_items, "Requested":project_staging_requested, "Projects":projects, "ReservationSubset":true},
		"InstalledAssigned":{"ManufacturingModules":installed_modules, "SpecialEquipment":special_equipment, "Ships":assigned_ships},
		"Consumed":{"Items":statistics.get("item_consumed_totals", {}).duplicate(true), "Total":maxi(0, int(statistics.get("items_consumed", 0)))},
		"Lost":{"Items":lost_items, "Projects":lost_projects}
	}


static func _ledger_add(target: Dictionary, item_id: String, quantity: int) -> void:
	if item_id.is_empty() or quantity <= 0:
		return
	target[item_id] = int(target.get(item_id, 0)) + quantity


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
	if item_id.is_empty() or quantity <= 0:
		return
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
	return 0


func construction_committed_quantity(item_id: String, excluded_slot: int = -1, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	return 0


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


func enqueue_ship_plan(plan_id: String, quantity: int = 1, design_id: String = "", custom_modules: Array = []) -> bool:
	if not bool(unlocked_ship_plans.get(plan_id, false)) or quantity <= 0:
		return false
	var project_id := "SHIPBUILD-%06d" % (shipyard_queue.size() + int(statistics.get("ships_built", 0)) + 1)
	shipyard_queue.append({
		"project_id":project_id,
		"plan_id":plan_id,
		"design_id":design_id,
		"custom_modules":custom_modules.duplicate(),
		"quantity_total":clampi(quantity, 1, 100),
		"quantity_remaining":clampi(quantity, 1, 100),
		"quantity_completed":0,
		"completed_segments":0,
		"paid_cycles":0,
		"cycle_progress":0.0,
		"productivity_progress":0.0,
		"consumed":{},
		"reserved_costs":{},
		"status":"RUNNING",
		"blocked_reason":"",
		"blocker":{},
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


func install_manufacturing_module(facility_id: String, module_id: String, module_kind: String, location_id: String = MAIN_BASE_LOCATION_ID) -> bool:
	return false


func uninstall_manufacturing_module(facility_id: String, module_id: String, module_kind: String, location_id: String = MAIN_BASE_LOCATION_ID) -> bool:
	return false


func remove_item(item_id: String, quantity: int, location_id: String = MAIN_BASE_LOCATION_ID) -> bool:
	if item_id.is_empty() or quantity <= 0:
		return false
	if item_quantity(item_id, location_id) < quantity:
		return false
	location_inventory(location_id)[item_id] = item_quantity(item_id, location_id) - quantity
	_record_item_consumed(item_id, quantity)
	return true


func transfer_inventory_to_fleet_supply(item_id: String, requested: int, fleet_id: String = DEFAULT_FORMATION_ID, location_id: String = MAIN_BASE_LOCATION_ID) -> int:
	if item_id.is_empty() or requested <= 0:
		return 0
	var transferred := mini(requested, available_item_quantity(item_id, location_id))
	if transferred <= 0:
		return 0
	location_inventory(location_id)[item_id] = item_quantity(item_id, location_id) - transferred
	var runtime := fleet_logistics_runtime(fleet_id)
	var supplies: Dictionary = runtime.get("supplies", {})
	supplies[item_id] = int(supplies.get(item_id, 0)) + transferred
	runtime["supplies"] = supplies
	return transferred


func _record_item_consumed(item_id: String, quantity: int) -> void:
	if item_id.is_empty() or quantity <= 0:
		return
	statistics["items_consumed"] = int(statistics.get("items_consumed", 0)) + quantity
	var consumed_totals: Dictionary = statistics.get("item_consumed_totals", {})
	consumed_totals[item_id] = int(consumed_totals.get(item_id, 0)) + quantity
	statistics["item_consumed_totals"] = consumed_totals


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
		"commissioned_at_ms":int(total_elapsed_ms),
		"current_loadout_id":"",
		"maintenance_state":"ACTIVE",
		"maintenance_coverage":1.0,
		"maintenance_debt":0.0,
		"lifetime_output":0,
		"lifetime_damage":0,
		"damage_taken":0.0,
		"service_record":{"extraction_cycles":0, "combat_deployments":0, "discoveries":0, "victories":0, "defeats":0, "damage_dealt":0.0, "combat_experience":0.0},
		"location_id":MAIN_BASE_LOCATION_ID
	}
	ships.append(ship)
	for definition_value in module_definitions:
		ship["modules"].append(str(definition_value))
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
	for module_value in ship.get("modules", []):
		var stored_value := str(module_value)
		var definition_id := equipment_definition_id(stored_value)
		result.append(definition_id if not definition_id.is_empty() else stored_value)
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
	return not ship.is_empty() and ship.get("status", "") == "DOCKED" and ship.get("condition", "") == "OPERATIONAL" and str(ship.get("maintenance_state", "ACTIVE")) != "MOTHBALLED"


func ship_is_deployment_ready(instance_id: String) -> bool:
	var ship := ship_by_id(instance_id)
	return ship_is_docked(instance_id) \
		and str(ship.get("maintenance_state", "ACTIVE")) == "ACTIVE" \
		and float(ship.get("maintenance_coverage", 1.0)) > 0.0


func ship_is_unassigned_docked(instance_id: String) -> bool:
	var ship := ship_by_id(instance_id)
	return ship_is_docked(instance_id) and ship.get("assignment", {}).is_empty()


func formation_ids() -> Array[String]:
	var result: Array[String] = []
	for formation_id_value in fleet_formations.keys():
		result.append(str(formation_id_value))
	result.sort()
	return result


func formation_runtime(formation_id: String = DEFAULT_FORMATION_ID) -> Dictionary:
	if formation_id in ["mining", "industry", "construction", "expedition"] or not fleet_formations.has(formation_id):
		return {}
	return fleet_formations[formation_id]


func formation_ship_ids(formation_id: String = DEFAULT_FORMATION_ID) -> Array:
	if not fleet_formations.has(formation_id):
		return []
	return fleet_formations[formation_id].get("ship_ids", []).duplicate()


func ship_formation_id(instance_id: String) -> String:
	for formation_id in formation_ids():
		if formation_ship_ids(formation_id).has(instance_id):
			return formation_id
	return ""


func set_formation_ship_ids(formation_id: String, ship_ids: Array) -> void:
	var formation := formation_runtime(formation_id)
	if formation.is_empty():
		return
	formation["ship_ids"] = ship_ids.duplicate()


func has_external_activity() -> bool:
	if active_expedition.get("status", "IDLE") == "RUNNING":
		return true
	return survey_mission.get("status", "IDLE") == "RUNNING"


## Compatibility helper for archived aggregate-industry diagnostics. Live
## production no longer consumes this scale-stage model.
static func scale_stage_for_level(level: int) -> String:
	if level >= 20:
		return "AUTOMATED_DISTRICT"
	if level >= 10:
		return "INDUSTRIAL_COMPLEX"
	if level >= 5:
		return "FACTORY"
	return "WORKSHOP"


func ship_can_refit(instance_id: String) -> bool:
	return ship_is_docked(instance_id)


func fleet_logistics_runtime(fleet_id: String = DEFAULT_FORMATION_ID) -> Dictionary:
	if fleet_id in ["mining", "industry", "construction", "expedition"] or not fleet_formations.has(fleet_id):
		return {}
	if not fleet_logistics.has(fleet_id):
		fleet_logistics[fleet_id] = {"command_capacity":100, "supplies":{}, "recovered":{}, "supply_plan":{}, "policies":{}, "formation":{"doctrine":"HOLD_FORMATION", "ship_zones":{}, "retreat_policy":{"mode":"HULL_THRESHOLD", "threshold":0.25}}}
	return fleet_logistics[fleet_id]


func fleet_supply_quantity(item_id: String, fleet_id: String = DEFAULT_FORMATION_ID) -> int:
	return int(fleet_logistics_runtime(fleet_id).get("supplies", {}).get(item_id, 0))


func consume_fleet_supply(item_id: String, quantity: int, fleet_id: String = DEFAULT_FORMATION_ID) -> bool:
	var runtime := fleet_logistics_runtime(fleet_id)
	var supplies: Dictionary = runtime.get("supplies", {})
	if int(supplies.get(item_id, 0)) < quantity:
		return false
	supplies[item_id] = int(supplies.get(item_id, 0)) - quantity
	runtime["supplies"] = supplies
	_record_item_consumed(item_id, quantity)
	return true


func add_recovered_cargo(item_id: String, quantity: int, fleet_id: String = DEFAULT_FORMATION_ID) -> void:
	var runtime := fleet_logistics_runtime(fleet_id)
	var recovered: Dictionary = runtime.get("recovered", {})
	recovered[item_id] = int(recovered.get(item_id, 0)) + quantity
	runtime["recovered"] = recovered


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
		"operating_state":"PAUSED",
		"blocker":{},
		"assigned_ship_ids":[],
		"reserved_costs":{},
		"allocated_capacity":1.0,
		"location_id":MAIN_BASE_LOCATION_ID,
		"site_id":"",
		"raw_material_id":""
	}


static func create_operation_record(index: int, domain_id: String) -> Dictionary:
	# Compatibility constructor for the remaining expedition runtime record.
	return _empty_operation(index, domain_id)


static func _empty_industrial_operation(index: int, facility_id: String, location_id: String = MAIN_BASE_LOCATION_ID) -> Dictionary:
	var operation := _empty_operation(index, "industry")
	operation["facility_id"] = facility_id
	operation["location_id"] = location_id
	operation["material_savings_fractional"] = {}
	operation["waste_fractional"] = {}
	operation["line_id"] = "LINE-%06d" % (index + 1)
	operation["product_family_id"] = ""
	operation["method_id"] = ""
	## Kept at 100 only so schema <=32 can round-trip. Runtime throughput ignores
	## this field and automatically shares a real facility between active lines.
	operation["capacity_allocation"] = 100.0
	operation["priority"] = 50
	operation["control_mode"] = "PINNED"
	operation["manual_lock"] = true
	operation["production_device_id"] = ""
	operation["allowed_method_group"] = ""
	operation["input_commitments"] = {}
	operation["fractional_materials"] = {}
	operation["theoretical_rate"] = 0.0
	operation["actual_rate"] = 0.0
	operation["blocked_reason"] = ""
	operation.erase("allocated_capacity")
	return operation


static func _empty_construction_project(index: int) -> Dictionary:
	var project := _empty_operation(index, "construction")
	project.merge({
		"project_id":"",
		"project_type":"",
		"target_id":"",
		"priority":50,
		"enqueued_at_ms":0,
		"start_level":0,
		"target_level":0,
		"total_work":100.0,
		"completed_work":0.0,
		"material_plan":{},
		"delivered_materials":{},
		"in_transit_materials":{},
		"consumed":{},
		"project_definition":{},
		"cancellation_result":{}
	}, true)
	return project


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


static func _normalized_construction_projects(source: Array) -> Array:
	var result: Array = []
	for index in MAX_CONSTRUCTION_OPERATIONS:
		var normalized := _empty_construction_project(index)
		if index < source.size() and source[index] is Dictionary:
			for key in (source[index] as Dictionary):
				normalized[key] = (source[index] as Dictionary)[key]
		normalized["slot"] = index
		normalized["domain"] = "construction"
		normalized["location_id"] = str(normalized.get("location_id", MAIN_BASE_LOCATION_ID))
		if normalized["location_id"].is_empty():
			normalized["location_id"] = MAIN_BASE_LOCATION_ID
		normalized["priority"] = clampi(int(normalized.get("priority", 50)), 0, 100)
		normalized["total_work"] = maxf(1.0, float(normalized.get("total_work", 100.0)))
		normalized["completed_work"] = clampf(float(normalized.get("completed_work", normalized.get("project_cycles_completed", 0))), 0.0, normalized["total_work"])
		for field in ["material_plan", "delivered_materials", "in_transit_materials", "consumed", "project_definition", "cancellation_result", "blocker"]:
			normalized[field] = normalized.get(field, {}).duplicate(true) if normalized.get(field, null) is Dictionary else {}
		result.append(normalized)
	return result


static func _normalized_next_construction_project_serial(requested: int, projects: Array, history: Array) -> int:
	var result := maxi(1, requested)
	for collection in [projects, history]:
		for project_value in collection:
			if project_value is not Dictionary:
				continue
			var project := project_value as Dictionary
			var project_id := str(project.get("project_id", ""))
			if project_id.begins_with("CONSTRUCTION-"):
				result = maxi(result, int(project_id.trim_prefix("CONSTRUCTION-")) + 1)
	return result


static func _serial_after_identifiers(requested: int, identifiers: Array, prefix: String) -> int:
	var result := maxi(1, requested)
	for identifier_value in identifiers:
		var identifier := str(identifier_value)
		if not identifier.begins_with(prefix):
			continue
		var suffix := identifier.trim_prefix(prefix)
		if suffix.is_valid_int():
			result = maxi(result, int(suffix) + 1)
	return result


static func _normalized_industrial_operations(source: Array) -> Array:
	var result: Array = []
	for index in source.size():
		if source[index] is not Dictionary:
			continue
		var operation: Dictionary = source[index].duplicate(true)
		var facility_id := str(operation.get("facility_id", MANUFACTURING_FACILITY_IDS[index] if index < MANUFACTURING_FACILITY_IDS.size() else ""))
		if facility_id.is_empty():
			continue
		var normalized := _empty_industrial_operation(result.size(), facility_id, str(operation.get("location_id", MAIN_BASE_LOCATION_ID)))
		for key in operation:
			normalized[key] = operation[key]
		normalized["slot"] = index
		normalized["domain"] = "industry"
		normalized["facility_id"] = facility_id
		normalized.erase("allocated_capacity")
		if str(normalized.get("location_id", "")).is_empty():
			normalized["location_id"] = MAIN_BASE_LOCATION_ID
		normalized["material_savings_fractional"] = normalized.get("material_savings_fractional", {}).duplicate(true)
		normalized["waste_fractional"] = normalized.get("waste_fractional", {}).duplicate(true)
		normalized["line_id"] = str(normalized.get("line_id", "LINE-%06d" % (result.size() + 1)))
		normalized["method_id"] = str(normalized.get("method_id", normalized.get("activity_id", "")))
		normalized["product_family_id"] = str(normalized.get("product_family_id", ""))
		normalized["capacity_allocation"] = 100.0
		normalized["priority"] = clampi(int(normalized.get("priority", 50)), 0, 100)
		normalized["control_mode"] = str(normalized.get("control_mode", "PINNED"))
		# Versioned compatibility: legacy AUTO never had distinct simulation
		# semantics, so old saves migrate to the truthful PINNED state.
		if normalized["control_mode"] == "AUTO":
			normalized["control_mode"] = "PINNED"
		if normalized["control_mode"] not in ["PINNED", "OFF"]:
			normalized["control_mode"] = "PINNED"
		normalized["manual_lock"] = bool(normalized.get("manual_lock", true))
		normalized["production_device_id"] = str(normalized.get("production_device_id", ""))
		normalized["allowed_method_group"] = str(normalized.get("allowed_method_group", ""))
		normalized["input_commitments"] = normalized.get("input_commitments", normalized.get("reserved_costs", {})).duplicate(true)
		normalized["fractional_materials"] = normalized.get("fractional_materials", {}).duplicate(true)
		normalized["theoretical_rate"] = maxf(0.0, float(normalized.get("theoretical_rate", 0.0)))
		normalized["actual_rate"] = maxf(0.0, float(normalized.get("actual_rate", 0.0)))
		result.append(normalized)
	for facility_id in MANUFACTURING_FACILITY_IDS:
		if result.any(func(operation): return str(operation.get("location_id", MAIN_BASE_LOCATION_ID)) == MAIN_BASE_LOCATION_ID and str(operation.get("facility_id", "")) == facility_id):
			continue
		result.append(_empty_industrial_operation(result.size(), facility_id, MAIN_BASE_LOCATION_ID))
	for index in result.size():
		result[index]["slot"] = index
	return result


static func _normalized_next_production_line_serial(requested: int, lines: Array) -> int:
	var result := maxi(1, requested)
	for line_value in lines:
		var line_id := str((line_value as Dictionary).get("line_id", ""))
		if line_id.begins_with("LINE-"):
			result = maxi(result, int(line_id.trim_prefix("LINE-")) + 1)
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
		runtime["blocker"] = runtime.get("blocker", {}).duplicate(true) if runtime.get("blocker", null) is Dictionary else {}
		runtime["location_id"] = str(runtime.get("location_id", MAIN_BASE_LOCATION_ID))
		runtime["design_id"] = str(runtime.get("design_id", ""))
		runtime["custom_modules"] = runtime.get("custom_modules", []).duplicate() if runtime.get("custom_modules", null) is Array else []
		if str(runtime["location_id"]).is_empty():
			runtime["location_id"] = MAIN_BASE_LOCATION_ID
		result.append(runtime)
	return result


static func _normalized_ship_service_projects(source: Array) -> Array:
	var result: Array = []
	for value in source:
		if value is not Dictionary:
			continue
		var runtime: Dictionary = value.duplicate(true)
		if str(runtime.get("project_id", "")).is_empty() or str(runtime.get("ship_id", "")).is_empty():
			continue
		runtime["project_kind"] = str(runtime.get("project_kind", "REACTIVATION"))
		runtime["status"] = str(runtime.get("status", "RUNNING"))
		runtime["progress_ms"] = maxf(0.0, float(runtime.get("progress_ms", 0.0)))
		runtime["duration_ms"] = maxf(1.0, float(runtime.get("duration_ms", 1.0)))
		runtime["consumed_materials"] = runtime.get("consumed_materials", {}).duplicate(true)
		runtime["location_id"] = str(runtime.get("location_id", MAIN_BASE_LOCATION_ID))
		result.append(runtime)
	return result


static func _normalized_fleet_maintenance(source: Dictionary) -> Dictionary:
	var result := {"fractional":{}, "debt":{}, "coverage":{}, "consumption_totals":{}}
	for key in result:
		if source.get(key, null) is Dictionary:
			result[key] = source[key].duplicate(true)
	return result


func _ensure_location(location_id: String, location_type: String, known: bool, system_id: String = SYSTEM_ID) -> void:
	if location_id.is_empty():
		location_id = MAIN_BASE_LOCATION_ID
	if not locations.has(location_id):
		locations[location_id] = LocationState.create(location_id, location_type, system_id, known)


func _load_locations(source: Dictionary, location_definitions: Dictionary) -> void:
	initialize_locations(location_definitions)
	for location_value in source.keys():
		var location_id := str(location_value)
		var definition: Dictionary = location_definitions.get(location_id, {})
		var location_type := str(definition.get("location_type", LocationState.ARTIFICIAL if location_id == MAIN_BASE_LOCATION_ID else LocationState.NATURAL))
		var system_id := str(definition.get("system_id", source[location_id].get("system_id", SYSTEM_ID)))
		var known := bool(regions.get(location_id, location_id == MAIN_BASE_LOCATION_ID))
		locations[location_id] = LocationState.normalize(source[location_value], location_id, location_type, system_id, known)
	_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)


func _normalize_location_ownership() -> void:
	_ensure_location(MAIN_BASE_LOCATION_ID, LocationState.ARTIFICIAL, true)
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


static func _normalized_demand_registry(source: Dictionary) -> Dictionary:
	var result := {"sources":{}, "history":[]}
	if source.get("sources", null) is Dictionary:
		for source_id_value in source.get("sources", {}).keys():
			var source_id := str(source_id_value)
			var demand: Dictionary = source["sources"][source_id].duplicate(true)
			demand["demand_id"] = source_id
			demand["product_id"] = str(demand.get("product_id", ""))
			demand["location_id"] = str(demand.get("location_id", MAIN_BASE_LOCATION_ID))
			demand["priority"] = clampi(int(demand.get("priority", 50)), 0, 100)
			demand["rate_per_hour"] = maxf(0.0, float(demand.get("rate_per_hour", 0.0)))
			demand["quantity"] = maxf(0.0, float(demand.get("quantity", 0.0)))
			result["sources"][source_id] = demand
	if source.get("history", null) is Array:
		result["history"] = source.get("history", []).duplicate(true)
	return result


static func _normalized_operations_maintenance(source: Dictionary) -> Dictionary:
	var result := {"fractional":{}, "coverage":{}, "consumption_totals":{}}
	for key in result:
		if source.get(key, null) is Dictionary:
			result[key] = source[key].duplicate(true)
	return result


static func _normalized_economy_telemetry(source: Dictionary) -> Dictionary:
	var result := {"window_started_at_ms":0, "elapsed_ms":0.0, "flows":{}}
	result["window_started_at_ms"] = maxi(0, int(source.get("window_started_at_ms", 0)))
	result["elapsed_ms"] = maxf(0.0, float(source.get("elapsed_ms", 0.0)))
	if source.get("flows", null) is Dictionary:
		result["flows"] = source.get("flows", {}).duplicate(true)
	return result


static func _normalized_automation_rules(source: Array) -> Array:
	var result: Array = []
	for value in source:
		if value is not Dictionary:
			continue
		var rule: Dictionary = (value as Dictionary).duplicate(true)
		rule["rule_id"] = str(rule.get("rule_id", "AUTOMATION-%06d" % (result.size() + 1)))
		rule["enabled"] = bool(rule.get("enabled", true))
		rule["paused"] = bool(rule.get("paused", false))
		rule["condition"] = rule.get("condition", {}).duplicate(true) if rule.get("condition", null) is Dictionary else {}
		rule["action"] = rule.get("action", {}).duplicate(true) if rule.get("action", null) is Dictionary else {}
		rule["cooldown_ms"] = maxf(0.0, float(rule.get("cooldown_ms", 30000.0)))
		rule["hysteresis"] = maxf(0.0, float(rule.get("hysteresis", 0.05)))
		rule["last_triggered_at_ms"] = int(rule.get("last_triggered_at_ms", -1))
		result.append(rule)
	return result


static func _normalized_survey_mission(source: Dictionary) -> Dictionary:
	var result := {"status":"IDLE", "mission_id":"", "formation_id":"", "origin":"", "target":"", "target_state":"", "survey_capability":"", "duration_ms":0.0, "progress_ms":0.0, "costs":{}, "assigned_ship_ids":[]}
	for key in result:
		if source.has(key):
			result[key] = source[key].duplicate(true) if source[key] is Dictionary or source[key] is Array else source[key]
	result["status"] = str(result.get("status", "IDLE"))
	result["duration_ms"] = maxf(0.0, float(result.get("duration_ms", 0.0)))
	result["progress_ms"] = clampf(float(result.get("progress_ms", 0.0)), 0.0, result["duration_ms"])
	result["costs"] = result.get("costs", {}).duplicate(true)
	result["assigned_ship_ids"] = result.get("assigned_ship_ids", []).duplicate()
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


static func _normalized_fleet_formations(source: Dictionary) -> Dictionary:
	var result := {}
	for formation_id_value in source.keys():
		var formation_id := str(formation_id_value)
		if formation_id.is_empty() or formation_id in ["mining", "industry", "construction", "expedition"] or source[formation_id_value] is not Dictionary:
			continue
		var source_formation := source[formation_id_value] as Dictionary
		var ship_ids: Array[String] = []
		for ship_id_value in source_formation.get("ship_ids", []):
			var ship_id := str(ship_id_value)
			if not ship_id.is_empty() and not ship_ids.has(ship_id):
				ship_ids.append(ship_id)
		result[formation_id] = {
			"id":formation_id,
			"name":str(source_formation.get("name", formation_id.replace("_", " ").capitalize())),
			"ship_ids":ship_ids
		}
	if result.is_empty():
		result[DEFAULT_FORMATION_ID] = {"id":DEFAULT_FORMATION_ID, "name":"First Task Force", "ship_ids":[]}
	return result


static func _normalized_fleet_logistics(source: Dictionary) -> Dictionary:
	var result := {
		DEFAULT_FORMATION_ID:{
			"command_capacity":100,
			"supplies":{},
			"recovered":{},
			"supply_plan":{"kinetic_munitions":60, "chemical_propellant":20, "repair_supplies":10},
			"policies":{"ammunition_empty":"RETURN", "repair_empty":"RETURN", "cargo_full":"RETURN"},
			"formation":{"doctrine":"HOLD_FORMATION", "ship_zones":{}, "retreat_policy":{"mode":"HULL_THRESHOLD", "threshold":0.25}}
		}
	}
	for fleet_id in source:
		if str(fleet_id) in ["mining", "industry", "construction", "expedition"]:
			continue
		if source[fleet_id] is not Dictionary:
			continue
		var normalized: Dictionary = result.get(fleet_id, {"command_capacity":100, "supplies":{}, "recovered":{}, "supply_plan":{}, "policies":{}, "formation":{"doctrine":"HOLD_FORMATION", "ship_zones":{}, "retreat_policy":{"mode":"HULL_THRESHOLD", "threshold":0.25}}}).duplicate(true)
		for field in ["command_capacity", "supplies", "recovered", "supply_plan", "policies", "formation"]:
			if source[fleet_id].has(field):
				normalized[field] = source[fleet_id][field].duplicate(true) if source[fleet_id][field] is Dictionary else source[fleet_id][field]
		var formation: Dictionary = normalized.get("formation", {})
		formation["doctrine"] = str(formation.get("doctrine", "HOLD_FORMATION"))
		formation["ship_zones"] = formation.get("ship_zones", {}).duplicate(true)
		var retreat_policy: Dictionary = formation.get("retreat_policy", {})
		retreat_policy["mode"] = str(retreat_policy.get("mode", "HULL_THRESHOLD"))
		retreat_policy["threshold"] = clampf(float(retreat_policy.get("threshold", 0.25)), 0.05, 0.95)
		formation["retreat_policy"] = retreat_policy
		normalized["formation"] = formation
		result[fleet_id] = normalized
	return result


static func _normalized_logistics_network(source: Dictionary) -> Dictionary:
	var result := {
		"dispatch_interval_ms":5000.0,
		"dispatch_progress_ms":0.0,
		"shipments":[],
		"next_shipment_serial":1,
		"services":{},
		"route_statistics":{},
		"item_statistics":{}
	}
	for key in result:
		if not source.has(key):
			continue
		result[key] = source[key].duplicate(true) if source[key] is Dictionary or source[key] is Array else source[key]
	result["dispatch_interval_ms"] = maxf(100.0, float(result.get("dispatch_interval_ms", 5000.0)))
	result["dispatch_progress_ms"] = maxf(0.0, float(result.get("dispatch_progress_ms", 0.0)))
	var shipment_ids: Array = []
	for shipment_value in result.get("shipments", []):
		if shipment_value is Dictionary:
			shipment_ids.append(str((shipment_value as Dictionary).get("id", "")))
	result["next_shipment_serial"] = _serial_after_identifiers(int(result.get("next_shipment_serial", 1)), shipment_ids, "SHIPMENT-")
	return result


static func _normalized_ship_designs(source: Dictionary) -> Dictionary:
	var result := {}
	for design_id_value in source.keys():
		var design_id := str(design_id_value)
		var value = source.get(design_id_value)
		if design_id.is_empty() or value is not Dictionary:
			continue
		var design: Dictionary = value.duplicate(true)
		design["id"] = design_id
		design["name"] = str(design.get("name", design_id))
		design["plan_id"] = str(design.get("plan_id", ""))
		design["hull_id"] = str(design.get("hull_id", ""))
		design["modules"] = design.get("modules", []).duplicate() if design.get("modules", null) is Array else []
		design["nodes"] = design.get("nodes", []).duplicate(true) if design.get("nodes", null) is Array else []
		design["connections"] = design.get("connections", []).duplicate(true) if design.get("connections", null) is Array else []
		design["saved_at_ms"] = maxi(0, int(design.get("saved_at_ms", 0)))
		if not design["plan_id"].is_empty() and not design["hull_id"].is_empty():
			result[design_id] = design
	return result


static func _normalized_saved_loadouts(source: Dictionary) -> Dictionary:
	var result := {}
	for source_key in source:
		if source[source_key] is not Dictionary:
			continue
		var loadout: Dictionary = source[source_key].duplicate(true)
		var blueprint_id := str(loadout.get("blueprint_id", loadout.get("id", source_key)))
		if blueprint_id.is_empty():
			continue
		var loadout_id := str(loadout.get("id", source_key))
		if loadout_id.is_empty():
			loadout_id = str(source_key)
		loadout["id"] = loadout_id
		loadout["blueprint_id"] = blueprint_id
		loadout["name"] = str(loadout.get("name", "%s Loadout" % blueprint_id))
		loadout["modules"] = loadout.get("modules", []).duplicate()
		result[loadout_id] = loadout
	return result


static func _normalized_megastructure_projects(source: Dictionary, completed: Dictionary) -> Dictionary:
	var result := {}
	for project_id in source:
		if source[project_id] is not Dictionary:
			continue
		var runtime: Dictionary = source[project_id].duplicate(true)
		runtime["id"] = str(runtime.get("id", project_id))
		runtime["progress_percent"] = clampi(int(runtime.get("progress_percent", 0)), 0, 100)
		runtime["phase_index"] = maxi(0, int(runtime.get("phase_index", runtime.get("stage_index", 0))))
		runtime["stage_index"] = int(runtime["phase_index"])
		runtime["delivered_materials"] = runtime.get("delivered_materials", {}).duplicate(true)
		runtime["phase_history"] = runtime.get("phase_history", []).duplicate(true)
		runtime["total_materials_consumed"] = runtime.get("total_materials_consumed", {}).duplicate(true)
		runtime["total_capital_goods"] = runtime.get("total_capital_goods", {}).duplicate(true)
		runtime["supplier_locations"] = runtime.get("supplier_locations", {}).duplicate(true)
		runtime["total_cargo_transported"] = maxf(0.0, float(runtime.get("total_cargo_transported", 0.0)))
		runtime["peak_construction_throughput"] = maxf(0.0, float(runtime.get("peak_construction_throughput", 0.0)))
		runtime["peak_power_demand"] = maxf(0.0, float(runtime.get("peak_power_demand", 0.0)))
		runtime["started_at_ms"] = int(runtime.get("started_at_ms", 0))
		runtime["completed_at_ms"] = int(runtime.get("completed_at_ms", 0))
		runtime["site_location_id"] = str(runtime.get("site_location_id", runtime.get("location_id", MAIN_BASE_LOCATION_ID)))
		runtime["status"] = str(runtime.get("status", "PLANNED"))
		result[str(project_id)] = runtime
	for project_id in completed:
		if not bool(completed.get(project_id, false)) or result.has(project_id):
			continue
		result[str(project_id)] = {"id":str(project_id), "progress_percent":100, "phase_index":8, "stage_index":8, "stage_name":"COMPLETE", "delivered_materials":{}, "phase_history":[], "total_materials_consumed":{}, "total_capital_goods":{}, "supplier_locations":{}, "total_cargo_transported":0.0, "peak_construction_throughput":0.0, "peak_power_demand":0.0, "started_at_ms":0, "completed_at_ms":0, "site_location_id":MAIN_BASE_LOCATION_ID, "status":"COMPLETE"}
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
		if not ship.has("commissioned_at_ms"):
			ship["commissioned_at_ms"] = int(ship.get("built_at_ms", 0))
		if not ship.has("current_loadout_id"):
			ship["current_loadout_id"] = ""
		ship["maintenance_state"] = str(ship.get("maintenance_state", "ACTIVE"))
		if str(ship["maintenance_state"]) not in ["ACTIVE", "READY_RESERVE", "MOTHBALLED"]:
			ship["maintenance_state"] = "ACTIVE"
		ship["maintenance_coverage"] = clampf(float(ship.get("maintenance_coverage", 1.0)), 0.0, 1.0)
		ship["maintenance_debt"] = maxf(0.0, float(ship.get("maintenance_debt", 0.0)))
		var service_record: Dictionary = ship.get("service_record", {})
		service_record.merge({"extraction_cycles":0, "combat_deployments":0, "discoveries":0, "victories":0, "defeats":0, "damage_dealt":0.0, "combat_experience":0.0}, false)
		ship["service_record"] = service_record


func _reconcile_fleet_maintenance() -> void:
	var debts: Dictionary = fleet_maintenance.get("debt", {})
	var coverage: Dictionary = fleet_maintenance.get("coverage", {})
	for ship_value in ships:
		var ship := ship_value as Dictionary
		var ship_id := str(ship.get("instance_id", ""))
		if ship_id.is_empty():
			continue
		# Older saves could carry one side of this mirrored UI/cache field only.
		# Preserve the larger liability so migration can never erase real debt.
		var canonical_debt := maxf(maxf(0.0, float(debts.get(ship_id, 0.0))), maxf(0.0, float(ship.get("maintenance_debt", 0.0))))
		debts[ship_id] = canonical_debt
		ship["maintenance_debt"] = canonical_debt
		var canonical_coverage := clampf(float(coverage.get(ship_id, ship.get("maintenance_coverage", 1.0))), 0.0, 1.0)
		coverage[ship_id] = canonical_coverage
		ship["maintenance_coverage"] = canonical_coverage
	fleet_maintenance["debt"] = debts
	fleet_maintenance["coverage"] = coverage


func _normalize_activity_fleets() -> void:
	var claimed: Array[String] = []
	var logistics_assignments := {}
	var survey_assignments := {}
	# Schema 37 retires ship work assignments. Repair stale in-memory records even
	# when a caller constructed state without passing through save migration.
	for ship_value in ships:
		var stale_ship := ship_value as Dictionary
		var stale_assignment: Dictionary = stale_ship.get("assignment", {})
		if str(stale_assignment.get("domain", "")) == "mining" or str(stale_assignment.get("type", "")) == "CONSTRUCTION_SUPPORT" or str(stale_ship.get("status", "")) in ["EXTRACTION_OPERATION", "CONSTRUCTION_SUPPORT"]:
			stale_ship["status"] = "DOCKED"
			stale_ship["assignment"] = {}
	if str(survey_mission.get("status", "IDLE")) == "RUNNING":
		var normalized_survey_ship_ids: Array = []
		for ship_id_value in survey_mission.get("assigned_ship_ids", []):
			var ship_id := str(ship_id_value)
			var candidate := ship_by_id(ship_id)
			if ship_id.is_empty() or claimed.has(ship_id) or candidate.is_empty() or str(candidate.get("condition", "OPERATIONAL")) != "OPERATIONAL" or str(candidate.get("maintenance_state", "ACTIVE")) != "ACTIVE":
				continue
			normalized_survey_ship_ids.append(ship_id)
			claimed.append(ship_id)
			survey_assignments[ship_id] = {
				"type":"SURVEY_MISSION",
				"mission_id":str(survey_mission.get("mission_id", "")),
				"target":str(survey_mission.get("target", ""))
			}
		survey_mission["assigned_ship_ids"] = normalized_survey_ship_ids
	for service_value in logistics_network.get("services", {}).values():
		if service_value is not Dictionary:
			continue
		var service := service_value as Dictionary
		var normalized_service_ship_ids: Array = []
		for ship_id_value in service.get("assigned_ship_ids", []):
			var ship_id := str(ship_id_value)
			var candidate := ship_by_id(ship_id)
			if ship_id.is_empty() or claimed.has(ship_id) or candidate.is_empty() or str(candidate.get("maintenance_state", "ACTIVE")) != "ACTIVE":
				continue
			normalized_service_ship_ids.append(ship_id)
			claimed.append(ship_id)
			logistics_assignments[ship_id] = {"domain":"logistics", "service_id":str(service.get("id", "")), "route_id":str(service.get("route_id", ""))}
		service["assigned_ship_ids"] = normalized_service_ship_ids
	var formation_claimed: Array[String] = []
	for formation_id in formation_ids():
		var normalized_ids: Array = []
		for ship_id in formation_ship_ids(formation_id):
			var id := str(ship_id)
			var candidate := ship_by_id(id)
			if not id.is_empty() and not formation_claimed.has(id) and not candidate.is_empty() and str(candidate.get("maintenance_state", "ACTIVE")) == "ACTIVE":
				normalized_ids.append(id)
				formation_claimed.append(id)
		set_formation_ship_ids(formation_id, normalized_ids)
	for ship in ships:
		if ship.get("status", "") in ["REPAIRING", "DISABLED", "BUILDING", "REFITTING", "REACTIVATING"]:
			continue
		var ship_id := str(ship.get("instance_id", ""))
		if logistics_assignments.has(ship_id):
			ship["status"] = "LOGISTICS_SERVICE"
			ship["assignment"] = logistics_assignments[ship_id].duplicate(true)
			continue
		if survey_assignments.has(ship_id):
			ship["status"] = "EXPEDITION"
			ship["assignment"] = survey_assignments[ship_id].duplicate(true)
			continue
		var formation_id := ship_formation_id(ship_id)
		ship["status"] = "DOCKED"
		ship["assignment"] = {} if formation_id.is_empty() or str(ship.get("maintenance_state", "ACTIVE")) != "ACTIVE" else {"formation_id":formation_id}
	if active_expedition.get("status", "IDLE") == "RUNNING":
		for ship_id in active_expedition.get("assigned_ship_ids", []):
			var ship := ship_by_id(str(ship_id))
			if not ship.is_empty() and ship.get("condition", "OPERATIONAL") == "OPERATIONAL":
				ship["status"] = "EXPEDITION"
				ship["assignment"] = {"type":"EXPEDITION", "formation_id":str(active_expedition.get("formation_id", DEFAULT_FORMATION_ID))}
