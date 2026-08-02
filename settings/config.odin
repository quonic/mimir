package settings

import ai "../ai"
import tool_policy "../tool_policy"
import json "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"

DEFAULT_CONFIG_ENDPOINT :: "http://localhost:11434"
DEFAULT_CONFIG_PROVIDER :: "ollama"
DEFAULT_TOOL_CONTINUATIONS :: 1000

Approval_Method :: enum int {
	Always_Ask = 0,
	Approve_Safe,
	Approve_All,
	Deny_All,
}

System_Prompt_Mode :: enum int {
	Append = 0,
	Replace,
}

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

Context_Window_Config_Wire :: struct {
	providerName: string,
	model:        string,
	tokens:       int,
}

Permission_Grant_Wire :: struct {
	kind:        string,
	projectRoot: string,
	directory:   string,
	command:     string,
	mcpServer:   string,
}

Mimir_Config_Wire :: struct {
	selectedProvider:  string,
	selectedModel:     string,
	embeddingProvider: string,
	embeddingModel:    string,
	safetyProvider:    string,
	safetyModel:       string,
	approvalMethod:    string,
	toolContinuations: int,
	systemPrompt:      string,
	systemPromptMode:  string,
	providers:         []Provider_Config_Wire,
	contextWindows:    []Context_Window_Config_Wire,
	mcpServers:        []MCP_Server_Config,
	skillPaths:        []string,
	permissionGrants:  []Permission_Grant_Wire,
}

Provider_Config :: struct {
	name:          string,
	type:          ai.Interface_Type,
	endpoint:      string,
	apiKey:        string,
	model:         string,
	enabled:       bool,
	nameOwned:     bool,
	endpointOwned: bool,
	apiKeyOwned:   bool,
	modelOwned:    bool,
}

Context_Window_Config :: struct {
	providerName: string,
	model:        string,
	tokens:       int,
}

Mimir_Config :: struct {
	selectedProvider:    string,
	selectedModel:       string,
	embeddingProvider:   string,
	embeddingModel:      string,
	safetyProvider:      string,
	safetyModel:         string,
	approvalMethod:      Approval_Method,
	toolContinuations:   int,
	systemPrompt:        string,
	systemPromptMode:    System_Prompt_Mode,
	providers:           [dynamic]Provider_Config,
	contextWindows:      [dynamic]Context_Window_Config,
	mcpServers:          [dynamic]MCP_Server_Config,
	skillPaths:          [dynamic]string,
	permissionGrants:    [dynamic]tool_policy.Permission_Grant,
	allocationAllocator: mem.Allocator,
}

approval_method_from_string :: proc(value: string) -> (Approval_Method, bool) {
	switch value {
	case "", "alwaysAsk":
		return .Always_Ask, true
	case "approveSafe":
		return .Approve_Safe, true
	case "approveAll":
		return .Approve_All, true
	case "denyAll":
		return .Deny_All, true
	}
	return .Always_Ask, false
}

approval_method_to_string :: proc(method: Approval_Method) -> string {
	switch method {
	case .Always_Ask:
		return "alwaysAsk"
	case .Approve_Safe:
		return "approveSafe"
	case .Approve_All:
		return "approveAll"
	case .Deny_All:
		return "denyAll"
	}
	return "alwaysAsk"
}

system_prompt_mode_from_string :: proc(value: string) -> (System_Prompt_Mode, bool) {
	switch value {
	case "", "append":
		return .Append, true
	case "replace":
		return .Replace, true
	}
	return .Append, false
}

system_prompt_mode_to_string :: proc(mode: System_Prompt_Mode) -> string {
	switch mode {
	case .Append:
		return "append"
	case .Replace:
		return "replace"
	}
	return "append"
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
	defer delete(dir, allocator)
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
	config.allocationAllocator = allocator
	config.selectedProvider = DEFAULT_CONFIG_PROVIDER
	config.approvalMethod = .Always_Ask
	config.toolContinuations = DEFAULT_TOOL_CONTINUATIONS
	config.systemPromptMode = .Append
	config.providers = make([dynamic]Provider_Config, 0, 1, allocator)
	config.contextWindows = make([dynamic]Context_Window_Config, 0, 0, allocator)
	config.mcpServers = make([dynamic]MCP_Server_Config, 0, 0, allocator)
	config.skillPaths = make([dynamic]string, 0, 2, allocator)
	config.permissionGrants = make([dynamic]tool_policy.Permission_Grant, 0, 0, allocator)
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

provider_config_destroy :: proc(provider: ^Provider_Config, allocator: mem.Allocator) {
	if provider.nameOwned && provider.name != "" {
		delete(provider.name, allocator)
	}
	if provider.endpointOwned && provider.endpoint != "" {
		delete(provider.endpoint, allocator)
	}
	if provider.apiKeyOwned && provider.apiKey != "" {
		delete(provider.apiKey, allocator)
	}
	if provider.modelOwned && provider.model != "" {
		delete(provider.model, allocator)
	}
}

config_context_window_tokens :: proc(config: ^Mimir_Config, providerName, model: string) -> int {
	if config == nil || providerName == "" || model == "" {
		return 0
	}
	for entry in config.contextWindows {
		if entry.providerName == providerName && entry.model == model {
			return entry.tokens
		}
	}
	return 0
}

config_set_context_window_tokens :: proc(
	config: ^Mimir_Config,
	providerName, model: string,
	tokens: int,
) -> bool {
	if config == nil || providerName == "" || model == "" || tokens < 0 {
		return false
	}
	for &entry in config.contextWindows {
		if entry.providerName == providerName && entry.model == model {
			entry.tokens = tokens
			return true
		}
	}
	append(
		&config.contextWindows,
		Context_Window_Config {
			providerName = strings.clone(providerName, config.allocationAllocator),
			model = strings.clone(model, config.allocationAllocator),
			tokens = tokens,
		},
	)
	return true
}

config_update_context_window_tokens :: proc(
	config: ^Mimir_Config,
	providerName, model: string,
	tokens: int,
) -> bool {
	if config == nil || providerName == "" || model == "" || tokens <= 0 {
		return false
	}
	for &entry in config.contextWindows {
		if entry.providerName == providerName && entry.model == model {
			if entry.tokens == tokens {
				return false
			}
			entry.tokens = tokens
			return true
		}
	}
	append(
		&config.contextWindows,
		Context_Window_Config {
			providerName = strings.clone(providerName, config.allocationAllocator),
			model = strings.clone(model, config.allocationAllocator),
			tokens = tokens,
		},
	)
	return true
}

config_destroy :: proc(config: ^Mimir_Config) {
	if config.selectedProvider != "" {
		delete(config.selectedProvider, config.allocationAllocator)
	}
	if config.selectedModel != "" {
		delete(config.selectedModel, config.allocationAllocator)
	}
	if config.embeddingProvider != "" {
		delete(config.embeddingProvider, config.allocationAllocator)
	}
	if config.embeddingModel != "" {
		delete(config.embeddingModel, config.allocationAllocator)
	}
	if config.safetyProvider != "" {
		delete(config.safetyProvider, config.allocationAllocator)
	}
	if config.safetyModel != "" {
		delete(config.safetyModel, config.allocationAllocator)
	}
	if config.systemPrompt != "" {
		delete(config.systemPrompt, config.allocationAllocator)
	}
	for &provider in config.providers {
		provider_config_destroy(&provider, config.allocationAllocator)
	}
	for &entry in config.contextWindows {
		if entry.providerName != "" {
			delete(entry.providerName, config.allocationAllocator)
		}
		if entry.model != "" {
			delete(entry.model, config.allocationAllocator)
		}
	}
	for path in config.skillPaths {
		delete(path, config.allocationAllocator)
	}
	for &grant in config.permissionGrants {
		tool_policy.permission_grant_destroy(&grant, config.allocationAllocator)
	}
	delete(config.providers)
	delete(config.contextWindows)
	delete(config.mcpServers)
	delete(config.skillPaths)
	delete(config.permissionGrants)
}

provider_type_to_string :: proc(providerType: ai.Interface_Type) -> string {
	switch providerType {
	case .Ollama:
		return "ollama"
	case .None:
		return "none"
	}
	return "none"
}

provider_type_from_string :: proc(text: string) -> (ai.Interface_Type, bool) {
	switch text {
	case "ollama":
		return .Ollama, true
	case "none":
		return .None, true
	}
	return .None, false
}

permission_grant_kind_from_string :: proc(
	text: string,
) -> (
	tool_policy.Permission_Grant_Kind,
	bool,
) {
	switch text {
	case "directorySubtree":
		return .Directory_Subtree, true
	case "commandPrefix":
		return .Command_Prefix, true
	case "mcpServer":
		return .MCP_Server, true
	}
	return .Directory_Subtree, false
}

permission_grant_kind_to_string :: proc(kind: tool_policy.Permission_Grant_Kind) -> string {
	switch kind {
	case .Directory_Subtree:
		return "directorySubtree"
	case .Command_Prefix:
		return "commandPrefix"
	case .MCP_Server:
		return "mcpServer"
	}
	return ""
}

permission_grant_from_wire :: proc(
	wire: Permission_Grant_Wire,
	allocator := context.allocator,
) -> (
	tool_policy.Permission_Grant,
	bool,
) {
	kind, kindOK := permission_grant_kind_from_string(wire.kind)
	projectRoot, rootOK := tool_policy.permission_normalize_absolute_path(
		wire.projectRoot,
		allocator,
	)
	if !kindOK || !rootOK {
		return tool_policy.Permission_Grant{}, false
	}

	grant := tool_policy.Permission_Grant {
		kind        = kind,
		projectRoot = projectRoot,
	}
	switch kind {
	case .Directory_Subtree:
		directory, directoryOK := tool_policy.permission_normalize_absolute_path(
			wire.directory,
			allocator,
		)
		if !directoryOK || !tool_policy.permission_path_is_within_project(projectRoot, directory) {
			tool_policy.permission_grant_destroy(&grant, allocator)
			if directory != "" {
				delete(directory, allocator)
			}
			return tool_policy.Permission_Grant{}, false
		}
		grant.directory = directory
	case .Command_Prefix:
		if wire.command == "" {
			tool_policy.permission_grant_destroy(&grant, allocator)
			return tool_policy.Permission_Grant{}, false
		}
		grant.command = strings.clone(wire.command, allocator)
	case .MCP_Server:
		if wire.mcpServer == "" {
			tool_policy.permission_grant_destroy(&grant, allocator)
			return tool_policy.Permission_Grant{}, false
		}
		grant.mcpServer = strings.clone(wire.mcpServer, allocator)
	}
	return grant, true
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
	config.allocationAllocator = allocator
	config.selectedProvider = strings.clone(wire.selectedProvider, allocator)
	config.selectedModel = strings.clone(wire.selectedModel, allocator)
	config.embeddingProvider = strings.clone(wire.embeddingProvider, allocator)
	config.embeddingModel = strings.clone(wire.embeddingModel, allocator)
	config.safetyProvider = strings.clone(wire.safetyProvider, allocator)
	config.safetyModel = strings.clone(wire.safetyModel, allocator)
	approvalMethod, approvalMethodOK := approval_method_from_string(wire.approvalMethod)
	if !approvalMethodOK {
		config_destroy(&config)
		return Mimir_Config{}, .Invalid_JSON
	}
	config.approvalMethod = approvalMethod
	systemPromptMode, systemPromptModeOK := system_prompt_mode_from_string(wire.systemPromptMode)
	if !systemPromptModeOK {
		config_destroy(&config)
		return Mimir_Config{}, .Invalid_JSON
	}
	config.systemPrompt = strings.clone(wire.systemPrompt, allocator)
	config.systemPromptMode = systemPromptMode
	if wire.toolContinuations < 0 {
		config_destroy(&config)
		return Mimir_Config{}, .Invalid_JSON
	}
	config.toolContinuations = wire.toolContinuations
	if config.toolContinuations == 0 {
		config.toolContinuations = DEFAULT_TOOL_CONTINUATIONS
	}
	config.providers = make([dynamic]Provider_Config, 0, len(wire.providers), allocator)
	config.contextWindows = make(
		[dynamic]Context_Window_Config,
		0,
		len(wire.contextWindows),
		allocator,
	)
	config.mcpServers = make([dynamic]MCP_Server_Config, 0, len(wire.mcpServers), allocator)
	config.skillPaths = make([dynamic]string, 0, len(wire.skillPaths), allocator)
	config.permissionGrants = make(
		[dynamic]tool_policy.Permission_Grant,
		0,
		len(wire.permissionGrants),
		allocator,
	)

	for provider in wire.providers {
		providerType, ok := provider_type_from_string(provider.type)
		if !ok || provider.name == "" {
			config_destroy(&config)
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
				nameOwned = true,
				endpointOwned = true,
				apiKeyOwned = true,
				modelOwned = true,
			},
		)
	}
	for entry in wire.contextWindows {
		if entry.providerName == "" || entry.model == "" || entry.tokens < 0 {
			config_destroy(&config)
			return Mimir_Config{}, .Invalid_JSON
		}
		append(
			&config.contextWindows,
			Context_Window_Config {
				providerName = strings.clone(entry.providerName, allocator),
				model = strings.clone(entry.model, allocator),
				tokens = entry.tokens,
			},
		)
	}
	for server in wire.mcpServers {
		append(&config.mcpServers, server)
	}
	for path in wire.skillPaths {
		append(&config.skillPaths, strings.clone(path, allocator))
	}
	for wireGrant in wire.permissionGrants {
		grant, grantOK := permission_grant_from_wire(wireGrant, allocator)
		if !grantOK {
			config_destroy(&config)
			return Mimir_Config{}, .Invalid_JSON
		}
		append(&config.permissionGrants, grant)
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
	defer delete(path, context.temp_allocator)
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
	defer delete(dir, context.temp_allocator)
	defer delete(path, context.temp_allocator)
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
	defer delete(payload, context.temp_allocator)
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
	strings.write_string(&builder, "  \"embeddingProvider\": ")
	write_json_string(&builder, config.embeddingProvider)
	strings.write_string(&builder, ",\n")
	strings.write_string(&builder, "  \"embeddingModel\": ")
	write_json_string(&builder, config.embeddingModel)
	strings.write_string(&builder, ",\n")
	strings.write_string(&builder, "  \"safetyProvider\": ")
	write_json_string(&builder, config.safetyProvider)
	strings.write_string(&builder, ",\n")
	strings.write_string(&builder, "  \"safetyModel\": ")
	write_json_string(&builder, config.safetyModel)
	strings.write_string(&builder, ",\n")
	strings.write_string(&builder, "  \"approvalMethod\": ")
	write_json_string(&builder, approval_method_to_string(config.approvalMethod))
	strings.write_string(&builder, ",\n")
	strings.write_string(&builder, "  \"toolContinuations\": ")
	write_decimal(&builder, config.toolContinuations)
	strings.write_string(&builder, ",\n")
	strings.write_string(&builder, "  \"systemPrompt\": ")
	write_json_string(&builder, config.systemPrompt)
	strings.write_string(&builder, ",\n")
	strings.write_string(&builder, "  \"systemPromptMode\": ")
	write_json_string(&builder, system_prompt_mode_to_string(config.systemPromptMode))
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
	strings.write_string(&builder, "  \"contextWindows\": [")
	for entry, index in config.contextWindows {
		if index > 0 {
			strings.write_string(&builder, ",")
		}
		strings.write_string(&builder, "\n    {\n      \"providerName\": ")
		write_json_string(&builder, entry.providerName)
		strings.write_string(&builder, ",\n      \"model\": ")
		write_json_string(&builder, entry.model)
		strings.write_string(&builder, ",\n      \"tokens\": ")
		write_decimal(&builder, entry.tokens)
		strings.write_string(&builder, "\n    }")
	}
	if len(config.contextWindows) > 0 {
		strings.write_string(&builder, "\n  ")
	}
	strings.write_string(&builder, "],\n")
	strings.write_string(&builder, "  \"mcpServers\": [],\n")
	strings.write_string(&builder, "  \"skillPaths\": [],\n")
	strings.write_string(&builder, "  \"permissionGrants\": [")
	for grant, index in config.permissionGrants {
		if index > 0 {
			strings.write_string(&builder, ",")
		}
		strings.write_string(&builder, "\n    {\n")
		strings.write_string(&builder, "      \"kind\": ")
		write_json_string(&builder, permission_grant_kind_to_string(grant.kind))
		strings.write_string(&builder, ",\n      \"projectRoot\": ")
		write_json_string(&builder, grant.projectRoot)
		switch grant.kind {
		case .Directory_Subtree:
			strings.write_string(&builder, ",\n      \"directory\": ")
			write_json_string(&builder, grant.directory)
		case .Command_Prefix:
			strings.write_string(&builder, ",\n      \"command\": ")
			write_json_string(&builder, grant.command)
		case .MCP_Server:
			strings.write_string(&builder, ",\n      \"mcpServer\": ")
			write_json_string(&builder, grant.mcpServer)
		}
		strings.write_string(&builder, "\n    }")
	}
	if len(config.permissionGrants) > 0 {
		strings.write_string(&builder, "\n  ")
	}
	strings.write_string(&builder, "]\n")
	strings.write_string(&builder, "}\n")
	return strings.to_string(builder)
}

write_decimal :: proc(builder: ^strings.Builder, value: int) {
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
