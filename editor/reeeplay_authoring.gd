@tool
class_name REEEplayAuthoring
extends RefCounted
## Editor authoring, scene discovery, proxy generation, budget estimation, and .reee inspection utilities.


## Recursively collects all REEEplayTracked nodes under root.
static func find_all_tracked(root: Node) -> Array[REEEplayTracked]:
	var out: Array[REEEplayTracked] = []
	if root == null:
		return out
	_collect_tracked(root, out)
	return out


static func _collect_tracked(node: Node, out: Array[REEEplayTracked]) -> void:
	if node is REEEplayTracked:
		out.append(node as REEEplayTracked)
	for child in node.get_children():
		_collect_tracked(child, out)


## Recursively collects all REEEplaySession nodes under root.
static func find_all_sessions(root: Node) -> Array[REEEplaySession]:
	var out: Array[REEEplaySession] = []
	if root == null:
		return out
	_collect_sessions(root, out)
	return out


static func _collect_sessions(node: Node, out: Array[REEEplaySession]) -> void:
	if node is REEEplaySession:
		out.append(node as REEEplaySession)
	for child in node.get_children():
		_collect_sessions(child, out)


## Finds the REEEplayTracked component managing node (or parent/child hierarchy).
static func find_tracked_for_node(node: Node) -> REEEplayTracked:
	if node == null:
		return null
	if node is REEEplayTracked:
		return node as REEEplayTracked
	for child in node.get_children():
		if child is REEEplayTracked:
			return child as REEEplayTracked
	var cur := node.get_parent()
	while cur != null:
		if cur is REEEplayTracked:
			var t := cur as REEEplayTracked
			if t.get_effective_target() == node:
				return t
		for sib in cur.get_children():
			if sib is REEEplayTracked and (sib as REEEplayTracked).get_effective_target() == node:
				return sib as REEEplayTracked
		cur = cur.get_parent()
	return null


## Computes readiness checks, resolved rate inheritance, and bandwidth estimate for a REEEplayTracked node.
static func diagnose_tracked(tracked: REEEplayTracked) -> Dictionary:
	var checks: Array[Dictionary] = []
	if tracked == null:
		return {
			"ready": false,
			"summary": "No REEEplayTracked",
			"checks": checks,
			"effective_hz": 0.0,
			"rate_chain": "none",
			"bytes_per_sec": 0.0,
			"channel_count": 0,
		}

	var target := tracked.get_effective_target()
	var target_ok := target != null
	checks.append({
		"ok": target_ok,
		"severity": "ok" if target_ok else "err",
		"title": "Target",
		"detail": target.name if target_ok else "Missing parent or target_node",
	})

	var arch := tracked.archetype
	var channels: Array = _resolved_channels(tracked)
	var ch_count := channels.size()
	var ch_over_limit := ch_count > 64
	checks.append({
		"ok": ch_count > 0 and not ch_over_limit,
		"severity": "err" if ch_over_limit else ("ok" if ch_count > 0 else "warn"),
		"title": "Channels",
		"detail": "%d explicit" % ch_count if ch_count > 0 else "Auto-inferred from node type",
	})

	var has_proxy := tracked.proxy_scene != null or (arch != null and arch.proxy_scene != null)
	var proxy_ok := has_proxy or tracked.fallback_to_source_scene
	checks.append({
		"ok": has_proxy,
		"severity": "ok" if has_proxy else ("warn" if tracked.fallback_to_source_scene else "err"),
		"title": "Proxy Scene",
		"detail": "Assigned" if has_proxy else ("Fallback to source scene" if tracked.fallback_to_source_scene else "Missing proxy_scene"),
	})

	var has_key := tracked.stable_key != &""
	checks.append({
		"ok": has_key,
		"severity": "ok" if has_key else "warn",
		"title": "Stable Key",
		"detail": String(tracked.stable_key) if has_key else "Auto-assigned at track time",
	})

	var resolved_tick := int(REEEplaySettings.value(&"reeeplay/recording/tick_rate"))
	if resolved_tick <= 0:
		resolved_tick = Engine.physics_ticks_per_second
	resolved_tick = maxi(1, resolved_tick)

	var base_sample := float(REEEplaySettings.value(&"reeeplay/recording/sample_rate"))
	var preset_idx := int(REEEplaySettings.value(&"reeeplay/recording/preset"))
	var rate_source := "Project"
	if preset_idx != REEEplayPreset.Kind.CUSTOM:
		var p := REEEplayPreset.from_kind(preset_idx as REEEplayPreset.Kind)
		resolved_tick = maxi(1, p.tick_rate)
		base_sample = float(p.sample_rate)
		rate_source = "Preset"
	if tracked.sample_rate > 0.0:
		base_sample = tracked.sample_rate
		rate_source = "Entity"

	var div := maxi(1, roundi(float(resolved_tick) / maxf(0.1, base_sample)))
	if arch != null and arch.default_divider > 1 and tracked.sample_rate <= 0.0:
		div = maxi(1, arch.default_divider)
		rate_source = "Archetype"
	var effective_hz := float(resolved_tick) / float(div)

	var bytes_per_sample := _estimate_channels_bytes(channels, target)
	var bytes_per_sec := bytes_per_sample * effective_hz
	var ready := target_ok and proxy_ok and not ch_over_limit
	var summary := "%.1f Hz · ~%.0f B/s" % [effective_hz, bytes_per_sec]
	var rate_chain := "%s (%.1f Hz -> div %d @ %d tick/s)" % [rate_source, effective_hz, div, resolved_tick]

	return {
		"ready": ready,
		"summary": summary if ready else "Setup incomplete",
		"checks": checks,
		"effective_hz": effective_hz,
		"rate_chain": rate_chain,
		"bytes_per_sec": bytes_per_sec,
		"channel_count": ch_count,
	}


## Attaches or updates a REEEplayTracked component on target with sensible transform/visibility channels.
static func auto_setup_node(target: Node, scene_root: Node = null) -> REEEplayTracked:
	if target == null:
		return null
	var tracked := find_tracked_for_node(target)
	if tracked == null:
		tracked = REEEplayTracked.new()
		tracked.name = "REEEplayTracked"
		target.add_child(tracked)
		var owner_node := scene_root if scene_root != null else target.owner
		if owner_node != null and owner_node != tracked:
			tracked.owner = owner_node
	if tracked.stable_key == &"":
		tracked.stable_key = StringName(target.name)
	if tracked.display_name.is_empty():
		tracked.display_name = target.name
	if tracked.custom_channels.is_empty() and (tracked.archetype == null or tracked.archetype.channels.is_empty()):
		if target is Node3D:
			add_channel_preset(tracked, &"transform_3d")
		elif target is Node2D:
			add_channel_preset(tracked, &"transform_2d")
		if target is Skeleton3D:
			add_channel_preset(tracked, &"skeleton_pose")
		if target is Node3D or target is CanvasItem:
			add_channel_preset(tracked, &"visibility")
	tracked.update_configuration_warnings()
	return tracked


## Appends a REEEplayChannelPresets bundle onto a REEEplayTracked or REEEplayArchetype without duplicate channel names.
static func add_channel_preset(holder: Object, preset_key: StringName) -> int:
	if holder == null:
		return 0
	var incoming: Array[REEEplayChannel] = []
	match preset_key:
		&"transform_3d":
			incoming = REEEplayChannelPresets.transform_3d()
		&"transform_3d_full":
			incoming = REEEplayChannelPresets.transform_3d_full()
		&"transform_2d":
			incoming = REEEplayChannelPresets.transform_2d()
		&"skeleton_pose":
			incoming = REEEplayChannelPresets.skeleton_pose()
		&"visibility":
			incoming = REEEplayChannelPresets.visibility()
		&"velocity_3d":
			incoming = REEEplayChannelPresets.velocity_3d()
		&"velocity_2d":
			incoming = REEEplayChannelPresets.velocity_2d()
		&"camera_3d":
			incoming = REEEplayChannelPresets.camera_3d()
		&"camera_2d":
			incoming = REEEplayChannelPresets.camera_2d()
		_:
			return 0

	var target_list: Array[REEEplayChannel] = []
	var is_tracked := holder is REEEplayTracked
	var is_arch := holder is REEEplayArchetype
	if is_tracked:
		target_list = (holder as REEEplayTracked).custom_channels
	elif is_arch:
		target_list = (holder as REEEplayArchetype).channels
	else:
		return 0

	var existing: Dictionary[StringName, bool] = {}
	for ch in target_list:
		if ch != null:
			existing[ch.effective_name()] = true

	var added := 0
	for ch in incoming:
		var cname := ch.effective_name()
		if existing.has(cname):
			continue
		target_list.append(ch)
		existing[cname] = true
		added += 1

	if is_tracked:
		(holder as REEEplayTracked).custom_channels = target_list
	elif is_arch:
		(holder as REEEplayArchetype).channels = target_list
	return added


## Generates a stripped visual-only PackedScene proxy from tracked's target node and assigns it.
static func generate_proxy_scene(tracked: REEEplayTracked, save_path: String = "") -> Dictionary:
	if tracked == null:
		return {"ok": false, "scene": null, "path": "", "message": "REEEplayTracked is null."}
	var target := tracked.get_effective_target()
	if target == null:
		return {"ok": false, "scene": null, "path": "", "message": "No target node found to duplicate."}

	var dup := target.duplicate()
	if dup == null:
		return {"ok": false, "scene": null, "path": "", "message": "Failed to duplicate target node."}

	REEEplayProxyFactory.sanitize_node(dup, true, true)
	_set_owner_recursive(dup, dup)

	var packed := PackedScene.new()
	var err := packed.pack(dup)
	dup.free()
	if err != OK:
		return {"ok": false, "scene": null, "path": save_path, "message": "PackedScene.pack failed (%d)." % err}

	if not save_path.is_empty():
		var dir := save_path.get_base_dir()
		if not dir.is_empty():
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir) if dir.begins_with("res://") or dir.begins_with("user://") else dir)
		var serr := ResourceSaver.save(packed, save_path)
		if serr != OK:
			return {"ok": false, "scene": packed, "path": save_path, "message": "Saved in memory, but ResourceSaver failed (%d)." % serr}

	tracked.proxy_scene = packed
	var loc_msg := save_path if not save_path.is_empty() else "memory-only PackedScene"
	return {"ok": true, "scene": packed, "path": save_path, "message": "Generated proxy scene (%s)." % loc_msg}


## Estimates bandwidth and CPU budget for N entities under the supplied sampling settings.
static func estimate_budget(
	sample_rate_hz: float,
	entity_count: int = 50,
	bytes_per_entity_sample: float = 18.0,
	keyframe_interval_sec: float = 5.0,
	active_ratio: float = 0.65
) -> Dictionary:
	var hz := maxf(0.1, sample_rate_hz)
	var ents := maxi(1, entity_count)
	var ratio := clampf(active_ratio, 0.05, 1.0)
	var kf_sec := maxf(0.5, keyframe_interval_sec)

	# Active deltas + periodic keyframe overhead amortized over keyframe_interval_sec.
	var delta_bps := hz * float(ents) * ratio * bytes_per_entity_sample
	var kf_bps := (float(ents) * bytes_per_entity_sample * 1.4) / kf_sec
	var total_bps := delta_bps + kf_bps
	var kb_per_sec := total_bps / 1024.0
	var mb_per_min := (kb_per_sec * 60.0) / 1024.0
	var mb_per_hour := mb_per_min * 60.0
	# Heuristic ~3.5 us per sampled active entity + 0.04 ms fixed bookkeeping at peak sample ticks.
	var est_tick_ms := 0.04 + float(ents) * ratio * 0.0035

	return {
		"sample_rate_hz": hz,
		"entity_count": ents,
		"kb_per_sec": kb_per_sec,
		"mb_per_min": mb_per_min,
		"mb_per_hour": mb_per_hour,
		"est_tick_ms": est_tick_ms,
		"keyframe_interval_sec": kf_sec,
	}


## Loads a .reee file (lazy blocks) and extracts structured summary, entity, event, damage, and block breakdowns.
static func inspect_reee_file(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {
			"ok": false,
			"error_message": "File not found: %s" % path,
			"file_size_bytes": 0,
			"recording": null,
			"summary": {},
			"entities": [],
			"events": [],
			"damage": [],
			"blocks": {"count": 0, "payload_bytes": 0, "raw_bytes": 0, "keyframes": 0},
		}

	var fa := FileAccess.open(path, FileAccess.READ)
	var file_size := int(fa.get_length()) if fa != null else 0
	if fa != null:
		fa.close()

	var read_res := REEEplayReader.load_file(path, {"lazy_blocks": true})
	if read_res.error != REEEplayFormat.LoadError.OK or read_res.recording == null:
		return {
			"ok": false,
			"error_message": read_res.error_message,
			"file_size_bytes": file_size,
			"recording": null,
			"summary": {},
			"entities": [],
			"events": [],
			"damage": [],
			"blocks": {"count": 0, "payload_bytes": 0, "raw_bytes": 0, "keyframes": 0},
		}

	var rec := read_res.recording
	var entities_out: Array[Dictionary] = []
	for eid in rec.entities:
		var info := rec.entities[eid]
		if info == null:
			continue
		var ch_list: Array[String] = []
		for cname in info.channel_names:
			ch_list.append(String(cname))
		entities_out.append({
			"entity_id": info.entity_id,
			"display_name": info.display_name,
			"archetype_id": String(info.archetype_id),
			"stable_key": String(info.stable_key),
			"team_id": info.team_id,
			"spawn_tick": info.spawn_tick,
			"despawn_tick": info.despawn_tick,
			"channels": ch_list,
		})

	var events_out: Array[Dictionary] = []
	for ev in rec.events:
		if ev == null:
			continue
		events_out.append({
			"event_id": ev.event_id,
			"tick": ev.tick,
			"timestamp": ev.timestamp,
			"type_id": String(ev.get_type_id()),
			"category": String(ev.category),
			"label": ev.get_timeline_label(),
		})

	var damage_out: Array[Dictionary] = []
	for de in rec.damage_log.entries:
		if de == null:
			continue
		var actor_name := de.actor.display_name if de.actor != null else ("Environment" if de.is_environmental else "Unknown")
		var victim_name := de.target.display_name if de.target != null else "Target"
		damage_out.append({
			"hit_id": de.hit_id,
			"tick": de.tick,
			"is_heal": de.is_heal,
			"is_environmental": de.is_environmental,
			"is_killing_blow": de.is_killing_blow,
			"amount": de.amount,
			"damage_type": String(de.damage_type),
			"source_name": de.source_name,
			"actor": actor_name,
			"victim": victim_name,
			"label": de.get_timeline_label(),
		})

	var total_payload := 0
	var total_raw := 0
	var keyframe_count := 0
	for blk in rec.blocks:
		total_payload += blk.payload_size
		total_raw += blk.raw_size
		if blk.is_keyframe:
			keyframe_count += 1

	var summary := {
		"recording_id": rec.recording_id,
		"game_id": rec.game_id,
		"game_version": rec.game_version,
		"scene_path": rec.scene_path,
		"tick_rate": rec.tick_rate,
		"total_ticks": rec.total_ticks,
		"duration_seconds": rec.get_duration_seconds(),
		"entity_count": rec.entities.size(),
		"event_count": rec.events.size(),
		"damage_count": rec.damage_log.size(),
		"block_count": rec.blocks.size(),
		"metadata": rec.metadata,
	}

	return {
		"ok": true,
		"error_message": "",
		"file_size_bytes": file_size,
		"recording": rec,
		"summary": summary,
		"entities": entities_out,
		"events": events_out,
		"damage": damage_out,
		"blocks": {
			"count": rec.blocks.size(),
			"payload_bytes": total_payload,
			"raw_bytes": total_raw,
			"keyframes": keyframe_count,
		},
	}


static func _resolved_channels(tracked: REEEplayTracked) -> Array:
	if not tracked.custom_channels.is_empty():
		return tracked.custom_channels
	if tracked.archetype != null and not tracked.archetype.channels.is_empty():
		return tracked.archetype.channels
	return []


static func _estimate_channels_bytes(channels: Array, target: Node) -> float:
	if channels.is_empty():
		return 14.0 if (target is Node3D) else (8.0 if target is Node2D else 10.0)
	var total := 0.0
	for ch_var in channels:
		var ch := ch_var as REEEplayChannel
		if ch == null:
			continue
		match ch.codec:
			REEEplayCodec.Id.BOOL:
				total += 1.0
			REEEplayCodec.Id.INT_VAR, REEEplayCodec.Id.F16, REEEplayCodec.Id.ANGLE_U16:
				total += 2.0
			REEEplayCodec.Id.F32, REEEplayCodec.Id.COLOR_RGBA8, REEEplayCodec.Id.STRING_REF, REEEplayCodec.Id.VEC2_Q16:
				total += 4.0
			REEEplayCodec.Id.VEC3_Q16, REEEplayCodec.Id.QUAT_S3:
				total += 6.0
			REEEplayCodec.Id.VEC2_F32:
				total += 8.0
			REEEplayCodec.Id.VEC3_F32:
				total += 12.0
			REEEplayCodec.Id.TRANSFORM2D:
				total += 24.0
			REEEplayCodec.Id.TRANSFORM3D:
				total += 48.0
			REEEplayCodec.Id.SKELETON_POSE:
				total += 140.0
			_:
				total += 12.0
	return maxf(4.0, total)


static func _set_owner_recursive(node: Node, owner_root: Node) -> void:
	for child in node.get_children():
		if child != owner_root:
			child.owner = owner_root
		_set_owner_recursive(child, owner_root)
