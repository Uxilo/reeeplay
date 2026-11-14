class_name REEEplayMarkerEvent
extends REEEplayEvent
## Named bookmark / round / checkpoint marker on the replay timeline.

var marker_name: String = "Marker"
var color: Color = Color(1.0, 0.82, 0.2, 1.0)


func _init() -> void:
	type_id = &"REEEplayMarkerEvent"
	category = &"marker"
	importance = 2.0


func get_type_id() -> StringName:
	return &"REEEplayMarkerEvent"


func get_timeline_label() -> String:
	return marker_name if not marker_name.is_empty() else super.get_timeline_label()


func get_timeline_color() -> Color:
	return color


func _serialize(ser: REEEplaySerializer) -> void:
	ser.write_string(marker_name)
	ser.write_color(color)


func _deserialize(ser: REEEplaySerializer, _from_version: int) -> void:
	marker_name = ser.read_string()
	color = ser.read_color()
