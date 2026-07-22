package vdb

import "core:math"
import "core:mem"
import "core:sync"

Error :: enum {
	None,
	Invalid_Dimensions,
	Invalid_Metric,
	Invalid_Index,
	Invalid_Query,
	Empty_Database,
	Invalid_Format,
	IO_Error,
}

Metric :: enum u32 {
	Cosine,
	Euclidean,
	Dot_Product,
}

Vector :: struct {
	data:     []f32,
	id:       string,
	metadata: string,
}

Database :: struct {
	lock:       sync.RW_Mutex,
	allocator:  mem.Allocator,
	vectors:    [dynamic]Vector,
	dimensions: int,
	metric:     Metric,
}

Result :: struct {
	index:    int,
	distance: f32,
	id:       string,
	metadata: string,
}

Result_Set :: struct {
	results:  [dynamic]Result,
	database: ^Database,
	locked:   bool,
}

Vector_View :: struct {
	data:     []f32,
	id:       string,
	metadata: string,
	database: ^Database,
	locked:   bool,
}

is_valid_metric :: proc(metric: Metric) -> bool {
	return metric >= .Cosine && metric <= .Dot_Product
}

init :: proc(
	database: ^Database,
	dimensions: int,
	metric: Metric,
	allocator := context.allocator,
) -> Error {
	if database == nil || dimensions <= 0 {
		return .Invalid_Dimensions
	}
	if !is_valid_metric(metric) {
		return .Invalid_Metric
	}

	database.allocator = allocator
	database.vectors = make([dynamic]Vector, 0, 0, allocator)
	database.dimensions = dimensions
	database.metric = metric
	return .None
}

destroy :: proc(database: ^Database) {
	if database == nil {
		return
	}

	if sync.rw_mutex_guard(&database.lock) {
		for vector in database.vectors {
			delete(vector.data, database.allocator)
			delete(vector.id, database.allocator)
			delete(vector.metadata, database.allocator)
		}
		delete(database.vectors)
		database.dimensions = 0
	}
}

dot_product :: proc(a, b: []f32) -> f32 {
	sum: f32
	for index in 0 ..< len(a) {
		sum += a[index] * b[index]
	}
	return sum
}

magnitude :: proc(vector: []f32) -> f32 {
	return math.sqrt(dot_product(vector, vector))
}

cosine_similarity :: proc(a, b: []f32) -> f32 {
	magnitudeA := magnitude(a)
	magnitudeB := magnitude(b)
	if magnitudeA == 0 || magnitudeB == 0 {
		return 0
	}
	return dot_product(a, b) / (magnitudeA * magnitudeB)
}

euclidean_distance :: proc(a, b: []f32) -> f32 {
	sum: f32
	for index in 0 ..< len(a) {
		difference := a[index] - b[index]
		sum += difference * difference
	}
	return math.sqrt(sum)
}

compute_distance :: proc(a, b: []f32, metric: Metric) -> f32 {
	switch metric {
	case .Cosine:
		return 1 - cosine_similarity(a, b)
	case .Euclidean:
		return euclidean_distance(a, b)
	case .Dot_Product:
		return -dot_product(a, b)
	case:
		return 0
	}
}
