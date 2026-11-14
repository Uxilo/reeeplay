class_name REEEplayRecording
extends RefCounted
## Complete replay container storing metadata, string table, entity schemas, frame blocks, events, attachments, damage logs, and world state.


class EntityFrame extends RefCounted:
	var entity_id: int = 0
	## Dictionary[int (channel index), Variant (decoded value)]
	var values: Dictionary[int, Variant] = {}

	func duplicate_frame() -> EntityFrame:
		var f := EntityFrame.new()
		f.entity_id = entity_id
		for k in values:
			f.values[k] = _copy_val(values[k])
		return f

	static func _copy_val(v: Variant) -> Variant:
		if v is Array or v is Dictionary:
			return v.duplicate(true)
		return v


class RateChange extends RefCounted:
	var entity_id: int = 0
	var divider: int = 1
	var phase: int = 0


class TickData extends RefCounted:
	var tick: int = 0
	var rate_changes: Array[RateChange] = []
	var spawns: PackedInt32Array = PackedInt32Array()
	var despawns: PackedInt32Array = PackedInt32Array()
	var entities: Array[EntityFrame] = []


class FrameBlock extends RefCounted:
	var start_tick: int = 0
	var tick_count: int = 0
	var is_keyframe: bool = true
	var ticks: Array[TickData] = []
	var file_offset: int = -1
	var payload_size: int = 0
	var raw_size: int = 0
	var is_compressed: bool = false
	var chunk_flags: int = 0

	func end_tick() -> int:
		return start_tick + maxi(0, tick_count - 1)


var format_major: int = 1
var format_minor: int = 0
var recording_id: String = ""
var game_id: String = ""
var game_version: String = ""
var scene_path: String = ""
var recorded_at_unix: int = 0
var tick_rate: int = 30
var start_tick: int = 0
var total_ticks: int = 0
var local_player_entity_id: int = 0
var tags: Array[StringName] = []
var metadata: Dictionary = {}

var string_table: REEEplayByteUtils.StringTable = REEEplayByteUtils.StringTable.new()
var entities: Dictionary[int, REEEplayEntityInfo] = {}
var archetypes: Dictionary[StringName, REEEplayArchetype] = {}
var blocks: Array[FrameBlock] = []
var events: Array[REEEplayEvent] = []
var attachments: Array[REEEplayAttachment] = []
var damage_log: REEEplayDamageLog = REEEplayDamageLog.new()

## Timeline per world-state key: StringName -> Array[{"tick": int, "value": Variant}]
var world_state_timeline: Dictionary[StringName, Array] = {}

## Lazy file reader backing (set by REEEplayReader when loaded with lazy block streaming).
var _lazy_reader: RefCounted = null
var _lru_order: Array[int] = []
var block_cache_capacity: int = 32


func get_end_tick() -> int:
	if total_ticks <= 0:
		return start_tick
	return start_tick + total_ticks - 1


func get_duration_seconds() -> float:
	return float(maxi(0, total_ticks)) / float(maxi(1, tick_rate))


func block_count() -> int:
	return blocks.size()


## Returns the decoded FrameBlock at block_idx, loading from disk + updating LRU cache if lazy-backed.
func get_block(block_idx: int) -> FrameBlock:
	if block_idx < 0 or block_idx >= blocks.size():
		return null
	var blk := blocks[block_idx]
	if blk.ticks.is_empty() and blk.tick_count > 0 and _lazy_reader != null:
		_lazy_reader.call("load_block_into", self, blk)
		_touch_lru(block_idx)
	elif _lazy_reader != null:
		_touch_lru(block_idx)
	return blk


func find_block_index_for_tick(tick: int) -> int:
	if blocks.is_empty():
		return -1
	var lo := 0
	var hi := blocks.size() - 1
	var best := 0
	while lo <= hi:
		var mid := (lo + hi) >> 1
		var s := blocks[mid].start_tick
		if s <= tick:
			best = mid
			lo = mid + 1
		else:
			hi = mid - 1
	return best


func get_entity_info(entity_id: int) -> REEEplayEntityInfo:
	return entities.get(entity_id, null)


func set_world_state_entry(key: StringName, tick: int, value: Variant) -> void:
	if key == &"":
		return
	var timeline: Array = world_state_timeline.get(key, [])
	if not timeline.is_empty():
		var last: Dictionary = timeline[timeline.size() - 1]
		if int(last["tick"]) == tick:
			last["value"] = value
			return
	timeline.append({"tick": tick, "value": value})
	world_state_timeline[key] = timeline


func get_world_state_keys() -> Array[StringName]:
	var out: Array[StringName] = []
	for k in world_state_timeline:
		out.append(k)
	return out


func get_world_state_at(key: StringName, tick: int, default_value: Variant = null) -> Variant:
	var timeline: Array = world_state_timeline.get(key, [])
	if timeline.is_empty():
		return default_value
	var lo := 0
	var hi := timeline.size() - 1
	var best_idx := -1
	while lo <= hi:
		var mid := (lo + hi) >> 1
		var t := int((timeline[mid] as Dictionary)["tick"])
		if t <= tick:
			best_idx = mid
			lo = mid + 1
		else:
			hi = mid - 1
	if best_idx < 0:
		return default_value
	return (timeline[best_idx] as Dictionary)["value"]


func get_events_in_range(from_tick: int, to_tick: int, category: StringName = &"") -> Array[REEEplayEvent]:
	var out: Array[REEEplayEvent] = []
	for ev in events:
		if ev.tick < from_tick or ev.tick > to_tick:
			continue
		if category != &"" and ev.category != category:
			continue
		out.append(ev)
	return out


func get_events_by_type(type_id: StringName) -> Array[REEEplayEvent]:
	var out: Array[REEEplayEvent] = []
	for ev in events:
		if ev.get_type_id() == type_id:
			out.append(ev)
	return out


func find_highlights(
	window_seconds: float = 8.0,
	min_score: float = 3.0,
	weights: Dictionary = {}
) -> Array[REEEplayHighlightDetector.HighlightWindow]:
	return REEEplayHighlightDetector.detect(events, tick_rate, window_seconds, min_score, weights)


func anonymize_pii() -> void:
	metadata.erase("host_ip")
	metadata.erase("server_address")
	for eid in entities:
		entities[eid].strip_pii()
	for ev in events:
		ev.strip_pii()
	for att in attachments:
		att.strip_pii()


## Reconstructs exact active entity states at target_tick using cached/lazy blocks.
## Returns { "states": Dictionary[int, Dictionary[int, Variant]], "active": Dictionary[int, bool], "rates": Dictionary[int, Dictionary] }
func reconstruct_state_at_tick(target_tick: int) -> Dictionary:
	var bidx := find_block_index_for_tick(target_tick)
	var states: Dictionary[int, Dictionary] = {}
	var active: Dictionary[int, bool] = {}
	var rates: Dictionary[int, Dictionary] = {}

	if bidx < 0:
		return {"states": states, "active": active, "rates": rates}

	var blk := get_block(bidx)
	if blk == null:
		return {"states": states, "active": active, "rates": rates}

	for td in blk.ticks:
		if td.tick > target_tick:
			break
		for rc in td.rate_changes:
			rates[rc.entity_id] = {"divider": rc.divider, "phase": rc.phase}
		for sid in td.spawns:
			active[sid] = true
			if not states.has(sid):
				states[sid] = {}
		for did in td.despawns:
			active.erase(did)
			states.erase(did)
		for ef in td.entities:
			active[ef.entity_id] = true
			var ent_state: Dictionary = states.get(ef.entity_id, {})
			for ch_idx in ef.values:
				ent_state[ch_idx] = EntityFrame._copy_val(ef.values[ch_idx])
			states[ef.entity_id] = ent_state

	return {"states": states, "active": active, "rates": rates}


## Extracts a self-contained replay clip for [from_tick, to_tick].
func slice(from_tick: int, to_tick: int, rebase_to_zero: bool = true) -> REEEplayRecording:
	var clamped_from := clampi(from_tick, start_tick, get_end_tick())
	var clamped_to := clampi(to_tick, clamped_from, get_end_tick())
	var tick_offset := clamped_from if rebase_to_zero else 0

	var clipped := REEEplayRecording.new()
	clipped.format_major = format_major
	clipped.format_minor = format_minor
	clipped.recording_id = recording_id + "_clip"
	clipped.game_id = game_id
	clipped.game_version = game_version
	clipped.scene_path = scene_path
	clipped.recorded_at_unix = recorded_at_unix
	clipped.tick_rate = tick_rate
	clipped.start_tick = 0 if rebase_to_zero else clamped_from
	clipped.total_ticks = maxi(1, clamped_to - clamped_from + 1)
	clipped.local_player_entity_id = local_player_entity_id
	clipped.tags = tags.duplicate()
	clipped.metadata = metadata.duplicate(true)
	for arch_id in archetypes:
		clipped.archetypes[arch_id] = archetypes[arch_id]

	# Seed first keyframe block from reconstructed state at clamped_from.
	var snap := reconstruct_state_at_tick(clamped_from)
	var active_at_start: Dictionary = snap["active"]
	var states_at_start: Dictionary = snap["states"]
	var rates_at_start: Dictionary = snap["rates"]

	var out_block := FrameBlock.new()
	out_block.start_tick = clamped_from - tick_offset
	out_block.is_keyframe = true

	var key_td := TickData.new()
	key_td.tick = clamped_from - tick_offset
	for eid_var in active_at_start:
		var eid := int(eid_var)
		key_td.spawns.append(eid)
		if rates_at_start.has(eid):
			var rc := RateChange.new()
			rc.entity_id = eid
			rc.divider = int(rates_at_start[eid]["divider"])
			rc.phase = int(rates_at_start[eid]["phase"])
			key_td.rate_changes.append(rc)
		var ef := EntityFrame.new()
		ef.entity_id = eid
		var ch_map: Dictionary = states_at_start.get(eid, {})
		for ch_idx in ch_map:
			ef.values[int(ch_idx)] = EntityFrame._copy_val(ch_map[ch_idx])
		key_td.entities.append(ef)
	out_block.ticks.append(key_td)

	var included_entities: Dictionary[int, bool] = {}
	for eid_var in active_at_start:
		included_entities[int(eid_var)] = true

	# Append remaining ticks inside (clamped_from, clamped_to].
	var start_bidx := maxi(0, find_block_index_for_tick(clamped_from))
	for bi in range(start_bidx, blocks.size()):
		var src_blk := get_block(bi)
		if src_blk == null or src_blk.start_tick > clamped_to:
			break
		for src_td in src_blk.ticks:
			if src_td.tick <= clamped_from:
				continue
			if src_td.tick > clamped_to:
				break
			var nt := TickData.new()
			nt.tick = src_td.tick - tick_offset
			for rc in src_td.rate_changes:
				var nrc := RateChange.new()
				nrc.entity_id = rc.entity_id
				nrc.divider = rc.divider
				nrc.phase = rc.phase
				nt.rate_changes.append(nrc)
			nt.spawns = src_td.spawns.duplicate()
			nt.despawns = src_td.despawns.duplicate()
			for sid in nt.spawns:
				included_entities[sid] = true
			for ef in src_td.entities:
				included_entities[ef.entity_id] = true
				nt.entities.append(ef.duplicate_frame())
			out_block.ticks.append(nt)

	out_block.tick_count = out_block.ticks.size()
	clipped.blocks.append(out_block)

	# Copy relevant entity descriptors.
	for eid in included_entities:
		var info := get_entity_info(eid)
		if info != null:
			var ecopy := info.duplicate_metadata()
			if ecopy.spawn_tick < clamped_from:
				ecopy.spawn_tick = 0 if rebase_to_zero else clamped_from
			else:
				ecopy.spawn_tick -= tick_offset
			if ecopy.despawn_tick >= 0:
				if ecopy.despawn_tick > clamped_to:
					ecopy.despawn_tick = -1
				else:
					ecopy.despawn_tick -= tick_offset
			clipped.entities[eid] = ecopy

	# Copy events & damage log within [clamped_from, clamped_to].
	var registry := REEEplayEventRegistry.new(true)
	for ev in events:
		if ev.tick < clamped_from or ev.tick > clamped_to:
			continue
		var buf := StreamPeerBuffer.new()
		buf.big_endian = false
		var st := REEEplayByteUtils.StringTable.new()
		registry.serialize_event(buf, ev, st)
		buf.seek(0)
		var cloned := registry.deserialize_event(buf, st)
		if cloned != null:
			cloned.tick = ev.tick - tick_offset
			clipped.events.append(cloned)
			if cloned is REEEplayDamageEntry:
				clipped.damage_log.add_entry(cloned as REEEplayDamageEntry)

	# Copy attachments within range.
	for att in attachments:
		if att.tick < clamped_from or att.tick > clamped_to:
			continue
		clipped.attachments.append(att)

	# Carry initial world state at clamped_from + updates in (clamped_from, clamped_to].
	for key in world_state_timeline:
		var init_val: Variant = get_world_state_at(key, clamped_from, null)
		if init_val != null:
			clipped.set_world_state_entry(key, clamped_from - tick_offset, init_val)
		var arr: Array = world_state_timeline[key]
		for item in arr:
			var d: Dictionary = item
			var t := int(d["tick"])
			if t > clamped_from and t <= clamped_to:
				clipped.set_world_state_entry(key, t - tick_offset, d["value"])

	return clipped


func _touch_lru(block_idx: int) -> void:
	var existing := _lru_order.find(block_idx)
	if existing >= 0:
		_lru_order.remove_at(existing)
	_lru_order.append(block_idx)
	var cap := maxi(2, block_cache_capacity)
	while _lru_order.size() > cap:
		var evict_idx := _lru_order[0]
		_lru_order.remove_at(0)
		if evict_idx >= 0 and evict_idx < blocks.size():
			var evict_blk := blocks[evict_idx]
			if evict_blk.file_offset >= 0:
				evict_blk.ticks.clear()

