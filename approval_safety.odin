package main

import "ai"
import "approval_safety"
import "core:mem"
import "core:strings"
import "settings"
import "text_input"

APPROVAL_SAFETY_MAX_DISPLAY_GRAPHEMES :: 200

Approval_Safety_Model :: struct {
	provider: settings.Provider_Config,
	model:    string,
}

// pending_approval_start_safety starts the safety classifier for the action of
// approval, with the safety model from config. When no safety model is
// available, it marks the safety state unavailable.
pending_approval_start_safety :: proc(
	approval: ^Pending_Approval,
	config: settings.Mimir_Config,
	allocator: mem.Allocator,
) {
	safety := &approval.safety
	approval_safety.init(safety, allocator)

	safetyModel, safetyModelOK := approval_safety_model_from_config(config)
	if !safetyModelOK {
		approval_safety.mark_unavailable(safety, allocator)
		return
	}
	client, clientErr := ai.new_client(safetyModel.provider.name, safetyModel.provider.apiKey)
	if clientErr != .None {
		approval_safety.mark_unavailable(safety, allocator)
		return
	}

	_ = approval_safety.start(
		safety,
		approval_safety.Start_Input {
			client = client,
			model = safetyModel.model,
			action = approval.prepared.action,
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

// pending_approval_poll_safety returns true when the safety classifier of
// approval finished since the last poll.
pending_approval_poll_safety :: proc(approval: ^Pending_Approval) -> bool {
	return approval_safety.poll(&approval.safety)
}

app_destroy_approval_safety :: proc(safety: ^approval_safety.State) {
	approval_safety.destroy(safety)
}

// pending_approval_safety_ready returns true when the safety classifier of
// approval does not run.
pending_approval_safety_ready :: proc(approval: ^Pending_Approval) -> bool {
	return !approval_safety.is_active(&approval.safety)
}

pending_approval_safety_unavailable :: proc(approval: ^Pending_Approval) -> bool {
	return approval_safety.is_unavailable(&approval.safety)
}

pending_approval_safety_verdict :: proc(approval: ^Pending_Approval) -> approval_safety.Verdict {
	return approval_safety.verdict(&approval.safety)
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

pending_approval_safety_response :: proc(
	approval: ^Pending_Approval,
	allocator := context.temp_allocator,
) -> string {
	response := approval_safety.response(&approval.safety, allocator)
	defer delete(response, allocator)
	return approval_safety_display_text(response, allocator)
}
