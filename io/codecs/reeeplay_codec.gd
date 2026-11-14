class_name REEEplayCodec
extends RefCounted
## Built-in binary channel codecs and comparison helpers for REEEplay.

enum Id {
	AUTO = 0,
	VARIANT = 1,
	BOOL = 2,
	INT_VAR = 3,
	F32 = 4,
	F16 = 5,
	VEC2_F32 = 6,
	VEC2_Q16 = 7,
	VEC3_F32 = 8,
	VEC3_Q16 = 9,
	QUAT_S3 = 10,
	ANGLE_U16 = 11,
	COLOR_RGBA8 = 12,
	STRING_REF = 13,
	TRANSFORM3D = 14,
	TRANSFORM2D = 15,
	SKELETON_POSE = 16,
}

const INV_SQRT2: float = 0.7071067811865476
const TAU_OVER_U16: float = TAU / 65535.0


## Resolves Id.AUTO to a concrete codec Id based on the sample Variant type.
static func resolve_auto_codec(sample: Variant, codec_id: int) -> int:
	if codec_id != Id.AUTO:
		return codec_id
	match typeof(sample):
		TYPE_BOOL:
			return Id.BOOL
		TYPE_INT:
			return Id.INT_VAR
		TYPE_FLOAT:
			return Id.F32
		TYPE_VECTOR2:
			return Id.VEC2_F32
		TYPE_VECTOR3:
			return Id.VEC3_F32
		TYPE_QUATERNION:
			return Id.QUAT_S3
		TYPE_COLOR:
			return Id.COLOR_RGBA8
		TYPE_STRING, TYPE_STRING_NAME:
			return Id.STRING_REF
		TYPE_TRANSFORM3D:
			return Id.TRANSFORM3D
		TYPE_TRANSFORM2D:
			return Id.TRANSFORM2D
		_:
			return Id.VARIANT


## Returns true if two values are equal within the effective epsilon for codec_id.
static func values_equal(a: Variant, b: Variant, epsilon: float = 0.0, codec_id: int = Id.AUTO) -> bool:
	if a == null and b == null:
		return true
	if a == null or b == null:
		return false

	var resolved := resolve_auto_codec(a, codec_id)
	match resolved:
		Id.BOOL, Id.INT_VAR:
			return a == b
		Id.STRING_REF:
			return StringName(a) == StringName(b)
		Id.F32, Id.F16:
			if typeof(a) != TYPE_FLOAT and typeof(a) != TYPE_INT:
				return false
			if typeof(b) != TYPE_FLOAT and typeof(b) != TYPE_INT:
				return false
			return absf(float(a) - float(b)) <= maxf(0.0, epsilon)
		Id.ANGLE_U16:
			if (typeof(a) != TYPE_FLOAT and typeof(a) != TYPE_INT) or (typeof(b) != TYPE_FLOAT and typeof(b) != TYPE_INT):
				return false
			return absf(angle_difference(float(a), float(b))) <= maxf(0.0, epsilon)
		Id.VEC2_F32, Id.VEC2_Q16:
			if typeof(a) != TYPE_VECTOR2 or typeof(b) != TYPE_VECTOR2:
				return false
			return (a as Vector2).distance_to(b as Vector2) <= maxf(0.0, epsilon)
		Id.VEC3_F32, Id.VEC3_Q16:
			if typeof(a) != TYPE_VECTOR3 or typeof(b) != TYPE_VECTOR3:
				return false
			return (a as Vector3).distance_to(b as Vector3) <= maxf(0.0, epsilon)
		Id.QUAT_S3:
			if typeof(a) != TYPE_QUATERNION or typeof(b) != TYPE_QUATERNION:
				return false
			var qa := (a as Quaternion).normalized()
			var qb := (b as Quaternion).normalized()
			return qa.angle_to(qb) <= maxf(0.0, epsilon)
		Id.COLOR_RGBA8:
			if typeof(a) != TYPE_COLOR or typeof(b) != TYPE_COLOR:
				return false
			var ca := a as Color
			var cb := b as Color
			if epsilon <= 0.0:
				return ca.r8 == cb.r8 and ca.g8 == cb.g8 and ca.b8 == cb.b8 and ca.a8 == cb.a8
			return maxf(
				maxf(absf(ca.r - cb.r), absf(ca.g - cb.g)),
				maxf(absf(ca.b - cb.b), absf(ca.a - cb.a))
			) <= epsilon
		Id.TRANSFORM3D:
			if typeof(a) != TYPE_TRANSFORM3D or typeof(b) != TYPE_TRANSFORM3D:
				return false
			var ta := a as Transform3D
			var tb := b as Transform3D
			var eps := maxf(0.0, epsilon)
			if ta.origin.distance_to(tb.origin) > eps:
				return false
			var ra := ta.basis.get_rotation_quaternion().normalized()
			var rb := tb.basis.get_rotation_quaternion().normalized()
			if ra.angle_to(rb) > eps:
				return false
			return ta.basis.get_scale().distance_to(tb.basis.get_scale()) <= eps
		Id.TRANSFORM2D:
			if typeof(a) != TYPE_TRANSFORM2D or typeof(b) != TYPE_TRANSFORM2D:
				return false
			var ta := a as Transform2D
			var tb := b as Transform2D
			var eps := maxf(0.0, epsilon)
			if ta.origin.distance_to(tb.origin) > eps:
				return false
			if absf(angle_difference(ta.get_rotation(), tb.get_rotation())) > eps:
				return false
			return ta.get_scale().distance_to(tb.get_scale()) <= eps
		Id.SKELETON_POSE:
			return _poses_equal(a, b, maxf(0.0, epsilon))
		_:
			return a == b


## Encodes a Variant channel value into buf using codec_id.
## string_table must be provided when using STRING_REF (or AUTO resolving to STRING_REF).
static func encode(
	buf: StreamPeerBuffer,
	value: Variant,
	codec_id: int,
	string_table: REEEplayByteUtils.StringTable = null,
	quantize_step: float = 0.001
) -> void:
	var resolved := resolve_auto_codec(value, codec_id)
	var step := quantize_step if quantize_step > 0.0 else 0.001
	match resolved:
		Id.BOOL:
			buf.put_u8(1 if bool(value) else 0)
		Id.INT_VAR:
			REEEplayByteUtils.put_varint(buf, int(value))
		Id.F32:
			buf.put_float(float(value))
		Id.F16:
			buf.put_u16(_float_to_f16(float(value)))
		Id.VEC2_F32:
			var v2 := value as Vector2
			buf.put_float(v2.x)
			buf.put_float(v2.y)
		Id.VEC2_Q16:
			var v2q := value as Vector2
			buf.put_16(clampi(roundi(v2q.x / step), -32767, 32767))
			buf.put_16(clampi(roundi(v2q.y / step), -32767, 32767))
		Id.VEC3_F32:
			var v3 := value as Vector3
			buf.put_float(v3.x)
			buf.put_float(v3.y)
			buf.put_float(v3.z)
		Id.VEC3_Q16:
			var v3q := value as Vector3
			buf.put_16(clampi(roundi(v3q.x / step), -32767, 32767))
			buf.put_16(clampi(roundi(v3q.y / step), -32767, 32767))
			buf.put_16(clampi(roundi(v3q.z / step), -32767, 32767))
		Id.QUAT_S3:
			buf.put_u32(_encode_quat_s3(value as Quaternion))
		Id.ANGLE_U16:
			var norm_angle := fposmod(float(value), TAU) / TAU
			buf.put_u16(clampi(roundi(norm_angle * 65535.0), 0, 65535))
		Id.COLOR_RGBA8:
			var c := value as Color
			buf.put_u8(clampi(c.r8, 0, 255))
			buf.put_u8(clampi(c.g8, 0, 255))
			buf.put_u8(clampi(c.b8, 0, 255))
			buf.put_u8(clampi(c.a8, 0, 255))
		Id.STRING_REF:
			assert(string_table != null, "REEEplayCodec: STRING_REF requires a StringTable")
			var idx := string_table.intern(StringName(value)) if string_table != null else 0
			REEEplayByteUtils.put_varuint(buf, idx)
		Id.TRANSFORM3D:
			var t3 := value as Transform3D
			buf.put_float(t3.origin.x)
			buf.put_float(t3.origin.y)
			buf.put_float(t3.origin.z)
			var q3 := t3.basis.get_rotation_quaternion().normalized()
			buf.put_u32(_encode_quat_s3(q3))
			var s3 := t3.basis.get_scale()
			var has_scale := not s3.is_equal_approx(Vector3.ONE)
			buf.put_u8(1 if has_scale else 0)
			if has_scale:
				buf.put_float(s3.x)
				buf.put_float(s3.y)
				buf.put_float(s3.z)
		Id.TRANSFORM2D:
			var t2 := value as Transform2D
			buf.put_float(t2.origin.x)
			buf.put_float(t2.origin.y)
			buf.put_float(t2.get_rotation())
			var s2 := t2.get_scale()
			var skew2 := t2.get_skew()
			var flags := 0
			if not s2.is_equal_approx(Vector2.ONE):
				flags |= 1
			if not is_zero_approx(skew2):
				flags |= 2
			buf.put_u8(flags)
			if (flags & 1) != 0:
				buf.put_float(s2.x)
				buf.put_float(s2.y)
			if (flags & 2) != 0:
				buf.put_float(skew2)
		Id.SKELETON_POSE:
			_encode_skeleton_pose(buf, value)
		_:
			# VARIANT fallback: never allow object serialization.
			var raw := var_to_bytes(value)
			REEEplayByteUtils.put_varuint(buf, raw.size())
			if not raw.is_empty():
				buf.put_data(raw)


## Decodes a Variant channel value from buf using a concrete codec_id.
static func decode(
	buf: StreamPeerBuffer,
	codec_id: int,
	string_table: REEEplayByteUtils.StringTable = null,
	quantize_step: float = 0.001
) -> Variant:
	var step := quantize_step if quantize_step > 0.0 else 0.001
	match codec_id:
		Id.BOOL:
			return buf.get_u8() != 0
		Id.INT_VAR:
			return REEEplayByteUtils.get_varint(buf)
		Id.F32:
			return buf.get_float()
		Id.F16:
			return _f16_to_float(buf.get_u16())
		Id.VEC2_F32:
			var x := buf.get_float()
			var y := buf.get_float()
			return Vector2(x, y)
		Id.VEC2_Q16:
			var qx := buf.get_16()
			var qy := buf.get_16()
			return Vector2(float(qx) * step, float(qy) * step)
		Id.VEC3_F32:
			var x := buf.get_float()
			var y := buf.get_float()
			var z := buf.get_float()
			return Vector3(x, y, z)
		Id.VEC3_Q16:
			var qx := buf.get_16()
			var qy := buf.get_16()
			var qz := buf.get_16()
			return Vector3(float(qx) * step, float(qy) * step, float(qz) * step)
		Id.QUAT_S3:
			return _decode_quat_s3(buf.get_u32())
		Id.ANGLE_U16:
			return float(buf.get_u16()) * TAU_OVER_U16
		Id.COLOR_RGBA8:
			var r := float(buf.get_u8()) / 255.0
			var g := float(buf.get_u8()) / 255.0
			var b := float(buf.get_u8()) / 255.0
			var a := float(buf.get_u8()) / 255.0
			return Color(r, g, b, a)
		Id.STRING_REF:
			var idx := REEEplayByteUtils.get_varuint(buf)
			if string_table == null or idx < 0:
				return &""
			return string_table.get_string(idx)
		Id.TRANSFORM3D:
			var origin := Vector3(buf.get_float(), buf.get_float(), buf.get_float())
			var rot := _decode_quat_s3(buf.get_u32())
			var has_scale := buf.get_u8() != 0
			var basis := Basis(rot)
			if has_scale:
				var scl := Vector3(buf.get_float(), buf.get_float(), buf.get_float())
				basis = basis.scaled_local(scl)
			return Transform3D(basis, origin)
		Id.TRANSFORM2D:
			var origin := Vector2(buf.get_float(), buf.get_float())
			var rot := buf.get_float()
			var flags := buf.get_u8()
			var scl := Vector2.ONE
			var skew_val := 0.0
			if (flags & 1) != 0:
				scl = Vector2(buf.get_float(), buf.get_float())
			if (flags & 2) != 0:
				skew_val = buf.get_float()
			return Transform2D(rot, scl, skew_val, origin)
		Id.SKELETON_POSE:
			return _decode_skeleton_pose(buf)
		_:
			var byte_len := REEEplayByteUtils.get_varuint(buf)
			if byte_len <= 0 or byte_len > 16777216:
				return null
			var res := buf.get_data(byte_len)
			if res[0] != OK:
				return null
			var raw: PackedByteArray = res[1]
			# bytes_to_var (unlike bytes_to_var_with_objects) never decodes Objects.
			return bytes_to_var(raw)


static func _encode_quat_s3(q_in: Quaternion) -> int:
	var q := q_in.normalized()
	var c := [q.x, q.y, q.z, q.w]
	var max_idx := 0
	var max_abs := absf(c[0])
	for i in range(1, 4):
		var a := absf(c[i])
		if a > max_abs:
			max_abs = a
			max_idx = i

	if c[max_idx] < 0.0:
		for i in range(4):
			c[i] = -c[i]

	var packed := max_idx & 0x3
	var shift := 2
	for i in range(4):
		if i == max_idx:
			continue
		var norm := clampf((c[i] + INV_SQRT2) / (2.0 * INV_SQRT2), 0.0, 1.0)
		var q10 := clampi(roundi(norm * 1023.0), 0, 1023)
		packed |= (q10 << shift)
		shift += 10
	return packed


static func _decode_quat_s3(packed: int) -> Quaternion:
	var max_idx := packed & 0x3
	var c := [0.0, 0.0, 0.0, 0.0]
	var shift := 2
	var sq_sum := 0.0
	for i in range(4):
		if i == max_idx:
			continue
		var q10 := (packed >> shift) & 0x3FF
		shift += 10
		var v := (float(q10) / 1023.0) * (2.0 * INV_SQRT2) - INV_SQRT2
		c[i] = v
		sq_sum += v * v
	c[max_idx] = sqrt(maxf(0.0, 1.0 - sq_sum))
	return Quaternion(c[0], c[1], c[2], c[3]).normalized()


static func _encode_skeleton_pose(buf: StreamPeerBuffer, value: Variant) -> void:
	var poses: Array = value if value is Array else []
	REEEplayByteUtils.put_varuint(buf, poses.size())
	for item in poses:
		var t3: Transform3D = item if item is Transform3D else Transform3D.IDENTITY
		buf.put_float(t3.origin.x)
		buf.put_float(t3.origin.y)
		buf.put_float(t3.origin.z)
		buf.put_u32(_encode_quat_s3(t3.basis.get_rotation_quaternion()))
		var scl := t3.basis.get_scale()
		var has_scale := not scl.is_equal_approx(Vector3.ONE)
		buf.put_u8(1 if has_scale else 0)
		if has_scale:
			buf.put_float(scl.x)
			buf.put_float(scl.y)
			buf.put_float(scl.z)


static func _decode_skeleton_pose(buf: StreamPeerBuffer) -> Array[Transform3D]:
	var count := REEEplayByteUtils.get_varuint(buf)
	var out: Array[Transform3D] = []
	if count <= 0 or count > 4096:
		return out
	out.resize(count)
	for i in range(count):
		var origin := Vector3(buf.get_float(), buf.get_float(), buf.get_float())
		var rot := _decode_quat_s3(buf.get_u32())
		var has_scale := buf.get_u8() != 0
		var basis := Basis(rot)
		if has_scale:
			var scl := Vector3(buf.get_float(), buf.get_float(), buf.get_float())
			basis = basis.scaled_local(scl)
		out[i] = Transform3D(basis, origin)
	return out


static func _poses_equal(a: Variant, b: Variant, epsilon: float) -> bool:
	if not (a is Array) or not (b is Array):
		return false
	var aa: Array = a
	var bb: Array = b
	if aa.size() != bb.size():
		return false
	for i in range(aa.size()):
		if not values_equal(aa[i], bb[i], epsilon, Id.TRANSFORM3D):
			return false
	return true


static func _float_to_f16(value: float) -> int:
	# Convert float32 bit pattern (via StreamPeerBuffer or manual IEEE 754) to binary16.
	var tmp := StreamPeerBuffer.new()
	tmp.big_endian = false
	tmp.put_float(value)
	tmp.seek(0)
	var bits := tmp.get_u32()
	var sign := (bits >> 16) & 0x8000
	var exp := ((bits >> 23) & 0xFF) - 127 + 15
	var mant := bits & 0x7FFFFF
	if ((bits >> 23) & 0xFF) == 0xFF:
		# Inf or NaN
		if mant != 0:
			return sign | 0x7E00
		return sign | 0x7C00
	if exp <= 0:
		if exp < -10:
			return sign
		mant = (mant | 0x800000) >> (1 - exp)
		return sign | (mant >> 13)
	if exp >= 31:
		return sign | 0x7C00
	return sign | (exp << 10) | (mant >> 13)


static func _f16_to_float(h: int) -> float:
	var sign := (h & 0x8000) << 16
	var exp := (h >> 10) & 0x1F
	var mant := h & 0x3FF
	var bits := 0
	if exp == 0:
		if mant == 0:
			bits = sign
		else:
			# Subnormal
			var e := 127 - 15 + 1
			while (mant & 0x400) == 0:
				mant <<= 1
				e -= 1
			mant &= 0x3FF
			bits = sign | (e << 23) | (mant << 13)
	elif exp == 31:
		bits = sign | 0x7F800000 | (mant << 13)
	else:
		bits = sign | ((exp - 15 + 127) << 23) | (mant << 13)

	var tmp := StreamPeerBuffer.new()
	tmp.big_endian = false
	tmp.put_u32(bits)
	tmp.seek(0)
	return tmp.get_float()
