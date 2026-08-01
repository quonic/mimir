package main

import approval_safety "./approval_safety"
import settings "./settings"
import "ai"
import "core:strings"
import text_input "text_input"

APPROVAL_SAFETY_MAX_DISPLAY_GRAPHEMES :: 200

Approval_Safety_Model :: struct {
	provider: settings.Provider_Config,
	model:    string,
}

app_start_approval_safety :: proc(state: ^App_State) {
	approval := &state.approval.safety
	approval_safety.init(approval, state.dispatcher.allocator)

	safetyModel, safetyModelOK := approval_safety_model_from_config(state.config)
	if !safetyModelOK {
		approval_safety.mark_unavailable(approval)
		return
	}
	client, clientErr := ai.new_client(safetyModel.provider.name, safetyModel.provider.apiKey)
	if clientErr != .None {
		approval_safety.mark_unavailable(approval)
		return
	}

	_ = approval_safety.start(
		approval,
		approval_safety.Start_Input {
			client = client,
			model = safetyModel.model,
			action = state.approval.prepared.action,
		},
	)
}

approval_safety_model_from_config :: proc(
	config: settings.Mimir_Config,
) -> (
	Approval_Safety_Model,
	bool,
) {
	providerName := config.selectedProvider
	model := config.selectedModel
	explicitSafetyModel := config.safetyProvider != "" || config.safetyModel != ""
	if explicitSafetyModel {
		if config.safetyProvider == "" || config.safetyModel == "" {
			return Approval_Safety_Model{}, false
		}
		providerName = config.safetyProvider
		model = config.safetyModel
	}
	if providerName == "" {
		return Approval_Safety_Model{}, false
	}
	provider, providerOK := app_find_provider(config, providerName)
	if !providerOK || !provider.enabled {
		return Approval_Safety_Model{}, false
	}
	if model == "" && !explicitSafetyModel {
		model = provider.model
	}
	if model == "" {
		return Approval_Safety_Model{}, false
	}
	return Approval_Safety_Model{provider = provider, model = model}, true
}

app_poll_approval_safety :: proc(state: ^App_State) -> bool {
	return approval_safety.poll(&state.approval.safety)
}

app_destroy_approval_safety :: proc(safety: ^approval_safety.State) {
	approval_safety.destroy(safety)
}

app_approval_safety_ready :: proc(state: ^App_State) -> bool {
	return !approval_safety.is_active(&state.approval.safety)
}

app_approval_safety_unavailable :: proc(state: ^App_State) -> bool {
	return approval_safety.is_unavailable(&state.approval.safety)
}

app_approval_safety_verdict :: proc(state: ^App_State) -> approval_safety.Verdict {
	return approval_safety.verdict(&state.approval.safety)
}

approval_safety_display_text :: proc(
	response: string,
	allocator := context.temp_allocator,
) -> string {
	text := response
	lineEnd := strings.index_byte(text, '\n')
	if lineEnd >= 0 {
		text = text[:lineEnd]
	}
	text = strings.trim_space(text)
	if text_input.unicode_grapheme_count(text) <= APPROVAL_SAFETY_MAX_DISPLAY_GRAPHEMES {
		return strings.clone(text, allocator)
	}
	end := text_input.unicode_grapheme_to_byte_offset(
		text,
		APPROVAL_SAFETY_MAX_DISPLAY_GRAPHEMES - len("..."),
	)
	return strings.concatenate({text[:end], "..."}, allocator)
}

app_approval_safety_response :: proc(
	state: ^App_State,
	allocator := context.temp_allocator,
) -> string {
	response := approval_safety.response(&state.approval.safety, allocator)
	defer delete(response, allocator)
	return approval_safety_display_text(response, allocator)
}
