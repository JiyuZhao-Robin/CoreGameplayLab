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
		"industry_summary":{"status":"NOT_AVAILABLE"},
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
	return result
