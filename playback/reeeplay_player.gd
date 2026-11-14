class_name REEEplayPlayer
extends Node
## Replay playback controller managing timeline progression, seek/scrubbing, interpolation, proxies, and cues.

signal playback_started
signal playback_paused
signal playback_finished
signal time_changed(current_seconds: float, duration_seconds: float)
signal tick_changed(tick: int)
signal event_reached(ev: REEEplayEvent)
signal proxy_spawned(entity_id: int, proxy: Node)
signal proxy_despawned(entity_id: int, proxy: Node)

var recording: REEEplayRecording = null
var archetypes: Dictionary[StringName, REEEplayArchetype] = {}
var proxy_root: Node = null
var cue_host: Node = null
var camera: REEEplayCamera = null

var is_playing: bool = false
var speed: float = 1.0
var loop: bool = false

var current_tick_float: float = 0.0
var current_tick: int = 0
var current_time: float = 0.0

## Active proxies by entity_id (int -> Node)
var _proxies: Dictionary[int, Node] = {}
## Interpolation window cache valid for [cached_base_tick, cached_base_tick + 1)
var _cached_base_tick: int = -1
var _cached_active: Dictionary[int, bool] = {}
var _prev_ticks: Dictionary[int, Dictionary] = {}   # entity_id -> { cidx -> int }
var _prev_vals: Dictionary[int, Dictionary] = {}    # entity_id -> { cidx -> Variant }
var _next_ticks: Dictionary[int, Dictionary] = {}   # entity_id -> { cidx -> int }
var _next_vals: Dictionary[int, Dictionary] = {}    # entity_id -> { cidx -> Variant }


func _ready() -> void:
	if bool(REEEplaySettings.value(&"reeeplay/playback/process_always")):
		process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if is_playing and recording != null:
		step_time(delta)
	if camera != null:
		camera.update_from_player(self, delta)


func load_recording(p_recording: REEEplayRecording, p_archetypes: Dictionary = {}) -> void:
	stop_and_clear()
	recording = p_recording
	for k in p_archetypes:
		archetypes[k] = p_archetypes[k]
	if recording != null:
		for k in recording.archetypes:
			if not archetypes.has(k):
				archetypes[k] = recording.archetypes[k]
		current_tick_float = float(recording.start_tick)
		current_tick = recording.start_tick
		current_time = 0.0
		_evaluate_and_apply(current_tick_float)
		time_changed.emit(current_time, recording.get_duration_seconds())
		tick_changed.emit(current_tick)


func register_archetype(arch: REEEplayArchetype) -> void:
	if arch != null and arch.archetype_id != &"":
		archetypes[arch.archetype_id] = arch


func play(p_speed: float = 0.0) -> void:
	if recording == null:
		return
	if not is_zero_approx(p_speed):
		speed = p_speed
	is_playing = true
	playback_started.emit()


func pause() -> void:
	if is_playing:
		is_playing = false
		playback_paused.emit()


func stop() -> void:
	is_playing = false
	if recording != null:
		seek_to_tick(recording.start_tick)
	playback_paused.emit()


func stop_and_clear() -> void:
	is_playing = false
	_cached_base_tick = -1
	_cached_active.clear()
	_prev_ticks.clear()
	_prev_vals.clear()
	_next_ticks.clear()
	_next_vals.clear()
	for eid in _proxies:
		var node := _proxies[eid]
		if is_instance_valid(node):
			node.queue_free()
	_proxies.clear()


func set_speed(new_speed: float) -> void:
	speed = new_speed


func get_playback_speed() -> float:
	return speed


func get_proxy(entity_id: int) -> Node:
	return _proxies.get(entity_id, null)


func get_active_proxy_ids() -> Array[int]:
	var out: Array[int] = []
	for eid in _proxies:
		out.append(eid)
	return out


func get_cue_host() -> Node:
	if is_instance_valid(cue_host):
		return cue_host
	if is_instance_valid(proxy_root):
		return proxy_root
	return self


func get_world_state(key: StringName, default_value: Variant = null) -> Variant:
	if recording == null:
		return default_value
	return recording.get_world_state_at(key, current_tick, default_value)


func seek_to_time(seconds: float) -> void:
	if recording == null:
		return
	var start_t := float(recording.start_tick)
	var end_t := float(recording.get_end_tick())
	var target_tick_f := clampf(start_t + seconds * float(maxi(1, recording.tick_rate)), start_t, end_t)
	_seek_internal(target_tick_f)


func seek_to_tick(tick: int) -> void:
	if recording == null:
		return
	var target_tick_f := clampf(float(tick), float(recording.start_tick), float(recording.get_end_tick()))
	_seek_internal(target_tick_f)


## Advances playback deterministically by delta seconds (useful both from _process and headless tests).
func step_time(delta: float) -> void:
	if recording == null or not is_playing:
		return
	var rate := float(maxi(1, recording.tick_rate))
	var old_tick_f := current_tick_float
	var new_tick_f := old_tick_f + delta * speed * rate
	var min_t := float(recording.start_tick)
	var max_t := float(recording.get_end_tick())

	var hit_end := false
	if speed >= 0.0 and new_tick_f >= max_t:
		if loop and max_t > min_t:
			new_tick_f = min_t + fposmod(new_tick_f - min_t, max_t - min_t)
		else:
			new_tick_f = max_t
			hit_end = true
	elif speed < 0.0 and new_tick_f <= min_t:
		if loop and max_t > min_t:
			new_tick_f = max_t - fposmod(min_t - new_tick_f, max_t - min_t)
		else:
			new_tick_f = min_t
			hit_end = true

	var prev_int := current_tick
	current_tick_float = new_tick_f
	current_tick = floori(new_tick_f)
	current_time = (current_tick_float - min_t) / rate

	_evaluate_and_apply(current_tick_float)
	_dispatch_cues_between(floori(old_tick_f), current_tick, speed >= 0.0)

	if current_tick != prev_int:
		tick_changed.emit(current_tick)
	time_changed.emit(current_time, recording.get_duration_seconds())

	if hit_end:
		is_playing = false
		playback_finished.emit()


func _seek_internal(target_tick_f: float) -> void:
	var prev_int := current_tick
	current_tick_float = target_tick_f
	current_tick = floori(target_tick_f)
	current_time = (current_tick_float - float(recording.start_tick)) / float(maxi(1, recording.tick_rate))
	_cached_base_tick = -1 # force clean window rebuild
	_evaluate_and_apply(current_tick_float)

	for ev in recording.events:
		if ev.tick == current_tick and ev is REEEplayCue and (ev as REEEplayCue).dispatch_on_seek:
			(ev as REEEplayCue)._on_playback_forward(self)

	if current_tick != prev_int:
		tick_changed.emit(current_tick)
	time_changed.emit(current_time, recording.get_duration_seconds())


func _dispatch_cues_between(from_tick: int, to_tick: int, forward: bool) -> void:
	if from_tick == to_tick or recording == null:
		return
	var max_cue_spd := float(REEEplaySettings.value(&"reeeplay/playback/max_cue_dispatch_speed"))
	var allow_cue := max_cue_spd <= 0.0 or absf(speed) <= max_cue_spd

	if forward and to_tick > from_tick:
		for ev in recording.events:
			if ev.tick > from_tick and ev.tick <= to_tick:
				event_reached.emit(ev)
				if allow_cue and ev is REEEplayCue:
					(ev as REEEplayCue)._on_playback_forward(self)
	elif not forward and to_tick < from_tick:
		for i in range(recording.events.size() - 1, -1, -1):
			var ev := recording.events[i]
			if ev.tick > to_tick and ev.tick <= from_tick:
				event_reached.emit(ev)
				if allow_cue and ev is REEEplayCue:
					(ev as REEEplayCue)._on_playback_reverse(self)


func _evaluate_and_apply(t_float: float) -> void:
	if recording == null or recording.block_count() == 0:
		return
	var base_tick := clampi(floori(t_float), recording.start_tick, recording.get_end_tick())
	if _cached_base_tick != base_tick:
		_rebuild_interpolation_window(base_tick)

	_sync_proxies()

	# Apply interpolated channel values for all active proxies.
	for eid in _cached_active:
		var proxy := _proxies.get(eid, null)
		if proxy == null or not is_instance_valid(proxy):
			continue
		var info := recording.get_entity_info(eid)
		if info == null:
			continue

		var p_vals: Dictionary = _prev_vals.get(eid, {})
		var p_ticks: Dictionary = _prev_ticks.get(eid, {})
		var n_vals: Dictionary = _next_vals.get(eid, {})
		var n_ticks: Dictionary = _next_ticks.get(eid, {})

		for cidx in p_vals:
			var val_a: Variant = p_vals[cidx]
			var out_val: Variant = val_a
			var allow_interp: bool = cidx < info.channel_interpolated.size() and bool(info.channel_interpolated[cidx])
			if allow_interp and n_vals.has(cidx):
				var t0 := int(p_ticks.get(cidx, base_tick))
				var t1 := int(n_ticks.get(cidx, base_tick))
				if t1 > t0:
					var alpha := clampf((t_float - float(t0)) / float(t1 - t0), 0.0, 1.0)
					var codec_id := info.channel_codecs[cidx] if cidx < info.channel_codecs.size() else REEEplayCodec.Id.AUTO
					out_val = REEEplayInterpolator.interpolate_value(val_a, n_vals[cidx], alpha, codec_id, true)
			_apply_channel_value(proxy, info, cidx, out_val)


func _rebuild_interpolation_window(base_tick: int) -> void:
	_cached_base_tick = base_tick
	_cached_active.clear()
	_prev_ticks.clear()
	_prev_vals.clear()
	_next_ticks.clear()
	_next_vals.clear()

	var bidx := recording.find_block_index_for_tick(base_tick)
	if bidx < 0:
		return
	var blk := recording.get_block(bidx)
	if blk == null or blk.ticks.is_empty():
		return

	var rates: Dictionary[int, Dictionary] = {}
	var base_array_pos := -1

	# 1) Replay block from start_tick up to base_tick to populate prev_vals & prev_ticks.
	for i in range(blk.ticks.size()):
		var td := blk.ticks[i]
		if td.tick > base_tick:
			break
		base_array_pos = i
		for rc in td.rate_changes:
			rates[rc.entity_id] = {"divider": maxi(1, rc.divider), "phase": rc.phase}
		for sid in td.spawns:
			_cached_active[sid] = true
			if not _prev_vals.has(sid):
				_prev_vals[sid] = {}
				_prev_ticks[sid] = {}
		for did in td.despawns:
			_cached_active.erase(did)
			_prev_vals.erase(did)
			_prev_ticks.erase(did)
		for ef in td.entities:
			_cached_active[ef.entity_id] = true
			var ev_map: Dictionary = _prev_vals.get(ef.entity_id, {})
			var et_map: Dictionary = _prev_ticks.get(ef.entity_id, {})
			for cidx in ef.values:
				ev_map[int(cidx)] = ef.values[cidx]
				et_map[int(cidx)] = td.tick
			_prev_vals[ef.entity_id] = ev_map
			_prev_ticks[ef.entity_id] = et_map

		# Advance last_sample_tick on scheduled ticks even when delta-suppressed (stationary plateaus).
		for eid in _cached_active:
			var rinfo: Dictionary = rates.get(eid, _default_rate_for(eid))
			var div := maxi(1, int(rinfo["divider"]))
			var ph := int(rinfo["phase"])
			if (td.tick % div) == ph:
				var et_map: Dictionary = _prev_ticks.get(eid, {})
				var ev_map: Dictionary = _prev_vals.get(eid, {})
				for cidx in ev_map:
					et_map[cidx] = td.tick

	# 2) Look ahead for next scheduled sample tick (> base_tick) for each active entity.
	var pending: Dictionary[int, bool] = {}
	for eid in _cached_active:
		pending[eid] = true
		_next_vals[eid] = {}
		_next_ticks[eid] = {}

	var fut_rates := rates.duplicate(true)
	var lookahead_tick := base_tick + 1
	var max_lookahead_tick := mini(recording.get_end_tick(), base_tick + 64)

	# Helper closure over remaining ticks in current block + keyframe tick of next block.
	var future_ticks: Array[REEEplayRecording.TickData] = []
	for i in range(maxi(0, base_array_pos + 1), blk.ticks.size()):
		if blk.ticks[i].tick > base_tick:
			future_ticks.append(blk.ticks[i])
	if bidx + 1 < recording.block_count():
		var next_blk := recording.get_block(bidx + 1)
		if next_blk != null and not next_blk.ticks.is_empty():
			future_ticks.append(next_blk.ticks[0])

	for td in future_ticks:
		if td.tick > max_lookahead_tick or pending.is_empty():
			break
		for rc in td.rate_changes:
			fut_rates[rc.entity_id] = {"divider": maxi(1, rc.divider), "phase": rc.phase}
		for did in td.despawns:
			pending.erase(did)
		for ef in td.entities:
			if not pending.has(ef.entity_id):
				continue
			var nv: Dictionary = _next_vals[ef.entity_id]
			var nt: Dictionary = _next_ticks[ef.entity_id]
			for cidx in ef.values:
				if not nv.has(int(cidx)):
					nv[int(cidx)] = ef.values[cidx]
					nt[int(cidx)] = td.tick

		# For any scheduled entity whose channel didn't change on its scheduled tick (delta suppressed),
		# fill remaining channels in next_vals with prev_vals at this scheduled tick so interpolation holds steady.
		var completed_eids: Array[int] = []
		for eid in pending:
			var rinfo: Dictionary = fut_rates.get(eid, _default_rate_for(eid))
			var div := maxi(1, int(rinfo["divider"]))
			var ph := int(rinfo["phase"])
			if (td.tick % div) == ph:
				var pv: Dictionary = _prev_vals.get(eid, {})
				var nv: Dictionary = _next_vals[eid]
				var nt: Dictionary = _next_ticks[eid]
				for cidx in pv:
					if not nv.has(cidx):
						nv[cidx] = pv[cidx]
						nt[cidx] = td.tick
				completed_eids.append(eid)
		for eid in completed_eids:
			pending.erase(eid)


func _default_rate_for(entity_id: int) -> Dictionary:
	var info := recording.get_entity_info(entity_id)
	if info != null:
		return {"divider": maxi(1, info.initial_divider), "phase": info.initial_phase}
	return {"divider": 1, "phase": 0}


func _sync_proxies() -> void:
	# Despawn proxies no longer active.
	var to_remove: Array[int] = []
	for eid in _proxies:
		if not _cached_active.has(eid):
			to_remove.append(eid)
	for eid in to_remove:
		var node := _proxies[eid]
		_proxies.erase(eid)
		if is_instance_valid(node):
			node.queue_free()
		proxy_despawned.emit(eid, node)

	# Spawn newly active proxies.
	var host: Node = proxy_root if is_instance_valid(proxy_root) else self
	for eid in _cached_active:
		if _proxies.has(eid) and is_instance_valid(_proxies[eid]):
			continue
		var info := recording.get_entity_info(eid)
		var proxy := REEEplayProxyFactory.create_proxy(info, archetypes)
		host.add_child(proxy)
		_proxies[eid] = proxy
		proxy_spawned.emit(eid, proxy)


func _apply_channel_value(proxy: Node, info: REEEplayEntityInfo, cidx: int, value: Variant) -> void:
	if cidx < 0 or cidx >= info.channel_names.size():
		return
	var ch_name := info.channel_names[cidx]
	var arch: REEEplayArchetype = archetypes.get(info.archetype_id, null)
	if arch != null:
		var ch := arch.find_channel(ch_name)
		if ch != null:
			ch.apply_to(proxy, value)
			return

	# Built-in fallback mapping for loaded replays without runtime archetypes registered.
	if ch_name == &"position":
		if proxy is Node3D or proxy is Node2D:
			proxy.set(&"global_position" if proxy.is_inside_tree() else &"position", value)
			return
	elif ch_name == &"rotation":
		if proxy is Node3D and value is Quaternion:
			var n3 := proxy as Node3D
			if n3.is_inside_tree():
				var scl := n3.global_basis.get_scale()
				n3.global_basis = Basis(value as Quaternion).scaled_local(scl)
			else:
				var scl := n3.basis.get_scale()
				n3.basis = Basis(value as Quaternion).scaled_local(scl)
			return
		elif proxy is Node2D and (value is float or value is int):
			var n2 := proxy as Node2D
			if n2.is_inside_tree():
				n2.global_rotation = float(value)
			else:
				n2.rotation = float(value)
			return
	elif ch_name == &"transform":
		if proxy is Node3D and value is Transform3D:
			var n3 := proxy as Node3D
			if n3.is_inside_tree():
				n3.global_transform = value as Transform3D
			else:
				n3.transform = value as Transform3D
			return
		elif proxy is Node2D and value is Transform2D:
			var n2 := proxy as Node2D
			if n2.is_inside_tree():
				n2.global_transform = value as Transform2D
			else:
				n2.transform = value as Transform2D
			return
	elif ch_name == &"skeleton_pose" and proxy is Skeleton3D and value is Array:
		var skel := proxy as Skeleton3D
		var poses: Array = value
		var count := mini(skel.get_bone_count(), poses.size())
		for i in range(count):
			if poses[i] is Transform3D:
				skel.set_bone_pose(i, poses[i] as Transform3D)
		return

	var path_str := String(ch_name)
	if path_str.contains(":"):
		proxy.set_indexed(NodePath(path_str), value)
	else:
		proxy.set(ch_name, value)
