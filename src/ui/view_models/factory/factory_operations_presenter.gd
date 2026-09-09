class_name FactoryOperationsPresenter
extends RefCounted

## Factory Operations v1 presentation adapter. It only reads a supplied
## Factory snapshot: Game and simulation authority remain unreachable here.

const SCHEMA_VERSION := 1
const OperationsProjection = preload("res://src/core/factory_operations_projection.gd")


func build(snapshot: Dictionary) -> Dictionary:
	var extension: Dictionary = snapshot.get("operations", {}) as Dictionary if snapshot.get("operations", {}) is Dictionary else {}
	var has_extension := int(extension.get("schema_version", 0)) == SCHEMA_VERSION
	# The application-provided v1 extension is authoritative, even when a
	# collection is empty. Legacy snapshots use the same pure projection as the
	# application rather than a UI-side approximation of inventory or deficits.
	var source: Dictionary = extension if has_extension else OperationsProjection.build(snapshot)
	return {
		"available":has_extension,
		"schema_version":SCHEMA_VERSION,
		"metrics":(source.get("metrics", {}) as Dictionary).duplicate(true),
		"stages":(source.get("stages", []) as Array).duplicate(true),
		"alerts":(source.get("alerts", []) as Array).duplicate(true),
		"materials":(source.get("materials", []) as Array).duplicate(true),
		"build_plans":(source.get("build_plans", []) as Array).duplicate(true)
	}
