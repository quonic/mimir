package main

import "ai"
import json "core:encoding/json"
import "core:os"
import "core:strings"

DEFAULT_CONFIG_ENDPOINT :: "http://localhost:11434"
DEFAULT_CONFIG_PROVIDER :: "ollama"

Config_Error :: enum int {
	None = 0,
	Invalid_Home,
	Not_Found,
	Io_Error,
	Invalid_JSON,
}

Provider_Config_Wire :: struct {
	name:     string,
	type:     string,
	endpoint: string,
	apiKey:   string,
	model:    string,
	enabled:  bool,
}

Mimir_Config_Wire :: struct {
	selectedProvider: string,
	selectedModel:    string,
	providers:        []Provider_Config_Wire,
	mcpServers:       []MCP_Server_Config,
	skillPaths:       []string,
}

Provider_Config :: struct {
	name:     string,
	type:     ai.Interface_Type,
	endpoint: string,
	apiKey:   string,
	model:    string,
	enabled:  bool,
}

Mimir_Config :: struct {
	selectedProvider: string,
	selectedModel:    string,
	providers:        [dynamic]Provider_Config,
	mcpServers:       [dynamic]MCP_Server_Config,
	skillPaths:       [dynamic]string,
}

Config_Register_Result :: struct {
	ollamaProbeFailed: bool,
	modelCount:        int,
}

config_dir :: proc(home: string, allocator := context.allocator) -> string {
	if home == "" {
		return ""
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, home)
	strings.write_string(&builder, "/.config/mimir")
	return strings.to_string(builder)
}

config_path :: proc(home: string, allocator := context.allocator) -> string {
	dir := config_dir(home, allocator)
	if dir == "" {
		return ""
	}
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, dir)
	strings.write_string(&builder, "/config.json")
	return strings.to_string(builder)
}

default_ollama_config :: proc(allocator := context.allocator) -> Mimir_Config {
	config: Mimir_Config
	config.selectedProvider = DEFAULT_CONFIG_PROVIDER
	config.providers = make([dynamic]Provider_Config, 0, 1, allocator)
	config.mcpServers = make([dynamic]MCP_Server_Config, 0, 0, allocator)
	config.skillPaths = make([dynamic]string, 0, 2, allocator)
	append(
		&config.providers,
		Provider_Config {
			name = DEFAULT_CONFIG_PROVIDER,
			type = .Ollama,
			endpoint = DEFAULT_CONFIG_ENDPOINT,
			enabled = true,
		},
	)
	return config
}

register_config_interfaces :: proc(
	config: Mimir_Config,
	probeOllama := false,
	allocator := context.allocator,
) -> Config_Register_Result {
	result: Config_Register_Result
	for provider in config.providers {
		if !provider.enabled {
			continue
		}

		if probeOllama && provider.type == .Ollama {
			models, err := ai.probe_ollama_endpoint(provider.endpoint, allocator)
			if err == .None {
				result.modelCount += len(models)
				ai.add_interface_with_models(
					provider.name,
					provider.type,
					provider.endpoint,
					models[:],
				)
				delete(models)
				continue
			}
			result.ollamaProbeFailed = true
		}

		ai.add_interface(provider.name, provider.type, provider.endpoint)
	}
	return result
}

provider_type_to_string :: proc(providerType: ai.Interface_Type) -> string {
	switch providerType {
	case .Anthropic:
		return "anthropic"
	case .OpenAI:
		return "openai"
	case .Ollama:
		return "ollama"
	case .None:
		return "none"
	}
	return "none"
}

provider_type_from_string :: proc(text: string) -> (ai.Interface_Type, bool) {
	switch text {
	case "anthropic":
		return .Anthropic, true
	case "openai":
		return .OpenAI, true
	case "ollama":
		return .Ollama, true
	case "none":
		return .None, true
	}
	return .None, false
}

parse_config_from_json :: proc(
	jsonText: string,
	allocator := context.allocator,
) -> (
	Mimir_Config,
	Config_Error,
) {
	wire: Mimir_Config_Wire
	decodeErr := json.unmarshal_string(jsonText, &wire, allocator = context.temp_allocator)
	if decodeErr != nil {
		return Mimir_Config{}, .Invalid_JSON
	}

	config: Mimir_Config
	config.selectedProvider = strings.clone(wire.selectedProvider, allocator)
	config.selectedModel = strings.clone(wire.selectedModel, allocator)
	config.providers = make([dynamic]Provider_Config, 0, len(wire.providers), allocator)
	config.mcpServers = make([dynamic]MCP_Server_Config, 0, len(wire.mcpServers), allocator)
	config.skillPaths = make([dynamic]string, 0, len(wire.skillPaths), allocator)

	for provider in wire.providers {
		providerType, ok := provider_type_from_string(provider.type)
		if !ok || provider.name == "" {
			return Mimir_Config{}, .Invalid_JSON
		}
		append(
			&config.providers,
			Provider_Config {
				name = strings.clone(provider.name, allocator),
				type = providerType,
				endpoint = strings.clone(provider.endpoint, allocator),
				apiKey = strings.clone(provider.apiKey, allocator),
				model = strings.clone(provider.model, allocator),
				enabled = provider.enabled,
			},
		)
	}

	for server in wire.mcpServers {
		append(&config.mcpServers, server)
	}

	for path in wire.skillPaths {
		append(&config.skillPaths, strings.clone(path, allocator))
	}

	return config, .None
}

load_config_from_file :: proc(
	home: string,
	allocator := context.allocator,
) -> (
	Mimir_Config,
	Config_Error,
) {
	path := config_path(home, context.temp_allocator)
	if path == "" {
		return Mimir_Config{}, .Invalid_Home
	}

	data, readErr := os.read_entire_file(path, context.temp_allocator)
	if readErr != nil {
		#partial switch err in readErr {
		case os.General_Error:
			if err == .Not_Exist {
				return Mimir_Config{}, .Not_Found
			}
		}
		return Mimir_Config{}, .Io_Error
	}

	return parse_config_from_json(string(data), allocator)
}

save_config_to_file :: proc(home: string, config: Mimir_Config) -> Config_Error {
	dir := config_dir(home, context.temp_allocator)
	path := config_path(home, context.temp_allocator)
	if dir == "" || path == "" {
		return .Invalid_Home
	}

	if !os.exists(dir) {
		mkdirErr := os.make_directory_all(dir)
		if mkdirErr != nil {
			return .Io_Error
		}
	}

	payload := config_to_json(config, context.temp_allocator)
	writeErr := os.write_entire_file(path, payload)
	if writeErr != nil {
		return .Io_Error
	}

	return .None
}

config_to_json :: proc(config: Mimir_Config, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, "{\n")
	strings.write_string(&builder, "  \"selectedProvider\": ")
	write_json_string(&builder, config.selectedProvider)
	strings.write_string(&builder, ",\n")
	strings.write_string(&builder, "  \"selectedModel\": ")
	write_json_string(&builder, config.selectedModel)
	strings.write_string(&builder, ",\n")
	strings.write_string(&builder, "  \"providers\": [")
	for provider, index in config.providers {
		if index > 0 {
			strings.write_string(&builder, ",")
		}
		strings.write_string(&builder, "\n    {\n")
		strings.write_string(&builder, "      \"name\": ")
		write_json_string(&builder, provider.name)
		strings.write_string(&builder, ",\n      \"type\": ")
		write_json_string(&builder, provider_type_to_string(provider.type))
		strings.write_string(&builder, ",\n      \"endpoint\": ")
		write_json_string(&builder, provider.endpoint)
		strings.write_string(&builder, ",\n      \"apiKey\": ")
		write_json_string(&builder, provider.apiKey)
		strings.write_string(&builder, ",\n      \"model\": ")
		write_json_string(&builder, provider.model)
		strings.write_string(&builder, ",\n      \"enabled\": ")
		if provider.enabled {
			strings.write_string(&builder, "true")
		} else {
			strings.write_string(&builder, "false")
		}
		strings.write_string(&builder, "\n    }")
	}
	if len(config.providers) > 0 {
		strings.write_string(&builder, "\n  ")
	}
	strings.write_string(&builder, "],\n")
	strings.write_string(&builder, "  \"mcpServers\": [],\n")
	strings.write_string(&builder, "  \"skillPaths\": []\n")
	strings.write_string(&builder, "}\n")
	return strings.to_string(builder)
}

write_json_string :: proc(builder: ^strings.Builder, text: string) {
	strings.write_byte(builder, '"')
	for index := 0; index < len(text); index += 1 {
		switch text[index] {
		case '"':
			strings.write_string(builder, "\\\"")
		case '\\':
			strings.write_string(builder, "\\\\")
		case '\n':
			strings.write_string(builder, "\\n")
		case '\r':
			strings.write_string(builder, "\\r")
		case '\t':
			strings.write_string(builder, "\\t")
		case:
			strings.write_byte(builder, text[index])
		}
	}
	strings.write_byte(builder, '"')
}
