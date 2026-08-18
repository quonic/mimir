package ai

// This package provides the interface for interacting with AI services.
// Native Ollama interfaces.

import http "../http"
import "core:mem"
import "core:strings"

Interface :: struct {
	name:     string,
	type:     Interface_Type,
	endpoint: http.URL,
	models:   [dynamic]Model,
}

Model :: struct {
	name:         string,
	capabilities: [dynamic]string,
}

Interface_Type :: enum {
	None,
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

interfaces: [dynamic]Interface
interfacesAllocator: mem.Allocator

clear_interfaces :: proc() {
	if interfaces == nil || len(interfaces) == 0 {
		return
	}
	for iface in interfaces {
		for &model in iface.models {
			model_destroy(&model, interfacesAllocator)
		}
		delete(iface.models)
	}
	delete_dynamic_array(interfaces)
	interfaces = nil
}

add_interface :: proc(name: string, type: Interface_Type, endpoint: string) {
	url := http.url_parse(endpoint)
	if url.host != "" {
		if interfaces == nil {
			interfaces = make([dynamic]Interface, 0, 0, context.allocator)
			interfacesAllocator = context.allocator
		}
		append_elem(&interfaces, Interface{name = name, type = type, endpoint = url})
	}
}

add_interface_with_models :: proc(
	name: string,
	type: Interface_Type,
	endpoint: string,
	models: []Model,
) {
	url := http.url_parse(endpoint)
	if url.host == "" {
		return
	}
	if interfaces == nil {
		interfaces = make([dynamic]Interface, 0, 0, context.allocator)
		interfacesAllocator = context.allocator
	}

	entry := Interface {
		name     = name,
		type     = type,
		endpoint = url,
	}
	for model in models {
		append_elem(&entry.models, model_clone(model))
	}

	append_elem(&interfaces, entry)
}

get_interface :: proc(name: string) -> (Interface, bool) {
	for iface in interfaces {
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

new_client_with_endpoint :: proc(
	interfaceType: Interface_Type,
	endpoint, apiKey: string,
) -> (
	Client,
	AI_Error,
) {
	url := http.url_parse(endpoint)
	if url.host == "" || (url.scheme != "http" && url.scheme != "https") {
		return Client{}, .Invalid_Request
	}
	return Client{iface = Interface{type = interfaceType, endpoint = url}, apiKey = apiKey}, .None
}

probe_ollama_endpoint :: proc(
	endpoint: string,
	allocator := context.allocator,
) -> (
	[dynamic]Model,
	AI_Error,
) {
	return probe_ollama_endpoint_with_api_key(endpoint, "", allocator)
}

probe_ollama_endpoint_with_api_key :: proc(
	endpoint: string,
	apiKey: string,
	allocator := context.allocator,
) -> (
	[dynamic]Model,
	AI_Error,
) {
	url := http.url_parse(endpoint)
	if url.host == "" || (url.scheme != "http" && url.scheme != "https") {
		return [dynamic]Model{}, .Invalid_Request
	}

	return list_ollama_models(
		Client {
			iface = Interface{name = "ollama", type = .Ollama, endpoint = url},
			apiKey = apiKey,
		},
		allocator,
	)
}

model_clone :: proc(model: Model, allocator := context.allocator) -> Model {
	clone := Model {
		name = strings.clone(model.name, allocator),
	}
	for capability in model.capabilities {
		append_elem(&clone.capabilities, strings.clone(capability, allocator))
	}
	return clone
}

model_destroy :: proc(model: ^Model, allocator := context.allocator) {
	if model.name != "" {
		delete_string(model.name, allocator)
	}
	for capability in model.capabilities {
		delete(capability, allocator)
	}
	delete_dynamic_array(model.capabilities)
}

models_destroy :: proc(models: ^[dynamic]Model, allocator := context.allocator) {
	for &model in models^ {
		model_destroy(&model, allocator)
	}
	delete_dynamic_array(models^)
}

model_has_capability :: proc(model: Model, capability: string) -> bool {
	for candidate in model.capabilities {
		if candidate == capability {
			return true
		}
	}
	return false
}

model_supports_chat :: proc(model: Model) -> bool {
	return model_has_capability(model, "completion") && model_has_capability(model, "tools")
}

model_supports_embeddings :: proc(model: Model) -> bool {
	return model_has_capability(model, "embedding")
}

model_supported :: proc(iface: Interface, model: string) -> bool {
	if len(iface.models) == 0 {
		return true
	}

	for candidate in iface.models {
		if candidate.name == model {
			return true
		}
	}

	return false
}
