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
