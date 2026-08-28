extends SceneTree

const EN_CATALOG_PATH := "res://data/localization_en.json"
const ZH_CATALOG_PATH := "res://data/localization_zh_CN.json"
const SOURCE_ROOT := "res://src"
const STABLE_CATALOG_SECTIONS := ["core_ui", "ui", "goal_steps", "megastructure_stages"]
const MAX_PRINTED_FINDINGS := 160

const MIXED_CHINESE_TERM_RULES := [
	{"needle":"Factory", "preferred":"工厂", "reason":"玩家中文将 Factory 统一为“工厂”"},
	{"needle":"Production Device", "preferred":"生产装置", "reason":"玩家中文将 Production Device 统一为“生产装置”"},
	{"needle":"Production Method", "preferred":"生产方式", "reason":"玩家中文将 Production Method 统一为“生产方式”"},
	{"needle":"Location", "preferred":"地点", "reason":"Location 是包含轨道、基地和天体的统一地点概念"},
	{"needle":"Inventory", "preferred":"库存", "reason":"玩家中文将 Inventory 统一为“库存”"},
	{"needle":"Cycle/s", "preferred":"周期/秒", "reason":"中文界面不直接暴露 Cycle/s"},
	{"needle":"freight units", "preferred":"货运单位", "reason":"中文界面不混用 freight units"},
	{"needle":"Phase", "preferred":"阶段", "reason":"玩家中文将 Phase 统一为“阶段”"},
	{"needle":"BOM", "preferred":"物料清单", "reason":"BOM 只允许出现在开发文档或同时解释的高级诊断中"},
]

const CHINESE_TERM_RULES := [
	{"needle":"飞船", "preferred":"舰船", "reason":"永久资产统一称为“舰船”"},
	{"needle":"星球", "preferred":"地点", "reason":"通用 Location 不应缩窄为星球；具体行星类型除外"},
	{"needle":"商品", "preferred":"产品", "reason":"工业产物统一称为“产品”，交易语境才使用“商品”"},
]


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	if OS.get_cmdline_user_args().has("--run-test-suite"):
		var test_scene := load("res://tests/ui_localization_audit_test.tscn") as PackedScene
		if test_scene == null:
			push_error("FAIL: unable to load UI localization audit test scene")
			quit(1)
			return
		root.add_child(test_scene.instantiate())
		return
	var report := run_repository_audit()
	var counts: Dictionary = report.get("counts", {})
	print("UI_LOCALIZATION_AUDIT files=%d scenes=%d scripts=%d stable_refs=%d stable_keys=%d inline=%d hardcoded=%d terminology=%d runtime_missing=%d catalog_debt=%d errors=%d warnings=%d review=%d" % [
		int(report.get("scanned_files", 0)),
		int(report.get("scanned_scenes", 0)),
		int(report.get("scanned_scripts", 0)),
		int(report.get("stable_key_reference_count", 0)),
		(report.get("stable_keys", []) as Array).size(),
		int(report.get("inline_reference_count", 0)),
		int(report.get("hardcoded_count", 0)),
		int(report.get("terminology_count", 0)),
		int(report.get("runtime_missing_count", 0)),
		int(report.get("catalog_parity_debt_count", 0)),
		int(counts.get("ERROR", 0)),
		int(counts.get("WARN", 0)),
		int(counts.get("REVIEW", 0)),
	])
	var code_counts := {}
	for finding_value in report.get("findings", []):
		var finding := finding_value as Dictionary
		var finding_code := str(finding.get("code", "UNKNOWN"))
		code_counts[finding_code] = int(code_counts.get(finding_code, 0)) + 1
	var codes: Array = code_counts.keys()
	codes.sort()
	var code_parts: Array[String] = []
	for code_value in codes:
		var code_name := str(code_value)
		code_parts.append("%s=%d" % [code_name, int(code_counts[code_name])])
	print("UI_LOCALIZATION_AUDIT_CODES %s" % ",".join(code_parts))
	if not OS.get_cmdline_user_args().has("--summary-only"):
		var findings: Array = report.get("findings", [])
		for index in mini(findings.size(), MAX_PRINTED_FINDINGS):
			var finding: Dictionary = findings[index]
			print("%s %s %s:%d %s%s" % [
				str(finding.get("severity", "REVIEW")),
				str(finding.get("code", "UNKNOWN")),
				str(finding.get("path", "<catalog>")),
				int(finding.get("line", 0)),
				str(finding.get("message", "")),
				" | %s" % str(finding.get("evidence", "")) if not str(finding.get("evidence", "")).is_empty() else "",
			])
		if findings.size() > MAX_PRINTED_FINDINGS:
			print("UI_LOCALIZATION_AUDIT omitted=%d (rerun without relying on console detail; counts include every finding)" % (findings.size() - MAX_PRINTED_FINDINGS))
	quit(1 if int(counts.get("ERROR", 0)) > 0 else 0)


static func run_repository_audit() -> Dictionary:
	var findings: Array[Dictionary] = []
	var english := _read_catalog(EN_CATALOG_PATH, "en", findings)
	var chinese := _read_catalog(ZH_CATALOG_PATH, "zh_CN", findings)
	var entries: Array[Dictionary] = []
	for path_value in _collect_source_paths(SOURCE_ROOT):
		var path := str(path_value)
		entries.append({"path":path, "text":FileAccess.get_file_as_string(path)})
	var report := audit_entries(entries, english, chinese)
	var merged_findings: Array = findings.duplicate()
	merged_findings.append_array(report.get("findings", []))
	report["findings"] = merged_findings
	_finalize_report(report)
	return report


static func audit_entries(entries: Array, english: Dictionary, chinese: Dictionary) -> Dictionary:
	var report := {
		"scanned_files":0,
		"scanned_scenes":0,
		"scanned_scripts":0,
		"stable_key_reference_count":0,
		"stable_keys":[],
		"inline_reference_count":0,
		"hardcoded_count":0,
		"terminology_count":0,
		"missing_count":0,
		"findings":[],
		"counts":{"ERROR":0, "WARN":0, "REVIEW":0},
	}
	var findings: Array = report["findings"]
	var stable_references: Array[Dictionary] = []
	var stable_key_set := {}
	for entry_value in entries:
		if entry_value is not Dictionary:
			continue
		var entry := entry_value as Dictionary
		var path := str(entry.get("path", ""))
		var text_value := str(entry.get("text", ""))
		if path.is_empty():
			continue
		report["scanned_files"] = int(report["scanned_files"]) + 1
		if path.ends_with(".tscn"):
			report["scanned_scenes"] = int(report["scanned_scenes"]) + 1
			_scan_scene(path, text_value, findings, report)
		elif path.ends_with(".gd"):
			report["scanned_scripts"] = int(report["scanned_scripts"]) + 1
			_scan_script(path, text_value, stable_references, stable_key_set, findings, report)
	_scan_stable_catalogs(english, chinese, stable_key_set, findings)
	_scan_reference_coverage(stable_references, english, chinese, findings)
	_scan_catalog_terminology(english, "en", findings, report)
	_scan_catalog_terminology(chinese, "zh_CN", findings, report)
	var stable_keys: Array = stable_key_set.keys()
	stable_keys.sort()
	report["stable_keys"] = stable_keys
	report["stable_key_reference_count"] = stable_references.size()
	_finalize_report(report)
	return report


static func _scan_script(path: String, text_value: String, stable_references: Array[Dictionary], stable_key_set: Dictionary, findings: Array, report: Dictionary) -> void:
	var call_regex := _compile_regex("I18n\\.(t|core)\\(\\s*([^,\\)]+)")
	var inline_regex := _compile_regex("I18n\\.inline\\(")
	var string_regex := _compile_regex("\"([^\"]*)\"")
	var lines := text_value.split("\n")
	for line_index in lines.size():
		var line := str(lines[line_index])
		var line_number := line_index + 1
		var inline_matches := inline_regex.search_all(line)
		for _inline_match in inline_matches:
			report["inline_reference_count"] = int(report["inline_reference_count"]) + 1
			_add_finding(findings, "INLINE_NOT_STABLE_KEY", "WARN", path, line_number, "I18n.inline is a legacy text replacement and does not count as a stable localization key.", _compact_evidence(line))
		for call_match in call_regex.search_all(line):
			var kind := call_match.get_string(1)
			var expression := call_match.get_string(2).strip_edges()
			if expression.begins_with("\"") and expression.ends_with("\""):
				var key := expression.substr(1, expression.length() - 2)
				if _is_stable_key(key):
					var section := "core_ui" if kind == "core" else "ui"
					stable_references.append({"section":section, "key":key, "path":path, "line":line_number})
					stable_key_set["%s.%s" % [section, key]] = true
				else:
					_add_finding(findings, "DYNAMIC_LOCALIZATION_KEY", "REVIEW", path, line_number, "Formatted or non-canonical localization keys cannot be proven by static catalog lookup.", key)
			else:
				_add_finding(findings, "DYNAMIC_LOCALIZATION_KEY", "REVIEW", path, line_number, "Dynamic localization key expression requires an explicit enumerated contract.", expression)
		var skip_hardcoded := line.contains("I18n.t(") or line.contains("I18n.core(") or line.contains("I18n.inline(")
		for literal_match in string_regex.search_all(line):
			var literal := literal_match.get_string(1)
			_scan_terminology_value(literal, "source", path, line_number, findings, report)
			if skip_hardcoded or not _looks_player_facing(literal):
				continue
			var application_internal := path.contains("/application/") and (
				line.contains("push_error(")
				or line.contains("push_warning(")
				or path.ends_with("/application/localization.gd") and line.contains("return t(")
				or line.contains(" in error")
			)
			if application_internal:
				_add_finding(findings, "APPLICATION_INTERNAL_TEXT_REVIEW", "REVIEW", path, line_number, "Application diagnostic, localization fallback or internal sentinel is not a player-facing hardcoded string; retain it for explicit review.", _compact_evidence(literal))
				continue
			var ui_internal_code := ""
			if path.ends_with("/ui/ui_theme_tokens.gd") and literal in ["Noto Sans CJK SC", "Microsoft YaHei UI", "Microsoft YaHei", "PingFang SC", "Segoe UI", "Arial Unicode MS"]:
				ui_internal_code = "UI_INTERNAL_FONT_IDENTIFIER_REVIEW"
			elif path.ends_with("/ui/main.gd") and line.contains("print(") and (literal.begins_with("CAPTURE_SAVED:") or literal.begins_with("CAPTURE_FAILED:")):
				ui_internal_code = "UI_INTERNAL_CAPTURE_MARKER_REVIEW"
			if not ui_internal_code.is_empty():
				_add_finding(findings, ui_internal_code, "REVIEW", path, line_number, "Non-player UI protocol or platform identifier is retained as an explicit review finding.", _compact_evidence(literal))
				continue
			if path.contains("/ui/"):
				report["hardcoded_count"] = int(report["hardcoded_count"]) + 1
				_add_finding(findings, "HARD_CODED_UI_TEXT", "WARN", path, line_number, "Player-facing UI text should use a stable localization key.", _compact_evidence(literal))
			elif path.contains("/application/"):
				report["hardcoded_count"] = int(report["hardcoded_count"]) + 1
				_add_finding(findings, "HARD_CODED_APPLICATION_TEXT", "WARN", path, line_number, "Application text may reach notices or guidance and needs localization review.", _compact_evidence(literal))
			elif path.contains("/core/"):
				_add_finding(findings, "CORE_PLAYER_TEXT_REVIEW", "REVIEW", path, line_number, "Human-readable core string may reach diagnostics; confirm whether it is player-facing before assigning a key.", _compact_evidence(literal))


static func _scan_scene(path: String, text_value: String, findings: Array, report: Dictionary) -> void:
	var property_regex := _compile_regex("^\\s*(text|tooltip_text|placeholder_text)\\s*=\\s*\"([^\"]*)\"")
	var lines := text_value.split("\n")
	for line_index in lines.size():
		var match_value := property_regex.search(str(lines[line_index]))
		if match_value == null:
			continue
		var literal := match_value.get_string(2)
		if literal.is_empty():
			continue
		report["hardcoded_count"] = int(report["hardcoded_count"]) + 1
		_add_finding(findings, "HARD_CODED_SCENE_TEXT", "WARN", path, line_index + 1, "Scene player-facing text must be assigned from a stable key at runtime or use a documented translation resource.", _compact_evidence(literal))
		_scan_terminology_value(literal, "source", path, line_index + 1, findings, report)


static func _scan_stable_catalogs(english: Dictionary, chinese: Dictionary, referenced_keys: Dictionary, findings: Array) -> void:
	for section_value in STABLE_CATALOG_SECTIONS:
		var section := str(section_value)
		var english_values := _flatten_dictionary(english.get(section, {}))
		var chinese_values := _flatten_dictionary(chinese.get(section, {}))
		var all_keys := {}
		for key_value in english_values.keys():
			all_keys[str(key_value)] = true
		for key_value in chinese_values.keys():
			all_keys[str(key_value)] = true
		var keys: Array = all_keys.keys()
		keys.sort()
		for key_value in keys:
			var key := str(key_value)
			var logical_key := "%s.%s" % [section, key]
			var runtime_contract := referenced_keys.has(logical_key) or section in ["goal_steps", "megastructure_stages"]
			if not english_values.has(key):
				if runtime_contract:
					_add_finding(findings, "CATALOG_MISSING_EN", "ERROR", EN_CATALOG_PATH, 0, "Runtime localization contract is missing in English.", logical_key)
				else:
					_add_finding(findings, "CATALOG_LEGACY_ONLY_ZH", "REVIEW", ZH_CATALOG_PATH, 0, "Unreferenced historical catalog entry exists only in Chinese; migrate it if the feature returns to the player surface.", logical_key)
				continue
			if not chinese_values.has(key):
				if runtime_contract:
					_add_finding(findings, "CATALOG_MISSING_ZH", "ERROR", ZH_CATALOG_PATH, 0, "Runtime localization contract is missing in Chinese.", logical_key)
				else:
					_add_finding(findings, "CATALOG_LEGACY_ONLY_EN", "REVIEW", EN_CATALOG_PATH, 0, "Unreferenced historical catalog entry exists only in English; migrate it if the feature returns to the player surface.", logical_key)
				continue
			var english_text := str(english_values[key]).strip_edges()
			var chinese_text := str(chinese_values[key]).strip_edges()
			if english_text.is_empty():
				_add_finding(findings, "CATALOG_BLANK_EN", "ERROR", EN_CATALOG_PATH, 0, "English stable catalog value is blank.", logical_key)
			if chinese_text.is_empty():
				_add_finding(findings, "CATALOG_BLANK_ZH", "ERROR", ZH_CATALOG_PATH, 0, "Chinese stable catalog value is blank.", logical_key)
			if _contains_cjk(english_text):
				_add_finding(findings, "CATALOG_EN_CONTAINS_CJK", "ERROR", EN_CATALOG_PATH, 0, "English stable catalog value contains CJK text.", logical_key)
			if _format_signature(english_text) != _format_signature(chinese_text):
				_add_finding(findings, "FORMAT_SIGNATURE_MISMATCH", "ERROR", "<catalog>", 0, "English and Chinese placeholders differ.", "%s en=%s zh=%s" % [logical_key, str(_format_signature(english_text)), str(_format_signature(chinese_text))])


static func _scan_reference_coverage(references: Array[Dictionary], english: Dictionary, chinese: Dictionary, findings: Array) -> void:
	var seen := {}
	for reference in references:
		var section := str(reference.get("section", ""))
		var key := str(reference.get("key", ""))
		var identity := "%s.%s" % [section, key]
		if seen.has(identity):
			continue
		seen[identity] = true
		var english_section: Dictionary = english.get(section, {}) if english.get(section, {}) is Dictionary else {}
		var chinese_section: Dictionary = chinese.get(section, {}) if chinese.get(section, {}) is Dictionary else {}
		if not english_section.has(key) or str(english_section.get(key, "")).strip_edges().is_empty():
			_add_finding(findings, "STABLE_KEY_MISSING_EN", "ERROR", str(reference.get("path", "")), int(reference.get("line", 0)), "Referenced stable key has no non-empty English catalog value.", identity)
		if not chinese_section.has(key) or str(chinese_section.get(key, "")).strip_edges().is_empty():
			_add_finding(findings, "STABLE_KEY_MISSING_ZH", "ERROR", str(reference.get("path", "")), int(reference.get("line", 0)), "Referenced stable key has no non-empty Chinese catalog value.", identity)


static func _scan_catalog_terminology(catalog: Dictionary, locale: String, findings: Array, report: Dictionary) -> void:
	for section_value in STABLE_CATALOG_SECTIONS:
		var section := str(section_value)
		var values := _flatten_dictionary(catalog.get(section, {}))
		for key_value in values.keys():
			_scan_terminology_value(str(values[key_value]), locale, "<catalog:%s.%s>" % [section, str(key_value)], 0, findings, report)


static func _scan_terminology_value(value: String, locale: String, path: String, line: int, findings: Array, report: Dictionary) -> void:
	if value.is_empty():
		return
	if locale == "en" and _contains_cjk(value):
		report["terminology_count"] = int(report["terminology_count"]) + 1
		_add_finding(findings, "ENGLISH_TEXT_CONTAINS_CJK", "WARN", path, line, "English player text contains CJK and may be only partially localized.", _compact_evidence(value))
	if locale == "zh_CN" or locale == "source" and _contains_cjk(value):
		for rule_value in MIXED_CHINESE_TERM_RULES:
			var rule := rule_value as Dictionary
			if value.contains(str(rule.get("needle", ""))):
				report["terminology_count"] = int(report["terminology_count"]) + 1
				_add_finding(findings, "MIXED_CHINESE_TERM", "WARN", path, line, "%s；建议“%s”。" % [str(rule.get("reason", "术语不一致")), str(rule.get("preferred", ""))], _compact_evidence(value))
		for rule_value in CHINESE_TERM_RULES:
			var rule := rule_value as Dictionary
			if value.contains(str(rule.get("needle", ""))):
				report["terminology_count"] = int(report["terminology_count"]) + 1
				_add_finding(findings, "TERM_REVIEW", "REVIEW", path, line, "%s；优先使用“%s”，确属例外时记录上下文。" % [str(rule.get("reason", "术语需复核")), str(rule.get("preferred", ""))], _compact_evidence(value))


static func _read_catalog(path: String, locale: String, findings: Array[Dictionary]) -> Dictionary:
	if not FileAccess.file_exists(path):
		_add_finding(findings, "CATALOG_FILE_MISSING", "ERROR", path, 0, "Localization catalog file is missing.", locale)
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		_add_finding(findings, "CATALOG_JSON_INVALID", "ERROR", path, 0, "Localization catalog is not a JSON object.", locale)
		return {}
	return parsed as Dictionary


static func _collect_source_paths(root: String) -> Array[String]:
	var paths: Array[String] = []
	_collect_source_paths_recursive(root, paths)
	paths.sort()
	return paths


static func _collect_source_paths_recursive(root: String, paths: Array[String]) -> void:
	var directory := DirAccess.open(root)
	if directory == null:
		return
	directory.list_dir_begin()
	var name := directory.get_next()
	while not name.is_empty():
		if name != "." and name != "..":
			var child := root.path_join(name)
			if directory.current_is_dir():
				_collect_source_paths_recursive(child, paths)
			elif child.ends_with(".gd") or child.ends_with(".tscn"):
				paths.append(child)
		name = directory.get_next()
	directory.list_dir_end()


static func _flatten_dictionary(value: Variant, prefix: String = "") -> Dictionary:
	var result := {}
	if value is not Dictionary:
		return result
	var dictionary := value as Dictionary
	for key_value in dictionary.keys():
		var key := str(key_value)
		var logical_key := key if prefix.is_empty() else "%s.%s" % [prefix, key]
		var child: Variant = dictionary[key_value]
		if child is Dictionary:
			result.merge(_flatten_dictionary(child, logical_key), true)
		elif child is String:
			result[logical_key] = child
	return result


static func _format_signature(value: String) -> Array[String]:
	var signature: Array[String] = []
	var format_regex := _compile_regex("%[-+0-9.]*[sdf]")
	for match_value in format_regex.search_all(value.replace("%%", "")):
		signature.append(match_value.get_string())
	return signature


static func _is_stable_key(key: String) -> bool:
	if key.is_empty() or key.contains("%"):
		return false
	for index in key.length():
		var character := key.unicode_at(index)
		var allowed := character >= 0x30 and character <= 0x39 or character >= 0x41 and character <= 0x5a or character >= 0x61 and character <= 0x7a or character in [0x2d, 0x2e, 0x5f]
		if not allowed:
			return false
	return true


static func _looks_player_facing(value: String) -> bool:
	var stripped := value.strip_edges()
	if stripped.length() < 2 or stripped.begins_with("res://") or stripped.begins_with("user://") or stripped.contains("::"):
		return false
	if _contains_cjk(stripped):
		return true
	var has_lowercase := false
	var has_space := stripped.contains(" ")
	for index in stripped.length():
		var code := stripped.unicode_at(index)
		if code >= 0x61 and code <= 0x7a:
			has_lowercase = true
			break
	return has_lowercase and has_space and not stripped.begins_with("http")


static func _contains_cjk(value: String) -> bool:
	for index in value.length():
		var code := value.unicode_at(index)
		if code >= 0x3400 and code <= 0x9fff or code >= 0xf900 and code <= 0xfaff:
			return true
	return false


static func _compile_regex(pattern: String) -> RegEx:
	var regex := RegEx.new()
	var error := regex.compile(pattern)
	assert(error == OK, "Invalid UI localization audit regex: %s" % pattern)
	return regex


static func _compact_evidence(value: String) -> String:
	var compact := value.strip_edges().replace("\t", " ").replace("\n", " ")
	while compact.contains("  "):
		compact = compact.replace("  ", " ")
	return compact.left(180)


static func _add_finding(findings: Array, code: String, severity: String, path: String, line: int, message: String, evidence: String = "") -> void:
	findings.append({
		"code":code,
		"severity":severity,
		"path":path,
		"line":line,
		"message":message,
		"evidence":evidence,
	})


static func _finalize_report(report: Dictionary) -> void:
	var findings: Array = report.get("findings", [])
	findings.sort_custom(func(left, right):
		var left_row := left as Dictionary
		var right_row := right as Dictionary
		var left_key := "%d|%s|%s|%08d|%s" % [_severity_rank(str(left_row.get("severity", "REVIEW"))), str(left_row.get("code", "")), str(left_row.get("path", "")), int(left_row.get("line", 0)), str(left_row.get("evidence", ""))]
		var right_key := "%d|%s|%s|%08d|%s" % [_severity_rank(str(right_row.get("severity", "REVIEW"))), str(right_row.get("code", "")), str(right_row.get("path", "")), int(right_row.get("line", 0)), str(right_row.get("evidence", ""))]
		return left_key < right_key
	)
	var counts := {"ERROR":0, "WARN":0, "REVIEW":0}
	var runtime_missing_count := 0
	var catalog_parity_debt_count := 0
	for finding_value in findings:
		var finding := finding_value as Dictionary
		var severity := str(finding.get("severity", "REVIEW"))
		counts[severity] = int(counts.get(severity, 0)) + 1
		var code := str(finding.get("code", ""))
		if code.begins_with("STABLE_KEY_MISSING_") or code.begins_with("CATALOG_MISSING_") or code.begins_with("CATALOG_BLANK_") or code == "CATALOG_FILE_MISSING":
			runtime_missing_count += 1
		if code.begins_with("CATALOG_LEGACY_ONLY_"):
			catalog_parity_debt_count += 1
	report["counts"] = counts
	report["missing_count"] = runtime_missing_count
	report["runtime_missing_count"] = runtime_missing_count
	report["catalog_parity_debt_count"] = catalog_parity_debt_count
	report["findings"] = findings


static func _severity_rank(severity: String) -> int:
	if severity == "ERROR":
		return 0
	if severity == "WARN":
		return 1
	return 2
