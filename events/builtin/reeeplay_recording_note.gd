class_name REEEplayRecordingNote
extends REEEplayEvent
## Developer, QA, or caster annotation attached to a specific replay tick.

var title: String = "Note"
var body: String = ""
var author: String = ""


func _init() -> void:
	type_id = &"REEEplayRecordingNote"
	category = &"note"
	importance = 0.5


func get_type_id() -> StringName:
	return &"REEEplayRecordingNote"


func get_timeline_label() -> String:
	return title if not title.is_empty() else "Note"


func get_timeline_color() -> Color:
	return Color(0.45, 0.9, 0.55, 1.0)


func strip_pii() -> void:
	super.strip_pii()
	author = ""


func _serialize(ser: REEEplaySerializer) -> void:
	ser.write_string(title)
	ser.write_string(body)
	ser.write_string(author)


func _deserialize(ser: REEEplaySerializer, _from_version: int) -> void:
	title = ser.read_string()
	body = ser.read_string()
	author = ser.read_string()

