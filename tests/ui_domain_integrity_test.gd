extends Node

const MAIN_UI_PATH := "res://src/ui/main.gd"
const GAME_PATH := "res://src/application/game.gd"
const FULL_GAMEPLAY_HARNESS_PATH := "res://tests/full_gameplay_ui_test.gd"
const UI_PATHS := [
	"res://src/ui/main.gd",
	"res://src/ui/ui_theme_tokens.gd",
	"res://src/ui/components/system_map_view.gd",
	"res://src/ui/components/megastructure_progress_view.gd"
]
const ENGINE_CALLBACKS := ["_ready", "_process", "_draw", "_input", "_unhandled_input", "_gui_input", "_notification"]
const STATE_MUTATORS := [
	"add_item", "remove_item", "unlock_ship_plan", "enqueue_ship_plan",
	"ensure_location", "ensure_location_industry", "set_location_inventory"
]
const CONTAINER_MUTATORS := [
	"append", "assign", "clear", "erase", "fill", "merge", "pop_back",
	"pop_front", "push_back", "push_front", "remove_at", "resize", "reverse", "set"
]

var failures: Array[String] = []


func _ready() -> void:
	var main_source := _read_source(MAIN_UI_PATH)
	var game_source := _read_source(GAME_PATH)
	var ui_sources := {}
	for path_value in UI_PATHS:
		var path := str(path_value)
		var source := _read_source(path)
		ui_sources[path] = source
		_check(not source.is_empty(), "UI source is readable: %s" % path)
	_check(not game_source.is_empty(), "Game application source is readable")
	if main_source.is_empty() or game_source.is_empty():
		_finish()
		return

	_guard_no_state_writes(ui_sources)
	_guard_no_state_alias_writes(ui_sources)
	_guard_stable_identity(ui_sources)
	_guard_live_controls(ui_sources)
	_guard_boolean_command_contract(main_source, game_source)
	_guard_atomic_ui_commands(main_source)
	_guard_canonical_loadout_candidates(main_source)
	_guard_single_guidance_authority(main_source)
	_guard_full_gameplay_harness()
	_finish()


func _guard_no_state_writes(ui_sources: Dictionary) -> void:
	var direct_assignment := _regex(r"Game\.state[^\r\n]*(?:\+=|-=|\*=|/=|%=|[^=!<>]=[^=])")
	var direct_container_mutation := _regex(r"Game\.state[^\r\n]*\.(append|assign|clear|erase|fill|merge|pop_back|pop_front|push_back|push_front|remove_at|resize|reverse|set)\s*\(")
	var state_api_mutation := _regex("Game\\.state\\.(%s)\\s*\\(" % "|".join(STATE_MUTATORS))
	var simulation_mutation := _regex(r"Game\.simulation\.(advance|advance_offline|process_boundary|process_interval|reset|step|tick)\s*\(")
	for path_value in ui_sources.keys():
		var path := str(path_value)
		var source := str(ui_sources[path])
		_check(direct_assignment.search(source) == null, "%s must not assign through Game.state" % path)
		_check(direct_container_mutation.search(source) == null, "%s must not mutate a Game.state container" % path)
		_check(state_api_mutation.search(source) == null, "%s must not call a mutable SpaceGameState API" % path)
		_check(simulation_mutation.search(source) == null, "%s must not advance or mutate Simulation directly" % path)


func _guard_no_state_alias_writes(ui_sources: Dictionary) -> void:
	var alias_declaration := _regex(r"^\s*var\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*:[^=]+)?\s*(?::=|=)\s*Game\.state(?:\.|\b)")
	for path_value in ui_sources.keys():
		var path := str(path_value)
		var aliases := {}
		var function_name := "<file>"
		var lines := str(ui_sources[path]).split("\n")
		for index in lines.size():
			var line := str(lines[index])
			if line.begins_with("func "):
				function_name = line.trim_prefix("func ").get_slice("(", 0)
				aliases.clear()
			var declaration := alias_declaration.search(line)
			if declaration != null:
				# These collection APIs return a new container. Mutating that local copy is
				# presentation work, not a write through to Game.state.
				if ".duplicate(" in line or ".slice(" in line or ".filter(" in line or ".map(" in line:
					continue
				aliases[declaration.get_string(1)] = index + 1
				continue
			for alias_value in aliases.keys():
				var alias := str(alias_value)
				var nested_assignment := _regex("\\b%s(?:\\[[^\\]\\r\\n]+\\]|\\.[A-Za-z_][A-Za-z0-9_]*)+\\s*(?:\\+=|-=|\\*=|/=|%%=|[^=!<>]=[^=])" % alias)
				var mutator := _regex("\\b%s(?:\\[[^\\]\\r\\n]+\\]|\\.[A-Za-z_][A-Za-z0-9_]*)*\\.(%s)\\s*\\(" % [alias, "|".join(CONTAINER_MUTATORS)])
				_check(nested_assignment.search(line) == null and mutator.search(line) == null, "%s:%d %s must not mutate Game.state alias '%s'" % [path, index + 1, function_name, alias])


func _guard_stable_identity(ui_sources: Dictionary) -> void:
	var combined := "\n".join(ui_sources.values())
	var display_bound_to_command := _regex(r"Game\.[A-Za-z_][A-Za-z0-9_]*\.bind\([^\r\n]*(get_item_text|\.text\b|_content_name|I18n\.)")
	_check(not combined.contains("get_item_text("), "OptionButton commands must resolve through parallel stable-ID arrays, not displayed text")
	_check(not combined.contains("find_key("), "UI must not reverse-map a display value to Domain identity")
	_check(display_bound_to_command.search(combined) == null, "display/localized values must never be bound as Game command identity")
	_check(combined.contains("_on_context_location_selected.bind(location_ids)"), "location selector preserves stable location IDs")
	_check(combined.contains("_save_logistics_policy.bind(item_id") and combined.contains("source_ids") and combined.contains("route_ids"), "logistics selectors preserve item/location/route IDs")


func _guard_live_controls(ui_sources: Dictionary) -> void:
	var main_source := str(ui_sources.get(MAIN_UI_PATH, ""))
	var invalid_enabled_button := _regex(r"_button\([^\r\n]*Callable\(\)\s*,\s*false")
	_check(invalid_enabled_button.search(main_source) == null, "an enabled _button must never have an invalid Callable")

	var declarations := _regex(r"(?m)^func\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(").search_all(main_source)
	for declaration in declarations:
		var function_name := declaration.get_string(1)
		if function_name in ENGINE_CALLBACKS or not function_name.begins_with("_"):
			continue
		var references := _regex("\\b%s\\b" % function_name).search_all(main_source).size()
		_check(references > 1, "main.gd function has no callback/call site: %s" % function_name)


func _guard_boolean_command_contract(main_source: String, game_source: String) -> void:
	var bound_commands := {}
	var bound_pattern := _regex(r"_command(?:\.bind)?\([^\r\n]*?Game\.([A-Za-z_][A-Za-z0-9_]*)(?:\.bind)?")
	for result in bound_pattern.search_all(main_source):
		bound_commands[result.get_string(1)] = true
	for command_value in bound_commands.keys():
		var command := str(command_value)
		var signature := _regex("(?m)^func\\s+%s\\([^\\r\\n]*\\)\\s*->\\s*bool\\s*:" % command)
		_check(signature.search(game_source) != null, "_command target Game.%s must return bool so failure cannot be logged as success" % command)


func _guard_atomic_ui_commands(main_source: String) -> void:
	var body := _function_body(main_source, "_authorize_storage_guard")
	if body.is_empty():
		return
	var writes := 0
	for symbol in ["set_production_line_control", "add_automation_rule"]:
		writes += body.count("Game.%s(" % symbol)
	_check(writes <= 1, "_authorize_storage_guard composes %d separately committing Game writes; move the transaction behind one application command" % writes)


func _guard_canonical_loadout_candidates(main_source: String) -> void:
	var body := _function_body(main_source, "_compatible_loadout_modules")
	if body.is_empty():
		return
	_check(body.contains("ship_loadout_valid(") or body.contains("loadout_availability("), "replacement-module buttons must use the canonical complete-loadout validator/availability query")


func _guard_single_guidance_authority(main_source: String) -> void:
	var body := _function_body(main_source, "_next_flow_step") + _function_body(main_source, "_next_flow_page")
	if body.is_empty():
		return
	var owns_milestones := body.contains("Game.state.completed_activities") or body.contains("Game.state.facilities")
	_check(not owns_milestones, "UI next-flow helpers must consume Game.guidance_snapshot() instead of owning progression milestone rules")


func _guard_full_gameplay_harness() -> void:
	var source := _read_source(FULL_GAMEPLAY_HARNESS_PATH)
	_check(not source.is_empty(), "Fresh Save UI playthrough harness source is readable")
	if source.is_empty():
		return
	var state_assignment := _regex(r"Game\.state[^\r\n]*(?:\+=|-=|\*=|/=|%=|[^=!<>]=[^=])")
	var state_container_mutation := _regex(r"Game\.state[^\r\n]*\.(append|assign|clear|erase|fill|merge|pop_back|pop_front|push_back|push_front|remove_at|resize|reverse|set)\s*\(")
	var simulation_mutation := _regex(r"Game\.simulation\.(advance|advance_offline|process_boundary|process_interval|reset|step|tick)\s*\(")
	var direct_game_call := _regex(r"Game\.([A-Za-z_][A-Za-z0-9_]*)\s*\(")
	var source_lines := source.split("\n")
	for line_index in source_lines.size():
		var line := String(source_lines[line_index])
		if line.strip_edges().begins_with("#"):
			continue
		_check(state_assignment.search(line) == null, "%s:%d must not assign through Game.state" % [FULL_GAMEPLAY_HARNESS_PATH, line_index + 1])
		_check(state_container_mutation.search(line) == null, "%s:%d must not mutate a Game.state container" % [FULL_GAMEPLAY_HARNESS_PATH, line_index + 1])
		_check(simulation_mutation.search(line) == null, "%s:%d must not advance or mutate Simulation directly" % [FULL_GAMEPLAY_HARNESS_PATH, line_index + 1])
		for call_match in direct_game_call.search_all(line):
			var method_name := call_match.get_string(1)
			_check(method_name in ["get", "can_start_activity", "is_processing"], "%s:%d must not call gameplay command Game.%s directly" % [FULL_GAMEPLAY_HARNESS_PATH, line_index + 1, method_name])


func _function_body(source: String, function_name: String) -> String:
	var marker := "\nfunc %s(" % function_name
	var start := source.find(marker)
	if start < 0 and source.begins_with("func %s(" % function_name):
		start = 0
	if start < 0:
		return ""
	var next := source.find("\nfunc ", start + marker.length())
	return source.substr(start, source.length() - start) if next < 0 else source.substr(start, next - start)


func _regex(pattern: String) -> RegEx:
	var expression := RegEx.new()
	var error := expression.compile(pattern)
	if error != OK:
		failures.append("Static guard regex failed to compile: %s" % pattern)
	return expression


func _read_source(path: String) -> String:
	if not FileAccess.file_exists(path):
		failures.append("Missing source: %s" % path)
		return ""
	return FileAccess.get_file_as_string(path)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS: UI Domain integrity static guard (source contracts only; no UI Journey claim)")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
