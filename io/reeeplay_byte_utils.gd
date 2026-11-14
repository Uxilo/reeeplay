## Binary varint, zigzag, and interned string-table utilities for .reee streams.
class_name REEEplayByteUtils
extends RefCounted


## Interns StringNames to compact integer IDs stored in STRS chunks.
class StringTable extends RefCounted:
	var _strings: Array[StringName] = []
	var _index_by_name: Dictionary[StringName, int] = {}

	## Returns the stable integer ID for `s`, inserting it if not yet present.
	func intern(s: StringName) -> int:
		if _index_by_name.has(s):
			return _index_by_name[s]
		var idx := _strings.size()
		_strings.append(s)
		_index_by_name[s] = idx
		return idx

	## Returns the StringName at `index`, or empty StringName if out of bounds.
	func get_string(index: int) -> StringName:
		if index < 0 or index >= _strings.size():
			return &""
		return _strings[index]

	## Returns the number of interned strings.
	func size() -> int:
		return _strings.size()

	## Returns all interned strings in index order.
	func all_strings() -> Array[StringName]:
		return _strings.duplicate()

	## Clears all interned strings.
	func clear() -> void:
		_strings.clear()
		_index_by_name.clear()

	## Serializes the string table to compact UTF-8 binary bytes.
	func to_bytes() -> PackedByteArray:
		var buf := StreamPeerBuffer.new()
		buf.big_endian = false
		REEEplayByteUtils.put_varuint(buf, _strings.size())
		for s: StringName in _strings:
			var utf8 := String(s).to_utf8_buffer()
			REEEplayByteUtils.put_varuint(buf, utf8.size())
			if not utf8.is_empty():
				buf.put_data(utf8)
		return buf.data_array

	## Deserializes a StringTable from bytes with bounds checking.
	static func from_bytes(bytes: PackedByteArray, max_strings: int = 1048576) -> StringTable:
		var table := StringTable.new()
		if bytes.is_empty():
			return table
		var buf := StreamPeerBuffer.new()
		buf.big_endian = false
		buf.data_array = bytes
		var count := REEEplayByteUtils.get_varuint(buf)
		if count < 0 or count > max_strings:
			return null
		for _i in count:
			var byte_len := REEEplayByteUtils.get_varuint(buf)
			if byte_len < 0 or buf.get_available_bytes() < byte_len:
				return null
			if byte_len == 0:
				table.intern(&"")
			else:
				var res := buf.get_data(byte_len)
				if res[0] != OK:
					return null
				var s := (res[1] as PackedByteArray).get_string_from_utf8()
				table.intern(StringName(s))
		return table


## Writes a non-negative 64-bit integer as unsigned LEB128 varint.
static func put_varuint(buf: StreamPeerBuffer, value: int) -> void:
	var v := value
	if v < 0:
		push_warning("REEEplayByteUtils.put_varuint: negative value clamped to 0")
		v = 0
	while v >= 0x80:
		buf.put_u8((v & 0x7F) | 0x80)
		v >>= 7
	buf.put_u8(v & 0x7F)


## Reads an unsigned LEB128 varint. Returns -1 on truncated or malformed input.
static func get_varuint(buf: StreamPeerBuffer) -> int:
	var result := 0
	var shift := 0
	while shift < 64:
		if buf.get_available_bytes() <= 0:
			return -1
		var b := buf.get_u8()
		result |= (b & 0x7F) << shift
		if (b & 0x80) == 0:
			return result
		shift += 7
	return -1


## Maps a signed 64-bit integer onto an unsigned integer for compact varint coding.
static func zigzag_encode(n: int) -> int:
	return (n << 1) ^ (n >> 63)


## Reverses zigzag encoding back to a signed integer.
static func zigzag_decode(u: int) -> int:
	return ((u >> 1) & 0x7FFFFFFFFFFFFFFF) ^ -(u & 1)


## Writes a signed integer as zigzag-encoded varint.
static func put_varint(buf: StreamPeerBuffer, value: int) -> void:
	put_varuint(buf, zigzag_encode(value))


## Reads a zigzag-encoded signed varint. Returns 0 if truncated (check buf errors if needed).
static func get_varint(buf: StreamPeerBuffer) -> int:
	var raw := get_varuint(buf)
	if raw < 0:
		return 0
	return zigzag_decode(raw)


## Writes a length-prefixed UTF-8 string.
static func put_utf8(buf: StreamPeerBuffer, text: String) -> void:
	var raw := text.to_utf8_buffer()
	put_varuint(buf, raw.size())
	if not raw.is_empty():
		buf.put_data(raw)


## Reads a length-prefixed UTF-8 string with bounds checking.
static func get_utf8(buf: StreamPeerBuffer, max_bytes: int = 16777216) -> String:
	var byte_len := get_varuint(buf)
	if byte_len <= 0 or byte_len > max_bytes or buf.get_available_bytes() < byte_len:
		return ""
	var res := buf.get_data(byte_len)
	if res[0] != OK:
		return ""
	return (res[1] as PackedByteArray).get_string_from_utf8()

