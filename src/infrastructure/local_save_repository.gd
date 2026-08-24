class_name LocalSaveRepository
extends SaveRepository

const SAVE_PATH := "user://space_idle_save.json"
const TEMP_PATH := "user://space_idle_save.tmp"
const BACKUP_PATH := "user://space_idle_save.backup.json"

func exists() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


func load_data() -> Dictionary:
	for path in [SAVE_PATH, BACKUP_PATH]:
		var parsed := _read_wrapper(path)
		if parsed.is_empty():
			continue
		var payload: Dictionary = parsed.get("payload", {})
		var schema_version := int(payload.get("save_version", parsed.get("save_version", 0)))
		if not GameVersion.can_migrate_save(schema_version):
			push_warning("Ignoring incompatible Lab save schema %d" % schema_version)
			continue
		var checksum := str(parsed.get("checksum", ""))
		var checksum_version := int(parsed.get("checksum_version", 1))
		if checksum_version >= 4 and checksum != _checksum(payload):
			push_warning("Save checksum mismatch in %s; trying backup" % path)
			continue
		return payload
	return {}


func save_state(state: SpaceGameState, content_version: String, enabled_content_packs: Array = []) -> bool:
	state.parent_revision = state.revision
	state.revision += 1
	state.saved_at_ms = int(Time.get_unix_time_from_system() * 1000.0)
	var payload := state.to_dictionary()
	payload["content_version"] = content_version
	payload["enabled_content_packs"] = enabled_content_packs
	var wrapper := {
		"save_id":state.save_id,
		"revision":state.revision,
		"parent_revision":state.parent_revision,
		"device_id":state.device_id,
		"save_version":SpaceGameState.SAVE_VERSION,
		"content_version":content_version,
		"game_version":SpaceGameState.GAME_VERSION,
		"enabled_content_packs":enabled_content_packs,
		"saved_at_ms":state.saved_at_ms,
		"payload":payload,
		"checksum":_checksum(payload),
		"checksum_version":4
	}
	var process_temp_path := "user://space_idle_save.%d.tmp" % OS.get_process_id()
	var file := FileAccess.open(process_temp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(wrapper, "  "))
	file.flush()
	file = null
	return _replace_atomically(process_temp_path)


func delete_save() -> bool:
	var success := true
	for path in [SAVE_PATH, TEMP_PATH, BACKUP_PATH]:
		if FileAccess.file_exists(path):
			success = DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK and success
	return success


func _read_wrapper(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _replace_atomically(temp_path: String = TEMP_PATH) -> bool:
	var save_absolute := ProjectSettings.globalize_path(SAVE_PATH)
	var temp_absolute := ProjectSettings.globalize_path(temp_path)
	var backup_absolute := ProjectSettings.globalize_path(BACKUP_PATH)
	if FileAccess.file_exists(BACKUP_PATH):
		DirAccess.remove_absolute(backup_absolute)
	if FileAccess.file_exists(SAVE_PATH):
		if DirAccess.rename_absolute(save_absolute, backup_absolute) != OK:
			return false
	if DirAccess.rename_absolute(temp_absolute, save_absolute) != OK:
		if FileAccess.file_exists(BACKUP_PATH):
			DirAccess.rename_absolute(backup_absolute, save_absolute)
		return false
	return true


func _checksum(value: Variant) -> String:
	return _canonical_json(value).sha256_text()


func _canonical_json(value: Variant) -> String:
	match typeof(value):
		TYPE_DICTIONARY:
			var keys: Array = value.keys()
			keys.sort_custom(func(a, b): return str(a) < str(b))
			var members: Array[String] = []
			for key in keys:
				members.append("%s:%s" % [JSON.stringify(str(key)), _canonical_json(value[key])])
			return "{%s}" % ",".join(members)
		TYPE_ARRAY:
			var entries: Array[String] = []
			for entry in value:
				entries.append(_canonical_json(entry))
			return "[%s]" % ",".join(entries)
		TYPE_INT, TYPE_FLOAT:
			var number := float(value)
			if number == floor(number):
				return str(int(number))
			return String.num(number, 12)
		_:
			return JSON.stringify(value)
