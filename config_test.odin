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
  "skillPaths": ["/tmp/mimir/skills"]
}`

	config, err := parse_config_from_json(payload, context.temp_allocator)
	defer {
		delete(config.providers)
		delete(config.mcpServers)
		delete(config.skillPaths)
	}

	assert(err == .None, "expected valid config JSON to parse")
	assert(config.selectedProvider == "ollama", "expected selected provider")
	assert(config.selectedModel == "llama3.2", "expected selected model")
	assert(len(config.providers) == 1, "expected one provider")
	assert(config.providers[0].type == ai.Interface_Type.Ollama, "expected Ollama provider")
	assert(config.providers[0].model == "llama3.2", "expected provider model")
	assert(config.providers[0].enabled, "expected provider to be enabled")
	assert(len(config.skillPaths) == 1, "expected skill path to parse")
	assert(config.skillPaths[0] == "/tmp/mimir/skills", "expected skill path")
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

	_, err := parse_config_from_json(payload, context.temp_allocator)
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
	}

	saveErr := save_config_to_file(home, config)
	assert(saveErr == .None, "expected config save to succeed")

	loaded, loadErr := load_config_from_file(home, context.temp_allocator)
	defer {
		delete(loaded.providers)
		delete(loaded.mcpServers)
		delete(loaded.skillPaths)
	}

	assert(loadErr == .None, "expected config load to succeed")
	assert(loaded.selectedProvider == DEFAULT_CONFIG_PROVIDER, "expected selected provider")
	assert(loaded.selectedModel == "llama3.2", "expected selected model round trip")
	assert(len(loaded.providers) == 1, "expected one provider after load")
	assert(loaded.providers[0].endpoint == DEFAULT_CONFIG_ENDPOINT, "expected endpoint round trip")
	assert(loaded.providers[0].model == "llama3.2", "expected provider model round trip")
	_ = t
}