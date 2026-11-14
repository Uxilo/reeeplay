@tool
class_name REEEplayRatePolicy
extends Resource
## Adaptive per-entity recording divider policy evaluated periodically during a session.

enum Mode {
	CONSTANT = 0,
	DISTANCE_LOD = 1,
	EVENT_BOOST = 2,
	ADAPTIVE_BUDGET = 3,
	COMBAT_BOOST = 4,
}

@export var enabled: bool = true
@export var mode: Mode = Mode.CONSTANT
@export var evaluation_interval_seconds: float = 0.25

@export_group("Dividers")
@export var baseline_divider: int = 1
@export var boost_divider: int = 1
@export var mid_divider: int = 2
@export var far_divider: int = 4
@export var culled_divider: int = 8

@export_group("Distance LOD")
@export var near_distance: float = 20.0
@export var mid_distance: float = 60.0
@export var far_distance: float = 120.0

@export_group("Boost & Budget")
@export var boost_duration_seconds: float = 2.0
@export var budget_ms_per_tick: float = 1.5
@export var hysteresis_seconds: float = 0.5

## Internal expiry map: entity_id (int) -> boost_until_sim_time (float)
var _boost_until: Dictionary[int, float] = {}
## Internal last divider map for hysteresis: entity_id (int) -> { divider: int, changed_at: float }
var _last_state: Dictionary[int, Dictionary] = {}
var _budget_scale: int = 1


## Marks an entity as boosted until sim_time + boost_duration_seconds.
func notify_event(entity_id: int, sim_time: float) -> void:
	if entity_id <= 0:
		return
	_boost_until[entity_id] = maxf(_boost_until.get(entity_id, 0.0), sim_time + boost_duration_seconds)


## Clears runtime state at session start.
func reset() -> void:
	_boost_until.clear()
	_last_state.clear()
	_budget_scale = 1


## Evaluates desired divider and phase per entity.
## context expects:
## - "sim_time": float
## - "focus_position": Variant (Vector3 or Vector2 or null)
## - "entities": Dictionary[int, Dictionary] with keys "position" (Variant), "priority" (int), "base_divider" (int)
## - "last_tick_ms": float
func evaluate(context: Dictionary) -> Dictionary[int, Dictionary]:
	var result: Dictionary[int, Dictionary] = {}
	var entities: Dictionary = context.get("entities", {})
	if not enabled or mode == Mode.CONSTANT:
		for eid in entities:
			var info: Dictionary = entities[eid]
			var div := maxi(1, int(info.get("base_divider", baseline_divider)))
			result[int(eid)] = {
				"divider": div,
				"phase": int(eid) % div,
			}
		return result

	var sim_time := float(context.get("sim_time", 0.0))
	var focus_pos: Variant = context.get("focus_position", null)

	if mode == Mode.ADAPTIVE_BUDGET:
		var last_ms := float(context.get("last_tick_ms", 0.0))
		if last_ms > budget_ms_per_tick * 1.15:
			_budget_scale = mini(8, _budget_scale + 1)
		elif last_ms < budget_ms_per_tick * 0.7 and _budget_scale > 1:
			_budget_scale -= 1

	for eid_var in entities:
		var eid := int(eid_var)
		var info: Dictionary = entities[eid_var]
		var base_div := maxi(baseline_divider, int(info.get("base_divider", baseline_divider)))
		var desired_div := base_div

		match mode:
			Mode.DISTANCE_LOD:
				desired_div = _eval_distance_divider(info.get("position", null), focus_pos, base_div)
			Mode.EVENT_BOOST, Mode.COMBAT_BOOST:
				if _boost_until.get(eid, -1.0) > sim_time:
					desired_div = maxi(1, boost_divider)
				else:
					desired_div = base_div
			Mode.ADAPTIVE_BUDGET:
				var prio := int(info.get("priority", 0))
				if prio > 0:
					desired_div = base_div
				else:
					desired_div = maxi(base_div, base_div * _budget_scale)

		# Apply simple hysteresis when increasing divider (throttling down), allow instant speed-up.
		if _last_state.has(eid):
			var prev: Dictionary = _last_state[eid]
			var prev_div := int(prev.get("divider", desired_div))
			var changed_at := float(prev.get("changed_at", -100.0))
			if desired_div > prev_div and (sim_time - changed_at) < hysteresis_seconds:
				desired_div = prev_div
			elif desired_div != prev_div:
				_last_state[eid] = {"divider": desired_div, "changed_at": sim_time}
		else:
			_last_state[eid] = {"divider": desired_div, "changed_at": sim_time}

		result[eid] = {
			"divider": maxi(1, desired_div),
			"phase": eid % maxi(1, desired_div),
		}

	return result


func _eval_distance_divider(entity_pos: Variant, focus_pos: Variant, base_div: int) -> int:
	if focus_pos == null or entity_pos == null:
		return base_div
	var dist := 0.0
	if entity_pos is Vector3 and focus_pos is Vector3:
		dist = (entity_pos as Vector3).distance_to(focus_pos as Vector3)
	elif entity_pos is Vector2 and focus_pos is Vector2:
		dist = (entity_pos as Vector2).distance_to(focus_pos as Vector2)
	else:
		return base_div

	if dist <= near_distance:
		return base_div
	if dist <= mid_distance:
		return maxi(base_div, mid_divider)
	if dist <= far_distance:
		return maxi(base_div, far_divider)
	return maxi(base_div, culled_divider)
