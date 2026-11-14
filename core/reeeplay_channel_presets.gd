class_name REEEplayChannelPresets
extends RefCounted
## Factory helpers returning common channel bundles for Godot node types.


static func transform_3d(
	vec_codec: REEEplayCodec.Id = REEEplayCodec.Id.VEC3_Q16,
	pos_epsilon: float = 0.001,
	rot_epsilon: float = 0.002,
	quantize_step: float = 0.005
) -> Array[REEEplayChannel]:
	var rot_ch := REEEplayChannel.create(
		"global_rotation",
		REEEplayCodec.Id.QUAT_S3,
		rot_epsilon,
		true,
		&"rotation"
	)
	rot_ch.getter = func(node: Node) -> Variant:
		var n3 := node as Node3D
		if n3 == null:
			return Quaternion.IDENTITY
		var b := n3.global_basis if n3.is_inside_tree() else n3.basis
		return b.get_rotation_quaternion()
	rot_ch.setter = func(proxy: Node, val: Variant) -> void:
		var p3 := proxy as Node3D
		if p3 != null and val is Quaternion:
			if p3.is_inside_tree():
				var scl := p3.global_basis.get_scale()
				p3.global_basis = Basis(val as Quaternion).scaled_local(scl)
			else:
				var scl := p3.basis.get_scale()
				p3.basis = Basis(val as Quaternion).scaled_local(scl)

	return [
		REEEplayChannel.create("global_position", vec_codec, pos_epsilon, true, &"position", quantize_step),
		rot_ch,
	]


static func transform_3d_full(pos_epsilon: float = 0.001) -> Array[REEEplayChannel]:
	return [
		REEEplayChannel.create("global_transform", REEEplayCodec.Id.TRANSFORM3D, pos_epsilon, true, &"transform"),
	]


static func transform_2d(
	vec_codec: REEEplayCodec.Id = REEEplayCodec.Id.VEC2_Q16,
	pos_epsilon: float = 0.05,
	rot_epsilon: float = 0.002,
	quantize_step: float = 0.05
) -> Array[REEEplayChannel]:
	return [
		REEEplayChannel.create("global_position", vec_codec, pos_epsilon, true, &"position", quantize_step),
		REEEplayChannel.create("global_rotation", REEEplayCodec.Id.ANGLE_U16, rot_epsilon, true, &"rotation"),
	]


static func visibility() -> Array[REEEplayChannel]:
	return [
		REEEplayChannel.create("visible", REEEplayCodec.Id.BOOL, 0.0, false, &"visible"),
	]


static func velocity_3d(epsilon: float = 0.05) -> Array[REEEplayChannel]:
	return [
		REEEplayChannel.create("velocity", REEEplayCodec.Id.VEC3_F32, epsilon, true, &"velocity"),
	]


static func velocity_2d(epsilon: float = 0.5) -> Array[REEEplayChannel]:
	return [
		REEEplayChannel.create("linear_velocity", REEEplayCodec.Id.VEC2_F32, epsilon, true, &"velocity"),
	]


static func camera_3d() -> Array[REEEplayChannel]:
	var chs := transform_3d(REEEplayCodec.Id.VEC3_F32, 0.001, 0.001)
	chs.append(REEEplayChannel.create("fov", REEEplayCodec.Id.F32, 0.05, true, &"fov"))
	return chs


static func camera_2d() -> Array[REEEplayChannel]:
	var chs := transform_2d(REEEplayCodec.Id.VEC2_F32, 0.05, 0.001)
	chs.append(REEEplayChannel.create("zoom", REEEplayCodec.Id.VEC2_F32, 0.002, true, &"zoom"))
	return chs


static func skeleton_pose() -> Array[REEEplayChannel]:
	var ch := REEEplayChannel.create("pose", REEEplayCodec.Id.SKELETON_POSE, 0.002, true, &"skeleton_pose")
	ch.getter = func(node: Node) -> Variant:
		var skel := node as Skeleton3D
		if skel == null:
			return []
		var out: Array[Transform3D] = []
		var count := skel.get_bone_count()
		out.resize(count)
		for i in range(count):
			out[i] = skel.get_bone_pose(i)
		return out
	ch.setter = func(proxy: Node, val: Variant) -> void:
		var skel := proxy as Skeleton3D
		if skel == null or not (val is Array):
			return
		var poses: Array = val
		var count := mini(skel.get_bone_count(), poses.size())
		for i in range(count):
			if poses[i] is Transform3D:
				skel.set_bone_pose(i, poses[i] as Transform3D)
	return [ch]
