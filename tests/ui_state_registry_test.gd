extends Node

const REGISTRY_PATH := "res://data/ui_state_registry.json"
const REQUIRED_FIELDS := [
	"stateId", "domainSource", "affectedScreens", "playerMeaning",
	"requiredVisualFeedback", "requiredExplanation", "requiredPossibleAction"
]
const REQUIRED_SYSTEMS := ["factory_entity", "factory_link", "factory_construction", "research", "logistics", "survey", "megastructure"]
const ACTIVE_SCREEN_IDS := [
	"alerts", "construction", "diagnostics", "expedition", "guidance", "header",
	"industry.factory", "inventory", "location", "location.logistics", "location.overview",
	"location.resources", "logistics", "megastructure", "research", "ships", "survey", "system"
]
const REQUIRED_CORE_STATES := [
	"FACTORY_ENTITY.IDLE", "FACTORY_ENTITY.RUNNING", "FACTORY_ENTITY.NO_RESOURCE",
	"FACTORY_ENTITY.NO_POWER", "FACTORY_ENTITY.POWER_LIMITED", "FACTORY_ENTITY.PARTIAL_COVERAGE",
	"FACTORY_ENTITY.INPUT_SHORTAGE", "FACTORY_ENTITY.OUTPUT_FULL", "FACTORY_ENTITY.NO_RECIPE",
	"FACTORY_LINK.IDLE", "FACTORY_LINK.CONNECTED", "FACTORY_LINK.FLOWING",
	"FACTORY_LINK.SOURCE_EMPTY", "FACTORY_LINK.TARGET_FULL",
	"FACTORY_CONSTRUCTION.WAITING_MATERIALS", "FACTORY_CONSTRUCTION.READY", "FACTORY_CONSTRUCTION.BUILDING",
	"RESEARCH.AVAILABLE", "RESEARCH.LOCKED", "RESEARCH.ACTIVE", "RESEARCH.WAITING_MATERIAL",
	"RESEARCH.WAITING_FACILITY", "RESEARCH.WAITING_PROTOTYPE",
	"RESEARCH.WAITING_FIELD_TEST", "RESEARCH.PAUSED", "RESEARCH.COMPLETED",
	"LOGISTICS.ACTIVE", "LOGISTICS.UNDERUTILIZED", "LOGISTICS.SATURATED",
	"LOGISTICS.BLOCKED_SOURCE", "LOGISTICS.BLOCKED_DESTINATION", "LOGISTICS.NO_TRANSPORT",
	"LOGISTICS.PAUSED",
	"SURVEY.UNKNOWN", "SURVEY.DETECTED", "SURVEY.SURVEYED", "SURVEY.DEEP_SURVEYED",
	"MEGASTRUCTURE.LOCKED", "MEGASTRUCTURE.RESEARCH_REQUIRED", "MEGASTRUCTURE.SITE_PREPARATION",
	"MEGASTRUCTURE.WAITING_MATERIAL", "MEGASTRUCTURE.READY", "MEGASTRUCTURE.WAITING_SITE_SERVICE", "MEGASTRUCTURE.BUILDING", "MEGASTRUCTURE.INTEGRATION",
	"MEGASTRUCTURE.COMMISSIONING", "MEGASTRUCTURE.COMPLETED"
]

var failures: Array[String] = []


func _ready() -> void:
	var registry := _read_registry()
	_check(not registry.is_empty(), "UI state registry parses")
	if registry.is_empty():
		_finish()
		return
	_check(int(registry.get("schemaVersion", 0)) == 1, "registry schemaVersion is supported")
	_check(str(registry.get("coverageClaim", "")) == "CONTRACT_ONLY", "registry does not claim runtime state coverage")
	_check(str(registry.get("runtimeCoverage", "")) == "UNVERIFIED", "registry explicitly marks runtime coverage unverified")
	var definitions_value = registry.get("definitions", null)
	_check(definitions_value is Array, "registry definitions is an array")
	if definitions_value is not Array:
		_finish()
		return
	var definitions: Array = definitions_value
	var seen := {}
	var definitions_by_id := {}
	var actual_state_ids: Array[String] = []
	var covered_systems := {}
	for definition_value in definitions:
		_check(definition_value is Dictionary, "every registry entry is an object")
		if definition_value is not Dictionary:
			continue
		var definition := definition_value as Dictionary
		var state_id := str(definition.get("stateId", ""))
		_check(not state_id.is_empty(), "every registry entry has a stateId")
		_check(not seen.has(state_id), "core state is unique: %s" % state_id)
		seen[state_id] = true
		definitions_by_id[state_id] = definition
		actual_state_ids.append(state_id)
		var system_id := str(definition.get("systemId", ""))
		_check(system_id in REQUIRED_SYSTEMS, "state has a core systemId: %s" % state_id)
		covered_systems[system_id] = true
		for field_value in REQUIRED_FIELDS:
			_check(definition.has(field_value), "%s has %s" % [state_id, field_value])
		_validate_domain_source(state_id, definition.get("domainSource", null))
		_check(not str(definition.get("playerMeaning", "")).strip_edges().is_empty(), "%s has playerMeaning text" % state_id)
		for array_field in ["affectedScreens", "requiredVisualFeedback", "requiredExplanation", "requiredPossibleAction"]:
			_validate_non_empty_string_array(state_id, array_field, definition.get(array_field, null))
		for screen_id_value in definition.get("affectedScreens", []):
			var screen_id := str(screen_id_value)
			_check(screen_id in ACTIVE_SCREEN_IDS, "%s references an active player-facing screen: %s" % [state_id, screen_id])
		_check(str(definition.get("runtimeCoverage", "")) == "UNVERIFIED", "%s does not claim runtime verification" % state_id)
	for system_id in REQUIRED_SYSTEMS:
		_check(covered_systems.has(system_id), "registry covers core system: %s" % system_id)
	var expected_state_ids: Array[String] = []
	for state_id in REQUIRED_CORE_STATES:
		expected_state_ids.append(state_id)
	actual_state_ids.sort()
	expected_state_ids.sort()
	_check(actual_state_ids == expected_state_ids, "registry contains exactly the declared core states")
	var waiting_facility: Dictionary = definitions_by_id.get("RESEARCH.WAITING_FACILITY", {})
	var waiting_facility_selector := str(waiting_facility.get("domainSource", {}).get("selector", ""))
	_check(
		"MISSING_FACILITY" in waiting_facility_selector and "RESEARCH_CAPACITY_SHORTAGE" in waiting_facility_selector,
		"RESEARCH.WAITING_FACILITY declares both runtime reasons mapped to WAITING_FACILITY"
	)
	_finish()


func _read_registry() -> Dictionary:
	if not FileAccess.file_exists(REGISTRY_PATH):
		failures.append("Missing registry: %s" % REGISTRY_PATH)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		failures.append("Invalid registry JSON: %s" % REGISTRY_PATH)
		return {}
	return parsed


func _validate_domain_source(state_id: String, source_value: Variant) -> void:
	_check(source_value is Dictionary, "%s domainSource is structured" % state_id)
	if source_value is not Dictionary:
		return
	var source := source_value as Dictionary
	for field in ["owner", "path", "symbol", "selector"]:
		_check(not str(source.get(field, "")).strip_edges().is_empty(), "%s domainSource has %s" % [state_id, field])


func _validate_non_empty_string_array(state_id: String, field: String, value: Variant) -> void:
	_check(value is Array and not (value as Array).is_empty(), "%s has non-empty %s" % [state_id, field])
	if value is not Array:
		return
	for entry in value as Array:
		_check(entry is String and not str(entry).strip_edges().is_empty(), "%s %s entries are non-empty strings" % [state_id, field])


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: UI state registry contract is structurally complete; runtime coverage remains UNVERIFIED")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
