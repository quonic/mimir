package ai

// Model capability/limit lookup sourced from models.dev.

import json "core:encoding/json"
import "core:mem"
import "core:strings"
import "core:sync"

import http "../http"

MODELS_DEV_API_URL :: "https://models.dev/api.json"

Models_Dev_Cost_Wire :: struct {
	input:        f64,
	output:       f64,
	reasoning:    f64,
	cache_read:   f64,
	cache_write:  f64,
	input_audio:  f64,
	output_audio: f64,
}

Models_Dev_Limit_Wire :: struct {
	contextWindow: int `json:"context"`,
	input:         int,
	output:        int,
}

Models_Dev_Modalities_Wire :: struct {
	input:  []string,
	output: []string,
}

Models_Dev_Model_Wire :: struct {
	name:              string,
	attachment:        bool,
	reasoning:         bool,
	tool_call:         bool,
	structured_output: bool,
	temperature:       bool,
	knowledge:         string,
	release_date:      string,
	last_updated:      string,
	open_weights:      bool,
	status:            string,
	cost:              Models_Dev_Cost_Wire,
	limit:             Models_Dev_Limit_Wire,
	modalities:        Models_Dev_Modalities_Wire,
}

Models_Dev_Provider_Wire :: struct {
	models: map[string]Models_Dev_Model_Wire,
}

Models_Dev_Api_Response_Wire :: map[string]Models_Dev_Provider_Wire

Models_Dev_Cost :: struct {
	input:       f64,
	output:      f64,
	reasoning:   f64,
	cacheRead:   f64,
	cacheWrite:  f64,
	inputAudio:  f64,
	outputAudio: f64,
}

Models_Dev_Limit :: struct {
	contextWindow: int,
	input:         int,
	output:        int,
}

Models_Dev_Modalities :: struct {
	input:  [dynamic]string,
	output: [dynamic]string,
}

Models_Dev_Model_Metadata :: struct {
	id:               string,
	name:             string,
	attachment:       bool,
	reasoning:        bool,
	toolCall:         bool,
	structuredOutput: bool,
	temperature:      bool,
	knowledge:        string,
	releaseDate:      string,
	lastUpdated:      string,
	openWeights:      bool,
	status:           string,
	cost:             Models_Dev_Cost,
	limit:            Models_Dev_Limit,
	modalities:       Models_Dev_Modalities,
}

models_dev_model_metadata_clone :: proc(
	metadata: Models_Dev_Model_Metadata,
	allocator := context.allocator,
) -> Models_Dev_Model_Metadata {
	clone := metadata
	clone.id = strings.clone(metadata.id, allocator)
	clone.name = strings.clone(metadata.name, allocator)
	clone.knowledge = strings.clone(metadata.knowledge, allocator)
	clone.releaseDate = strings.clone(metadata.releaseDate, allocator)
	clone.lastUpdated = strings.clone(metadata.lastUpdated, allocator)
	clone.status = strings.clone(metadata.status, allocator)
	clone.modalities.input = make([dynamic]string, 0, len(metadata.modalities.input), allocator)
	for value in metadata.modalities.input {
		append(&clone.modalities.input, strings.clone(value, allocator))
	}
	clone.modalities.output = make([dynamic]string, 0, len(metadata.modalities.output), allocator)
	for value in metadata.modalities.output {
		append(&clone.modalities.output, strings.clone(value, allocator))
	}
	return clone
}

models_dev_model_metadata_destroy :: proc(
	metadata: ^Models_Dev_Model_Metadata,
	allocator := context.allocator,
) {
	if metadata.id != "" {
		delete_string(metadata.id, allocator)
	}
	if metadata.name != "" {
		delete_string(metadata.name, allocator)
	}
	if metadata.knowledge != "" {
		delete_string(metadata.knowledge, allocator)
	}
	if metadata.releaseDate != "" {
		delete_string(metadata.releaseDate, allocator)
	}
	if metadata.lastUpdated != "" {
		delete_string(metadata.lastUpdated, allocator)
	}
	if metadata.status != "" {
		delete_string(metadata.status, allocator)
	}
	for value in metadata.modalities.input {
		delete(value, allocator)
	}
	delete_dynamic_array(metadata.modalities.input)
	for value in metadata.modalities.output {
		delete(value, allocator)
	}
	delete_dynamic_array(metadata.modalities.output)
}

models_dev_metadata_map_destroy :: proc(
	metadata: ^map[string]Models_Dev_Model_Metadata,
	allocator := context.allocator,
) {
	for key, value in metadata^ {
		entry := value
		models_dev_model_metadata_destroy(&entry, allocator)
		delete_string(key, allocator)
	}
	delete_map(metadata^)
}

// Pure parser: no HTTP. Keep only the OpenAI provider branch for compatibility.
parse_models_dev_openai_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	map[string]Models_Dev_Model_Metadata,
	AI_Error,
) {
	wire: Models_Dev_Api_Response_Wire
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	openai, ok := wire["openai"]
	if decodeErr != nil || !ok || len(openai.models) == 0 {
		return nil, .Invalid_Response
	}

	metadata := make(map[string]Models_Dev_Model_Metadata, len(openai.models), allocator)
	for modelID, modelWire in openai.models {
		models_dev_append_metadata(&metadata, modelID, modelWire, allocator)
	}
	return metadata, .None
}

parse_models_dev_catalog_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (
	map[string]Models_Dev_Model_Metadata,
	AI_Error,
) {
	wire: Models_Dev_Api_Response_Wire
	decodeErr := json.unmarshal_string(body, &wire, allocator = context.temp_allocator)
	if decodeErr != nil || len(wire) == 0 {
		return nil, .Invalid_Response
	}

	metadata := make(map[string]Models_Dev_Model_Metadata, 0, allocator)
	if openai, ok := wire["openai"]; ok {
		for modelID, modelWire in openai.models {
			models_dev_append_metadata(&metadata, modelID, modelWire, allocator)
		}
	}
	for provider, providerWire in wire {
		if provider == "openai" {
			continue
		}
		for modelID, modelWire in providerWire.models {
			lowerID := strings.to_lower(modelID, context.temp_allocator)
			if _, exists := metadata[lowerID]; !exists {
				models_dev_append_metadata(&metadata, modelID, modelWire, allocator)
			}
		}
	}
	if len(metadata) == 0 {
		models_dev_metadata_map_destroy(&metadata, allocator)
		return nil, .Invalid_Response
	}
	return metadata, .None
}

models_dev_append_metadata :: proc(
	metadata: ^map[string]Models_Dev_Model_Metadata,
	modelID: string,
	modelWire: Models_Dev_Model_Wire,
	allocator: mem.Allocator,
) {
	key := strings.to_lower(modelID, allocator)
	entry := Models_Dev_Model_Metadata {
		id = strings.to_lower(modelID, allocator),
		name = strings.clone(modelWire.name, allocator),
		attachment = modelWire.attachment,
		reasoning = modelWire.reasoning,
		toolCall = modelWire.tool_call,
		structuredOutput = modelWire.structured_output,
		temperature = modelWire.temperature,
		knowledge = strings.clone(modelWire.knowledge, allocator),
		releaseDate = strings.clone(modelWire.release_date, allocator),
		lastUpdated = strings.clone(modelWire.last_updated, allocator),
		openWeights = modelWire.open_weights,
		status = strings.clone(modelWire.status, allocator),
		cost = Models_Dev_Cost {
			input = modelWire.cost.input,
			output = modelWire.cost.output,
			reasoning = modelWire.cost.reasoning,
			cacheRead = modelWire.cost.cache_read,
			cacheWrite = modelWire.cost.cache_write,
			inputAudio = modelWire.cost.input_audio,
			outputAudio = modelWire.cost.output_audio,
		},
		limit = Models_Dev_Limit {
			contextWindow = modelWire.limit.contextWindow,
			input = modelWire.limit.input,
			output = modelWire.limit.output,
		},
	}
	entry.modalities.input = make([dynamic]string, 0, len(modelWire.modalities.input), allocator)
	for value in modelWire.modalities.input {
		append(&entry.modalities.input, strings.clone(value, allocator))
	}
	entry.modalities.output = make([dynamic]string, 0, len(modelWire.modalities.output), allocator)
	for value in modelWire.modalities.output {
		append(&entry.modalities.output, strings.clone(value, allocator))
	}
	metadata^[key] = entry
}

// Exact match only, normalized to lowercase; falls back to stripping a leading "prefix/" segment
// (e.g. "ollama/llama3.1" -> "llama3.1") when the unstripped name has no match.
models_dev_lookup :: proc(
	metadata: map[string]Models_Dev_Model_Metadata,
	modelName: string,
	allocator := context.allocator,
) -> (
	Models_Dev_Model_Metadata,
	bool,
) {
	lower := strings.to_lower(modelName, context.temp_allocator)
	if entry, ok := metadata[lower]; ok {
		return models_dev_model_metadata_clone(entry, allocator), true
	}
	if slashIndex := strings.index_byte(lower, '/'); slashIndex >= 0 {
		stripped := lower[slashIndex + 1:]
		if entry, ok := metadata[stripped]; ok {
			return models_dev_model_metadata_clone(entry, allocator), true
		}
	}
	for _, entry in metadata {
		entryID := strings.to_lower(entry.id, context.temp_allocator)
		if entryID == lower {
			return models_dev_model_metadata_clone(entry, allocator), true
		}
		if slashIndex := strings.index_byte(lower, '/'); slashIndex >= 0 {
			if entryID == lower[slashIndex + 1:] {
				return models_dev_model_metadata_clone(entry, allocator), true
			}
		}
	}
	return Models_Dev_Model_Metadata{}, false
}

modelsDevCache: map[string]Models_Dev_Model_Metadata
modelsDevCacheLoaded: bool
// guards the lazily-populated process-lifetime cache below from concurrent fetches.
modelsDevCacheMutex: sync.Mutex

fetch_models_dev_openai_metadata :: proc(
	allocator := context.allocator,
) -> (
	map[string]Models_Dev_Model_Metadata,
	AI_Error,
) {
	sync.mutex_lock(&modelsDevCacheMutex)
	if modelsDevCacheLoaded {
		cached := modelsDevCache
		sync.mutex_unlock(&modelsDevCacheMutex)
		return cached, .None
	}
	sync.mutex_unlock(&modelsDevCacheMutex)

	extraHeaders: [dynamic][2]string
	defer delete(extraHeaders)
	append_standard_ai_headers(&extraHeaders, .OpenAI, .Model_Metadata)

	body, status, err := do_json_get(MODELS_DEV_API_URL, extraHeaders[:])
	if err != .None {
		return nil, err
	}
	defer if body != "" {delete(body)}
	if !http.status_is_success(status) {
		return nil, map_status_to_error(status)
	}

	metadata, parseErr := parse_models_dev_catalog_response(body, context.allocator)
	if parseErr != .None {
		return nil, parseErr
	}

	sync.mutex_lock(&modelsDevCacheMutex)
	defer sync.mutex_unlock(&modelsDevCacheMutex)
	if !modelsDevCacheLoaded {
		modelsDevCache = metadata
		modelsDevCacheLoaded = true
	}
	return modelsDevCache, .None
}

// Convenience wrapper: a fetch failure is indistinguishable from "model not found".
models_dev_lookup_openai_model :: proc(
	modelName: string,
	allocator := context.allocator,
) -> (
	Models_Dev_Model_Metadata,
	bool,
) {
	metadata, err := fetch_models_dev_openai_metadata()
	if err != .None || metadata == nil {
		return Models_Dev_Model_Metadata{}, false
	}
	return models_dev_lookup(metadata, modelName, allocator)
}
