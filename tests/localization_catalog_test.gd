extends Node

var failures: Array[String] = []


func _ready() -> void:
	var english := _read_catalog("res://data/localization_en.json")
	var chinese := _read_catalog("res://data/localization_zh_CN.json")
	_check(not english.is_empty(), "English catalog parses")
	_check(not chinese.is_empty(), "Chinese catalog parses")
	var english_core: Dictionary = english.get("core_ui", {})
	var chinese_core: Dictionary = chinese.get("core_ui", {})
	_check(english_core.size() >= 100, "core UI catalog covers the product shell and core systems")
	_check(_sorted_keys(english_core) == _sorted_keys(chinese_core), "zh-CN and en core_ui keys are aligned")
	for key_value in english_core.keys():
		var key := String(key_value)
		_check(not String(english_core[key]).strip_edges().is_empty(), "English core key has text: %s" % key)
		_check(not String(chinese_core.get(key, "")).strip_edges().is_empty(), "Chinese core key has text: %s" % key)
		_check(not _contains_cjk(String(english_core[key])), "English core key contains no CJK: %s" % key)
	for required_key in [
		"notice.sponsor_facility", "technology_domain.materials_science",
		"technology_domain.manufacturing", "technology_domain.energy",
		"technology_domain.propulsion", "technology_domain.automation_computing",
		"technology_domain.ship_engineering", "technology_domain.logistics",
		"technology_domain.anomaly_science", "requirement.technology_domain",
		"requirement.research_capacity", "requirement.operating_condition",
		"requirement.experimental_maturity", "requirement.spillover",
		"requirement.manufacturing_module", "requirement.survey_state",
		"requirement.mining_site_available", "requirement.mining_sites_mastered",
		"requirement.megastructure_phase", "operating_condition.computing_capacity",
		"operating_condition.power_capacity", "operating_condition.advanced_power_capacity",
		"operating_condition.cooling_capacity", "operating_condition.logistics_throughput",
		"operating_condition.precision_manufacturing"
	]:
		_check(english.get("ui", {}).has(required_key), "English UI catalog has %s" % required_key)
		_check(chinese.get("ui", {}).has(required_key), "Chinese UI catalog has %s" % required_key)
	var english_stages: Dictionary = english.get("megastructure_stages", {}).get("stellar_energy", {})
	var chinese_stages: Dictionary = chinese.get("megastructure_stages", {}).get("stellar_energy", {})
	_check(english_stages.size() == 9 and _sorted_keys(english_stages) == _sorted_keys(chinese_stages), "both catalogs cover all eight phases plus operational state")
	_check(_sorted_keys(english.get("goal_steps", {})) == _sorted_keys(chinese.get("goal_steps", {})), "every contextual Guidance step has aligned zh-CN and en text")
	_finish()


func _read_catalog(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		failures.append("Missing catalog: %s" % path)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		failures.append("Invalid catalog JSON: %s" % path)
		return {}
	return parsed


func _sorted_keys(values: Dictionary) -> Array:
	var keys := values.keys()
	keys.sort()
	return keys


func _contains_cjk(text_value: String) -> bool:
	for index in text_value.length():
		var code := text_value.unicode_at(index)
		if (code >= 0x3400 and code <= 0x9fff) or (code >= 0xf900 and code <= 0xfaff):
			return true
	return false


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: bilingual localization catalogs are aligned")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
