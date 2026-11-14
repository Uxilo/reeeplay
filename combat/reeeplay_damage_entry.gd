class_name REEEplayDamageEntry
extends REEEplayEvent
## Recorded damage or healing hit entry synchronized with both the event timeline and REEEplayDamageLog.

var hit_id: int = 0
var amount: float = 0.0
var raw_amount: float = 0.0
var absorbed: float = 0.0
var damage_type: StringName = &"physical"
var source_name: String = ""
var hit_zone: StringName = &""
var is_critical: bool = false
var is_killing_blow: bool = false
var is_heal: bool = false
var victim_hp_before: float = 0.0
var victim_hp_after: float = 0.0

## Alias property forwarding to REEEplayEvent.actor.
var attacker: REEEplayActorRef:
	get:
		return actor
	set(value):
		actor = value
		if value != null:
			entity_id = value.entity_id

## Alias property forwarding to REEEplayEvent.target.
var victim: REEEplayActorRef:
	get:
		return target
	set(value):
		target = value
		if value != null:
			secondary_entity_id = value.entity_id


func _init() -> void:
	type_id = &"REEEplayDamageEntry"
	category = &"combat"
	importance = 1.5


func get_type_id() -> StringName:
	return &"REEEplayDamageEntry"


func get_timeline_label() -> String:
	var verb := "healed" if is_heal else "hit"
	var a_name := actor.display_name if actor != null and not actor.display_name.is_empty() else "World"
	var v_name := target.display_name if target != null and not target.display_name.is_empty() else "Target"
	return "%s %s %s (%.1f %s)" % [a_name, verb, v_name, amount, String(damage_type)]


func get_timeline_color() -> Color:
	if is_heal:
		return Color(0.25, 0.85, 0.45, 1.0)
	if is_killing_blow:
		return Color(1.0, 0.18, 0.18, 1.0)
	if is_critical:
		return Color(1.0, 0.65, 0.15, 1.0)
	return Color(0.92, 0.35, 0.32, 1.0)


func _serialize(ser: REEEplaySerializer) -> void:
	ser.write_uint(maxi(0, hit_id))
	ser.write_float(amount)
	ser.write_float(raw_amount)
	ser.write_float(absorbed)
	ser.write_string_name(damage_type)
	ser.write_string(source_name)
	ser.write_string_name(hit_zone)
	var bits := 0
	if is_critical:
		bits |= 1
	if is_killing_blow:
		bits |= 2
	if is_heal:
		bits |= 4
	ser.write_uint(bits)
	ser.write_float(victim_hp_before)
	ser.write_float(victim_hp_after)


func _deserialize(ser: REEEplaySerializer, _from_version: int) -> void:
	hit_id = ser.read_uint()
	amount = ser.read_float()
	raw_amount = ser.read_float()
	absorbed = ser.read_float()
	damage_type = ser.read_string_name()
	source_name = ser.read_string()
	hit_zone = ser.read_string_name()
	var bits := ser.read_uint()
	is_critical = (bits & 1) != 0
	is_killing_blow = (bits & 2) != 0
	is_heal = (bits & 4) != 0
	victim_hp_before = ser.read_float()
	victim_hp_after = ser.read_float()
