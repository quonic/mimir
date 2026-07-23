package main

import "core:os"
import "core:strings"
import "core:testing"
import vdb "vdb"

@(test)
test_code_index_discovers_git_project_root :: proc(t: ^testing.T) {
	directory, directoryError := os.make_directory_temp(
		"",
		"mimir-code-index-",
		context.temp_allocator,
	)
	assert(directoryError == nil, "expected temporary project directory")
	defer os.remove_all(directory)

	gitDirectory := strings.concatenate({directory, "/.git"}, context.temp_allocator)
	defer delete(gitDirectory, context.temp_allocator)
	childDirectory := strings.concatenate({directory, "/src/nested"}, context.temp_allocator)
	defer delete(childDirectory, context.temp_allocator)
	assert(os.make_directory_all(gitDirectory) == nil, "expected git marker directory")
	assert(os.make_directory_all(childDirectory) == nil, "expected nested project directory")

	root := code_index_project_root(childDirectory, context.temp_allocator)
	defer delete(root, context.temp_allocator)
	assert(root == directory, "expected nearest git root")
	_ = t
}

@(test)
test_code_index_cache_path_is_model_specific :: proc(t: ^testing.T) {
	home := "/tmp/mimir-home"
	root := "/tmp/mimir-project"
	first := code_index_cache_path(
		home,
		root,
		"ollama",
		"nomic-embed-text",
		context.temp_allocator,
	)
	second := code_index_cache_path(
		home,
		root,
		"ollama",
		"nomic-embed-text",
		context.temp_allocator,
	)
	third := code_index_cache_path(
		home,
		root,
		"ollama",
		"mxbai-embed-large",
		context.temp_allocator,
	)
	defer delete(first, context.temp_allocator)
	defer delete(second, context.temp_allocator)
	defer delete(third, context.temp_allocator)

	assert(first != "", "expected cache path for configured embedding model")
	assert(first == second, "expected deterministic cache path")
	assert(first != third, "expected embedding model to isolate cache files")
	_ = t
}

@(test)
test_code_index_chunks_source_with_stable_overlapping_ranges :: proc(t: ^testing.T) {
	chunks := code_index_chunk_text(
		"src/example.odin",
		"one\ntwo\nthree\nfour\nfive",
		3,
		1,
		context.temp_allocator,
	)
	defer code_index_chunks_destroy(&chunks, context.temp_allocator)

	assert(len(chunks) == 2, "expected two overlapping chunks")
	assert(chunks[0].id == "src/example.odin:1-3", "expected first stable chunk ID")
	assert(chunks[0].content == "one\ntwo\nthree\n", "expected first chunk content")
	assert(chunks[1].id == "src/example.odin:3-5", "expected overlapping second chunk ID")
	assert(chunks[1].content == "three\nfour\nfive", "expected second chunk content")
	_ = t
}

@(test)
test_code_index_adds_embeddings_to_vdb :: proc(t: ^testing.T) {
	chunks := code_index_chunk_text(
		"main.odin",
		"first\nsecond\nthird",
		2,
		1,
		context.temp_allocator,
	)
	defer code_index_chunks_destroy(&chunks, context.temp_allocator)

	index: Code_Index
	defer code_index_destroy(&index, context.temp_allocator)
	embeddings := [2][]f32{{1, 0}, {0, 1}}
	assert(
		code_index_add_embeddings(&index, chunks[:], embeddings[:], context.temp_allocator),
		"expected chunk embeddings to populate VDB",
	)
	assert(index.dirty, "expected new vectors to mark index dirty")
	assert(vdb.count(&index.database) == 2, "expected one vector per chunk")
	assert(vdb.dimensions(&index.database) == 2, "expected embedding dimensions")
	_ = t
}

@(test)
test_code_index_search_copies_ranked_results_and_releases_lock :: proc(t: ^testing.T) {
	index: Code_Index
	defer code_index_destroy(&index, context.temp_allocator)
	assert(
		vdb.init(&index.database, 2, .Cosine, context.temp_allocator) == .None,
		"expected database initialization",
	)
	index.databaseInitialized = true
	assert(
		vdb.add_vector(&index.database, []f32{1, 0}, "first", "first metadata") == .None,
		"expected first vector",
	)
	assert(
		vdb.add_vector(&index.database, []f32{0, 1}, "second", "second metadata") == .None,
		"expected second vector",
	)

	results := code_index_search(&index, []f32{1, 0}, 1, context.temp_allocator)
	defer code_index_search_results_destroy(&results, context.temp_allocator)
	assert(len(results) == 1, "expected one search result")
	assert(results[0].id == "first", "expected nearest result first")
	assert(results[0].metadata == "first metadata", "expected copied result metadata")
	assert(
		vdb.add_vector(&index.database, []f32{1, 1}, "third") == .None,
		"expected released search lock",
	)
	_ = t
}

@(test)
test_code_index_saves_and_loads_database :: proc(t: ^testing.T) {
	home, homeError := os.make_directory_temp("", "mimir-code-index-home-", context.temp_allocator)
	assert(homeError == nil, "expected temporary home directory")
	defer os.remove_all(home)

	project := strings.concatenate({home, "/project"}, context.temp_allocator)
	defer delete(project, context.temp_allocator)
	gitDirectory := strings.concatenate({project, "/.git"}, context.temp_allocator)
	defer delete(gitDirectory, context.temp_allocator)
	assert(os.make_directory_all(gitDirectory) == nil, "expected git marker directory")

	index, initError := code_index_init(
		project,
		home,
		"ollama",
		"nomic-embed-text",
		context.temp_allocator,
	)
	assert(initError == .None, "expected code index initialization")
	defer code_index_destroy(&index, context.temp_allocator)
	assert(
		vdb.init(&index.database, 2, .Cosine, context.temp_allocator) == .None,
		"expected database initialization",
	)
	index.databaseInitialized = true
	assert(
		vdb.add_vector(&index.database, []f32{1, 2}, "chunk", "metadata") == .None,
		"expected vector add",
	)
	assert(code_index_save(&index) == .None, "expected cache save")

	loaded, loadedInitError := code_index_init(
		project,
		home,
		"ollama",
		"nomic-embed-text",
		context.temp_allocator,
	)
	assert(loadedInitError == .None, "expected loaded index initialization")
	defer code_index_destroy(&loaded, context.temp_allocator)
	assert(code_index_load(&loaded, context.temp_allocator) == .None, "expected cache load")
	assert(vdb.count(&loaded.database) == 1, "expected persisted vector")
	_ = t
}
