class_name ModifierEngine
extends RefCounted


func evaluate(base_value: float, target: String, modifiers: Array, integer_result: bool = false) -> float:
	var matching: Array = []
	for modifier in modifiers:
		if modifier.get("target", "") == target and _condition_met(modifier.get("condition", true)):
			matching.append(modifier)
	matching.sort_custom(_sort_modifier)
	var value := base_value
	for modifier in matching:
		if modifier.get("operation", "") == "ADD":
			value += float(modifier.get("value", 0))
	for modifier in matching:
		if modifier.get("operation", "") == "MULTIPLY":
			value *= float(modifier.get("value", 1))
	var override_found := false
	for modifier in matching:
		if modifier.get("operation", "") == "OVERRIDE":
			value = float(modifier.get("value", value))
			override_found = true
	if override_found:
		pass
	for modifier in matching:
		if modifier.has("min"):
			value = maxf(value, float(modifier["min"]))
		if modifier.has("max"):
			value = minf(value, float(modifier["max"]))
	return roundf(value) if integer_result else value


func validate(modifiers: Array) -> Array[String]:
	var errors: Array[String] = []
	var overrides := {}
	for modifier in modifiers:
		if modifier.get("operation", "") != "OVERRIDE":
			continue
		var key := "%s@%d" % [modifier.get("target", ""), int(modifier.get("priority", 0))]
		if overrides.has(key):
			errors.append("Conflicting OVERRIDE modifiers for %s" % key)
		overrides[key] = true
	return errors


func _condition_met(condition: Variant) -> bool:
	return bool(condition)


func _sort_modifier(a: Dictionary, b: Dictionary) -> bool:
	var priority_a := int(a.get("priority", 0))
	var priority_b := int(b.get("priority", 0))
	if priority_a == priority_b:
		return str(a.get("source_id", "")) < str(b.get("source_id", ""))
	return priority_a < priority_b
