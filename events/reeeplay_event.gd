@abstract
class_name REEEplayEvent
extends RefCounted
## Base class for semantic timeline events recorded alongside entity state frames.

const _BASE_PROPS: Dictionary[StringName, bool] = {
	&"event_id": true,
	&"type_id": true,
	&"schema_version": true,
	&"tick": true,
	&"timestamp": true,
	&"entity_id": true,
	&"secondary_entity_id": true,
	&"actor": true,
	&"target": true,
	&"position": true,
	&"category": true,
	&"label": true,
	&"tags": true,
	&"importance": true,
	&"is_timeline_visible": true,
	&"script": true,
}

var event_id: int = 0
var type_id: StringName = &""
var schema_version: int = 1
var tick: int = 0
var timestamp: float = 0.0
var entity_id: int = 0
var secondary_entity_id: int = 0
var actor: REEEplayActorRef = null
var target: REEEplayActorRef = null
var position: Variant = null
var category: StringName = &"gameplay"
var label: String = ""
var tags: Array[StringName] = []
var importance: float = 1.0
var is_timeline_visible: bool = true


## Returns the stable registry type identifier for this event class.
func get_type_id() -> StringName:
	if type_id != &"":
		return type_id
	var scr := get_script() as Script
	if scr != null:
		var gname := scr.get_global_name()
		if gname != &"":
			return gname
	return &"REEEplayEvent"


## Override in versioned subclasses when payload fields evolve across releases.
func get_schema_version() -> int:
	return schema_version


func get_timeline_label() -> String:
	return label if not label.is_empty() else String(get_type_id())


func get_timeline_color() -> Color:
	return Color(0.28, 0.72, 1.0, 1.0)


func highlight_weight() -> float:
	return importance


func highlight_tags() -> Array[StringName]:
	return tags


## Override to anonymize PII before sharing replays.
func strip_pii() -> void:
	if actor != null:
		actor = actor.anonymized()
	if target != null:
		target = target.anonymized()


## Serializes subclass-specific payload fields. Defaults to exporting non-base script variables.
func _serialize(ser: REEEplaySerializer) -> void:
	ser.write_variant(_export_script_data())


## Deserializes subclass-specific payload fields, invoking _migrate() when schema versions differ.
func _deserialize(ser: REEEplaySerializer, from_version: int) -> void:
	var data_var: Variant = ser.read_variant()
	if data_var is Dictionary:
		var data: Dictionary = data_var
		var target_ver := get_schema_version()
		if from_version != target_ver:
			data = _migrate(data, from_version, target_ver)
		_import_script_data(data)


## Override to upgrade dictionary payloads serialized by older schema versions.
func _migrate(data: Dictionary, _from_version: int, _to_version: int) -> Dictionary:
	return data


func _export_script_data() -> Dictionary:
	var out: Dictionary = {}
	for prop in get_property_list():
		var usage := int(prop["usage"])
		if (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) == 0:
			continue
		var pname := StringName(prop["name"])
		if _BASE_PROPS.has(pname) or String(pname).begins_with("_"):
			continue
		var val: Variant = get(pname)
		if val is Object:
			continue
		out[String(pname)] = val
	return out


func _import_script_data(data: Dictionary) -> void:
	for key in data:
		var pname := StringName(key)
		if _BASE_PROPS.has(pname):
			continue
		set(pname, data[key])
