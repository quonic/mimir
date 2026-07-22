package vdb

import "core:sort"
import "core:sync"

search :: proc(database: ^Database, query: []f32, k: int) -> (Result_Set, Error) {
	if database == nil || len(query) != database.dimensions || k <= 0 {
		return {}, .Invalid_Query
	}

	sync.rw_mutex_shared_lock(&database.lock)
	if len(database.vectors) == 0 {
		sync.rw_mutex_shared_unlock(&database.lock)
		return {}, .Empty_Database
	}
	resultCount := k
	if resultCount > len(database.vectors) {
		resultCount = len(database.vectors)
	}

	results := make([dynamic]Result, 0, len(database.vectors), database.allocator)
	for vector, index in database.vectors {
		append(
			&results,
			Result {
				index = index,
				distance = compute_distance(query, vector.data, database.metric),
				id = vector.id,
				metadata = vector.metadata,
			},
		)
	}

	_sort_results(results[:])
	resize(&results, resultCount)
	return Result_Set{results = results, database = database, locked = true}, .None
}

result_set_destroy :: proc(resultSet: ^Result_Set) {
	if resultSet == nil {
		return
	}

	delete(resultSet.results)
	if resultSet.locked {
		sync.rw_mutex_shared_unlock(&resultSet.database.lock)
	}
	resultSet^ = {}
}

_sort_results :: proc(results: []Result) {
	collection := results
	interface := sort.Interface {
		collection = rawptr(&collection),
		len = proc(interface: sort.Interface) -> int {
			collection := (^[]Result)(interface.collection)
			return len(collection^)
		},
		less = proc(interface: sort.Interface, left, right: int) -> bool {
			collection := (^[]Result)(interface.collection)
			leftResult := collection[left]
			rightResult := collection[right]
			if leftResult.distance == rightResult.distance {
				return leftResult.index < rightResult.index
			}
			return leftResult.distance < rightResult.distance
		},
		swap = proc(interface: sort.Interface, left, right: int) {
			collection := (^[]Result)(interface.collection)
			collection[left], collection[right] = collection[right], collection[left]
		},
	}
	sort.sort(interface)
}
