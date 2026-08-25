class_name GameVersion
extends RefCounted

## Single source of truth for the standalone Lab product and save contract.
const PRODUCT_VERSION := "1.21.0-core-rules"
const SAVE_SCHEMA_VERSION := 27
const MIN_MIGRATABLE_SAVE_SCHEMA_VERSION := 24


static func can_migrate_save(schema_version: int) -> bool:
	return schema_version >= MIN_MIGRATABLE_SAVE_SCHEMA_VERSION and schema_version <= SAVE_SCHEMA_VERSION
