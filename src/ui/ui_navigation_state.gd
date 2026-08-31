class_name UiNavigationState
extends RefCounted

## Device-local presentation state. This object never owns gameplay state and
## never enters the save payload.

const DEFAULT_WORKSPACE := "system_map"
const MAX_HISTORY := 32

var active_workspace := DEFAULT_WORKSPACE
var selected_kind := "location"
var selected_id := ""
var left_rail_collapsed := false
var right_inspector_collapsed := false

var _history: Array[String] = []


func navigate(workspace: String, known_workspaces: Dictionary, record_history := true) -> bool:
	if not known_workspaces.has(workspace):
		return false
	if workspace == active_workspace:
		return true
	if record_history and known_workspaces.has(active_workspace):
		_history.append(active_workspace)
		if _history.size() > MAX_HISTORY:
			_history.pop_front()
	active_workspace = workspace
	return true


func back_target(known_workspaces: Dictionary) -> String:
	while not _history.is_empty():
		var candidate := String(_history.pop_back())
		if candidate != active_workspace and known_workspaces.has(candidate):
			return candidate
	if active_workspace != DEFAULT_WORKSPACE and known_workspaces.has(DEFAULT_WORKSPACE):
		return DEFAULT_WORKSPACE
	return ""


func select_context(kind: String, entity_id: String) -> void:
	selected_kind = kind
	selected_id = entity_id


func restore_workspace(workspace: String) -> void:
	active_workspace = workspace if not workspace.is_empty() else DEFAULT_WORKSPACE
	_history.clear()


func clear_history() -> void:
	_history.clear()
