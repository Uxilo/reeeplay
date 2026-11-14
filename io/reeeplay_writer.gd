class_name REEEplayWriter
extends RefCounted
## Serializes a REEEplayRecording into a .reee binary file (or PackedByteArray) with zstd + CRC32.


static func save_file(
	recording: REEEplayRecording,
	path: String,
	compress: bool = true,
	event_registry: REEEplayEventRegistry = null
) -> int:
	if recording == null or path.is_empty():
		return ERR_INVALID_PARAMETER

	var abs_dir := path.get_base_dir()
	if not abs_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(abs_dir)

	var tmp_path := path + ".tmp"
	var bytes := serialize_to_bytes(recording, compress, event_registry)
	if bytes.is_empty():
		return ERR_CANT_CREATE

	var fa := FileAccess.open(tmp_path, FileAccess.WRITE)
	if fa == null:
		return FileAccess.get_open_error()
	fa.store_buffer(bytes)
	fa.flush()
	fa.close()

	# Atomic rename/replace where supported.
	var rename_err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path) if tmp_path.begins_with("res://") or tmp_path.begins_with("user://") else tmp_path,
		ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	)
	if rename_err != OK:
		# Fallback overwrite directly if rename failed (e.g., cross-filesystem or virtual path).
		var direct := FileAccess.open(path, FileAccess.WRITE)
		if direct == null:
			return FileAccess.get_open_error()
		direct.store_buffer(bytes)
		direct.close()
	return OK


static func serialize_to_bytes(
	recording: REEEplayRecording,
	compress: bool = true,
	event_registry: REEEplayEventRegistry = null
) -> PackedByteArray:
	if recording == null:
		return PackedByteArray()

	var reg := event_registry if event_registry != null else REEEplayEventRegistry.new(true)
	var min_comp_bytes := maxi(0, int(REEEplaySettings.value(&"reeeplay/storage/compression_min_bytes")))
	var st := recording.string_table

	var out := StreamPeerBuffer.new()
	out.big_endian = false

	# 16-byte Header: "REEE" + major(u16) + minor(u16) + flags(u32) + reserved(u32)
	REEEplayFormat.put_fourcc(out, REEEplayFormat.MAGIC_HEADER)
	out.put_u16(REEEplayFormat.FORMAT_MAJOR)
	out.put_u16(REEEplayFormat.FORMAT_MINOR)
	out.put_u32(1 if compress else 0)
	out.put_u32(0)

	var chunk_offsets: Dictionary[String, Dictionary] = {}

	# Write chunks that intern into string_table BEFORE writing STRT.
	chunk_offsets[REEEplayFormat.FOURCC_META] = _write_chunk(
		out, REEEplayFormat.FOURCC_META, 1, REEEplayFormat.CHUNK_FLAG_CRITICAL,
		_encode_meta(recording, st), compress, min_comp_bytes
	)
	chunk_offsets[REEEplayFormat.FOURCC_ENTS] = _write_chunk(
		out, REEEplayFormat.FOURCC_ENTS, 1, REEEplayFormat.CHUNK_FLAG_CRITICAL,
		_encode_ents(recording, st), compress, min_comp_bytes
	)

	var block_index: Array[Dictionary] = []
	for bi in range(recording.block_count()):
		var blk := recording.get_block(bi)
		if blk == null:
			continue
		var blk_offset := out.get_position()
		var blk_raw := _encode_frame_block(recording, blk, st)
		var blk_info := _write_chunk(
			out, REEEplayFormat.FOURCC_FBLK, 1, 0,
			blk_raw, compress, min_comp_bytes
		)
		block_index.append({
			"start_tick": blk.start_tick,
			"tick_count": blk.tick_count,
			"is_keyframe": blk.is_keyframe,
			"offset": blk_offset,
			"payload_size": int(blk_info["payload_size"]),
			"raw_size": int(blk_info["raw_size"]),
			"chunk_flags": int(blk_info["chunk_flags"]),
		})

	chunk_offsets[REEEplayFormat.FOURCC_EVNT] = _write_chunk(
		out, REEEplayFormat.FOURCC_EVNT, 1, 0,
		_encode_events(recording, reg, st), compress, min_comp_bytes
	)
	chunk_offsets[REEEplayFormat.FOURCC_ATTH] = _write_chunk(
		out, REEEplayFormat.FOURCC_ATTH, 1, 0,
		_encode_attachments(recording, reg, st), compress, min_comp_bytes
	)
	chunk_offsets[REEEplayFormat.FOURCC_WRLD] = _write_chunk(
		out, REEEplayFormat.FOURCC_WRLD, 1, 0,
		_encode_world_state(recording, st), compress, min_comp_bytes
	)

	# Write STRT after all chunks so every interned string is preserved.
	chunk_offsets[REEEplayFormat.FOURCC_STRT] = _write_chunk(
		out, REEEplayFormat.FOURCC_STRT, 1, REEEplayFormat.CHUNK_FLAG_CRITICAL,
		st.to_bytes(), compress, min_comp_bytes
	)

	# Write INDX at index_offset.
	var index_offset := out.get_position()
	_write_chunk(
		out, REEEplayFormat.FOURCC_INDX, 1, REEEplayFormat.CHUNK_FLAG_CRITICAL,
		_encode_index(chunk_offsets, block_index), false, min_comp_bytes
	)

	# CRC32 over everything before footer.
	var body_bytes := out.data_array
	var crc := REEEplayFormat.crc32(body_bytes, body_bytes.size())

	# 16-byte Footer: index_offset(u64) + crc32(u32) + "EEER"(4B)
	out.put_u64(index_offset)
	out.put_u32(crc)
	REEEplayFormat.put_fourcc(out, REEEplayFormat.MAGIC_FOOTER)
	return out.data_array


static func _write_chunk(
	out: StreamPeerBuffer,
	fourcc: String,
	chunk_version: int,
	base_flags: int,
	raw_payload: PackedByteArray,
	allow_compress: bool,
	min_compress_bytes: int
) -> Dictionary:
	var offset := out.get_position()
	var payload := raw_payload
	var flags := base_flags
	if allow_compress and raw_payload.size() >= min_compress_bytes:
		var compressed := raw_payload.compress(FileAccess.COMPRESSION_ZSTD)
		if compressed.size() > 0 and compressed.size() < raw_payload.size():
			payload = compressed
			flags |= REEEplayFormat.CHUNK_FLAG_ZSTD

	REEEplayFormat.put_fourcc(out, fourcc)
	out.put_u16(chunk_version)
	out.put_u16(flags)
	out.put_u32(payload.size())
	out.put_u32(raw_payload.size())
	if not payload.is_empty():
		out.put_data(payload)

	return {
		"offset": offset,
		"payload_size": payload.size(),
		"raw_size": raw_payload.size(),
		"chunk_flags": flags,
	}


static func _encode_meta(rec: REEEplayRecording, st: REEEplayByteUtils.StringTable) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	REEEplayByteUtils.put_utf8(b, rec.recording_id)
	REEEplayByteUtils.put_utf8(b, rec.game_id)
	REEEplayByteUtils.put_utf8(b, rec.game_version)
	REEEplayByteUtils.put_utf8(b, rec.scene_path)
	b.put_u64(maxi(0, rec.recorded_at_unix))
	REEEplayByteUtils.put_varuint(b, maxi(1, rec.tick_rate))
	REEEplayByteUtils.put_varuint(b, maxi(0, rec.start_tick))
	REEEplayByteUtils.put_varuint(b, maxi(0, rec.total_ticks))
	REEEplayByteUtils.put_varuint(b, maxi(0, rec.local_player_entity_id))

	REEEplayByteUtils.put_varuint(b, rec.tags.size())
	for t in rec.tags:
		REEEplayByteUtils.put_varuint(b, st.intern(t))

	var meta_bytes := var_to_bytes(rec.metadata)
	REEEplayByteUtils.put_varuint(b, meta_bytes.size())
	if not meta_bytes.is_empty():
		b.put_data(meta_bytes)
	return b.data_array


static func _encode_ents(rec: REEEplayRecording, st: REEEplayByteUtils.StringTable) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	var ids: Array[int] = []
	for eid in rec.entities:
		ids.append(eid)
	ids.sort()

	REEEplayByteUtils.put_varuint(b, ids.size())
	for eid in ids:
		var info := rec.entities[eid]
		REEEplayByteUtils.put_varuint(b, info.entity_id)
		REEEplayByteUtils.put_varuint(b, st.intern(info.archetype_id))
		REEEplayByteUtils.put_varuint(b, st.intern(info.stable_key))
		REEEplayByteUtils.put_utf8(b, info.display_name)
		REEEplayByteUtils.put_utf8(b, info.player_id)
		REEEplayByteUtils.put_varint(b, info.team_id)
		REEEplayByteUtils.put_varuint(b, maxi(0, info.spawn_tick))
		REEEplayByteUtils.put_varint(b, info.despawn_tick)
		REEEplayByteUtils.put_utf8(b, info.scene_path)
		REEEplayByteUtils.put_varuint(b, maxi(1, info.initial_divider))
		REEEplayByteUtils.put_varuint(b, maxi(0, info.initial_phase))
		REEEplayByteUtils.put_varint(b, info.priority)

		var ch_count := info.channel_names.size()
		REEEplayByteUtils.put_varuint(b, ch_count)
		for i in range(ch_count):
			REEEplayByteUtils.put_varuint(b, st.intern(info.channel_names[i]))
			REEEplayByteUtils.put_varuint(b, int(info.channel_codecs[i]) if i < info.channel_codecs.size() else REEEplayCodec.Id.VARIANT)
			b.put_float(info.channel_steps[i] if i < info.channel_steps.size() else 0.001)
			b.put_u8(1 if (i < info.channel_interpolated.size() and info.channel_interpolated[i]) else 0)

		var emeta := var_to_bytes(info.metadata)
		REEEplayByteUtils.put_varuint(b, emeta.size())
		if not emeta.is_empty():
			b.put_data(emeta)
	return b.data_array


static func _encode_frame_block(
	rec: REEEplayRecording,
	blk: REEEplayRecording.FrameBlock,
	st: REEEplayByteUtils.StringTable
) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	REEEplayByteUtils.put_varuint(b, maxi(0, blk.start_tick))
	REEEplayByteUtils.put_varuint(b, blk.ticks.size())
	b.put_u8(1 if blk.is_keyframe else 0)

	var prev_tick := blk.start_tick
	for ti in range(blk.ticks.size()):
		var td := blk.ticks[ti]
		var delta_t := maxi(0, td.tick - prev_tick)
		prev_tick = td.tick
		REEEplayByteUtils.put_varuint(b, delta_t)

		REEEplayByteUtils.put_varuint(b, td.rate_changes.size())
		for rc in td.rate_changes:
			REEEplayByteUtils.put_varuint(b, rc.entity_id)
			REEEplayByteUtils.put_varuint(b, maxi(1, rc.divider))
			REEEplayByteUtils.put_varuint(b, maxi(0, rc.phase))

		REEEplayByteUtils.put_varuint(b, td.spawns.size())
		for sid in td.spawns:
			REEEplayByteUtils.put_varuint(b, sid)

		REEEplayByteUtils.put_varuint(b, td.despawns.size())
		for did in td.despawns:
			REEEplayByteUtils.put_varuint(b, did)

		REEEplayByteUtils.put_varuint(b, td.entities.size())
		for ef in td.entities:
			REEEplayByteUtils.put_varuint(b, ef.entity_id)
			var info := rec.get_entity_info(ef.entity_id)
			var ch_count := info.channel_count() if info != null else 0
			var word_count := maxi(1, ceili(float(ch_count) / 31.0))

			# Write 31-bit bitmask words, then emit values in ascending channel index order.
			for w in range(word_count):
				var mask := 0
				var base_idx := w * 31
				for bit in range(31):
					var cidx := base_idx + bit
					if ef.values.has(cidx):
						mask |= (1 << bit)
				REEEplayByteUtils.put_varuint(b, mask)

			var sorted_idxs: Array[int] = []
			for cidx_var in ef.values:
				sorted_idxs.append(int(cidx_var))
			sorted_idxs.sort()
			for cidx in sorted_idxs:
				var codec_id := REEEplayCodec.Id.VARIANT
				var qstep := 0.001
				if info != null and cidx < info.channel_codecs.size():
					codec_id = info.channel_codecs[cidx]
					qstep = info.channel_steps[cidx]
				REEEplayCodec.encode(b, ef.values[cidx], codec_id, st, qstep)

	return b.data_array


static func _encode_events(
	rec: REEEplayRecording,
	reg: REEEplayEventRegistry,
	st: REEEplayByteUtils.StringTable
) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	REEEplayByteUtils.put_varuint(b, rec.events.size())
	for ev in rec.events:
		reg.serialize_event(b, ev, st)
	return b.data_array


static func _encode_attachments(
	rec: REEEplayRecording,
	reg: REEEplayEventRegistry,
	st: REEEplayByteUtils.StringTable
) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	REEEplayByteUtils.put_varuint(b, rec.attachments.size())
	for att in rec.attachments:
		reg.serialize_attachment(b, att, st)
	return b.data_array


static func _encode_world_state(rec: REEEplayRecording, st: REEEplayByteUtils.StringTable) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	REEEplayByteUtils.put_varuint(b, rec.world_state_timeline.size())
	for key in rec.world_state_timeline:
		REEEplayByteUtils.put_varuint(b, st.intern(key))
		var arr: Array = rec.world_state_timeline[key]
		REEEplayByteUtils.put_varuint(b, arr.size())
		for item in arr:
			var d: Dictionary = item
			REEEplayByteUtils.put_varuint(b, maxi(0, int(d["tick"])))
			var raw := var_to_bytes(d["value"])
			REEEplayByteUtils.put_varuint(b, raw.size())
			if not raw.is_empty():
				b.put_data(raw)
	return b.data_array


static func _encode_index(chunk_offsets: Dictionary[String, Dictionary], block_index: Array[Dictionary]) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.big_endian = false

	REEEplayByteUtils.put_varuint(b, chunk_offsets.size())
	for fourcc in chunk_offsets:
		var info := chunk_offsets[fourcc]
		REEEplayFormat.put_fourcc(b, fourcc)
		b.put_u64(int(info["offset"]))

	REEEplayByteUtils.put_varuint(b, block_index.size())
	for bi in block_index:
		REEEplayByteUtils.put_varuint(b, int(bi["start_tick"]))
		REEEplayByteUtils.put_varuint(b, int(bi["tick_count"]))
		b.put_u8(1 if bool(bi["is_keyframe"]) else 0)
		b.put_u64(int(bi["offset"]))
		b.put_u32(int(bi["payload_size"]))
		b.put_u32(int(bi["raw_size"]))
		b.put_u16(int(bi["chunk_flags"]))
	return b.data_array
