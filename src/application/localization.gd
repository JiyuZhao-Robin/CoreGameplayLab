extends Node

signal locale_changed(locale: String)

const TRANSLATION_PATHS := {
	"en":"res://data/localization_en.json",
	"zh_CN":"res://data/localization_zh_CN.json"
}
const SETTINGS_PATH := "user://settings.cfg"

var current_locale := "en"
var _translations := {}
var _translations_by_locale := {}
var _inline_keys_by_locale := {}


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
	var catalog: Dictionary = _translations_by_locale.get(current_locale, {})
	return str(catalog.get("ui", {}).get(key, fallback if not fallback.is_empty() else key))


func core(key: String, fallback: String = "") -> String:
	var catalog: Dictionary = _translations_by_locale.get(current_locale, {})
	return str(catalog.get("core_ui", {}).get(key, fallback if not fallback.is_empty() else key))


func inline(text_value: String) -> String:
	if is_chinese() or text_value.is_empty():
		return text_value
	var replacements: Dictionary = _translations_by_locale.get(current_locale, {}).get("inline", {})
	if replacements.has(text_value):
		return str(replacements[text_value])
	var keys: Array = _inline_keys_by_locale.get(current_locale, [])
	var translated := text_value
	for source_value in keys:
		var source := str(source_value)
		if translated.contains(source):
			translated = translated.replace(source, str(replacements[source]))
	return translated


func content(definition: Dictionary, field: String = "name") -> String:
	var fallback := str(definition.get(field, ""))
	var id := str(definition.get("id", ""))
	var catalog: Dictionary = _translations_by_locale.get(current_locale, {})
	return str(catalog.get("content", {}).get(id, {}).get(field, fallback))


func goal_step(step_id: String, fallback: String) -> String:
	var catalog: Dictionary = _translations_by_locale.get(current_locale, {})
	return str(catalog.get("goal_steps", {}).get(step_id, fallback))


func megastructure_stage(megastructure_id: String, percent: int, fallback: String) -> String:
	var catalog: Dictionary = _translations_by_locale.get(current_locale, {})
	return str(catalog.get("megastructure_stages", {}).get(megastructure_id, {}).get(str(percent), fallback))


func domain_name(domain_id: String, database: ContentDatabase) -> String:
	return content(database.domains.get(domain_id, {"id":domain_id, "name":domain_id.capitalize()}), "name")


func status(status_id: String) -> String:
	return core("status.%s" % status_id, t("status.%s" % status_id, status_id))


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
	_translations_by_locale.clear()
	_inline_keys_by_locale.clear()
	for locale_value in TRANSLATION_PATHS.keys():
		var locale := str(locale_value)
		var path := str(TRANSLATION_PATHS[locale])
		if not FileAccess.file_exists(path):
			push_warning("Translation file is missing: %s" % path)
			continue
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) != TYPE_DICTIONARY:
			push_warning("Translation file is invalid: %s" % path)
			continue
		var catalog: Dictionary = parsed
		var content_translations: Dictionary = catalog.get("content", {})
		for definition_id_value in catalog.get("content_overrides", {}).keys():
			var definition_id := str(definition_id_value)
			var merged: Dictionary = content_translations.get(definition_id, {}).duplicate(true)
			merged.merge(catalog["content_overrides"][definition_id], true)
			content_translations[definition_id] = merged
		catalog["content"] = content_translations
		_translations_by_locale[locale] = catalog
		var inline_keys: Array = catalog.get("inline", {}).keys()
		inline_keys.sort_custom(func(left, right): return str(left).length() > str(right).length())
		_inline_keys_by_locale[locale] = inline_keys
	# Compatibility for existing tests and any diagnostic tooling that reads the
	# historical Chinese catalog directly.
	_translations = _translations_by_locale.get("zh_CN", {})


func _load_preference() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		current_locale = "zh_CN" if str(config.get_value("localization", "locale", "en")).begins_with("zh") else "en"


func _apply_command_line_locale() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--locale="):
			current_locale = "zh_CN" if argument.trim_prefix("--locale=").begins_with("zh") else "en"
