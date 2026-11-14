class_name REEEplaySerializer
extends RefCounted
## Versioned binary serialization helper passed to REEEplayEvent, REEEplayCue, and REEEplayAttachment.

var buffer: StreamPeerBuffer
var string_table: REEEplayByteUtils.StringTable
var is_writing: bool = true
var schema_version: int = 1


func _init(
	p_is_writing: bool = true,
	p_data: PackedByteArray = PackedByteArray(),
	p_string_table: REEEplayByteUtils.StringTable = null,
	p_schema_version: int = 1
) -> void:
	is_writing = p_is_writing
	string_table = p_string_table
	schema_version = p_schema_version
	buffer = StreamPeerBuffer.new()
	buffer.big_endian = false
	if not p_is_writing:
		buffer.data_array = p_data
		buffer.seek(0)


func to_bytes() -> PackedByteArray:
	return buffer.data_array


func get_available_bytes() -> int:
	return buffer.get_available_bytes()


func write_bool(v: bool) -> void:
	buffer.put_u8(1 if v else 0)


func read_bool() -> bool:
	return buffer.get_u8() != 0 if buffer.get_available_bytes() >= 1 else false


func write_int(v: int) -> void:
	REEEplayByteUtils.put_varint(buffer, v)


func read_int() -> int:
	return REEEplayByteUtils.get_varint(buffer)


func write_uint(v: int) -> void:
	REEEplayByteUtils.put_varuint(buffer, v)


func read_uint() -> int:
	return REEEplayByteUtils.get_varuint(buffer)


func write_float(v: float) -> void:
	buffer.put_float(v)


func read_float() -> float:
	return buffer.get_float() if buffer.get_available_bytes() >= 4 else 0.0


func write_string(v: String) -> void:
	REEEplayByteUtils.put_utf8(buffer, v)


func read_string() -> String:
	return REEEplayByteUtils.get_utf8(buffer)


func write_string_name(v: StringName) -> void:
	if string_table != null:
		REEEplayByteUtils.put_varuint(buffer, string_table.intern(v))
	else:
		REEEplayByteUtils.put_utf8(buffer, String(v))


func read_string_name() -> StringName:
	if string_table != null:
		var idx := REEEplayByteUtils.get_varuint(buffer)
		return string_table.get_string(idx) if idx >= 0 else &""
	return StringName(REEEplayByteUtils.get_utf8(buffer))


func write_vec2(v: Vector2) -> void:
	buffer.put_float(v.x)
	buffer.put_float(v.y)


func read_vec2() -> Vector2:
	if buffer.get_available_bytes() < 8:
		return Vector2.ZERO
	return Vector2(buffer.get_float(), buffer.get_float())


func write_vec3(v: Vector3) -> void:
	buffer.put_float(v.x)
	buffer.put_float(v.y)
	buffer.put_float(v.z)


func read_vec3() -> Vector3:
	if buffer.get_available_bytes() < 12:
		return Vector3.ZERO
	return Vector3(buffer.get_float(), buffer.get_float(), buffer.get_float())


func write_quat(v: Quaternion) -> void:
	REEEplayCodec.encode(buffer, v, REEEplayCodec.Id.QUAT_S3)


func read_quat() -> Quaternion:
	if buffer.get_available_bytes() < 4:
		return Quaternion.IDENTITY
	return REEEplayCodec.decode(buffer, REEEplayCodec.Id.QUAT_S3) as Quaternion


func write_color(v: Color) -> void:
	REEEplayCodec.encode(buffer, v, REEEplayCodec.Id.COLOR_RGBA8)


func read_color() -> Color:
	if buffer.get_available_bytes() < 4:
		return Color.WHITE
	return REEEplayCodec.decode(buffer, REEEplayCodec.Id.COLOR_RGBA8) as Color


func write_transform3d(v: Transform3D) -> void:
	REEEplayCodec.encode(buffer, v, REEEplayCodec.Id.TRANSFORM3D)


func read_transform3d() -> Transform3D:
	return REEEplayCodec.decode(buffer, REEEplayCodec.Id.TRANSFORM3D) as Transform3D


func write_actor(actor: REEEplayActorRef) -> void:
	if actor == null:
		buffer.put_u8(0)
	else:
		buffer.put_u8(1)
		actor.serialize(buffer, string_table)


func read_actor() -> REEEplayActorRef:
	if buffer.get_available_bytes() < 1:
		return null
	if buffer.get_u8() == 0:
		return null
	return REEEplayActorRef.deserialize(buffer, string_table)


func write_bytes(bytes: PackedByteArray) -> void:
	REEEplayByteUtils.put_varuint(buffer, bytes.size())
	if not bytes.is_empty():
		buffer.put_data(bytes)


func read_bytes(max_bytes: int = 16777216) -> PackedByteArray:
	var length := REEEplayByteUtils.get_varuint(buffer)
	if length <= 0 or length > max_bytes or length > buffer.get_available_bytes():
		return PackedByteArray()
	var res := buffer.get_data(length)
	if res[0] != OK:
		return PackedByteArray()
	return res[1] as PackedByteArray


## Serializes a Variant safely WITHOUT object encoding.
func write_variant(v: Variant) -> void:
	var raw := var_to_bytes(v)
	write_bytes(raw)


## Deserializes a Variant safely WITHOUT allowing Object decoding.
func read_variant() -> Variant:
	var raw := read_bytes()
	if raw.is_empty():
		return null
	return bytes_to_var(raw)
