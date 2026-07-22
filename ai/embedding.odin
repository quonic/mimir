package ai

import json "core:encoding/json"

Embedding_Options :: struct {
	dimensions:         int,
	hasDimensions:      bool,
	ollamaTruncate:     bool,
	hasOllamaTruncate:  bool,
	ollamaKeepAlive:    string,
	hasOllamaKeepAlive: bool,
	ollamaOptions:      json.Value,
	hasOllamaOptions:   bool,
}

Embedding_Request :: struct {
	model:   string,
	input:   string,
	options: Embedding_Options,
}

Embedding_Batch_Request :: struct {
	model:   string,
	inputs:  []string,
	options: Embedding_Options,
}

Embedding_Response :: struct {
	model:           string,
	embedding:       [dynamic]f32,
	inputTokenCount: int,
	totalDuration:   i64,
	loadDuration:    i64,
}

Embedding_Batch_Response :: struct {
	model:           string,
	embeddings:      [dynamic][dynamic]f32,
	inputTokenCount: int,
	totalDuration:   i64,
	loadDuration:    i64,
}

embedding_response_destroy :: proc(response: ^Embedding_Response, allocator := context.allocator) {
	if response.model != "" {
		delete(response.model, allocator)
	}
	delete(response.embedding)
	response^ = {}
}

embedding_batch_response_destroy :: proc(
	response: ^Embedding_Batch_Response,
	allocator := context.allocator,
) {
	if response.model != "" {
		delete(response.model, allocator)
	}
	for &embedding in response.embeddings {
		delete(embedding)
	}
	delete(response.embeddings)
	response^ = {}
}
