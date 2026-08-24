class_name SaveRepository
extends RefCounted


func exists() -> bool:
	return false


func load_data() -> Dictionary:
	return {}


func save_state(_state: SpaceGameState, _content_version: String, _enabled_content_packs: Array = []) -> bool:
	return false


func delete_save() -> bool:
	return false
