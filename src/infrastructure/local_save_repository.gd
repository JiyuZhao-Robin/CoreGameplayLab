class_name LocalSaveRepository
extends SaveRepository

const SAVE_PATH := "user://space_idle_save.json"
const TEMP_PATH := "user://space_idle_save.tmp"
const BACKUP_PATH := "user://space_idle_save.backup.json"

var _save_path := SAVE_PATH
var _temp_path := TEMP_PATH
var _backup_path := BACKUP_PATH


func configure_audit_root(root_path: String) -> bool:
	var normalized := root_path.simplify_path()
	if not normalized.is_absolute_path() or not normalized.get_file().begins_with("helios-ui-persistence-audit-"):
		return false
	_save_path = normalized.path_join("space_idle_save.json")
	_temp_path = normalized.path_join("space_idle_save.tmp")
	_backup_path = normalized.path_join("space_idle_save.backup.json")
	return true

func exists() -> bool:
	return FileAccess.file_exists(_save_path)


func load_data() -> Dictionary:
	for path in [_save_path, _backup_path]:
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
	var next_parent_revision := state.revision
	var next_revision := state.revision + 1
	var next_saved_at_ms := int(Time.get_unix_time_from_system() * 1000.0)
	var payload := state.to_dictionary()
	payload["parent_revision"] = next_parent_revision
	payload["revision"] = next_revision
	payload["saved_at_ms"] = next_saved_at_ms
	payload["content_version"] = content_version
	payload["enabled_content_packs"] = enabled_content_packs
	# Hash the exact JSON-compatible value that will be read back. Blueprint node
	# positions may contain editor-produced floating-point values whose textual
	# JSON representation is normalized during serialization; hashing the live
	# Variant tree could therefore reject the file immediately after writing it.
	var serialized_payload: Variant = JSON.parse_string(JSON.stringify(payload))
	if serialized_payload is not Dictionary:
		return false
	var persisted_payload := serialized_payload as Dictionary
	var wrapper := {
		"save_id":state.save_id,
		"revision":next_revision,
		"parent_revision":next_parent_revision,
		"device_id":state.device_id,
		"save_version":SpaceGameState.SAVE_VERSION,
		"content_version":content_version,
		"game_version":SpaceGameState.GAME_VERSION,
		"enabled_content_packs":enabled_content_packs,
		"saved_at_ms":next_saved_at_ms,
		"payload":persisted_payload,
		"checksum":_checksum(persisted_payload),
		"checksum_version":4
	}
	var process_temp_path := _save_path.get_base_dir().path_join("space_idle_save.%d.tmp" % OS.get_process_id())
	var file := FileAccess.open(process_temp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(wrapper, "  "))
	file.flush()
	file = null
	if not _replace_atomically(process_temp_path):
		return false
	state.parent_revision = next_parent_revision
	state.revision = next_revision
	state.saved_at_ms = next_saved_at_ms
	return true


func delete_save() -> bool:
	var success := true
	for path in [_save_path, _temp_path, _backup_path]:
		if FileAccess.file_exists(path):
			success = DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK and success
	return success


func _read_wrapper(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func _replace_atomically(temp_path: String = "") -> bool:
	if temp_path.is_empty():
		temp_path = _temp_path
	var save_absolute := ProjectSettings.globalize_path(_save_path)
	var temp_absolute := ProjectSettings.globalize_path(temp_path)
	var backup_absolute := ProjectSettings.globalize_path(_backup_path)
	if FileAccess.file_exists(_backup_path):
		DirAccess.remove_absolute(backup_absolute)
	if FileAccess.file_exists(_save_path):
		if DirAccess.rename_absolute(save_absolute, backup_absolute) != OK:
			return false
	if DirAccess.rename_absolute(temp_absolute, save_absolute) != OK:
		if FileAccess.file_exists(_backup_path):
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
