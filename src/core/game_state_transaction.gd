class_name GameStateTransaction
extends RefCounted

var working_state: SpaceGameState
var events: Array[Dictionary] = []
var committed := false


func _init(current_state: SpaceGameState, domain_ids: Array) -> void:
	working_state = SpaceGameState.from_dictionary(current_state.to_dictionary(), domain_ids)


func record(event: Dictionary) -> void:
	events.append(event.duplicate(true))


func commit() -> SpaceGameState:
	committed = true
	return working_state


func rollback() -> void:
	committed = false
	events.clear()
	working_state = null
