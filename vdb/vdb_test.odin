package vdb

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_distance_metrics :: proc(t: ^testing.T) {
	left := []f32{1, 0}
	right := []f32{0, 1}
	assert(dot_product(left, right) == 0, "expected orthogonal dot product")
	assert(cosine_similarity(left, right) == 0, "expected orthogonal cosine similarity")
	assert(euclidean_distance(left, right) == 1.4142135, "expected Euclidean distance")
	assert(
		compute_distance(left, right, .Dot_Product) == 0,
		"expected dot-product distance to negate the dot product",
	)
	_ = t
}

@(test)
test_database_copies_vectors_and_returns_leased_views :: proc(t: ^testing.T) {
	database: Database
	assert(init(&database, 2, .Euclidean, context.allocator) == .None, "expected database init")
	defer destroy(&database)

	input := []f32{1, 2}
	assert(add_vector(&database, input, "first", "meta") == .None, "expected vector add")
	input[0] = 99

	view, viewError := get_vector(&database, 0)
	assert(viewError == .None, "expected vector view")
	assert(view.data[0] == 1, "expected database to own a copy of vector data")
	assert(view.id == "first", "expected vector ID")
	assert(view.metadata == "meta", "expected vector metadata")
	vector_view_destroy(&view)
	_ = t
}

@(test)
test_search_orders_results_and_clamps_k :: proc(t: ^testing.T) {
	database: Database
	assert(init(&database, 2, .Euclidean, context.allocator) == .None, "expected database init")
	defer destroy(&database)

	assert(add_vector(&database, []f32{2, 0}, "second") == .None, "expected second vector")
	assert(add_vector(&database, []f32{1, 0}, "first") == .None, "expected first vector")
	assert(add_vector(&database, []f32{3, 0}, "third") == .None, "expected third vector")

	resultSet, searchError := search(&database, []f32{0, 0}, 10)
	assert(searchError == .None, "expected search")
	defer result_set_destroy(&resultSet)
	assert(len(resultSet.results) == 3, "expected k to clamp to database count")
	assert(resultSet.results[0].id == "first", "expected nearest ID first")
	assert(resultSet.results[1].id == "second", "expected next nearest ID")
	assert(resultSet.results[2].id == "third", "expected furthest ID last")
	_ = t
}

@(test)
test_remove_vector_preserves_remaining_order :: proc(t: ^testing.T) {
	database: Database
	assert(init(&database, 1, .Euclidean, context.allocator) == .None, "expected database init")
	defer destroy(&database)

	assert(add_vector(&database, []f32{1}, "one") == .None, "expected first vector")
	assert(add_vector(&database, []f32{2}, "two") == .None, "expected second vector")
	assert(add_vector(&database, []f32{3}, "three") == .None, "expected third vector")
	assert(remove_vector(&database, 1) == .None, "expected removal")
	assert(count(&database) == 2, "expected reduced count")

	view, viewError := get_vector(&database, 1)
	assert(viewError == .None, "expected remaining vector view")
	assert(view.id == "three", "expected ordered removal to preserve following vector")
	vector_view_destroy(&view)
	_ = t
}

@(test)
test_save_and_load_round_trip :: proc(t: ^testing.T) {
	directory, directoryError := os.make_directory_temp("", "mimir-vdb-*", context.temp_allocator)
	assert(directoryError == nil, "expected temporary directory")
	defer os.remove_all(directory)
	path := strings.concatenate({directory, "/vectors.vdb"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)

	database: Database
	assert(init(&database, 2, .Cosine, context.allocator) == .None, "expected database init")
	defer destroy(&database)
	assert(
		add_vector(&database, []f32{1, 2}, "entry", "persisted metadata") == .None,
		"expected vector add",
	)
	assert(save(&database, path) == .None, "expected database save")

	loaded: Database
	assert(load(&loaded, path, context.allocator) == .None, "expected database load")
	defer destroy(&loaded)
	assert(count(&loaded) == 1, "expected loaded vector count")
	assert(dimensions(&loaded) == 2, "expected loaded dimensions")
	assert(loaded.metric == .Cosine, "expected loaded metric")

	view, viewError := get_vector(&loaded, 0)
	assert(viewError == .None, "expected loaded vector view")
	assert(view.data[0] == 1 && view.data[1] == 2, "expected loaded vector data")
	assert(view.id == "entry", "expected loaded ID")
	assert(view.metadata == "persisted metadata", "expected loaded metadata")
	vector_view_destroy(&view)
	_ = t
}

@(test)
test_load_rejects_invalid_format :: proc(t: ^testing.T) {
	directory, directoryError := os.make_directory_temp("", "mimir-vdb-*", context.temp_allocator)
	assert(directoryError == nil, "expected temporary directory")
	defer os.remove_all(directory)
	path := strings.concatenate({directory, "/invalid.vdb"}, context.temp_allocator)
	defer delete(path, context.temp_allocator)
	assert(os.write_entire_file(path, []byte{0, 1, 2}) == nil, "expected invalid file write")

	database: Database
	assert(load(&database, path, context.allocator) == .Invalid_Format, "expected format error")
	_ = t
}
