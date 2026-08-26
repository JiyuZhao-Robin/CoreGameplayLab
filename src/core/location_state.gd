class_name LocationState
extends RefCounted

const NATURAL := "NATURAL"
const ARTIFICIAL := "ARTIFICIAL"
const DISCOVERED := "DISCOVERED"
const UNDISCOVERED := "UNDISCOVERED"
const SURVEYED := "SURVEYED"
const UNSURVEYED := "UNSURVEYED"


static func create(location_id: String, location_type: String, system_id: String, known: bool) -> Dictionary:
	return {
		"id":location_id,
		"type":location_type if location_type in [NATURAL, ARTIFICIAL] else NATURAL,
		"system_id":system_id,
		"discovery_state":DISCOVERED if known else UNDISCOVERED,
		"survey_state":SURVEYED if known else UNSURVEYED,
		"inventory":{},
		"reserves":{},
		"power":{"status":"NOT_AVAILABLE"},
		"industry":{
			"industries":{},
			"power_capacity":1000.0 if location_id == "earth_orbit" else 100.0,
			"cooling_capacity":1000.0 if location_type == ARTIFICIAL else 0.0,
			"structural_capacity":100.0 if location_type == ARTIFICIAL else 0.0
		},
		"industry_summary":{"status":"NOT_AVAILABLE"},
		"automation":{"industrial_template_id":"", "managed_policy_items":[], "status":"MANUAL", "auto_expand_enabled":false, "target_industry_level":1, "expansion_progress_ms":0.0, "last_blocked_reason":"", "blocker":{}},
		"logistics":{"policies":{}, "storage_capacity":1000000, "hub_throughput":100, "local_throughput_capacity":100.0},
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
	result["inventory"] = result.get("inventory", {}).duplicate(true)
	result["reserves"] = result.get("reserves", {}).duplicate(true)
	result["industry"] = result.get("industry", {}).duplicate(true)
	result["industry"].merge({"industries":{}, "power_capacity":100.0, "cooling_capacity":100.0 if str(result.get("type", location_type)) == ARTIFICIAL else 0.0, "structural_capacity":100.0 if str(result.get("type", location_type)) == ARTIFICIAL else 0.0}, false)
	result["industry"]["industries"] = result["industry"].get("industries", {}).duplicate(true)
	result["automation"] = result.get("automation", {}).duplicate(true)
	result["automation"].merge({"industrial_template_id":"", "managed_policy_items":[], "status":"MANUAL", "auto_expand_enabled":false, "target_industry_level":1, "expansion_progress_ms":0.0, "last_blocked_reason":"", "blocker":{}}, false)
	result["automation"]["managed_policy_items"] = result["automation"].get("managed_policy_items", []).duplicate()
	result["automation"]["target_industry_level"] = maxi(1, int(result["automation"].get("target_industry_level", 1)))
	result["automation"]["expansion_progress_ms"] = maxf(0.0, float(result["automation"].get("expansion_progress_ms", 0.0)))
	result["logistics"] = result.get("logistics", {}).duplicate(true)
	return result
