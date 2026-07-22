package vdb

import "core:strings"
import "core:sync"

add_vector :: proc(database: ^Database, data: []f32, id: string, metadata: string = "") -> Error {
	if database == nil || len(data) != database.dimensions {
		return .Invalid_Dimensions
	}

	if sync.rw_mutex_guard(&database.lock) {
		vectorData := make([]f32, len(data), database.allocator)
		copy(vectorData, data)
		append(
			&database.vectors,
			Vector {
				data = vectorData,
				id = strings.clone(id, database.allocator),
				metadata = strings.clone(metadata, database.allocator),
			},
		)
	}
	return .None
}

remove_vector :: proc(database: ^Database, index: int) -> Error {
	if database == nil {
		return .Invalid_Index
	}

	if sync.rw_mutex_guard(&database.lock) {
		if index < 0 || index >= len(database.vectors) {
			return .Invalid_Index
		}

		vector := database.vectors[index]
		delete(vector.data, database.allocator)
		delete(vector.id, database.allocator)
		delete(vector.metadata, database.allocator)
		for current := index; current < len(database.vectors) - 1; current += 1 {
			database.vectors[current] = database.vectors[current + 1]
		}
		pop(&database.vectors)
	}
	return .None
}

count :: proc(database: ^Database) -> int {
	if database == nil {
		return 0
	}

	if sync.rw_mutex_shared_guard(&database.lock) {
		return len(database.vectors)
	}
	return 0
}

dimensions :: proc(database: ^Database) -> int {
	if database == nil {
		return 0
	}
	return database.dimensions
}

get_vector :: proc(database: ^Database, index: int) -> (Vector_View, Error) {
	if database == nil {
		return {}, .Invalid_Index
	}

	sync.rw_mutex_shared_lock(&database.lock)
	if index < 0 || index >= len(database.vectors) {
		sync.rw_mutex_shared_unlock(&database.lock)
		return {}, .Invalid_Index
	}

	vector := database.vectors[index]
	return Vector_View {
			data = vector.data[:],
			id = vector.id,
			metadata = vector.metadata,
			database = database,
			locked = true,
		},
		.None
}

vector_view_destroy :: proc(view: ^Vector_View) {
	if view == nil || !view.locked {
		return
	}

	sync.rw_mutex_shared_unlock(&view.database.lock)
	view^ = {}
}
