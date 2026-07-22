package vdb

import "core:os"
import "core:sync"
import "core:unicode/utf8"

VDB_FORMAT_MAGIC :: u32(0x3142_4456)
VDB_FORMAT_VERSION :: u32(1)

save :: proc(database: ^Database, path: string) -> Error {
	if database == nil {
		return .Invalid_Dimensions
	}

	buffer := make([dynamic]byte, 0, 128, database.allocator)
	defer delete(buffer)
	if sync.rw_mutex_shared_guard(&database.lock) {
		_append_u32(&buffer, VDB_FORMAT_MAGIC)
		_append_u32(&buffer, VDB_FORMAT_VERSION)
		_append_u32(&buffer, u32(database.metric))
		_append_u64(&buffer, u64(database.dimensions))
		_append_u64(&buffer, u64(len(database.vectors)))

		for vector in database.vectors {
			for value in vector.data {
				_append_u32(&buffer, transmute(u32)value)
			}
			_append_string(&buffer, vector.id)
			_append_string(&buffer, vector.metadata)
		}
	}

	if os.write_entire_file(path, buffer[:]) != nil {
		return .IO_Error
	}
	return .None
}

load :: proc(database: ^Database, path: string, allocator := context.allocator) -> Error {
	if database == nil {
		return .Invalid_Dimensions
	}

	data, readError := os.read_entire_file(path, allocator)
	if readError != nil {
		return .IO_Error
	}
	defer delete(data, allocator)

	offset := 0
	magic: u32
	ok: bool
	magic, ok = _read_u32(data, &offset)
	if !ok || magic != VDB_FORMAT_MAGIC {
		return .Invalid_Format
	}
	version: u32
	version, ok = _read_u32(data, &offset)
	if !ok || version != VDB_FORMAT_VERSION {
		return .Invalid_Format
	}
	metricValue: u32
	metricValue, ok = _read_u32(data, &offset)
	metric := Metric(metricValue)
	if !ok || !is_valid_metric(metric) {
		return .Invalid_Format
	}
	dimensionsValue: u64
	dimensionsValue, ok = _read_u64(data, &offset)
	if !ok || dimensionsValue == 0 || u64(int(dimensionsValue)) != dimensionsValue {
		return .Invalid_Format
	}
	countValue: u64
	countValue, ok = _read_u64(data, &offset)
	if !ok || u64(int(countValue)) != countValue {
		return .Invalid_Format
	}

	loadError := init(database, int(dimensionsValue), metric, allocator)
	if loadError != .None {
		return loadError
	}
	for _ in 0 ..< int(countValue) {
		if int(dimensionsValue) > (len(data) - offset) / size_of(f32) {
			destroy(database)
			return .Invalid_Format
		}

		vectorData := make([]f32, int(dimensionsValue), allocator)
		for index in 0 ..< len(vectorData) {
			bits, vectorOK := _read_u32(data, &offset)
			if !vectorOK {
				delete(vectorData, allocator)
				destroy(database)
				return .Invalid_Format
			}
			vectorData[index] = transmute(f32)bits
		}
		id, idOK := _read_string(data, &offset)
		metadata, metadataOK := _read_string(data, &offset)
		if !idOK || !metadataOK || !utf8.valid_string(id) || !utf8.valid_string(metadata) {
			delete(vectorData, allocator)
			destroy(database)
			return .Invalid_Format
		}

		addError := add_vector(database, vectorData, id, metadata)
		delete(vectorData, allocator)
		if addError != .None {
			destroy(database)
			return addError
		}
	}
	if offset != len(data) {
		destroy(database)
		return .Invalid_Format
	}
	return .None
}

_append_u32 :: proc(buffer: ^[dynamic]byte, value: u32) {
	for shift := 0; shift < 32; shift += 8 {
		append(buffer, byte(value >> u32(shift)))
	}
}

_append_u64 :: proc(buffer: ^[dynamic]byte, value: u64) {
	for shift := 0; shift < 64; shift += 8 {
		append(buffer, byte(value >> u64(shift)))
	}
}

_append_string :: proc(buffer: ^[dynamic]byte, value: string) {
	_append_u64(buffer, u64(len(value)))
	append(buffer, ..transmute([]byte)value)
}

_read_u32 :: proc(data: []byte, offset: ^int) -> (u32, bool) {
	if offset^ < 0 || len(data) - offset^ < 4 {
		return 0, false
	}
	value :=
		u32(data[offset^]) |
		u32(data[offset^ + 1]) << 8 |
		u32(data[offset^ + 2]) << 16 |
		u32(data[offset^ + 3]) << 24
	offset^ += 4
	return value, true
}

_read_u64 :: proc(data: []byte, offset: ^int) -> (u64, bool) {
	if offset^ < 0 || len(data) - offset^ < 8 {
		return 0, false
	}
	value: u64
	for shift := 0; shift < 64; shift += 8 {
		value |= u64(data[offset^ + shift / 8]) << u64(shift)
	}
	offset^ += 8
	return value, true
}

_read_string :: proc(data: []byte, offset: ^int) -> (string, bool) {
	length, ok := _read_u64(data, offset)
	if !ok || length > u64(len(data) - offset^) {
		return "", false
	}
	end := offset^ + int(length)
	value := string(data[offset^:end])
	offset^ = end
	return value, true
}
