class_name REEEplayInterpolator
extends RefCounted
## Type-aware channel interpolation utilities for REEEplay playback.


static func interpolate_value(
	a: Variant,
	b: Variant,
	alpha: float,
	codec_id: int = REEEplayCodec.Id.AUTO,
	allow_interpolate: bool = true
) -> Variant:
	if a == null:
		return b
	if b == null or not allow_interpolate or alpha <= 0.0:
		return a
	if alpha >= 1.0:
		return b

	var resolved := REEEplayCodec.resolve_auto_codec(a, codec_id)
	match resolved:
		REEEplayCodec.Id.BOOL, REEEplayCodec.Id.INT_VAR, REEEplayCodec.Id.STRING_REF:
			return a
		REEEplayCodec.Id.F32, REEEplayCodec.Id.F16:
			if (a is float or a is int) and (b is float or b is int):
				return lerpf(float(a), float(b), alpha)
			return a
		REEEplayCodec.Id.ANGLE_U16:
			if (a is float or a is int) and (b is float or b is int):
				return lerp_angle(float(a), float(b), alpha)
			return a
		REEEplayCodec.Id.VEC2_F32, REEEplayCodec.Id.VEC2_Q16:
			if a is Vector2 and b is Vector2:
				return (a as Vector2).lerp(b as Vector2, alpha)
			return a
		REEEplayCodec.Id.VEC3_F32, REEEplayCodec.Id.VEC3_Q16:
			if a is Vector3 and b is Vector3:
				return (a as Vector3).lerp(b as Vector3, alpha)
			return a
		REEEplayCodec.Id.QUAT_S3:
			if a is Quaternion and b is Quaternion:
				return (a as Quaternion).normalized().slerp((b as Quaternion).normalized(), alpha)
			return a
		REEEplayCodec.Id.COLOR_RGBA8:
			if a is Color and b is Color:
				return (a as Color).lerp(b as Color, alpha)
			return a
		REEEplayCodec.Id.TRANSFORM3D:
			if a is Transform3D and b is Transform3D:
				return (a as Transform3D).interpolate_with(b as Transform3D, alpha)
			return a
		REEEplayCodec.Id.TRANSFORM2D:
			if a is Transform2D and b is Transform2D:
				return (a as Transform2D).interpolate_with(b as Transform2D, alpha)
			return a
		REEEplayCodec.Id.SKELETON_POSE:
			if a is Array and b is Array:
				return _interpolate_skeleton_pose(a as Array, b as Array, alpha)
			return a
		_:
			return a


static func _interpolate_skeleton_pose(a: Array, b: Array, alpha: float) -> Array[Transform3D]:
	var count := mini(a.size(), b.size())
	var out: Array[Transform3D] = []
	out.resize(count)
	for i in range(count):
		if a[i] is Transform3D and b[i] is Transform3D:
			out[i] = (a[i] as Transform3D).interpolate_with(b[i] as Transform3D, alpha)
		else:
			out[i] = a[i] if a[i] is Transform3D else Transform3D.IDENTITY
	return out

