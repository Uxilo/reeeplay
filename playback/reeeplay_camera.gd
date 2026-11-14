class_name REEEplayCamera
extends Node3D
## Multi-mode replay spectator camera supporting free-fly, follow, orbit, and recorded POV tracking.

enum Mode {
	FREE_FLY = 0,
	FOLLOW = 1,
	ORBIT = 2,
	RECORDED_POV = 3,
}

@export var mode: Mode = Mode.ORBIT
@export var target_entity_id: int = 0
@export var follow_offset: Vector3 = Vector3(0.0, 3.0, 6.0)
@export var orbit_distance: float = 6.0
@export var orbit_yaw: float = 0.0
@export var orbit_pitch: float = -0.35
@export var orbit_pivot_offset: Vector3 = Vector3(0.0, 1.4, 0.0)
@export var follow_smoothing: float = 12.0
@export var free_fly_speed: float = 12.0
@export var free_fly_fast_multiplier: float = 2.5

var camera: Camera3D = null
var _free_yaw: float = 0.0
var _free_pitch: float = 0.0


func _ready() -> void:
	ensure_camera()


func ensure_camera() -> Camera3D:
	if camera == null:
		for child in get_children():
			if child is Camera3D:
				camera = child as Camera3D
				break
	if camera == null:
		camera = Camera3D.new()
		camera.name = "ReplayCamera3D"
		add_child(camera)
	return camera


func rotate_orbit(delta_yaw: float, delta_pitch: float) -> void:
	orbit_yaw += delta_yaw
	orbit_pitch = clampf(orbit_pitch + delta_pitch, -1.45, 1.35)


func rotate_free_fly(delta_yaw: float, delta_pitch: float) -> void:
	_free_yaw += delta_yaw
	_free_pitch = clampf(_free_pitch + delta_pitch, -1.5, 1.5)


func move_free_fly(local_dir: Vector3, delta: float, fast: bool = false) -> void:
	if mode != Mode.FREE_FLY:
		return
	var basis := Basis.from_euler(Vector3(_free_pitch, _free_yaw, 0.0))
	var spd := free_fly_speed * (free_fly_fast_multiplier if fast else 1.0)
	global_position += (basis * local_dir) * spd * delta
	global_basis = basis


func update_from_player(player: Node, delta: float) -> void:
	var cam := ensure_camera()
	if player == null or not player.has_method("get_proxy"):
		return

	var target_node: Node3D = null
	if target_entity_id > 0:
		target_node = player.call("get_proxy", target_entity_id) as Node3D

	var weight := 1.0 - exp(-follow_smoothing * maxf(0.0, delta))
	match mode:
		Mode.FREE_FLY:
			var basis := Basis.from_euler(Vector3(_free_pitch, _free_yaw, 0.0))
			global_basis = basis
		Mode.FOLLOW:
			if target_node != null and target_node.is_visible_in_tree():
				var desired := target_node.global_position + target_node.global_basis * follow_offset
				global_position = global_position.lerp(desired, weight)
				look_at(target_node.global_position + orbit_pivot_offset, Vector3.UP)
		Mode.ORBIT:
			if target_node != null and target_node.is_visible_in_tree():
				var pivot := target_node.global_position + orbit_pivot_offset
				var offset_basis := Basis.from_euler(Vector3(orbit_pitch, orbit_yaw, 0.0))
				var desired_pos := pivot + offset_basis * Vector3(0.0, 0.0, orbit_distance)
				global_position = global_position.lerp(desired_pos, weight) if follow_smoothing > 0.0 else desired_pos
				if not global_position.is_equal_approx(pivot):
					look_at(pivot, Vector3.UP)
		Mode.RECORDED_POV:
			if target_node != null and target_node.is_visible_in_tree():
				global_transform = target_node.global_transform
				var fov_val: Variant = target_node.get(&"fov")
				if fov_val is float:
					cam.fov = float(fov_val)
