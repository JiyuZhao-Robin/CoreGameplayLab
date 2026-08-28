extends Node

const LocalizationAudit = preload("res://tools/ui_localization_audit.gd")

var failures: Array[String] = []


func _ready() -> void:
	_test_inline_is_not_a_stable_key()
	_test_missing_language_and_scene_text_are_detected()
	_test_application_internal_text_is_reviewed_separately()
	_test_ui_internal_identifiers_are_reviewed_narrowly()
	_test_application_player_notices_are_bilingual()
	_test_unreferenced_historical_catalog_drift_is_separate_debt()
	_test_repository_audit_is_consistent()
	_finish()


func _test_inline_is_not_a_stable_key() -> void:
	var english := {"core_ui":{"shell.save":"Save"}, "ui":{}, "goal_steps":{}, "megastructure_stages":{}}
	var chinese := {"core_ui":{"shell.save":"保存"}, "ui":{}, "goal_steps":{}, "megastructure_stages":{}}
	var report := LocalizationAudit.audit_entries([{
		"path":"res://src/ui/synthetic.gd",
		"text":"var stable = I18n.core(\"shell.save\")\nvar legacy = I18n.inline(\"保存\")\nlabel.text = \"生产由 Factory 执行\"",
	}], english, chinese)
	_check(int(report.get("stable_key_reference_count", 0)) == 1, "only I18n.core/t literal calls count as stable-key references")
	_check((report.get("stable_keys", []) as Array) == ["core_ui.shell.save"], "the stable-key inventory excludes I18n.inline source text")
	_check(int(report.get("inline_reference_count", 0)) == 1 and _has_code(report, "INLINE_NOT_STABLE_KEY"), "I18n.inline is reported as transitional localization debt")
	_check(_has_code(report, "HARD_CODED_UI_TEXT"), "player-facing script literals are reported")
	_check(_has_code(report, "MIXED_CHINESE_TERM"), "mixed Chinese/English product terminology is reported")


func _test_missing_language_and_scene_text_are_detected() -> void:
	var english := {"core_ui":{}, "ui":{"notice.synthetic":"Synthetic notice"}, "goal_steps":{}, "megastructure_stages":{}}
	var chinese := {"core_ui":{}, "ui":{"notice.zh_only":"仅中文"}, "goal_steps":{}, "megastructure_stages":{}}
	var report := LocalizationAudit.audit_entries([
		{"path":"res://src/application/synthetic.gd", "text":"var notice = I18n.t(\"notice.synthetic\")\nvar other = I18n.t(\"notice.zh_only\")"},
		{"path":"res://src/ui/synthetic.tscn", "text":"[node name=\"Title\" type=\"Label\"]\ntext = \"硬编码场景标题\""},
	], english, chinese)
	_check(_has_code(report, "CATALOG_MISSING_ZH") and _has_code(report, "STABLE_KEY_MISSING_ZH"), "missing Chinese coverage is reported at catalog and call site")
	_check(_has_code(report, "CATALOG_MISSING_EN") and _has_code(report, "STABLE_KEY_MISSING_EN"), "missing English coverage is reported at catalog and call site")
	_check(_has_code(report, "HARD_CODED_SCENE_TEXT"), "hard-coded scene text is reported")
	_check(int(report.get("scanned_scenes", 0)) == 1 and int(report.get("scanned_scripts", 0)) == 1, "scene and script scan counts remain explicit")
	_check(int(report.get("runtime_missing_count", 0)) == 4, "referenced catalog gaps remain runtime errors at both catalog and call-site evidence")


func _test_unreferenced_historical_catalog_drift_is_separate_debt() -> void:
	var english := {"core_ui":{}, "ui":{"notice.legacy_en":"Legacy English only"}, "goal_steps":{}, "megastructure_stages":{}}
	var chinese := {"core_ui":{}, "ui":{"notice.legacy_zh":"仅有历史中文"}, "goal_steps":{}, "megastructure_stages":{}}
	var report := LocalizationAudit.audit_entries([], english, chinese)
	var counts: Dictionary = report.get("counts", {})
	_check(int(counts.get("ERROR", 0)) == 0, "unreferenced historical catalog drift does not masquerade as a runtime missing key")
	_check(int(report.get("runtime_missing_count", 0)) == 0, "historical-only entries are excluded from runtime missing count")
	_check(int(report.get("catalog_parity_debt_count", 0)) == 2, "historical English-only and Chinese-only entries remain explicit catalog debt")
	_check(_has_code(report, "CATALOG_LEGACY_ONLY_EN") and _has_code(report, "CATALOG_LEGACY_ONLY_ZH"), "both historical drift directions are classified")


func _test_application_internal_text_is_reviewed_separately() -> void:
	var catalogs := {"core_ui":{}, "ui":{}, "goal_steps":{}, "megastructure_stages":{}}
	var report := LocalizationAudit.audit_entries([{
		"path":"res://src/application/synthetic.gd",
		"text":"push_error(\"Content validation failed\")\nreturn _reject(\"Player command failed\")\nif \"slot limit\" in error:\n\tpass",
	}], catalogs, catalogs)
	_check(_count_code(report, "APPLICATION_INTERNAL_TEXT_REVIEW") == 2, "developer diagnostics and internal sentinels remain explicit REVIEW findings")
	_check(_count_code(report, "HARD_CODED_APPLICATION_TEXT") == 1, "actual player-facing application rejection remains hardcoded debt")


func _test_application_player_notices_are_bilingual() -> void:
	Game.persistence_enabled = false
	I18n.set_locale("en")
	Game.reset_game()
	_check(not Game.set_ship_maintenance_state("missing", "invalid") and Game.last_notice == "Invalid maintenance state", "English application command rejection uses its stable notice key")
	_check(not Game.set_location_logistics_limits("missing", 0, 0) and Game.last_notice == "Unknown location", "English shared location rejection is localized")
	_check(str(Game.call("_format_duration", 3661000)) == "1h 01m", "English player duration format is localized")
	I18n.set_locale("zh_CN")
	_check(not Game.set_ship_maintenance_state("missing", "invalid") and Game.last_notice == "无效的维护状态", "Chinese application command rejection uses its stable notice key")
	_check(not Game.set_location_logistics_limits("missing", 0, 0) and Game.last_notice == "未知地点", "Chinese shared location rejection is localized")
	_check(str(Game.call("_format_duration", 3661000)) == "1小时 01分", "Chinese player duration format is localized")


func _test_ui_internal_identifiers_are_reviewed_narrowly() -> void:
	var catalogs := {"core_ui":{}, "ui":{}, "goal_steps":{}, "megastructure_stages":{}}
	var report := LocalizationAudit.audit_entries([
		{"path":"res://src/ui/ui_theme_tokens.gd", "text":"var font_names := PackedStringArray([\"Microsoft YaHei\"] )\nlabel.text = \"Player heading\""},
		{"path":"res://src/ui/main.gd", "text":"print(\"CAPTURE_SAVED: %s\" % path)\n_label(\"Player notice\")"},
	], catalogs, catalogs)
	_check(_count_code(report, "UI_INTERNAL_FONT_IDENTIFIER_REVIEW") == 1, "platform font-family identifiers remain explicit non-player review findings")
	_check(_count_code(report, "UI_INTERNAL_CAPTURE_MARKER_REVIEW") == 1, "screenshot harness protocol markers remain explicit non-player review findings")
	_check(_count_code(report, "HARD_CODED_UI_TEXT") == 2, "the narrow internal exceptions do not hide adjacent player-facing UI text")


func _test_repository_audit_is_consistent() -> void:
	var report := LocalizationAudit.run_repository_audit()
	var counts: Dictionary = report.get("counts", {})
	var finding_count := (report.get("findings", []) as Array).size()
	_check(int(report.get("scanned_files", 0)) > 0, "repository audit scans source scenes and scripts")
	_check(int(report.get("stable_key_reference_count", 0)) > 0, "repository audit inventories stable localization calls")
	_check(int(report.get("inline_reference_count", 0)) == _count_code(report, "INLINE_NOT_STABLE_KEY"), "inline calls are reported separately and never promoted to stable coverage")
	_check(int(report.get("hardcoded_count", 0)) == _count_code(report, "HARD_CODED_UI_TEXT") + _count_code(report, "HARD_CODED_APPLICATION_TEXT") + _count_code(report, "HARD_CODED_SCENE_TEXT"), "hard-coded player text total matches its findings")
	_check(_count_code(report, "HARD_CODED_UI_TEXT") == 0 and _count_code(report, "HARD_CODED_SCENE_TEXT") == 0, "production UI and scenes have no remaining hardcoded player-facing text")
	_check(_count_code(report, "HARD_CODED_APPLICATION_TEXT") == 0, "application player notices, guidance and structured rejections have no remaining hardcoded text")
	_check(int(report.get("inline_reference_count", 0)) == 0, "production localization uses stable keys without legacy inline bridges")
	_check(int(report.get("terminology_count", 0)) == 0, "production localization has no unresolved terminology warning")
	_check(int(report.get("runtime_missing_count", 0)) == _count_code(report, "STABLE_KEY_MISSING_EN") + _count_code(report, "STABLE_KEY_MISSING_ZH") + _count_code(report, "CATALOG_MISSING_EN") + _count_code(report, "CATALOG_MISSING_ZH") + _count_code(report, "CATALOG_BLANK_EN") + _count_code(report, "CATALOG_BLANK_ZH") + _count_code(report, "CATALOG_FILE_MISSING"), "runtime missing total excludes historical catalog-only debt")
	_check(int(report.get("catalog_parity_debt_count", 0)) == _count_code(report, "CATALOG_LEGACY_ONLY_EN") + _count_code(report, "CATALOG_LEGACY_ONLY_ZH"), "catalog parity debt is reported independently")
	_check(int(report.get("runtime_missing_count", 0)) == 0, "every stable localization key referenced by production code has non-empty English and Chinese values")
	_check(int(counts.get("ERROR", 0)) == 0, "the repository localization runtime gate has no catalog, format-signature or English CJK error")
	_check(finding_count == int(counts.get("ERROR", 0)) + int(counts.get("WARN", 0)) + int(counts.get("REVIEW", 0)), "severity counts account for every repository finding")


func _has_code(report: Dictionary, code: String) -> bool:
	return (report.get("findings", []) as Array).any(func(value): return str((value as Dictionary).get("code", "")) == code)


func _count_code(report: Dictionary, code: String) -> int:
	return (report.get("findings", []) as Array).filter(func(value): return str((value as Dictionary).get("code", "")) == code).size()


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		var report := LocalizationAudit.run_repository_audit()
		var counts: Dictionary = report.get("counts", {})
		print("PASS: UI localization audit detects stable keys, inline debt, missing languages, hard-coded text and terminology; current debt remains errors=%d warnings=%d review=%d" % [int(counts.get("ERROR", 0)), int(counts.get("WARN", 0)), int(counts.get("REVIEW", 0))])
		get_tree().quit(0)
		return
	for failure in failures:
		push_error("FAIL: %s" % failure)
	get_tree().quit(1)
