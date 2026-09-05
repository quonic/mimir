package ai

import "core:strings"
import "core:testing"

@(test)
test_parse_models_dev_openai_response_extracts_fields :: proc(t: ^testing.T) {
	body :=
		`{"openai":{"models":{"GPT-5":{"name":"GPT-5","attachment":true,"reasoning":true,` +
		`"tool_call":true,"structured_output":true,"temperature":false,"knowledge":"2025-08",` +
		`"release_date":"2025-08-07","last_updated":"2025-08-07","open_weights":false,` +
		`"status":"beta","cost":{"input":1.25,"output":10,"cache_read":0.125},` +
		`"limit":{"context":400000,"input":272000,"output":128000},` +
		`"modalities":{"input":["text","image"],"output":["text"]}}}},` +
		`"anthropic":{"models":{"claude":{"name":"Claude"}}}}`

	metadata, err := parse_models_dev_openai_response(body, context.allocator)
	defer models_dev_metadata_map_destroy(&metadata, context.allocator)

	assert(err == .None, "expected models.dev response to parse")
	assert(len(metadata) == 1, "expected only the openai provider's models to be captured")

	entry, ok := metadata["gpt-5"]
	assert(ok, "expected lowercase model id key")
	assert(entry.id == "gpt-5", "expected metadata id to be lowercase")
	assert(entry.name == "GPT-5", "expected model display name")
	assert(entry.attachment, "expected attachment support")
	assert(entry.reasoning, "expected reasoning support")
	assert(entry.toolCall, "expected tool_call support")
	assert(entry.structuredOutput, "expected structured_output support")
	assert(!entry.temperature, "expected temperature unsupported")
	assert(entry.knowledge == "2025-08", "expected knowledge cutoff")
	assert(entry.releaseDate == "2025-08-07", "expected release date")
	assert(entry.lastUpdated == "2025-08-07", "expected last updated date")
	assert(!entry.openWeights, "expected closed weights")
	assert(entry.status == "beta", "expected status")
	assert(entry.cost.input == 1.25, "expected cost input")
	assert(entry.cost.output == 10, "expected cost output")
	assert(entry.cost.cacheRead == 0.125, "expected cost cache_read")
	assert(entry.limit.contextWindow == 400000, "expected context limit")
	assert(entry.limit.input == 272000, "expected input limit")
	assert(entry.limit.output == 128000, "expected output limit")
	assert(len(entry.modalities.input) == 2, "expected two input modalities")
	assert(entry.modalities.input[1] == "image", "expected image modality")
	assert(
		len(entry.modalities.output) == 1 && entry.modalities.output[0] == "text",
		"expected text output modality",
	)
	_ = t
}

@(test)
test_parse_models_dev_openai_response_missing_openai_key :: proc(t: ^testing.T) {
	metadata, err := parse_models_dev_openai_response(
		`{"anthropic":{"models":{"claude":{"name":"Claude"}}}}`,
		context.allocator,
	)
	defer models_dev_metadata_map_destroy(&metadata, context.allocator)

	assert(err == .Invalid_Response, "expected missing openai key to be invalid")
	assert(len(metadata) == 0, "expected no metadata")
	_ = t
}

@(test)
test_parse_models_dev_catalog_response_includes_non_openai_models :: proc(t: ^testing.T) {
	body :=
		`{"openai":{"models":{"shared":{"name":"OpenAI shared",` +
		`"limit":{"context":128000}}}},` +
		`"local":{"models":{"qwen3.8-27b":{"name":"Local Qwen",` +
		`"limit":{"context":262144}},"shared":{"name":"Local shared",` +
		`"limit":{"context":4096}}}}}`
	metadata, err := parse_models_dev_catalog_response(body, context.allocator)
	defer models_dev_metadata_map_destroy(&metadata, context.allocator)

	assert(err == .None, "expected full models.dev catalog to parse")
	assert(len(metadata) == 2, "expected unique model IDs from all providers")
	assert(metadata["qwen3.8-27b"].limit.contextWindow == 262144, "expected local model limit")
	assert(
		metadata["shared"].limit.contextWindow == 128000,
		"expected OpenAI metadata to take precedence",
	)
	_ = t
}

@(test)
test_models_dev_lookup_exact_match_case_insensitive :: proc(t: ^testing.T) {
	metadata := make(map[string]Models_Dev_Model_Metadata, 1, context.allocator)
	defer models_dev_metadata_map_destroy(&metadata, context.allocator)
	metadata["gpt-5"] = Models_Dev_Model_Metadata {
		id   = strings.clone("gpt-5"),
		name = strings.clone("GPT-5"),
	}

	entry, ok := models_dev_lookup(metadata, "GPT-5", context.allocator)
	defer models_dev_model_metadata_destroy(&entry, context.allocator)

	assert(ok, "expected case-insensitive exact match")
	assert(entry.name == "GPT-5", "expected matched entry")
	_ = t
}

@(test)
test_models_dev_lookup_strips_prefix_before_first_slash :: proc(t: ^testing.T) {
	metadata := make(map[string]Models_Dev_Model_Metadata, 1, context.allocator)
	defer models_dev_metadata_map_destroy(&metadata, context.allocator)
	metadata["llama3.1"] = Models_Dev_Model_Metadata {
		id   = strings.clone("llama3.1"),
		name = strings.clone("Llama 3.1"),
	}

	entry, ok := models_dev_lookup(metadata, "ollama/llama3.1", context.allocator)
	defer models_dev_model_metadata_destroy(&entry, context.allocator)

	assert(ok, "expected prefix-stripped match")
	assert(entry.id == "llama3.1", "expected stripped lookup to match the base model id")
	_ = t
}

@(test)
test_models_dev_lookup_returns_false_when_not_found :: proc(t: ^testing.T) {
	metadata := make(map[string]Models_Dev_Model_Metadata, 1, context.allocator)
	defer models_dev_metadata_map_destroy(&metadata, context.allocator)
	metadata["gpt-5"] = Models_Dev_Model_Metadata {
		id   = strings.clone("gpt-5"),
		name = strings.clone("GPT-5"),
	}

	entry, ok := models_dev_lookup(metadata, "ollama/unknown-model", context.allocator)

	assert(!ok, "expected no match")
	assert(entry.id == "", "expected zero value on no match")
	_ = t
}

@(test)
test_models_dev_lookup_matches_model_name_to_metadata_id :: proc(t: ^testing.T) {
	metadata := make(map[string]Models_Dev_Model_Metadata, 1, context.allocator)
	defer models_dev_metadata_map_destroy(&metadata, context.allocator)
	metadataKey := strings.clone("catalog-key", context.allocator)
	metadata[metadataKey] = Models_Dev_Model_Metadata {
		id   = strings.clone("GPT-5", context.allocator),
		name = strings.clone("GPT-5", context.allocator),
	}

	entry, ok := models_dev_lookup(metadata, "gpt-5", context.allocator)
	defer models_dev_model_metadata_destroy(&entry, context.allocator)

	assert(ok, "expected model name to match metadata ID")
	assert(entry.id == "GPT-5", "expected metadata entry matched by ID")
	_ = t
}
