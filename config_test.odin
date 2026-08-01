package main

import "ai"
import "core:os"
import "core:testing"
import settings "./settings"

@(test)
test_provider_type_round_trip :: proc(t: ^testing.T) {
	providerType, ok := settings.provider_type_from_string("ollama")
	assert(ok, "expected ollama provider type string to parse")
	assert(providerType == .Ollama, "expected ollama provider type")
	assert(settings.provider_type_to_string(providerType) == "ollama", "expected ollama round trip")

	_, invalidOk := settings.provider_type_from_string("wat")
	assert(!invalidOk, "expected unknown provider type to fail")
	_ = t
}

@(test)
test_parse_config_from_json :: proc(t: ^testing.T) {
	payload := `{
  "selectedProvider": "ollama",
  "selectedModel": "llama3.2",
	"contextWindows": [
		{
			"providerName": "ollama",
			"model": "llama3.2",
			"tokens": 131072
		}
	],
  "providers": [
    {
      "name": "ollama",
      "type": "ollama",
      "endpoint": "http://localhost:11434",
      "apiKey": "",
      "model": "llama3.2",
      "enabled": true
    }
  ],
  "mcpServers": [],
	"skillPaths": ["/tmp/mimir/skills"],
	"permissionGrants": [
		{
			"kind": "directorySubtree",
			"projectRoot": "/tmp/mimir",
			"directory": "/tmp/mimir/generated"
		}
	]
}`

	config, err := settings.parse_config_from_json(payload, context.allocator)
	defer settings.config_destroy(&config)

	assert(err == .None, "expected valid config JSON to parse")
	assert(config.selectedProvider == "ollama", "expected selected provider")
	assert(config.selectedModel == "llama3.2", "expected selected model")
	assert(config.embeddingProvider == "", "expected missing embedding provider to stay empty")
	assert(config.embeddingModel == "", "expected missing embedding model to stay empty")
	assert(config.safetyProvider == "", "expected missing safety provider to stay empty")
	assert(config.safetyModel == "", "expected missing safety model to stay empty")
	assert(
		config.approvalMethod == .Always_Ask,
		"expected missing approval method to default to always ask",
	)
	assert(
		config.toolContinuations == settings.DEFAULT_TOOL_CONTINUATIONS,
		"expected missing tool continuation limit to use the default",
	)
	assert(len(config.providers) == 1, "expected one provider")
	assert(config.providers[0].type == ai.Interface_Type.Ollama, "expected Ollama provider")
	assert(config.providers[0].model == "llama3.2", "expected provider model")
	assert(
		settings.config_context_window_tokens(&config, "ollama", "llama3.2") == 131072,
		"expected model-specific context window",
	)
	assert(config.providers[0].enabled, "expected provider to be enabled")
	assert(len(config.skillPaths) == 1, "expected skill path to parse")
	assert(config.skillPaths[0] == "/tmp/mimir/skills", "expected skill path")
	assert(len(config.permissionGrants) == 1, "expected one permission grant")
	assert(
		config.permissionGrants[0].kind == .Directory_Subtree,
		"expected directory subtree permission grant",
	)
	_ = t
}

@(test)
test_parse_config_rejects_invalid_provider_type :: proc(t: ^testing.T) {
	payload := `{
  "selectedProvider": "bad",
  "selectedModel": "",
  "providers": [
    {
      "name": "bad",
      "type": "bad",
      "endpoint": "http://localhost:11434",
      "apiKey": "",
      "model": "",
      "enabled": true
    }
  ],
  "mcpServers": [],
  "skillPaths": []
}`

	_, err := settings.parse_config_from_json(payload, context.allocator)
	assert(err == .Invalid_JSON, "expected invalid provider type to reject config")
	_ = t
}

@(test)
test_load_config_reports_missing_file :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-config-*", context.temp_allocator)
	assert(tempErr == nil, "expected temp home directory")
	defer os.remove_all(home)

	_, err := settings.load_config_from_file(home, context.temp_allocator)
	assert(err == .Not_Found, "expected missing config file to be reported")
	_ = t
}

@(test)
test_save_and_load_config_round_trip :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-config-*", context.temp_allocator)
	assert(tempErr == nil, "expected temp home directory")
	defer os.remove_all(home)

	config := settings.default_ollama_config(context.temp_allocator)
	config.selectedModel = "llama3.2"
	config.embeddingProvider = "ollama"
	config.embeddingModel = "nomic-embed-text"
	config.safetyProvider = "ollama"
	config.safetyModel = "llama3.2:instruct"
	config.approvalMethod = .Approve_Safe
	config.toolContinuations = 2500
	config.providers[0].model = "llama3.2"
	assert(
		settings.config_set_context_window_tokens(&config, "ollama", "llama3.2", 131072),
		"expected context window setting to save",
	)
	defer {
		delete(config.providers)
		for &entry in config.contextWindows {
			delete(entry.providerName, context.temp_allocator)
			delete(entry.model, context.temp_allocator)
		}
		delete(config.contextWindows)
		delete(config.mcpServers)
		delete(config.skillPaths)
		delete(config.permissionGrants)
	}

	saveErr := settings.save_config_to_file(home, config)
	assert(saveErr == .None, "expected config save to succeed")

	loaded, loadErr := settings.load_config_from_file(home, context.temp_allocator)
	defer {
		delete(loaded.providers)
		for &entry in loaded.contextWindows {
			delete(entry.providerName, context.temp_allocator)
			delete(entry.model, context.temp_allocator)
		}
		delete(loaded.contextWindows)
		delete(loaded.mcpServers)
		delete(loaded.skillPaths)
		delete(loaded.permissionGrants)
	}

	assert(loadErr == .None, "expected config load to succeed")
	assert(loaded.selectedProvider == settings.DEFAULT_CONFIG_PROVIDER, "expected selected provider")
	assert(loaded.selectedModel == "llama3.2", "expected selected model round trip")
	assert(loaded.embeddingProvider == "ollama", "expected embedding provider round trip")
	assert(loaded.embeddingModel == "nomic-embed-text", "expected embedding model round trip")
	assert(loaded.safetyProvider == "ollama", "expected safety provider round trip")
	assert(loaded.safetyModel == "llama3.2:instruct", "expected safety model round trip")
	assert(loaded.approvalMethod == .Approve_Safe, "expected approval method round trip")
	assert(loaded.toolContinuations == 2500, "expected tool continuation limit round trip")
	assert(len(loaded.providers) == 1, "expected one provider after load")
	assert(
		loaded.providers[0].endpoint == settings.DEFAULT_CONFIG_ENDPOINT,
		"expected endpoint round trip",
	)
	assert(loaded.providers[0].model == "llama3.2", "expected provider model round trip")
	assert(
		settings.config_context_window_tokens(&loaded, "ollama", "llama3.2") == 131072,
		"expected context window round trip",
	)
	_ = t
}

@(test)
test_parse_config_rejects_negative_tool_continuations :: proc(t: ^testing.T) {
	payload := `{
  "toolContinuations": -1,
  "providers": [],
  "mcpServers": [],
  "skillPaths": []
}`

	_, err := settings.parse_config_from_json(payload, context.temp_allocator)
	assert(err == .Invalid_JSON, "expected negative tool continuation limit to reject config")
	_ = t
}

@(test)
test_parse_config_rejects_invalid_approval_method :: proc(t: ^testing.T) {
	payload := `{
  "approvalMethod": "sometimes",
  "providers": [],
  "mcpServers": [],
  "skillPaths": []
}`

	_, err := settings.parse_config_from_json(payload, context.temp_allocator)
	assert(err == .Invalid_JSON, "expected invalid approval method to reject config")
	_ = t
}

@(test)
test_approval_method_string_round_trip :: proc(t: ^testing.T) {
	methods := [4]settings.Approval_Method{.Always_Ask, .Approve_Safe, .Approve_All, .Deny_All}
	for method in methods {
		value := settings.approval_method_to_string(method)
		parsed, parsedOK := settings.approval_method_from_string(value)
		assert(parsedOK, "expected approval method string to parse")
		assert(parsed == method, "expected approval method string round trip")
	}
	_ = t
}

@(test)
test_config_update_context_window_tokens_changes_only_new_values :: proc(t: ^testing.T) {
	config := settings.default_ollama_config(context.temp_allocator)
	defer settings.config_destroy(&config)

	assert(
		settings.config_update_context_window_tokens(&config, "ollama", "qwen3", 32768),
		"expected new context window to be added",
	)
	assert(
		!settings.config_update_context_window_tokens(&config, "ollama", "qwen3", 32768),
		"expected unchanged context window to be a no-op",
	)
	assert(
		settings.config_update_context_window_tokens(&config, "ollama", "qwen3", 65536),
		"expected changed context window to update",
	)
	assert(
		settings.config_context_window_tokens(&config, "ollama", "qwen3") == 65536,
		"expected updated model-specific context window",
	)
	assert(
		!settings.config_update_context_window_tokens(&config, "ollama", "qwen3", 0),
		"expected unknown context window to be ignored",
	)
	_ = t
}

@(test)
test_parse_config_rejects_permission_grant_outside_project :: proc(t: ^testing.T) {
	payload := `{
	"selectedProvider": "ollama",
	"selectedModel": "",
	"providers": [],
	"mcpServers": [],
	"skillPaths": [],
	"permissionGrants": [
		{
			"kind": "directorySubtree",
			"projectRoot": "/workspace/project",
			"directory": "/tmp"
		}
	]
}`

	_, err := settings.parse_config_from_json(payload, context.temp_allocator)
	assert(err == .Invalid_JSON, "expected out-of-project directory grant to reject config")
	_ = t
}

@(test)
test_input_history_path_is_unique_per_working_directory :: proc(t: ^testing.T) {
	home := "/tmp/mimir-home"
	projectA := "/tmp/project-a"
	projectB := "/tmp/project-b"

	pathA := input_history_path(home, projectA, context.temp_allocator)
	pathARepeat := input_history_path(home, projectA, context.temp_allocator)
	pathB := input_history_path(home, projectB, context.temp_allocator)

	assert(pathA != "", "expected history path for a valid home and directory")
	assert(pathA == pathARepeat, "expected history path to be deterministic")
	assert(pathA != pathB, "expected working directories to have isolated history paths")
	_ = t
}

@(test)
test_save_load_and_clear_input_history :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-history-*", context.temp_allocator)
	assert(tempErr == nil, "expected temporary home directory")
	defer os.remove_all(home)

	projectA := "/tmp/project-a"
	projectB := "/tmp/project-b"
	historyA := [2]string{"first entry", "quoted \"entry\"\nnext line"}
	historyB := [1]string{"other project"}

	assert(
		save_input_history_to_file(home, projectA, historyA[:]) == .None,
		"expected first history to save",
	)
	assert(
		save_input_history_to_file(home, projectB, historyB[:]) == .None,
		"expected second history to save",
	)

	loadedA, loadErrA := load_input_history_from_file(home, projectA, context.temp_allocator)
	defer {
		for &entry in loadedA {
			entry = ""
		}
		delete(loadedA)
	}
	assert(loadErrA == .None, "expected first history to load")
	assert(len(loadedA) == 2, "expected all first history entries")
	assert(loadedA[1] == "quoted \"entry\"\nnext line", "expected escaped entry to round trip")

	assert(clear_input_history_file(home, projectA) == .None, "expected first history to clear")
	_, missingErr := load_input_history_from_file(home, projectA, context.temp_allocator)
	assert(missingErr == .Not_Found, "expected cleared history file to be absent")

	loadedB, loadErrB := load_input_history_from_file(home, projectB, context.temp_allocator)
	defer {
		for &entry in loadedB {
			entry = ""
		}
		delete(loadedB)
	}
	assert(loadErrB == .None, "expected second history to remain")
	assert(loadedB[0] == "other project", "expected second history to be unchanged")
	_ = t
}
