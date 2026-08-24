extends Node

signal locale_changed(locale: String)

const TRANSLATION_PATH := "res://data/localization_zh_CN.json"
const SETTINGS_PATH := "user://settings.cfg"

var current_locale := "en"
var _translations := {}


func _ready() -> void:
	_load_translations()
	_load_preference()
	_apply_command_line_locale()


func is_chinese() -> bool:
	return current_locale == "zh_CN"


func toggle_locale() -> void:
	set_locale("en" if is_chinese() else "zh_CN")


func set_locale(locale: String) -> void:
	var normalized := "zh_CN" if locale.begins_with("zh") else "en"
	if normalized == current_locale:
		return
	current_locale = normalized
	var config := ConfigFile.new()
	config.set_value("localization", "locale", current_locale)
	config.save(SETTINGS_PATH)
	locale_changed.emit(current_locale)


func t(key: String, fallback: String = "") -> String:
	if not is_chinese():
		return fallback if not fallback.is_empty() else key
	return str(_translations.get("ui", {}).get(key, fallback if not fallback.is_empty() else key))


func content(definition: Dictionary, field: String = "name") -> String:
	var fallback := str(definition.get(field, ""))
	if not is_chinese():
		return fallback
	var id := str(definition.get("id", ""))
	return str(_translations.get("content", {}).get(id, {}).get(field, fallback))


func domain_name(domain_id: String, database: ContentDatabase) -> String:
	return content(database.domains.get(domain_id, {"id":domain_id, "name":domain_id.capitalize()}), "name")


func status(status_id: String) -> String:
	return t("status.%s" % status_id, status_id)


func category(category_id: String) -> String:
	return t("category.%s" % category_id, category_id)


func expedition_phase(phase_id: String) -> String:
	return t("phase.%s" % phase_id, phase_id.capitalize())


func expedition_reason(reason_id: String) -> String:
	if reason_id.is_empty():
		return t("reason.none", "No failure")
	if reason_id.begins_with("BUILD_INSUFFICIENT"):
		return t("reason.BUILD_INSUFFICIENT", "The fleet build did not meet this route node's requirements")
	return t("reason.%s" % reason_id, reason_id.replace("_", " ").capitalize())


func _load_translations() -> void:
	if not FileAccess.file_exists(TRANSLATION_PATH):
		push_warning("Chinese translation file is missing")
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(TRANSLATION_PATH))
	if typeof(parsed) == TYPE_DICTIONARY:
		_translations = parsed
	else:
		push_warning("Chinese translation file is invalid")


func _load_preference() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		current_locale = "zh_CN" if str(config.get_value("localization", "locale", "en")).begins_with("zh") else "en"


func _apply_command_line_locale() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--locale="):
			current_locale = "zh_CN" if argument.trim_prefix("--locale=").begins_with("zh") else "en"
