extends Node

const REGISTRY_PATH := "res://data/player_action_registry.json"
const UI_SOURCE_PATH := "res://src/ui/main.gd"
const DOMAIN_SOURCE_PATH := "res://src/application/game.gd"
const REQUIRED_FIELDS := [
	"actionId", "domainCommand", "requiredContext", "uiEntryPoints", "unlockedBy",
	"expectedSuccessResult", "expectedFailureReasons", "saveRelevant", "coreGameplay", "verified"
]
const REQUIRED_CORE_ACTIONS := [
	"SAVE_GAME",
	"START_SURVEY_MISSION",
	"START_PRODUCTION", "STOP_PRODUCTION", "CHANGE_PRODUCTION_METHOD", "ADD_PRODUCTION_LINE",
	"CHANGE_PRODUCTION_PRIORITY", "SET_PRODUCTION_CONTROL_PINNED", "SET_PRODUCTION_CONTROL_OFF",
	"EXPAND_FACTORY", "UPGRADE_SCALE_STAGE", "ADOPT_INDUSTRIAL_TRANSFORMATION",
	"UPGRADE_LOCATION_CAPACITY", "INSTALL_FACILITY_MODULE", "INSTALL_MANUFACTURING_MODULE",
	"UNINSTALL_MANUFACTURING_MODULE", "SET_ADVANCED_POWER_PRIORITY",
	"SET_LOGISTICS_POLICY", "CLEAR_LOGISTICS_POLICY", "CHANGE_TRANSPORT_MODE",
	"ASSIGN_LOGISTICS_SHIP", "CHANGE_ROUTE_PRIORITY", "SET_ROUTE_PAUSED",
	"START_CONSTRUCTION", "PAUSE_CONSTRUCTION", "RESUME_CONSTRUCTION",
	"CHANGE_PROJECT_PRIORITY", "CANCEL_CONSTRUCTION",
	"START_RESEARCH", "SELECT_RESEARCH_ROUTE", "STOP_RESEARCH",
	"BUILD_SHIP", "REORDER_SHIP_BUILD", "CANCEL_SHIP_BUILD", "ASSIGN_SHIP",
	"SET_FLEET_SUPPLY_PLAN", "RESUPPLY_FLEET", "SET_FLEET_DOCTRINE",
	"SET_RETREAT_POLICY", "SET_COMBAT_ZONE", "APPLY_SHIP_LOADOUT", "REPLACE_SHIP_MODULE",
	"INSTALL_SHIP_MODULE", "REMOVE_SHIP_MODULE", "CANCEL_SHIP_REFIT",
	"START_EXPEDITION", "RECALL_EXPEDITION", "START_COMBAT_ACTION",
	"SELECT_MEGASTRUCTURE_SITE", "START_MEGASTRUCTURE_PHASE", "CANCEL_MEGASTRUCTURE_PHASE"
]
const RETIRED_ACTIONS := [
	"SET_PRODUCTION_CONTROL_AUTO", "DEVELOP_SITE", "START_EXTRACTION",
	"STOP_EXTRACTION", "INTEGRATE_EXTRACTION_SITE",
	"ASSIGN_CONSTRUCTION_SUPPORT", "RELEASE_CONSTRUCTION_SUPPORT"
]

var failures: Array[String] = []
var _ui_source := ""
var _domain_source := ""


func _ready() -> void:
	_ui_source = _read_source(UI_SOURCE_PATH)
	_domain_source = _read_source(DOMAIN_SOURCE_PATH)
	_check(not _ui_source.is_empty(), "player UI source is readable")
	_check(not _domain_source.is_empty(), "Game application source is readable")
	var registry := _read_registry()
	_check(not registry.is_empty(), "player action registry parses")
	if registry.is_empty():
		_finish()
		return
	_check(int(registry.get("schemaVersion", 0)) == 1, "registry schemaVersion is supported")
	_check(str(registry.get("coverageClaim", "")) == "STATIC_SOURCE_CONTRACT_ONLY", "registry only claims static source coverage")
	_check(str(registry.get("uiJourneyCoverage", "")) == "UNVERIFIED", "registry does not claim an unexecuted UI Journey")
	var policy_value = registry.get("verificationPolicy", null)
	_check(policy_value is Dictionary, "verificationPolicy is structured")
	if policy_value is Dictionary:
		var policy := policy_value as Dictionary
		_check(str(policy.get("verifiedMeaning", "")).contains("Static source tracing"), "verified is explicitly limited to static source tracing")
		_check(str(policy.get("uiJourneyVerifiedMeaning", "")).contains("real UI"), "UI Journey verification has an explicit runtime standard")
		var known_failing = policy.get("knownFailingActions", null)
		_check(known_failing is Array and (known_failing as Array).is_empty(), "no known core action remains without a static UI entry point")
	var actions_value = registry.get("actions", null)
	_check(actions_value is Array, "registry actions is an array")
	if actions_value is not Array:
		_finish()
		return
	var seen := {}
	var actual_core_actions: Array[String] = []
	for action_value in actions_value as Array:
		_check(action_value is Dictionary, "every action registry entry is an object")
		if action_value is not Dictionary:
			continue
		var action := action_value as Dictionary
		var action_id := str(action.get("actionId", ""))
		_check(not action_id.is_empty(), "every action has an actionId")
		_check(not seen.has(action_id), "actionId is unique: %s" % action_id)
		seen[action_id] = true
		for field_value in REQUIRED_FIELDS:
			_check(action.has(field_value), "%s has %s" % [action_id, field_value])
		_validate_string_array(action_id, "requiredContext", action.get("requiredContext", null), true)
		_validate_string_array(action_id, "unlockedBy", action.get("unlockedBy", null), false)
		_validate_string_array(action_id, "uiEntryPoints", action.get("uiEntryPoints", null), false)
		_validate_string_array(action_id, "expectedFailureReasons", action.get("expectedFailureReasons", null), false)
		_check(not str(action.get("domainCommand", "")).strip_edges().is_empty(), "%s has a Domain command" % action_id)
		_check(not str(action.get("expectedSuccessResult", "")).strip_edges().is_empty(), "%s has a success contract" % action_id)
		_check(not bool(action.get("uiJourneyVerified", false)), "%s does not invent UI Journey verification" % action_id)
		if action.has("uiJourneyCoverage"):
			_check(str(action.get("uiJourneyCoverage", "")) == "UNVERIFIED", "%s per-action UI Journey coverage remains unverified" % action_id)
		if not bool(action.get("coreGameplay", false)):
			continue
		actual_core_actions.append(action_id)
		_validate_core_action(action_id, action)
	for retired_action in RETIRED_ACTIONS:
		_check(not seen.has(retired_action), "retired action is absent: %s" % retired_action)
	var expected_core_actions: Array[String] = []
	for action_id in REQUIRED_CORE_ACTIONS:
		expected_core_actions.append(action_id)
	actual_core_actions.sort()
	expected_core_actions.sort()
	_check(actual_core_actions == expected_core_actions, "registry contains exactly the declared core player action inventory")
	_check(not _ui_source.contains('Game.set_production_line_control.bind(slot, "AUTO"'), "UI does not recreate the retired AUTO production action")
	_check(_ui_source.contains("Game.install_ship_module.bind"), "ship-module install has a real UI callback")
	_check(_ui_source.contains("Game.remove_ship_module.bind"), "ship-module removal has a real UI callback")
	_finish()


func _validate_core_action(action_id: String, action: Dictionary) -> void:
	_check(bool(action.get("verified", false)), "%s has a statically verified UI-to-Domain trace" % action_id)
	var entry_points = action.get("uiEntryPoints", null)
	_check(entry_points is Array and not (entry_points as Array).is_empty(), "%s has at least one real UI entry point" % action_id)
	if entry_points is Array:
		for entry_value in entry_points as Array:
			_check(str(entry_value).contains("src/ui/main.gd"), "%s UI entry point names the real player UI source" % action_id)
	var failures_value = action.get("expectedFailureReasons", null)
	_check(failures_value is Array and not (failures_value as Array).is_empty(), "%s has a non-empty failure contract" % action_id)
	var domain_command := str(action.get("domainCommand", "")).strip_edges()
	_check(domain_command.begins_with("Game."), "%s core action is owned by Game" % action_id)
	if not domain_command.begins_with("Game."):
		return
	var symbol := domain_command.trim_prefix("Game.")
	_check(not symbol.is_empty() and symbol.is_valid_identifier(), "%s names one concrete Game command symbol" % action_id)
	if symbol.is_empty() or not symbol.is_valid_identifier():
		return
	_check(_domain_source.contains("\nfunc %s(" % symbol) or _domain_source.begins_with("func %s(" % symbol), "%s Domain command exists: Game.%s" % [action_id, symbol])
	_check(_ui_source.contains("Game.%s" % symbol), "%s UI source references Game.%s" % [action_id, symbol])


func _read_registry() -> Dictionary:
	if not FileAccess.file_exists(REGISTRY_PATH):
		failures.append("Missing registry: %s" % REGISTRY_PATH)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(REGISTRY_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		failures.append("Invalid registry JSON: %s" % REGISTRY_PATH)
		return {}
	return parsed


func _read_source(path: String) -> String:
	if not FileAccess.file_exists(path):
		failures.append("Missing source: %s" % path)
		return ""
	return FileAccess.get_file_as_string(path)


func _validate_string_array(action_id: String, field: String, value: Variant, require_non_empty: bool) -> void:
	_check(value is Array, "%s %s is an array" % [action_id, field])
	if value is not Array:
		return
	if require_non_empty:
		_check(not (value as Array).is_empty(), "%s has non-empty %s" % [action_id, field])
	for entry_value in value as Array:
		_check(entry_value is String and not str(entry_value).strip_edges().is_empty(), "%s %s entries are non-empty strings" % [action_id, field])


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: player action registry covers %d core actions with static UI-to-Domain source contracts; UI Journey coverage remains UNVERIFIED" % REQUIRED_CORE_ACTIONS.size())
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
