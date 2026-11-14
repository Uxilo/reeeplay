class_name REEEplayUnknownEvent
extends REEEplayEvent
## Lossless placeholder created when loading a replay containing an unregistered event type_id.

var original_type_id: StringName = &""
var original_schema_version: int = 1
var raw_payload: PackedByteArray = PackedByteArray()


func get_type_id() -> StringName:
	return original_type_id if original_type_id != &"" else &"REEEplayUnknownEvent"


func get_schema_version() -> int:
	return original_schema_version


func get_timeline_label() -> String:
	return "[Unknown: %s]" % String(get_type_id())


func get_timeline_color() -> Color:
	return Color(0.6, 0.6, 0.6, 0.85)

