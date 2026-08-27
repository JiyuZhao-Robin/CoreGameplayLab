class_name GameVersion
extends RefCounted

## Single source of truth for the standalone Lab product and save contract.
const PRODUCT_VERSION := "1.28.0-industrial-geography"
const SAVE_SCHEMA_VERSION := 34
const MIN_MIGRATABLE_SAVE_SCHEMA_VERSION := 24


static func can_migrate_save(schema_version: int) -> bool:
	return schema_version >= MIN_MIGRATABLE_SAVE_SCHEMA_VERSION and schema_version <= SAVE_SCHEMA_VERSION
