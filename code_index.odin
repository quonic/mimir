package main

import "core:hash"
import "core:os"
import "core:strings"
import vdb "vdb"

CODE_INDEX_SCHEMA_VERSION :: "1"

Code_Index_Error :: enum int {
	None = 0,
	Invalid_Project,
	Invalid_Cache,
	Not_Found,
	Io_Error,
	Invalid_Format,
}

Code_Index :: struct {
	projectRoot:         string,
	embeddingProvider:   string,
	embeddingModel:      string,
	cacheDir:            string,
	cachePath:           string,
	database:            vdb.Database,
	databaseInitialized: bool,
	dirty:               bool,
}

Code_Chunk :: struct {
	id:        string,
	metadata:  string,
	content:   string,
	startLine: int,
	endLine:   int,
}

Code_Search_Result :: struct {
	id:       string,
	metadata: string,
	distance: f32,
}

code_index_init :: proc(
	workingDirectory, home, embeddingProvider, embeddingModel: string,
	allocator := context.allocator,
) -> (
	Code_Index,
	Code_Index_Error,
) {
	projectRoot := code_index_project_root(workingDirectory, allocator)
	if projectRoot == "" {
		return Code_Index{}, .Invalid_Project
	}
	defer delete(projectRoot, allocator)

	cacheDir := history_cache_dir(home, allocator)
	cachePath := code_index_cache_path(
		home,
		projectRoot,
		embeddingProvider,
		embeddingModel,
		allocator,
	)
	if cacheDir == "" || cachePath == "" {
		if cacheDir != "" {
			delete(cacheDir, allocator)
		}
		return Code_Index{}, .Invalid_Cache
	}

	return Code_Index {
			projectRoot = strings.clone(projectRoot, allocator),
			embeddingProvider = strings.clone(embeddingProvider, allocator),
			embeddingModel = strings.clone(embeddingModel, allocator),
			cacheDir = cacheDir,
			cachePath = cachePath,
		},
		.None
}

code_index_destroy :: proc(index: ^Code_Index, allocator := context.allocator) {
	if index == nil {
		return
	}
	if index.databaseInitialized {
		vdb.destroy(&index.database)
	}
	delete(index.projectRoot, allocator)
	delete(index.embeddingProvider, allocator)
	delete(index.embeddingModel, allocator)
	delete(index.cacheDir, allocator)
	delete(index.cachePath, allocator)
	index^ = {}
}

code_index_project_root :: proc(
	workingDirectory: string,
	allocator := context.allocator,
) -> string {
	normalized, normalizedOK := permission_normalize_absolute_path(workingDirectory, allocator)
	if !normalizedOK {
		return ""
	}
	candidate := strings.clone(normalized, allocator)
	for {
		gitPath := strings.concatenate({candidate, "/.git"}, allocator)
		isGitRoot := os.exists(gitPath)
		delete(gitPath, allocator)
		if isGitRoot {
			result := strings.clone(candidate, allocator)
			delete(candidate, allocator)
			delete(normalized, allocator)
			return result
		}

		parent := code_index_parent_path(candidate, allocator)
		delete(candidate, allocator)
		if parent == "" {
			return normalized
		}
		candidate = parent
	}
}

code_index_parent_path :: proc(path: string, allocator := context.allocator) -> string {
	for index := len(path) - 1; index > 0; index -= 1 {
		if path[index] == '/' {
			if index == 0 {
				return "/"
			}
			return strings.clone(path[:index], allocator)
		}
	}
	return ""
}

code_index_cache_path :: proc(
	home, projectRoot, embeddingProvider, embeddingModel: string,
	allocator := context.allocator,
) -> string {
	cacheDir := history_cache_dir(home, allocator)
	if cacheDir == "" || projectRoot == "" || embeddingProvider == "" || embeddingModel == "" {
		if cacheDir != "" {
			delete(cacheDir, allocator)
		}
		return ""
	}
	defer delete(cacheDir, allocator)

	identity := strings.concatenate(
		{
			CODE_INDEX_SCHEMA_VERSION,
			"\x00",
			projectRoot,
			"\x00",
			embeddingProvider,
			"\x00",
			embeddingModel,
		},
		allocator,
	)
	defer delete(identity, allocator)
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, cacheDir)
	strings.write_string(&builder, "/code-index-")
	code_index_write_hex_u64(&builder, hash.fnv64a(transmute([]byte)identity))
	strings.write_string(&builder, ".vdb")
	return strings.to_string(builder)
}

code_index_write_hex_u64 :: proc(builder: ^strings.Builder, value: u64) {
	hexDigits := "0123456789abcdef"
	for shift := 60; shift >= 0; shift -= 4 {
		strings.write_byte(builder, hexDigits[(value >> u64(shift)) & 0xf])
	}
}

code_index_chunk_text :: proc(
	relativePath, text: string,
	maximumLines, overlapLines: int,
	allocator := context.allocator,
) -> [dynamic]Code_Chunk {
	chunks := make([dynamic]Code_Chunk, 0, 0, allocator)
	if relativePath == "" ||
	   text == "" ||
	   maximumLines <= 0 ||
	   overlapLines < 0 ||
	   overlapLines >= maximumLines {
		return chunks
	}

	lines := strings.split(text, "\n", allocator)
	defer delete(lines, allocator)
	lineCount := len(lines)
	if lineCount > 0 && lines[lineCount - 1] == "" {
		lineCount -= 1
	}
	for start := 0; start < lineCount; {
		end := start + maximumLines
		if end > lineCount {
			end = lineCount
		}

		content := code_index_join_lines(lines[start:end], start, lineCount, allocator)
		id := code_index_chunk_identifier(relativePath, start + 1, end, allocator)
		metadata := code_index_chunk_metadata(relativePath, start + 1, end, allocator)
		append(
			&chunks,
			Code_Chunk {
				id = id,
				metadata = metadata,
				content = content,
				startLine = start + 1,
				endLine = end,
			},
		)
		if end == lineCount {
			break
		}
		start = end - overlapLines
	}
	return chunks
}

code_index_chunks_destroy :: proc(chunks: ^[dynamic]Code_Chunk, allocator := context.allocator) {
	if chunks == nil {
		return
	}
	for &chunk in chunks^ {
		delete(chunk.id, allocator)
		delete(chunk.metadata, allocator)
		delete(chunk.content, allocator)
	}
	delete(chunks^)
}

code_index_join_lines :: proc(
	lines: []string,
	start, total: int,
	allocator := context.allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for line, index in lines {
		strings.write_string(&builder, line)
		if start + index < total - 1 {
			strings.write_byte(&builder, '\n')
		}
	}
	return strings.to_string(builder)
}

code_index_chunk_identifier :: proc(
	relativePath: string,
	startLine, endLine: int,
	allocator := context.allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, relativePath)
	strings.write_byte(&builder, ':')
	code_index_write_decimal(&builder, startLine)
	strings.write_byte(&builder, '-')
	code_index_write_decimal(&builder, endLine)
	return strings.to_string(builder)
}

code_index_chunk_metadata :: proc(
	relativePath: string,
	startLine, endLine: int,
	allocator := context.allocator,
) -> string {
	return code_index_chunk_identifier(relativePath, startLine, endLine, allocator)
}

code_index_write_decimal :: proc(builder: ^strings.Builder, value: int) {
	if value == 0 {
		strings.write_byte(builder, '0')
		return
	}
	digits: [20]byte
	length := 0
	remaining := value
	for remaining > 0 {
		digits[length] = byte(remaining % 10) + '0'
		length += 1
		remaining /= 10
	}
	for index := length - 1; index >= 0; index -= 1 {
		strings.write_byte(builder, digits[index])
	}
}

code_index_add_embeddings :: proc(
	index: ^Code_Index,
	chunks: []Code_Chunk,
	embeddings: [][]f32,
	allocator := context.allocator,
) -> bool {
	if index == nil ||
	   len(chunks) == 0 ||
	   len(chunks) != len(embeddings) ||
	   len(embeddings[0]) == 0 {
		return false
	}
	if !index.databaseInitialized {
		if vdb.init(&index.database, len(embeddings[0]), .Cosine, allocator) != .None {
			return false
		}
		index.databaseInitialized = true
	}
	if vdb.dimensions(&index.database) != len(embeddings[0]) {
		return false
	}
	for embedding, chunkIndex in embeddings {
		if len(embedding) != vdb.dimensions(&index.database) ||
		   vdb.add_vector(
			   &index.database,
			   embedding,
			   chunks[chunkIndex].id,
			   chunks[chunkIndex].metadata,
		   ) !=
			   .None {
			return false
		}
	}
	index.dirty = true
	return true
}

code_index_search :: proc(
	index: ^Code_Index,
	query: []f32,
	maximumResults: int,
	allocator := context.allocator,
) -> [dynamic]Code_Search_Result {
	results := make([dynamic]Code_Search_Result, 0, 0, allocator)
	if index == nil || !index.databaseInitialized || len(query) == 0 || maximumResults <= 0 {
		return results
	}

	resultSet, searchError := vdb.search(&index.database, query, maximumResults)
	if searchError != .None {
		return results
	}
	defer vdb.result_set_destroy(&resultSet)
	for result in resultSet.results {
		append(
			&results,
			Code_Search_Result {
				id = strings.clone(result.id, allocator),
				metadata = strings.clone(result.metadata, allocator),
				distance = result.distance,
			},
		)
	}
	return results
}

code_index_search_results_destroy :: proc(
	results: ^[dynamic]Code_Search_Result,
	allocator := context.allocator,
) {
	if results == nil {
		return
	}
	for &result in results^ {
		delete(result.id, allocator)
		delete(result.metadata, allocator)
	}
	delete(results^)
}

code_index_load :: proc(index: ^Code_Index, allocator := context.allocator) -> Code_Index_Error {
	if index == nil || index.cachePath == "" {
		return .Invalid_Cache
	}
	if index.databaseInitialized {
		return .None
	}
	if !os.exists(index.cachePath) {
		return .Not_Found
	}

	loadError := vdb.load(&index.database, index.cachePath, allocator)
	#partial switch loadError {
	case .None:
		index.databaseInitialized = true
		return .None
	case .Invalid_Format:
		return .Invalid_Format
	case:
		return .Io_Error
	}
}

code_index_save :: proc(index: ^Code_Index) -> Code_Index_Error {
	if index == nil ||
	   !index.databaseInitialized ||
	   index.cacheDir == "" ||
	   index.cachePath == "" {
		return .Invalid_Cache
	}
	if !os.exists(index.cacheDir) && os.make_directory_all(index.cacheDir) != nil {
		return .Io_Error
	}
	if vdb.save(&index.database, index.cachePath) != .None {
		return .Io_Error
	}
	index.dirty = false
	return .None
}
