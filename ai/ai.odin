package ai

// This package provides the interface for interacting with AI services.
// Anthropic, OpenAI-compatible, and native Ollama interfaces.

import http "../http"

Interface :: struct {
	name:     string,
	type:     Interface_Type,
	endpoint: http.URL,
	models:   [dynamic]string,
}

Interface_Type :: enum {
	None,
	Anthropic,
	OpenAI,
	Ollama,
}

AI_Error :: enum {
	None,
	Interface_Not_Found,
	Unsupported_Interface,
	Unsupported_Model,
	Invalid_Request,
	Invalid_Response,
	Authentication_Error,
	Rate_Limited,
	Server_Error,
	Network_Error,
	Provider_Error,
}

Client :: struct {
	iface:  Interface,
	apiKey: string,
}

Interfaces: [dynamic]Interface

clear_interfaces :: proc() {
	for iface in Interfaces {
		delete(iface.models)
	}
	delete(Interfaces)
	Interfaces = nil
}

add_interface :: proc(name: string, type: Interface_Type, endpoint: string) {
	url := http.url_parse(endpoint)
	if url.host != "" {
		append(&Interfaces, Interface{name = name, type = type, endpoint = url})
	}
}

add_interface_with_models :: proc(
	name: string,
	type: Interface_Type,
	endpoint: string,
	models: []string,
) {
	url := http.url_parse(endpoint)
	if url.host == "" {
		return
	}

	entry := Interface {
		name     = name,
		type     = type,
		endpoint = url,
	}
	for model in models {
		append(&entry.models, model)
	}

	append(&Interfaces, entry)
}

get_interface :: proc(name: string) -> (Interface, bool) {
	for iface in Interfaces {
		if iface.name == name {
			return iface, true
		}
	}

	return Interface{}, false
}

new_client :: proc(interfaceName: string, apiKey: string) -> (Client, AI_Error) {
	iface, ok := get_interface(interfaceName)
	if !ok {
		return Client{}, .Interface_Not_Found
	}

	return Client{iface = iface, apiKey = apiKey}, .None
}

probe_ollama_endpoint :: proc(
	endpoint: string,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	AI_Error,
) {
	url := http.url_parse(endpoint)
	if url.host == "" || (url.scheme != "http" && url.scheme != "https") {
		return [dynamic]string{}, .Invalid_Request
	}

	return list_models(
		Client{iface = Interface{name = "ollama", type = .Ollama, endpoint = url}},
		allocator,
	)
}

model_supported :: proc(iface: Interface, model: string) -> bool {
	if len(iface.models) == 0 {
		return true
	}

	for candidate in iface.models {
		if candidate == model {
			return true
		}
	}

	return false
}
