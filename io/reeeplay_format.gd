class_name REEEplayFormat
extends RefCounted
## Binary .reee container format constants, LoadError enum, and IEEE 802.3 CRC32 helpers.

enum LoadError {
	OK = 0,
	FILE_NOT_FOUND = 1,
	CORRUPT_HEADER = 2,
	CRC_MISMATCH = 3,
	UNSUPPORTED_MAJOR = 4,
	MISSING_CRITICAL_CHUNK = 5,
	GAME_VERSION_REJECTED = 6,
	BOUNDS_EXCEEDED = 7,
	IO_ERROR = 8,
}

const MAGIC_HEADER := "REEE"
const MAGIC_FOOTER := "EEER"
const FORMAT_MAJOR: int = 1
const FORMAT_MINOR: int = 0
const HEADER_SIZE: int = 16
const FOOTER_SIZE: int = 16
const CHUNK_HEADER_SIZE: int = 16

const CHUNK_FLAG_ZSTD: int = 1
const CHUNK_FLAG_CRITICAL: int = 2

const FOURCC_META := "META"
const FOURCC_STRT := "STRT"
const FOURCC_ENTS := "ENTS"
const FOURCC_FBLK := "FBLK"
const FOURCC_EVNT := "EVNT"
const FOURCC_ATTH := "ATTH"
const FOURCC_WRLD := "WRLD"
const FOURCC_INDX := "INDX"

const MAX_CHUNK_BYTES: int = 134217728 # 128 MB hard cap
const MAX_STRING_COUNT: int = 1048576
const MAX_ENTITY_COUNT: int = 100000
const MAX_BLOCK_COUNT: int = 1000000
const MAX_TICKS_PER_BLOCK: int = 100000
const MAX_EVENT_COUNT: int = 2000000

static var _crc_table: PackedInt64Array = PackedInt64Array()


static func ensure_crc_table() -> void:
	if not _crc_table.is_empty():
		return
	_crc_table.resize(256)
	for i in range(256):
		var c := i
		for _j in range(8):
			if (c & 1) != 0:
				c = 0xEDB88320 ^ (c >> 1)
			else:
				c >>= 1
		_crc_table[i] = c & 0xFFFFFFFF


static func crc32(bytes: PackedByteArray, length: int = -1) -> int:
	return crc32_finalize(crc32_update(0xFFFFFFFF, bytes, length))


static func crc32_update(running_crc: int, bytes: PackedByteArray, length: int = -1) -> int:
	ensure_crc_table()
	var n := bytes.size() if length < 0 else mini(bytes.size(), length)
	var crc := running_crc & 0xFFFFFFFF
	for i in range(n):
		var idx := (crc ^ bytes[i]) & 0xFF
		crc = (_crc_table[idx] ^ (crc >> 8)) & 0xFFFFFFFF
	return crc


static func crc32_finalize(running_crc: int) -> int:
	return (running_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF


## Computes CRC32 over the first byte_count bytes of an open FileAccess in 64 KB streaming chunks.
static func crc32_file_range(fa: FileAccess, byte_count: int) -> int:
	fa.seek(0)
	var crc := 0xFFFFFFFF
	var remaining := byte_count
	while remaining > 0:
		var chunk_len := mini(65536, remaining)
		var buf := fa.get_buffer(chunk_len)
		if buf.size() != chunk_len:
			return -1
		crc = crc32_update(crc, buf, chunk_len)
		remaining -= chunk_len
	return crc32_finalize(crc)


static func put_fourcc(buf: StreamPeerBuffer, code: String) -> void:
	var ascii := code.to_ascii_buffer()
	for i in range(4):
		buf.put_u8(ascii[i] if i < ascii.size() else 0x20)


static func get_fourcc(buf: StreamPeerBuffer) -> String:
	var res := buf.get_data(4)
	if res[0] != OK:
		return ""
	var bytes: PackedByteArray = res[1]
	return bytes.get_string_from_ascii()


static func error_name(err: LoadError) -> String:
	match err:
		LoadError.OK:
			return "OK"
		LoadError.FILE_NOT_FOUND:
			return "FILE_NOT_FOUND"
		LoadError.CORRUPT_HEADER:
			return "CORRUPT_HEADER"
		LoadError.CRC_MISMATCH:
			return "CRC_MISMATCH"
		LoadError.UNSUPPORTED_MAJOR:
			return "UNSUPPORTED_MAJOR"
		LoadError.MISSING_CRITICAL_CHUNK:
			return "MISSING_CRITICAL_CHUNK"
		LoadError.GAME_VERSION_REJECTED:
			return "GAME_VERSION_REJECTED"
		LoadError.BOUNDS_EXCEEDED:
			return "BOUNDS_EXCEEDED"
		_:
			return "IO_ERROR"

