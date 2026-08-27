class_name LocationState
extends RefCounted

const NATURAL := "NATURAL"
const ARTIFICIAL := "ARTIFICIAL"
const DISCOVERED := "DISCOVERED"
const UNDISCOVERED := "UNDISCOVERED"
const UNKNOWN := "UNKNOWN"
const DETECTED := "DETECTED"
const SURVEYED := "SURVEYED"
const DEEP_SURVEYED := "DEEP_SURVEYED"
const SURVEY_STATE_ORDER := [UNKNOWN, DETECTED, SURVEYED, DEEP_SURVEYED]
const DEFAULT_STORAGE_CAPACITIES := {"BULK":400000, "COMPONENT":300000, "FLUID":200000, "SPECIAL":100000}


static func create(location_id: String, location_type: String, system_id: String, known: bool) -> Dictionary:
	return {
		"id":location_id,
		"type":location_type if location_type in [NATURAL, ARTIFICIAL] else NATURAL,
		"system_id":system_id,
		"discovery_state":DISCOVERED if known else UNDISCOVERED,
		"survey_state":SURVEYED if known else UNKNOWN,
		"environment":{},
		"inventory":{},
		"reserves":{},
		"power":{"status":"NOT_AVAILABLE"},
		"industry":{
			"industries":{},
			"specialization_id":"",
			"power_capacity":1000.0 if location_id == "earth_orbit" else 100.0,
			"cooling_capacity":1000.0 if location_type == ARTIFICIAL else 0.0,
			"structural_capacity":100.0 if location_type == ARTIFICIAL else 0.0
		},
		"industry_summary":{"status":"NOT_AVAILABLE"},
		"construction":{"capacity":100.0 if location_id == "earth_orbit" else 1.0, "active_project_ids":[]},
		"automation":{"industrial_template_id":"", "managed_policy_items":[], "status":"MANUAL", "auto_expand_enabled":false, "target_industry_level":1, "expansion_progress_ms":0.0, "last_blocked_reason":"", "blocker":{}},
		"logistics":{"policies":{}, "storage_capacity":1000000, "storage_capacities":DEFAULT_STORAGE_CAPACITIES.duplicate(true), "hub_throughput":100, "local_throughput_capacity":100.0},
		"logistics_summary":{"status":"NOT_CONNECTED"},
		"projects_summary":{"active_count":0},
		"fleet_presence":[]
	}


static func normalize(source: Dictionary, location_id: String, location_type: String, system_id: String, known: bool) -> Dictionary:
	var result := create(location_id, location_type, system_id, known)
	for key in result:
		if source.has(key):
			result[key] = source[key].duplicate(true) if source[key] is Dictionary or source[key] is Array else source[key]
	result["id"] = location_id
	result["type"] = str(result.get("type", location_type))
	result["system_id"] = str(result.get("system_id", system_id))
	var survey_state := str(result.get("survey_state", SURVEYED if known else UNKNOWN))
	if survey_state == "UNSURVEYED":
		survey_state = UNKNOWN
	if survey_state not in SURVEY_STATE_ORDER:
		survey_state = SURVEYED if known else UNKNOWN
	result["survey_state"] = survey_state
	result["environment"] = result.get("environment", {}).duplicate(true)
	result["inventory"] = result.get("inventory", {}).duplicate(true)
	result["reserves"] = result.get("reserves", {}).duplicate(true)
	result["industry"] = result.get("industry", {}).duplicate(true)
	result["industry"].merge({"industries":{}, "specialization_id":"", "power_capacity":100.0, "cooling_capacity":100.0 if str(result.get("type", location_type)) == ARTIFICIAL else 0.0, "structural_capacity":100.0 if str(result.get("type", location_type)) == ARTIFICIAL else 0.0}, false)
	result["industry"]["industries"] = result["industry"].get("industries", {}).duplicate(true)
	result["construction"] = result.get("construction", {}).duplicate(true)
	result["construction"].merge({"capacity":100.0 if location_id == "earth_orbit" else 1.0, "active_project_ids":[]}, false)
	result["construction"]["capacity"] = maxf(0.0, float(result["construction"].get("capacity", 0.0)))
	result["construction"]["active_project_ids"] = result["construction"].get("active_project_ids", []).duplicate()
	result["automation"] = result.get("automation", {}).duplicate(true)
	result["automation"].merge({"industrial_template_id":"", "managed_policy_items":[], "status":"MANUAL", "auto_expand_enabled":false, "target_industry_level":1, "expansion_progress_ms":0.0, "last_blocked_reason":"", "blocker":{}}, false)
	result["automation"]["managed_policy_items"] = result["automation"].get("managed_policy_items", []).duplicate()
	result["automation"]["target_industry_level"] = maxi(1, int(result["automation"].get("target_industry_level", 1)))
	result["automation"]["expansion_progress_ms"] = maxf(0.0, float(result["automation"].get("expansion_progress_ms", 0.0)))
	result["logistics"] = result.get("logistics", {}).duplicate(true)
	result["logistics"].merge({"policies":{}, "storage_capacity":1000000, "storage_capacities":DEFAULT_STORAGE_CAPACITIES.duplicate(true), "hub_throughput":100, "local_throughput_capacity":100.0}, false)
	result["logistics"]["policies"] = result["logistics"].get("policies", {}).duplicate(true)
	var storage_capacities: Dictionary = result["logistics"].get("storage_capacities", {}).duplicate(true)
	if storage_capacities.is_empty():
		storage_capacities = _split_legacy_storage_capacity(int(result["logistics"].get("storage_capacity", 1000000)))
	for storage_class in DEFAULT_STORAGE_CAPACITIES:
		storage_capacities[storage_class] = maxi(0, int(storage_capacities.get(storage_class, 0)))
	result["logistics"]["storage_capacities"] = storage_capacities
	result["logistics"]["storage_capacity"] = _total_storage_capacity(storage_capacities)
	return result


static func _split_legacy_storage_capacity(total: int) -> Dictionary:
	var normalized := maxi(0, total)
	return {
		"BULK":int(floor(float(normalized) * 0.40)),
		"COMPONENT":int(floor(float(normalized) * 0.30)),
		"FLUID":int(floor(float(normalized) * 0.20)),
		"SPECIAL":normalized - int(floor(float(normalized) * 0.90))
	}


static func _total_storage_capacity(capacities: Dictionary) -> int:
	var total := 0
	for value in capacities.values():
		total += maxi(0, int(value))
	return total
