class_name REEEplayDiff
extends RefCounted
## Tick-by-tick comparison utility for verifying replay determinism and regression testing.


class DiffResult extends RefCounted:
	var ok: bool = true
	var error_message: String = ""
	var tick_rate_a: int = 0
	var tick_rate_b: int = 0
	var duration_ticks_a: int = 0
	var duration_ticks_b: int = 0
	var ticks_compared: int = 0
	var first_divergent_tick: int = -1
	var max_position_drift: float = 0.0
	var max_rotation_drift_deg: float = 0.0
	var max_numeric_delta: float = 0.0
	var missing_entities_in_b: PackedInt32Array = PackedInt32Array()
	var missing_entities_in_a: PackedInt32Array = PackedInt32Array()
	var event_count_a: int = 0
	var event_count_b: int = 0
	var event_mismatches: Array[String] = []
	var damage_entry_count_a: int = 0
	var damage_entry_count_b: int = 0
	var damage_mismatches: Array[String] = []

	func is_identical(pos_eps: float = 0.001, rot_deg_eps: float = 0.1, num_eps: float = 0.001) -> bool:
		if not ok:
			return false
		if tick_rate_a != tick_rate_b or duration_ticks_a != duration_ticks_b:
			return false
		if not missing_entities_in_a.is_empty() or not missing_entities_in_b.is_empty():
			return false
		if not event_mismatches.is_empty() or not damage_mismatches.is_empty():
			return false
		return (
			max_position_drift <= pos_eps
			and max_rotation_drift_deg <= rot_deg_eps
			and max_numeric_delta <= num_eps
		)

	func to_summary() -> String:
		if not ok:
			return "Diff Error: %s" % error_message
		var lines := PackedStringArray([
			"=== REEEplay Diff ===",
			"Tick rate: A=%d Hz, B=%d Hz | Duration: A=%d ticks, B=%d ticks | Compared: %d ticks" % [
				tick_rate_a, tick_rate_b, duration_ticks_a, duration_ticks_b, ticks_compared
			],
			"Max Position Drift: %.6f | Max Rotation Drift: %.4f deg | Max Numeric Delta: %.6f" % [
				max_position_drift, max_rotation_drift_deg, max_numeric_delta
			],
			"First Divergent Tick: %s" % (str(first_divergent_tick) if first_divergent_tick >= 0 else "None"),
			"Events: A=%d, B=%d (mismatches=%d) | Damage Entries: A=%d, B=%d (mismatches=%d)" % [
				event_count_a, event_count_b, event_mismatches.size(),
				damage_entry_count_a, damage_entry_count_b, damage_mismatches.size(),
			],
		])
		if not missing_entities_in_b.is_empty():
			lines.append("Missing entities in B: %s" % str(missing_entities_in_b))
		if not missing_entities_in_a.is_empty():
			lines.append("Missing entities in A: %s" % str(missing_entities_in_a))
		for m in event_mismatches.slice(0, 5):
			lines.append("  Event diff: %s" % m)
		for m in damage_mismatches.slice(0, 5):
			lines.append("  Damage diff: %s" % m)
		return "\n".join(lines)


static func compare(a: REEEplayRecording, b: REEEplayRecording, options: Dictionary = {}) -> DiffResult:
	var res := DiffResult.new()
	if a == null or b == null:
		res.ok = false
		res.error_message = "Both recordings must be non-null."
		return res

	var pos_eps := float(options.get("pos_eps", 0.001))
	var rot_deg_eps := float(options.get("rot_deg_eps", 0.1))
	var num_eps := float(options.get("num_eps", 0.001))
	var tick_step := maxi(1, int(options.get("tick_step", 1)))

	res.tick_rate_a = a.tick_rate
	res.tick_rate_b = b.tick_rate
	res.duration_ticks_a = a.total_ticks
	res.duration_ticks_b = b.total_ticks
	res.event_count_a = a.events.size()
	res.event_count_b = b.events.size()
	res.damage_entry_count_a = a.damage_log.entries.size()
	res.damage_entry_count_b = b.damage_log.entries.size()

	for eid in a.entities:
		if not b.entities.has(eid):
			res.missing_entities_in_b.append(int(eid))
	for eid in b.entities:
		if not a.entities.has(eid):
			res.missing_entities_in_a.append(int(eid))

	var min_end := mini(a.get_end_tick(), b.get_end_tick())
	var start_t := maxi(a.start_tick, b.start_tick)
	if min_end >= start_t:
		var t := start_t
		while t <= min_end:
			var state_a := a.reconstruct_state_at_tick(t)
			var state_b := b.reconstruct_state_at_tick(t)
			res.ticks_compared += 1
			var tick_diverged := _compare_tick_states(state_a, state_b, res, pos_eps, rot_deg_eps, num_eps)
			if tick_diverged and res.first_divergent_tick < 0:
				res.first_divergent_tick = t
			t += tick_step

	_compare_events(a, b, res)
	_compare_damage_logs(a, b, res)
	return res


static func compare_files(path_a: String, path_b: String, options: Dictionary = {}) -> DiffResult:
	var ra := REEEplayReader.load_file(path_a)
	if ra.error != REEEplayFormat.LoadError.OK or ra.recording == null:
		var err_res := DiffResult.new()
		err_res.ok = false
		err_res.error_message = "Failed to load A (%s): %s" % [path_a, ra.error_message]
		return err_res
	var rb := REEEplayReader.load_file(path_b)
	if rb.error != REEEplayFormat.LoadError.OK or rb.recording == null:
		var err_res := DiffResult.new()
		err_res.ok = false
		err_res.error_message = "Failed to load B (%s): %s" % [path_b, rb.error_message]
		return err_res
	return compare(ra.recording, rb.recording, options)


static func _compare_tick_states(
	raw_a: Dictionary,
	raw_b: Dictionary,
	res: DiffResult,
	pos_eps: float,
	rot_deg_eps: float,
	num_eps: float
) -> bool:
	var state_a: Dictionary = raw_a.get("states", {})
	var state_b: Dictionary = raw_b.get("states", {})
	var diverged := false
	for eid in state_a:
		if not state_b.has(eid):
			continue
		var ch_a: Dictionary = state_a[eid]
		var ch_b: Dictionary = state_b[eid]
		for cidx in ch_a:
			if not ch_b.has(cidx):
				continue
			var va: Variant = ch_a[cidx]
			var vb: Variant = ch_b[cidx]
			if _measure_value_delta(va, vb, res, pos_eps, rot_deg_eps, num_eps):
				diverged = true
	return diverged


static func _measure_value_delta(
	va: Variant,
	vb: Variant,
	res: DiffResult,
	pos_eps: float,
	rot_deg_eps: float,
	num_eps: float
) -> bool:
	var diverged := false
	if va is Vector3 and vb is Vector3:
		var d := (va as Vector3).distance_to(vb as Vector3)
		res.max_position_drift = maxf(res.max_position_drift, d)
		diverged = d > pos_eps
	elif va is Vector2 and vb is Vector2:
		var d := (va as Vector2).distance_to(vb as Vector2)
		res.max_position_drift = maxf(res.max_position_drift, d)
		diverged = d > pos_eps
	elif va is Quaternion and vb is Quaternion:
		var deg := rad_to_deg((va as Quaternion).normalized().angle_to((vb as Quaternion).normalized()))
		res.max_rotation_drift_deg = maxf(res.max_rotation_drift_deg, deg)
		diverged = deg > rot_deg_eps
	elif va is Transform3D and vb is Transform3D:
		var ta := va as Transform3D
		var tb := vb as Transform3D
		var dp := ta.origin.distance_to(tb.origin)
		var dr := rad_to_deg(ta.basis.get_rotation_quaternion().angle_to(tb.basis.get_rotation_quaternion()))
		res.max_position_drift = maxf(res.max_position_drift, dp)
		res.max_rotation_drift_deg = maxf(res.max_rotation_drift_deg, dr)
		diverged = (dp > pos_eps) or (dr > rot_deg_eps)
	elif va is Transform2D and vb is Transform2D:
		var ta := va as Transform2D
		var tb := vb as Transform2D
		var dp := ta.origin.distance_to(tb.origin)
		var dr := rad_to_deg(absf(angle_difference(ta.get_rotation(), tb.get_rotation())))
		res.max_position_drift = maxf(res.max_position_drift, dp)
		res.max_rotation_drift_deg = maxf(res.max_rotation_drift_deg, dr)
		diverged = (dp > pos_eps) or (dr > rot_deg_eps)
	elif (va is float or va is int) and (vb is float or vb is int):
		var dn := absf(float(va) - float(vb))
		res.max_numeric_delta = maxf(res.max_numeric_delta, dn)
		diverged = dn > num_eps
	elif va is PackedFloat32Array and vb is PackedFloat32Array:
		var pa := va as PackedFloat32Array
		var pb := vb as PackedFloat32Array
		var count := mini(pa.size(), pb.size())
		for i in range(count):
			var dn := absf(pa[i] - pb[i])
			res.max_numeric_delta = maxf(res.max_numeric_delta, dn)
			if dn > num_eps:
				diverged = true
	return diverged


static func _compare_events(a: REEEplayRecording, b: REEEplayRecording, res: DiffResult) -> void:
	var n := mini(a.events.size(), b.events.size())
	if a.events.size() != b.events.size():
		res.event_mismatches.append("Event count differs: A=%d, B=%d" % [a.events.size(), b.events.size()])
	for i in range(n):
		var ea := a.events[i]
		var eb := b.events[i]
		if ea.tick != eb.tick or ea.get_type_id() != eb.get_type_id() or ea.get_timeline_label() != eb.get_timeline_label():
			res.event_mismatches.append("Idx %d: A=(t=%d %s '%s') vs B=(t=%d %s '%s')" % [
				i,
				ea.tick, ea.get_type_id(), ea.get_timeline_label(),
				eb.tick, eb.get_type_id(), eb.get_timeline_label(),
			])


static func _compare_damage_logs(a: REEEplayRecording, b: REEEplayRecording, res: DiffResult) -> void:
	var ea := a.damage_log.entries
	var eb := b.damage_log.entries
	if ea.size() != eb.size():
		res.damage_mismatches.append("Damage entry count differs: A=%d, B=%d" % [ea.size(), eb.size()])
	var n := mini(ea.size(), eb.size())
	for i in range(n):
		var da := ea[i]
		var db := eb[i]
		if da.tick != db.tick or not is_equal_approx(da.amount, db.amount) or da.damage_type != db.damage_type or da.is_heal != db.is_heal:
			res.damage_mismatches.append("Entry %d: A=(t=%d %.1f %s) vs B=(t=%d %.1f %s)" % [
				i, da.tick, da.amount, da.damage_type, db.tick, db.amount, db.damage_type
			])
