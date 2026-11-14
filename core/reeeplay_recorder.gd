class_name REEEplayRecorder
extends RefCounted
## Live state sampler managing entity tracking, rate dividers, delta suppression, keyframes, and ring buffers.

signal tick_captured(tick: int)
signal entity_spawned(entity_id: int)
signal entity_despawned(entity_id: int)

var preset: REEEplayPreset = null
var recording: REEEplayRecording = null
var is_recording: bool = false
var current_tick: int = 0
var accumulator: float = 0.0
var focus_node: Node = null
var focus_position: Variant = null

var _archetypes: Dictionary[StringName, REEEplayArchetype] = {}
var _active_entities: Dictionary[int, REEEplayEntityInfo] = {}
var _node_to_id: Dictionary[int, int] = {} # instance_id -> entity_id
var _stable_key_to_id: Dictionary[StringName, int] = {}
var _next_entity_id: int = 1 # 0 is reserved for world state
var _next_event_id: int = 1
var _next_attachment_id: int = 1

var _pending_spawns: PackedInt32Array = PackedInt32Array()
var _pending_despawns: PackedInt32Array = PackedInt32Array()
var _pending_rate_changes: Array[REEEplayRecording.RateChange] = []
var _current_block: REEEplayRecording.FrameBlock = null
var _keyframe_interval_ticks: int = 150
var _ticks_in_current_block: int = 0
var _last_policy_eval_tick: int = -100000
var _policy_eval_interval_ticks: int = 8
var _last_tick_duration_ms: float = 0.0
var _current_world_state: Dictionary[StringName, Variant] = {}
var _damage_tracker: REEEplayDamageTracker = REEEplayDamageTracker.new()


func _init(p_preset: REEEplayPreset = null) -> void:
	preset = p_preset if p_preset != null else REEEplayPreset.from_kind(REEEplayPreset.Kind.CUSTOM)


func register_archetype(arch: REEEplayArchetype) -> void:
	if arch == null or arch.archetype_id == &"":
		return
	_archetypes[arch.archetype_id] = arch
	if recording != null:
		recording.archetypes[arch.archetype_id] = arch


func get_archetype(archetype_id: StringName) -> REEEplayArchetype:
	return _archetypes.get(archetype_id, null)


func get_damage_tracker() -> REEEplayDamageTracker:
	return _damage_tracker


func begin(options: Dictionary = {}) -> REEEplayRecording:
	recording = REEEplayRecording.new()
	recording.recording_id = str(options.get("recording_id", "rec_%d" % Time.get_unix_time_from_system()))
	recording.game_id = str(options.get("game_id", ProjectSettings.get_setting("application/config/name", "GodotGame")))
	recording.game_version = str(options.get("game_version", ProjectSettings.get_setting("application/config/version", "1.0.0")))
	recording.scene_path = str(options.get("scene_path", ""))
	recording.recorded_at_unix = int(Time.get_unix_time_from_system())
	recording.tick_rate = maxi(1, int(options.get("tick_rate", preset.tick_rate)))
	recording.metadata = (options.get("metadata", {}) as Dictionary).duplicate(true)
	for arch_id in _archetypes:
		recording.archetypes[arch_id] = _archetypes[arch_id]

	current_tick = 0
	accumulator = 0.0
	_next_entity_id = 1
	_next_event_id = 1
	_next_attachment_id = 1
	_active_entities.clear()
	_node_to_id.clear()
	_stable_key_to_id.clear()
	_pending_spawns.clear()
	_pending_despawns.clear()
	_pending_rate_changes.clear()
	_current_world_state.clear()
	_current_block = null
	_ticks_in_current_block = 0
	_last_policy_eval_tick = -100000

	_keyframe_interval_ticks = maxi(1, roundi(preset.keyframe_interval_seconds * float(recording.tick_rate)))
	var policy_interval := preset.rate_policy.evaluation_interval_seconds if preset.rate_policy != null else 0.25
	_policy_eval_interval_ticks = maxi(1, roundi(policy_interval * float(recording.tick_rate)))
	if preset.rate_policy != null:
		preset.rate_policy.reset()

	_damage_tracker.reset()
	_damage_tracker.configure(
		func() -> int: return current_tick,
		_resolve_actor_from_variant,
		_on_damage_event_emitted
	)

	is_recording = true
	return recording


func stop() -> REEEplayRecording:
	if not is_recording:
		return recording
	is_recording = false
	_flush_current_block()
	if recording != null:
		recording.total_ticks = current_tick
	_damage_tracker.disconnect_all_routers()
	return recording


## Tracks a live Node under archetype_id (or inferred transform channels) and returns its entity_id (>= 1).
func track(target: Node, archetype_id: StringName = &"", options: Dictionary = {}) -> int:
	if target == null or recording == null:
		return 0
	var inst_id := target.get_instance_id()
	if _node_to_id.has(inst_id):
		return _node_to_id[inst_id]

	var arch := _archetypes.get(archetype_id, null)
	var stable_key := StringName(options.get("stable_key", &""))
	var reuse_id := int(options.get("entity_id", 0))
	if reuse_id <= 0 and stable_key != &"" and _stable_key_to_id.has(stable_key):
		reuse_id = _stable_key_to_id[stable_key]

	var eid := reuse_id if reuse_id > 0 else _allocate_entity_id()
	var info := recording.entities.get(eid, null)
	if info == null:
		info = REEEplayEntityInfo.new()
		info.entity_id = eid
		info.spawn_tick = current_tick
		recording.entities[eid] = info
	else:
		info.despawn_tick = -1

	info.archetype_id = archetype_id
	info.archetype = arch
	info.stable_key = stable_key
	info.display_name = str(options.get("display_name", target.name))
	info.player_id = str(options.get("player_id", ""))
	info.team_id = int(options.get("team_id", -1))
	info.priority = int(options.get("priority", arch.priority if arch != null else 0))
	info.scene_path = str(options.get("scene_path", target.scene_file_path))
	if options.has("metadata"):
		info.metadata = (options["metadata"] as Dictionary).duplicate(true)

	# Determine channels (custom override > archetype > auto transform inference).
	var raw_channels: Array = []
	if options.has("channels") and (options["channels"] as Array).size() > 0:
		raw_channels = options["channels"] as Array
	elif arch != null and not arch.channels.is_empty():
		raw_channels = arch.channels
	else:
		raw_channels = _infer_default_channels(target)

	info.channels.clear()
	for ch in raw_channels:
		if ch is REEEplayChannel:
			info.channels.append(ch as REEEplayChannel)
	info.sync_from_channels()
	info.last_values.clear()
	info.sample_count = 0
	info.needs_full_sample = true

	var base_div := maxi(1, int(options.get("divider", arch.default_divider if arch != null else _baseline_divider())))
	info.initial_divider = base_div
	info.current_divider = base_div
	info.current_phase = int(options.get("phase", eid % base_div))
	info.initial_phase = info.current_phase
	info.target = target

	_active_entities[eid] = info
	_node_to_id[inst_id] = eid
	if stable_key != &"":
		_stable_key_to_id[stable_key] = eid
	if bool(options.get("is_local_player", false)):
		recording.local_player_entity_id = eid

	_pending_spawns.append(eid)
	entity_spawned.emit(eid)
	return eid


## Explicitly respawns a target reusing a previous entity_id (or matching stable_key), clearing despawn state.
func respawn(target: Node, entity_id: int, archetype_id: StringName = &"", options: Dictionary = {}) -> int:
	var opts := options.duplicate()
	if entity_id > 0:
		opts["entity_id"] = entity_id
	return track(target, archetype_id, opts)


func despawn(target_or_id: Variant) -> void:
	var eid := _lookup_entity_id(target_or_id)
	if eid <= 0:
		return
	var info := _active_entities.get(eid, null)
	if info == null:
		return
	if is_instance_valid(info.target):
		_node_to_id.erase(info.target.get_instance_id())
	info.target = null
	info.despawn_tick = current_tick
	_active_entities.erase(eid)
	_pending_despawns.append(eid)
	entity_despawned.emit(eid)


func set_entity_rate(target_or_id: Variant, divider: int, phase: int = -1) -> void:
	var eid := _lookup_entity_id(target_or_id)
	if eid <= 0:
		return
	var info := _active_entities.get(eid, null)
	if info == null:
		return
	var new_div := maxi(1, divider)
	var new_phase := (eid % new_div) if phase < 0 else (phase % new_div)
	if info.current_divider == new_div and info.current_phase == new_phase:
		return
	info.current_divider = new_div
	info.current_phase = new_phase
	var rc := REEEplayRecording.RateChange.new()
	rc.entity_id = eid
	rc.divider = new_div
	rc.phase = new_phase
	_pending_rate_changes.append(rc)


func set_world_state(key: StringName, value: Variant) -> void:
	if recording == null or key == &"":
		return
	_current_world_state[key] = value
	recording.set_world_state_entry(key, current_tick, value)


func emit_event(ev: REEEplayEvent) -> void:
	if recording == null or ev == null:
		return
	if ev.event_id <= 0:
		ev.event_id = _next_event_id
		_next_event_id += 1
	if ev.tick == 0 and current_tick > 0:
		ev.tick = current_tick
	ev.timestamp = REEEplayClock.tick_to_seconds(ev.tick, recording.tick_rate)
	recording.events.append(ev)

	if preset.rate_policy != null and preset.rate_policy.enabled:
		var policy := preset.rate_policy
		if policy.mode == REEEplayRatePolicy.Mode.EVENT_BOOST or policy.mode == REEEplayRatePolicy.Mode.COMBAT_BOOST:
			var sim_t := REEEplayClock.tick_to_seconds(current_tick, recording.tick_rate)
			if ev.entity_id > 0:
				policy.notify_event(ev.entity_id, sim_t)
			if ev.secondary_entity_id > 0:
				policy.notify_event(ev.secondary_entity_id, sim_t)


func add_attachment(att: REEEplayAttachment) -> void:
	if recording == null or att == null:
		return
	if att.attachment_id <= 0:
		att.attachment_id = _next_attachment_id
		_next_attachment_id += 1
	if att.tick == 0 and current_tick > 0:
		att.tick = current_tick
	recording.attachments.append(att)


## Advances recording accumulator by delta seconds and captures fixed-timestep ticks.
func advance(delta: float, max_steps_per_frame: int = 8) -> int:
	if not is_recording or recording == null:
		return 0
	var tick_dt := 1.0 / float(maxi(1, recording.tick_rate))
	accumulator += maxf(0.0, delta)
	var steps := 0
	while accumulator >= tick_dt and steps < max_steps_per_frame:
		accumulator -= tick_dt
		capture_tick()
		steps += 1
	return steps


## Captures exactly one simulation tick into the current FrameBlock.
func capture_tick() -> void:
	if not is_recording or recording == null:
		return

	var t_start := Time.get_ticks_usec()

	# Periodically evaluate rate policy.
	if preset.rate_policy != null and preset.rate_policy.enabled:
		if (current_tick - _last_policy_eval_tick) >= _policy_eval_interval_ticks:
			_evaluate_rate_policy()
			_last_policy_eval_tick = current_tick

	# Start new keyframe block if needed.
	var force_keyframe := false
	if _current_block == null or _ticks_in_current_block >= _keyframe_interval_ticks:
		_flush_current_block()
		_current_block = REEEplayRecording.FrameBlock.new()
		_current_block.start_tick = current_tick
		_current_block.is_keyframe = true
		_ticks_in_current_block = 0
		force_keyframe = true

	var td := REEEplayRecording.TickData.new()
	td.tick = current_tick

	# Auto-despawn freed targets.
	var freed_ids: Array[int] = []
	for eid in _active_entities:
		var info := _active_entities[eid]
		if info.target == null or not is_instance_valid(info.target):
			freed_ids.append(eid)
	for eid in freed_ids:
		_active_entities.erase(eid)
		_pending_despawns.append(eid)
		var finfo := recording.entities.get(eid, null)
		if finfo != null:
			finfo.despawn_tick = current_tick
			finfo.target = null

	if not _pending_spawns.is_empty():
		td.spawns = _pending_spawns.duplicate()
		_pending_spawns.clear()
	if not _pending_despawns.is_empty():
		td.despawns = _pending_despawns.duplicate()
		_pending_despawns.clear()
	if not _pending_rate_changes.is_empty():
		td.rate_changes = _pending_rate_changes.duplicate()
		_pending_rate_changes.clear()

	# Sample each active entity whose divider/phase hits on current_tick (or full on keyframe/spawn).
	for eid in _active_entities:
		var info := _active_entities[eid]
		var full_sample := force_keyframe or info.needs_full_sample
		var on_schedule := (current_tick % maxi(1, info.current_divider)) == info.current_phase
		if not full_sample and not on_schedule:
			continue

		var ef := _sample_entity(info, full_sample)
		info.needs_full_sample = false
		info.sample_count += 1
		if not ef.values.is_empty():
			td.entities.append(ef)

	_current_block.ticks.append(td)
	_current_block.tick_count = _current_block.ticks.size()
	_ticks_in_current_block += 1

	var tick_just_captured := current_tick
	current_tick += 1
	recording.total_ticks = current_tick - recording.start_tick

	if preset.recording_mode == REEEplayPreset.RecordingMode.RING_BUFFER:
		_trim_ring_buffer()

	_last_tick_duration_ms = float(Time.get_ticks_usec() - t_start) / 1000.0
	tick_captured.emit(tick_just_captured)


## Extracts trailing ring_buffer_seconds into a standalone REEEplayRecording (useful for FULL_WITH_RING / RING_BUFFER).
func export_ring_clip(seconds: float = -1.0) -> REEEplayRecording:
	if recording == null:
		return null
	_flush_current_block()
	var dur := seconds if seconds > 0.0 else preset.ring_buffer_seconds
	var window_ticks := maxi(1, roundi(dur * float(recording.tick_rate)))
	var end_t := recording.get_end_tick()
	var from_t := maxi(recording.start_tick, end_t - window_ticks + 1)
	var clip := recording.slice(from_t, end_t, true)
	# Re-open _current_block smoothly if still recording.
	if is_recording and _current_block != null:
		_current_block = null
		_ticks_in_current_block = 0
	return clip


func _sample_entity(info: REEEplayEntityInfo, full_sample: bool) -> REEEplayRecording.EntityFrame:
	var ef := REEEplayRecording.EntityFrame.new()
	ef.entity_id = info.entity_id
	var ch_count := info.channels.size()
	if info.last_values.size() != ch_count:
		info.last_values.resize(ch_count)
		full_sample = true

	var eps_scale := maxf(0.0, preset.epsilon_scale)
	for i in range(ch_count):
		var ch := info.channels[i]
		if not full_sample and ch.rate_divider > 1:
			if (info.sample_count % ch.rate_divider) != 0:
				continue

		var val: Variant = ch.sample_from(info.target)
		if val == null:
			continue

		if info.channel_codecs[i] == REEEplayCodec.Id.AUTO:
			info.channel_codecs[i] = REEEplayCodec.resolve_auto_codec(val, REEEplayCodec.Id.AUTO)

		var eff_eps := ch.epsilon * eps_scale
		if not full_sample and info.last_values[i] != null:
			if REEEplayCodec.values_equal(val, info.last_values[i], eff_eps, info.channel_codecs[i]):
				continue

		info.last_values[i] = REEEplayRecording.EntityFrame._copy_val(val)
		ef.values[i] = info.last_values[i]

	return ef


func _evaluate_rate_policy() -> void:
	var ent_ctx: Dictionary = {}
	var eff_focus := focus_position
	if is_instance_valid(focus_node):
		if focus_node is Node3D:
			var f3 := focus_node as Node3D
			eff_focus = f3.global_position if f3.is_inside_tree() else f3.position
		elif focus_node is Node2D:
			var f2 := focus_node as Node2D
			eff_focus = f2.global_position if f2.is_inside_tree() else f2.position

	for eid in _active_entities:
		var info := _active_entities[eid]
		var pos: Variant = null
		if info.target is Node3D:
			var n3 := info.target as Node3D
			pos = n3.global_position if n3.is_inside_tree() else n3.position
		elif info.target is Node2D:
			var n2 := info.target as Node2D
			pos = n2.global_position if n2.is_inside_tree() else n2.position
		ent_ctx[eid] = {
			"position": pos,
			"priority": info.priority,
			"base_divider": info.initial_divider,
		}

	var ctx := {
		"sim_time": REEEplayClock.tick_to_seconds(current_tick, recording.tick_rate),
		"focus_position": eff_focus,
		"entities": ent_ctx,
		"last_tick_ms": _last_tick_duration_ms,
	}
	var desired := preset.rate_policy.evaluate(ctx)
	for eid in desired:
		var d: Dictionary = desired[eid]
		set_entity_rate(eid, int(d.get("divider", 1)), int(d.get("phase", -1)))


func _flush_current_block() -> void:
	if recording != null and _current_block != null and _current_block.tick_count > 0:
		# Avoid duplicating block if already appended.
		if recording.blocks.is_empty() or recording.blocks[recording.blocks.size() - 1] != _current_block:
			recording.blocks.append(_current_block)
	_current_block = null


func _trim_ring_buffer() -> void:
	if recording == null:
		return
	var keep_ticks := maxi(1, roundi(preset.ring_buffer_seconds * float(recording.tick_rate)))
	# Only drop closed blocks from the front once the next block STILL satisfies keep_ticks up to current_tick.
	while recording.blocks.size() >= 1:
		var oldest := recording.blocks[0]
		var second_start := recording.blocks[1].start_tick if recording.blocks.size() >= 2 else (_current_block.start_tick if _current_block != null else current_tick)
		if (current_tick - second_start) < keep_ticks:
			break
		recording.blocks.remove_at(0)
		recording.start_tick = second_start
		recording.total_ticks = maxi(0, current_tick - recording.start_tick)

	# Trim events / world_state strictly before recording.start_tick (keep latest world state anchored).
	if recording.start_tick > 0:
		var min_t := recording.start_tick
		if not recording.events.is_empty():
			var kept_events: Array[REEEplayEvent] = []
			for ev in recording.events:
				if ev.tick >= min_t:
					kept_events.append(ev)
			recording.events = kept_events
		for key in recording.world_state_timeline:
			var arr: Array = recording.world_state_timeline[key]
			if arr.size() <= 1:
				continue
			var anchor: Variant = recording.get_world_state_at(key, min_t, null)
			var kept: Array = []
			if anchor != null:
				kept.append({"tick": min_t, "value": anchor})
			for item in arr:
				var d: Dictionary = item
				if int(d["tick"]) > min_t:
					kept.append(d)
			recording.world_state_timeline[key] = kept


func _baseline_divider() -> int:
	if preset.sample_rate > 0 and preset.tick_rate > preset.sample_rate:
		return maxi(1, roundi(float(preset.tick_rate) / float(preset.sample_rate)))
	if preset.rate_policy != null:
		return maxi(1, preset.rate_policy.baseline_divider)
	return 1


func _allocate_entity_id() -> int:
	var eid := _next_entity_id
	_next_entity_id += 1
	return eid


func _lookup_entity_id(target_or_id: Variant) -> int:
	if target_or_id is int:
		return int(target_or_id)
	if target_or_id is Node and is_instance_valid(target_or_id):
		return int(_node_to_id.get((target_or_id as Node).get_instance_id(), 0))
	if target_or_id is StringName:
		return int(_stable_key_to_id.get(target_or_id as StringName, 0))
	return 0


func _infer_default_channels(target: Node) -> Array[REEEplayChannel]:
	if target is Node3D:
		return REEEplayChannelPresets.transform_3d(preset.default_vector3_codec)
	if target is Node2D:
		return REEEplayChannelPresets.transform_2d(preset.default_vector2_codec)
	return []


func _resolve_actor_from_variant(v: Variant) -> REEEplayActorRef:
	var eid := _lookup_entity_id(v)
	if eid > 0:
		var info := recording.get_entity_info(eid) if recording != null else null
		if info != null:
			return REEEplayActorRef.create(eid, info.display_name, info.player_id, info.team_id, info.archetype_id)
		return REEEplayActorRef.create(eid)
	if v is Node:
		return REEEplayActorRef.create(0, (v as Node).name)
	return REEEplayActorRef.anonymous()


func _on_damage_event_emitted(entry: REEEplayDamageEntry) -> void:
	emit_event(entry)
