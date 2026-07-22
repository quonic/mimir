package main

import "ai"
import "core:os"
import "core:testing"

@(test)
test_provider_type_round_trip :: proc(t: ^testing.T) {
	providerType, ok := provider_type_from_string("ollama")
	assert(ok, "expected ollama provider type string to parse")
	assert(providerType == .Ollama, "expected ollama provider type")
	assert(provider_type_to_string(providerType) == "ollama", "expected ollama round trip")

	_, invalidOk := provider_type_from_string("wat")
	assert(!invalidOk, "expected unknown provider type to fail")
	_ = t
}

@(test)
test_parse_config_from_json :: proc(t: ^testing.T) {
	payload := `{
  "selectedProvider": "ollama",
  "selectedModel": "llama3.2",
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

	config, err := parse_config_from_json(payload, context.allocator)
	defer config_destroy(&config)

	assert(err == .None, "expected valid config JSON to parse")
	assert(config.selectedProvider == "ollama", "expected selected provider")
	assert(config.selectedModel == "llama3.2", "expected selected model")
	assert(len(config.providers) == 1, "expected one provider")
	assert(config.providers[0].type == ai.Interface_Type.Ollama, "expected Ollama provider")
	assert(config.providers[0].model == "llama3.2", "expected provider model")
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

	_, err := parse_config_from_json(payload, context.allocator)
	assert(err == .Invalid_JSON, "expected invalid provider type to reject config")
	_ = t
}

@(test)
test_load_config_reports_missing_file :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-config-*", context.temp_allocator)
	assert(tempErr == nil, "expected temp home directory")
	defer os.remove_all(home)

	_, err := load_config_from_file(home, context.temp_allocator)
	assert(err == .Not_Found, "expected missing config file to be reported")
	_ = t
}

@(test)
test_save_and_load_config_round_trip :: proc(t: ^testing.T) {
	home, tempErr := os.make_directory_temp("", "mimir-config-*", context.temp_allocator)
	assert(tempErr == nil, "expected temp home directory")
	defer os.remove_all(home)

	config := default_ollama_config(context.temp_allocator)
	config.selectedModel = "llama3.2"
	config.providers[0].model = "llama3.2"
	defer {
		delete(config.providers)
		delete(config.mcpServers)
		delete(config.skillPaths)
		delete(config.permissionGrants)
	}

	saveErr := save_config_to_file(home, config)
	assert(saveErr == .None, "expected config save to succeed")

	loaded, loadErr := load_config_from_file(home, context.temp_allocator)
	defer {
		delete(loaded.providers)
		delete(loaded.mcpServers)
		delete(loaded.skillPaths)
		delete(loaded.permissionGrants)
	}

	assert(loadErr == .None, "expected config load to succeed")
	assert(loaded.selectedProvider == DEFAULT_CONFIG_PROVIDER, "expected selected provider")
	assert(loaded.selectedModel == "llama3.2", "expected selected model round trip")
	assert(len(loaded.providers) == 1, "expected one provider after load")
	assert(loaded.providers[0].endpoint == DEFAULT_CONFIG_ENDPOINT, "expected endpoint round trip")
	assert(loaded.providers[0].model == "llama3.2", "expected provider model round trip")
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

	_, err := parse_config_from_json(payload, context.temp_allocator)
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
