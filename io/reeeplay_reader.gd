class_name REEEplayReader
extends RefCounted
## Validates and reads .reee binary files with strict bounds checks, CRC32 validation, and lazy block LRU support.


class ReadResult extends RefCounted:
	var error: REEEplayFormat.LoadError = REEEplayFormat.LoadError.OK
	var error_message: String = ""
	var recording: REEEplayRecording = null


var _file_path: String = ""
var _event_registry: REEEplayEventRegistry = null


static func load_file(path: String, options: Dictionary = {}) -> ReadResult:
	var result := ReadResult.new()
	if path.is_empty() or not FileAccess.file_exists(path):
		result.error = REEEplayFormat.LoadError.FILE_NOT_FOUND
		result.error_message = "Replay file not found: %s" % path
		return result

	var fa := FileAccess.open(path, FileAccess.READ)
	if fa == null:
		result.error = REEEplayFormat.LoadError.IO_ERROR
		result.error_message = "Failed to open replay file (%d): %s" % [FileAccess.get_open_error(), path]
		return result

	var file_len := fa.get_length()
	if file_len < REEEplayFormat.HEADER_SIZE + REEEplayFormat.FOOTER_SIZE:
		fa.close()
		result.error = REEEplayFormat.LoadError.CORRUPT_HEADER
		result.error_message = "File smaller than REEEplay header+footer minimum size."
		return result

	# Parse header (little-endian).
	fa.big_endian = false
	var header_bytes := fa.get_buffer(REEEplayFormat.HEADER_SIZE)
	var hbuf := StreamPeerBuffer.new()
	hbuf.big_endian = false
	hbuf.data_array = header_bytes
	if REEEplayFormat.get_fourcc(hbuf) != REEEplayFormat.MAGIC_HEADER:
		fa.close()
		result.error = REEEplayFormat.LoadError.CORRUPT_HEADER
		result.error_message = "Missing REEE magic header."
		return result

	var format_major := hbuf.get_u16()
	var format_minor := hbuf.get_u16()
	if format_major != REEEplayFormat.FORMAT_MAJOR:
		fa.close()
		result.error = REEEplayFormat.LoadError.UNSUPPORTED_MAJOR
		result.error_message = "Unsupported format major version: %d" % format_major
		return result

	# Parse footer.
	var footer_pos := file_len - REEEplayFormat.FOOTER_SIZE
	fa.seek(footer_pos)
	var fbuf := StreamPeerBuffer.new()
	fbuf.big_endian = false
	fbuf.data_array = fa.get_buffer(REEEplayFormat.FOOTER_SIZE)
	var index_offset := fbuf.get_u64()
	var expected_crc := fbuf.get_u32()
	if REEEplayFormat.get_fourcc(fbuf) != REEEplayFormat.MAGIC_FOOTER:
		fa.close()
		result.error = REEEplayFormat.LoadError.CORRUPT_HEADER
		result.error_message = "Missing EEER magic footer."
		return result

	if index_offset < REEEplayFormat.HEADER_SIZE or index_offset >= footer_pos:
		fa.close()
		result.error = REEEplayFormat.LoadError.CORRUPT_HEADER
		result.error_message = "Invalid INDX offset in footer."
		return result

	# Verify streaming CRC32 if enabled.
	if bool(options.get("verify_crc", true)):
		var actual_crc := REEEplayFormat.crc32_file_range(fa, footer_pos)
		if actual_crc < 0 or actual_crc != expected_crc:
			fa.close()
			result.error = REEEplayFormat.LoadError.CRC_MISMATCH
			result.error_message = "CRC32 mismatch (expected %08X, got %08X)." % [expected_crc, actual_crc]
			return result

	# Read INDX chunk.
	var idx_chunk := _read_chunk_at(fa, index_offset, footer_pos)
	if idx_chunk["error"] != REEEplayFormat.LoadError.OK:
		fa.close()
		result.error = idx_chunk["error"]
		result.error_message = str(idx_chunk["message"])
		return result
	if str(idx_chunk["fourcc"]) != REEEplayFormat.FOURCC_INDX:
		fa.close()
		result.error = REEEplayFormat.LoadError.MISSING_CRITICAL_CHUNK
		result.error_message = "Footer index_offset does not point to INDX chunk."
		return result

	var index_data := _decode_index(idx_chunk["raw"] as PackedByteArray)
	if index_data["error"] != REEEplayFormat.LoadError.OK:
		fa.close()
		result.error = index_data["error"]
		result.error_message = str(index_data["message"])
		return result

	var chunk_offsets: Dictionary = index_data["chunk_offsets"]
	for req in [REEEplayFormat.FOURCC_META, REEEplayFormat.FOURCC_STRT, REEEplayFormat.FOURCC_ENTS]:
		if not chunk_offsets.has(req):
			fa.close()
			result.error = REEEplayFormat.LoadError.MISSING_CRITICAL_CHUNK
			result.error_message = "Missing critical chunk: %s" % req
			return result

	var rec := REEEplayRecording.new()
	rec.format_major = format_major
	rec.format_minor = format_minor
	rec.block_cache_capacity = maxi(2, int(REEEplaySettings.value(&"reeeplay/playback/block_cache_size")))

	# Decode STRT first so all subsequent chunks resolve StringNames immediately.
	var strt_chunk := _read_chunk_at(fa, int(chunk_offsets[REEEplayFormat.FOURCC_STRT]), footer_pos)
	if strt_chunk["error"] != REEEplayFormat.LoadError.OK:
		fa.close()
		result.error = strt_chunk["error"]
		result.error_message = str(strt_chunk["message"])
		return result
	rec.string_table = REEEplayByteUtils.StringTable.from_bytes(strt_chunk["raw"] as PackedByteArray, REEEplayFormat.MAX_STRING_COUNT)

	# Decode META.
	var meta_chunk := _read_chunk_at(fa, int(chunk_offsets[REEEplayFormat.FOURCC_META]), footer_pos)
	if meta_chunk["error"] != REEEplayFormat.LoadError.OK:
		fa.close()
		result.error = meta_chunk["error"]
		result.error_message = str(meta_chunk["message"])
		return result
	_decode_meta(rec, meta_chunk["raw"] as PackedByteArray)

	# Optional game version validation.
	var req_version := str(options.get("accepted_game_version", ""))
	if not req_version.is_empty() and rec.game_version != req_version:
		fa.close()
		result.error = REEEplayFormat.LoadError.GAME_VERSION_REJECTED
		result.error_message = "Rejected game_version '%s' (expected '%s')." % [rec.game_version, req_version]
		return result
	if options.has("version_validator") and options["version_validator"] is Callable:
		var validator: Callable = options["version_validator"]
		if validator.is_valid() and not bool(validator.call(rec.game_id, rec.game_version)):
			fa.close()
			result.error = REEEplayFormat.LoadError.GAME_VERSION_REJECTED
			result.error_message = "version_validator rejected game_id=%s game_version=%s." % [rec.game_id, rec.game_version]
			return result

	# Decode ENTS.
	var ents_chunk := _read_chunk_at(fa, int(chunk_offsets[REEEplayFormat.FOURCC_ENTS]), footer_pos)
	if ents_chunk["error"] != REEEplayFormat.LoadError.OK:
		fa.close()
		result.error = ents_chunk["error"]
		result.error_message = str(ents_chunk["message"])
		return result
	var ents_err := _decode_ents(rec, ents_chunk["raw"] as PackedByteArray)
	if ents_err != REEEplayFormat.LoadError.OK:
		fa.close()
		result.error = ents_err
		result.error_message = "ENTS chunk exceeded bounds."
		return result

	var reg: REEEplayEventRegistry = options.get("event_registry", null)
	if reg == null:
		reg = REEEplayEventRegistry.new(true)

	# Decode optional EVNT, ATTH, WRLD.
	if chunk_offsets.has(REEEplayFormat.FOURCC_EVNT):
		var ev_chunk := _read_chunk_at(fa, int(chunk_offsets[REEEplayFormat.FOURCC_EVNT]), footer_pos)
		if ev_chunk["error"] == REEEplayFormat.LoadError.OK:
			_decode_events(rec, ev_chunk["raw"] as PackedByteArray, reg)

	if chunk_offsets.has(REEEplayFormat.FOURCC_ATTH):
		var att_chunk := _read_chunk_at(fa, int(chunk_offsets[REEEplayFormat.FOURCC_ATTH]), footer_pos)
		if att_chunk["error"] == REEEplayFormat.LoadError.OK:
			_decode_attachments(rec, att_chunk["raw"] as PackedByteArray, reg)

	if chunk_offsets.has(REEEplayFormat.FOURCC_WRLD):
		var wrld_chunk := _read_chunk_at(fa, int(chunk_offsets[REEEplayFormat.FOURCC_WRLD]), footer_pos)
		if wrld_chunk["error"] == REEEplayFormat.LoadError.OK:
			_decode_world_state(rec, wrld_chunk["raw"] as PackedByteArray)

	# Populate FrameBlock headers from INDX.
	var block_entries: Array = index_data["block_index"]
	for bdict in block_entries:
		var blk := REEEplayRecording.FrameBlock.new()
		blk.start_tick = int(bdict["start_tick"])
		blk.tick_count = int(bdict["tick_count"])
		blk.is_keyframe = bool(bdict["is_keyframe"])
		blk.file_offset = int(bdict["offset"])
		blk.payload_size = int(bdict["payload_size"])
		blk.raw_size = int(bdict["raw_size"])
		blk.chunk_flags = int(bdict["chunk_flags"])
		blk.is_compressed = (blk.chunk_flags & REEEplayFormat.CHUNK_FLAG_ZSTD) != 0
		rec.blocks.append(blk)

	var reader := REEEplayReader.new()
	reader._file_path = path
	reader._event_registry = reg
	rec._lazy_reader = reader

	var lazy := bool(options.get("lazy_blocks", true))
	if not lazy:
		for i in range(rec.blocks.size()):
			if not reader.load_block_into(rec, rec.blocks[i], fa):
				fa.close()
				result.error = REEEplayFormat.LoadError.BOUNDS_EXCEEDED
				result.error_message = "Failed to decode FBLK #%d." % i
				return result

	fa.close()
	result.recording = rec
	return result


## Reads and decodes a single FrameBlock from disk on demand (used by REEEplayRecording.get_block).
func load_block_into(rec: REEEplayRecording, blk: REEEplayRecording.FrameBlock, open_fa: FileAccess = null) -> bool:
	if blk == null or blk.file_offset < 0:
		return false
	var fa := open_fa
	var should_close := false
	if fa == null:
		fa = FileAccess.open(_file_path, FileAccess.READ)
		if fa == null:
			return false
		should_close = true

	var chunk := _read_chunk_at(fa, blk.file_offset, fa.get_length() - REEEplayFormat.FOOTER_SIZE)
	if should_close:
		fa.close()
	if chunk["error"] != REEEplayFormat.LoadError.OK:
		return false

	return _decode_frame_block(rec, blk, chunk["raw"] as PackedByteArray)


static func _read_chunk_at(fa: FileAccess, offset: int, max_end_offset: int) -> Dictionary:
	if offset < REEEplayFormat.HEADER_SIZE or offset + REEEplayFormat.CHUNK_HEADER_SIZE > max_end_offset:
		return {"error": REEEplayFormat.LoadError.BOUNDS_EXCEEDED, "message": "Chunk offset out of bounds."}

	fa.seek(offset)
	var hdr := fa.get_buffer(REEEplayFormat.CHUNK_HEADER_SIZE)
	if hdr.size() != REEEplayFormat.CHUNK_HEADER_SIZE:
		return {"error": REEEplayFormat.LoadError.IO_ERROR, "message": "Truncated chunk header."}

	var hbuf := StreamPeerBuffer.new()
	hbuf.big_endian = false
	hbuf.data_array = hdr
	var fourcc := REEEplayFormat.get_fourcc(hbuf)
	var _ver := hbuf.get_u16()
	var flags := hbuf.get_u16()
	var payload_size := hbuf.get_u32()
	var raw_size := hbuf.get_u32()

	if payload_size > REEEplayFormat.MAX_CHUNK_BYTES or raw_size > REEEplayFormat.MAX_CHUNK_BYTES:
		return {"error": REEEplayFormat.LoadError.BOUNDS_EXCEEDED, "message": "Chunk size exceeds security limit."}
	if offset + REEEplayFormat.CHUNK_HEADER_SIZE + payload_size > max_end_offset:
		return {"error": REEEplayFormat.LoadError.BOUNDS_EXCEEDED, "message": "Chunk payload extends past file body."}

	var payload := fa.get_buffer(payload_size) if payload_size > 0 else PackedByteArray()
	if payload.size() != payload_size:
		return {"error": REEEplayFormat.LoadError.IO_ERROR, "message": "Truncated chunk payload."}

	var raw := payload
	if (flags & REEEplayFormat.CHUNK_FLAG_ZSTD) != 0 and raw_size > 0:
		raw = payload.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
		if raw.size() != raw_size:
			return {"error": REEEplayFormat.LoadError.CORRUPT_HEADER, "message": "Zstd decompression mismatch for %s." % fourcc}

	return {
		"error": REEEplayFormat.LoadError.OK,
		"fourcc": fourcc,
		"flags": flags,
		"raw": raw,
	}


static func _decode_meta(rec: REEEplayRecording, raw: PackedByteArray) -> void:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = raw
	rec.recording_id = REEEplayByteUtils.get_utf8(b)
	rec.game_id = REEEplayByteUtils.get_utf8(b)
	rec.game_version = REEEplayByteUtils.get_utf8(b)
	rec.scene_path = REEEplayByteUtils.get_utf8(b)
	rec.recorded_at_unix = b.get_u64()
	rec.tick_rate = maxi(1, REEEplayByteUtils.get_varuint(b))
	rec.start_tick = maxi(0, REEEplayByteUtils.get_varuint(b))
	rec.total_ticks = maxi(0, REEEplayByteUtils.get_varuint(b))
	rec.local_player_entity_id = maxi(0, REEEplayByteUtils.get_varuint(b))

	var tag_count := REEEplayByteUtils.get_varuint(b)
	for _i in range(clampi(tag_count, 0, 1024)):
		rec.tags.append(rec.string_table.get_string(REEEplayByteUtils.get_varuint(b)))

	var meta_len := REEEplayByteUtils.get_varuint(b)
	if meta_len > 0 and meta_len <= b.get_available_bytes():
		var res := b.get_data(meta_len)
		if res[0] == OK:
			var mv: Variant = bytes_to_var(res[1] as PackedByteArray)
			if mv is Dictionary:
				rec.metadata = mv as Dictionary


static func _decode_ents(rec: REEEplayRecording, raw: PackedByteArray) -> REEEplayFormat.LoadError:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = raw
	var count := REEEplayByteUtils.get_varuint(b)
	if count < 0 or count > REEEplayFormat.MAX_ENTITY_COUNT:
		return REEEplayFormat.LoadError.BOUNDS_EXCEEDED

	for _i in range(count):
		var info := REEEplayEntityInfo.new()
		info.entity_id = REEEplayByteUtils.get_varuint(b)
		info.archetype_id = rec.string_table.get_string(REEEplayByteUtils.get_varuint(b))
		info.stable_key = rec.string_table.get_string(REEEplayByteUtils.get_varuint(b))
		info.display_name = REEEplayByteUtils.get_utf8(b)
		info.player_id = REEEplayByteUtils.get_utf8(b)
		info.team_id = REEEplayByteUtils.get_varint(b)
		info.spawn_tick = REEEplayByteUtils.get_varuint(b)
		info.despawn_tick = REEEplayByteUtils.get_varint(b)
		info.scene_path = REEEplayByteUtils.get_utf8(b)
		info.initial_divider = maxi(1, REEEplayByteUtils.get_varuint(b))
		info.initial_phase = maxi(0, REEEplayByteUtils.get_varuint(b))
		info.priority = REEEplayByteUtils.get_varint(b)

		var ch_count := REEEplayByteUtils.get_varuint(b)
		if ch_count < 0 or ch_count > 1024:
			return REEEplayFormat.LoadError.BOUNDS_EXCEEDED
		info.channel_names.resize(ch_count)
		info.channel_codecs.resize(ch_count)
		info.channel_steps.resize(ch_count)
		info.channel_interpolated.resize(ch_count)
		for ci in range(ch_count):
			info.channel_names[ci] = rec.string_table.get_string(REEEplayByteUtils.get_varuint(b))
			info.channel_codecs[ci] = REEEplayByteUtils.get_varuint(b)
			info.channel_steps[ci] = b.get_float()
			info.channel_interpolated[ci] = b.get_u8() != 0

		var emeta_len := REEEplayByteUtils.get_varuint(b)
		if emeta_len > 0 and emeta_len <= b.get_available_bytes():
			var res := b.get_data(emeta_len)
			if res[0] == OK:
				var mv: Variant = bytes_to_var(res[1] as PackedByteArray)
				if mv is Dictionary:
					info.metadata = mv as Dictionary

		rec.entities[info.entity_id] = info
	return REEEplayFormat.LoadError.OK


static func _decode_frame_block(rec: REEEplayRecording, blk: REEEplayRecording.FrameBlock, raw: PackedByteArray) -> bool:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = raw

	var start_tick := REEEplayByteUtils.get_varuint(b)
	var tick_count := REEEplayByteUtils.get_varuint(b)
	if tick_count < 0 or tick_count > REEEplayFormat.MAX_TICKS_PER_BLOCK:
		return false
	blk.start_tick = start_tick
	blk.tick_count = tick_count
	blk.is_keyframe = b.get_u8() != 0
	blk.ticks.clear()
	blk.ticks.resize(tick_count)

	var running_tick := start_tick
	for ti in range(tick_count):
		var delta_t := REEEplayByteUtils.get_varuint(b)
		if delta_t < 0:
			return false
		running_tick += delta_t

		var td := REEEplayRecording.TickData.new()
		td.tick = running_tick

		var rc_count := REEEplayByteUtils.get_varuint(b)
		if rc_count < 0 or rc_count > REEEplayFormat.MAX_ENTITY_COUNT:
			return false
		for _r in range(rc_count):
			var rc := REEEplayRecording.RateChange.new()
			rc.entity_id = REEEplayByteUtils.get_varuint(b)
			rc.divider = maxi(1, REEEplayByteUtils.get_varuint(b))
			rc.phase = maxi(0, REEEplayByteUtils.get_varuint(b))
			td.rate_changes.append(rc)

		var sp_count := REEEplayByteUtils.get_varuint(b)
		if sp_count < 0 or sp_count > REEEplayFormat.MAX_ENTITY_COUNT:
			return false
		for _s in range(sp_count):
			td.spawns.append(REEEplayByteUtils.get_varuint(b))

		var dp_count := REEEplayByteUtils.get_varuint(b)
		if dp_count < 0 or dp_count > REEEplayFormat.MAX_ENTITY_COUNT:
			return false
		for _d in range(dp_count):
			td.despawns.append(REEEplayByteUtils.get_varuint(b))

		var ent_count := REEEplayByteUtils.get_varuint(b)
		if ent_count < 0 or ent_count > REEEplayFormat.MAX_ENTITY_COUNT:
			return false
		for _e in range(ent_count):
			var ef := REEEplayRecording.EntityFrame.new()
			ef.entity_id = REEEplayByteUtils.get_varuint(b)
			var info := rec.get_entity_info(ef.entity_id)
			var ch_count := info.channel_count() if info != null else 0
			var word_count := maxi(1, ceili(float(ch_count) / 31.0))
			var active_indices: Array[int] = []
			for w in range(word_count):
				var mask := REEEplayByteUtils.get_varuint(b)
				var base_idx := w * 31
				for bit in range(31):
					if (mask & (1 << bit)) != 0:
						active_indices.append(base_idx + bit)

			for cidx in active_indices:
				var codec_id := REEEplayCodec.Id.VARIANT
				var qstep := 0.001
				if info != null and cidx < info.channel_codecs.size():
					codec_id = info.channel_codecs[cidx]
					qstep = info.channel_steps[cidx]
				ef.values[cidx] = REEEplayCodec.decode(b, codec_id, rec.string_table, qstep)

			td.entities.append(ef)
		blk.ticks[ti] = td
	return true


static func _decode_events(rec: REEEplayRecording, raw: PackedByteArray, reg: REEEplayEventRegistry) -> void:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = raw
	var count := clampi(REEEplayByteUtils.get_varuint(b), 0, REEEplayFormat.MAX_EVENT_COUNT)
	for _i in range(count):
		var ev := reg.deserialize_event(b, rec.string_table)
		if ev != null:
			rec.events.append(ev)
			if ev is REEEplayDamageEntry:
				rec.damage_log.add_entry(ev as REEEplayDamageEntry)


static func _decode_attachments(rec: REEEplayRecording, raw: PackedByteArray, reg: REEEplayEventRegistry) -> void:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = raw
	var count := clampi(REEEplayByteUtils.get_varuint(b), 0, REEEplayFormat.MAX_EVENT_COUNT)
	for _i in range(count):
		var att := reg.deserialize_attachment(b, rec.string_table)
		if att != null:
			rec.attachments.append(att)


static func _decode_world_state(rec: REEEplayRecording, raw: PackedByteArray) -> void:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = raw
	var key_count := clampi(REEEplayByteUtils.get_varuint(b), 0, 100000)
	for _k in range(key_count):
		var key := rec.string_table.get_string(REEEplayByteUtils.get_varuint(b))
		var entry_count := clampi(REEEplayByteUtils.get_varuint(b), 0, 1000000)
		for _e in range(entry_count):
			var tick := REEEplayByteUtils.get_varuint(b)
			var blen := REEEplayByteUtils.get_varuint(b)
			var val: Variant = null
			if blen > 0 and blen <= b.get_available_bytes():
				var res := b.get_data(blen)
				if res[0] == OK:
					val = bytes_to_var(res[1] as PackedByteArray)
			rec.set_world_state_entry(key, tick, val)


static func _decode_index(raw: PackedByteArray) -> Dictionary:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.data_array = raw

	var chunk_count := REEEplayByteUtils.get_varuint(b)
	if chunk_count < 0 or chunk_count > 1024:
		return {"error": REEEplayFormat.LoadError.BOUNDS_EXCEEDED, "message": "Invalid INDX chunk count."}
	var chunk_offsets: Dictionary[String, int] = {}
	for _c in range(chunk_count):
		var fourcc := REEEplayFormat.get_fourcc(b)
		var offset := b.get_u64()
		chunk_offsets[fourcc] = offset

	var blk_count := REEEplayByteUtils.get_varuint(b)
	if blk_count < 0 or blk_count > REEEplayFormat.MAX_BLOCK_COUNT:
		return {"error": REEEplayFormat.LoadError.BOUNDS_EXCEEDED, "message": "INDX block count exceeds cap."}
	var blocks: Array[Dictionary] = []
	for _bi in range(blk_count):
		var start_t := REEEplayByteUtils.get_varuint(b)
		var t_count := REEEplayByteUtils.get_varuint(b)
		if t_count < 0 or t_count > REEEplayFormat.MAX_TICKS_PER_BLOCK:
			return {"error": REEEplayFormat.LoadError.BOUNDS_EXCEEDED, "message": "INDX block tick_count exceeds cap."}
		var is_kf := b.get_u8() != 0
		var offset := b.get_u64()
		var payload_size := b.get_u32()
		var raw_size := b.get_u32()
		var cflags := b.get_u16()
		blocks.append({
			"start_tick": start_t,
			"tick_count": t_count,
			"is_keyframe": is_kf,
			"offset": offset,
			"payload_size": payload_size,
			"raw_size": raw_size,
			"chunk_flags": cflags,
		})

	return {
		"error": REEEplayFormat.LoadError.OK,
		"chunk_offsets": chunk_offsets,
		"block_index": blocks,
	}
