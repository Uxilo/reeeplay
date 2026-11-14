@abstract
class_name REEEplayAttachment
extends RefCounted
## Base class for sparse/large data blobs attached to a REEEplay recording or timeline tick.

const _BASE_PROPS: Dictionary[StringName, bool] = {
	&"attachment_id": true,
	&"type_id": true,
	&"schema_version": true,
	&"tick": true,
	&"entity_id": true,
	&"label": true,
	&"script": true,
}

var attachment_id: int = 0
var type_id: StringName = &""
var schema_version: int = 1
var tick: int = 0
var entity_id: int = 0
var label: String = ""


func get_type_id() -> StringName:
	if type_id != &"":
		return type_id
	var scr := get_script() as Script
	if scr != null:
		var gname := scr.get_global_name()
		if gname != &"":
			return gname
	return &"REEEplayAttachment"


func get_schema_version() -> int:
	return schema_version


func _serialize(ser: REEEplaySerializer) -> void:
	ser.write_variant(_export_script_data())


func _deserialize(ser: REEEplaySerializer, from_version: int) -> void:
	var data_var: Variant = ser.read_variant()
	if data_var is Dictionary:
		var data: Dictionary = data_var
		var target_ver := get_schema_version()
		if from_version != target_ver:
			data = _migrate(data, from_version, target_ver)
		_import_script_data(data)


func _migrate(data: Dictionary, _from_version: int, _to_version: int) -> Dictionary:
	return data


func strip_pii() -> void:
	pass


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
