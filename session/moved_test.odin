package session

import "../ai"
import "../builtin_tools"
import "../settings"
import "../tool_policy"
import "core:strings"
import "core:testing"

// Tests of the code that moved from package main: tool call decoding, tool definitions, the
// safety model, the embedding client, the transcript and the system prompt.

// Returns the default config, with an Ollama provider. Free it with
// test_default_config_destroy.
test_default_config :: proc() -> settings.Mimir_Config {
	return settings.default_ollama_config(context.allocator)
}

test_default_config_destroy :: proc(config: ^settings.Mimir_Config) {
	delete(config.providers)
	delete(config.disabledSkills)
	delete(config.permissionGrants)
	delete(config.contextWindows)
}

@(test)
test_patch_file_tool_call_decodes_owned_patch_content :: proc(t: ^testing.T) {
	call, callOK := tool_call_from_ai(
		ai.Tool_Call {
			id = "call-patch",
			name = "patch_file",
			arguments = `{"file_path":"src/main.odin","patch_content":"--- a/src/main.odin\n+++ b/src/main.odin\n@@ -1 +1 @@\n-old\n+new\n"}`,
		},
		context.allocator,
	)
	defer tool_policy.tool_call_destroy(&call, context.allocator)
	assert(callOK, "expected patch_file tool call to decode")
	assert(call.filePath == "src/main.odin", "expected patch target path")
	assert(strings.contains(call.patchContent, "@@ -1 +1 @@"), "expected owned patch content")
	_ = t
}


@(test)
test_patch_file_tool_call_requires_patch_arguments :: proc(t: ^testing.T) {
	call, callOK := tool_call_from_ai(
		ai.Tool_Call {
			id = "call-patch",
			name = "patch_file",
			arguments = `{"file_path":"src/main.odin"}`,
		},
		context.allocator,
	)
	assert(!callOK, "expected missing patch_content to be rejected")
	assert(call.id == "", "expected rejected call to be empty")
	_ = t
}


@(test)
test_grep_search_tool_call_decodes_pattern_and_normalizes_limit :: proc(t: ^testing.T) {
	defaultCall, defaultOK := tool_call_from_ai(
		ai.Tool_Call {
			id = "call-grep-default",
			name = "grep_search",
			arguments = `{"file_path":"src/main.odin","search_string":"^main ::"}`,
		},
		context.allocator,
	)
	defer tool_policy.tool_call_destroy(&defaultCall, context.allocator)
	assert(defaultOK, "expected grep_search tool call to decode")
	assert(defaultCall.filePath == "src/main.odin", "expected grep target path")
	assert(defaultCall.query == "^main ::", "expected search_string to map to query")
	assert(
		defaultCall.maxResults == builtin_tools.GREP_SEARCH_DEFAULT_MAX_RESULTS,
		"expected omitted max_results to use the grep default",
	)

	cappedCall, cappedOK := tool_call_from_ai(
		ai.Tool_Call {
			id = "call-grep-capped",
			name = "grep_search",
			arguments = `{"file_path":"src/main.odin","search_string":"main","max_results":500}`,
		},
		context.allocator,
	)
	defer tool_policy.tool_call_destroy(&cappedCall, context.allocator)
	assert(cappedOK, "expected grep_search with a large limit to decode")
	assert(
		cappedCall.maxResults == builtin_tools.GREP_SEARCH_MAX_RESULTS,
		"expected grep max_results to be capped",
	)
	_ = t
}


@(test)
test_grep_search_tool_call_rejects_missing_pattern_and_negative_limit :: proc(t: ^testing.T) {
	missingCall, missingOK := tool_call_from_ai(
		ai.Tool_Call {
			id = "call-grep-missing",
			name = "grep_search",
			arguments = `{"file_path":"src/main.odin"}`,
		},
		context.allocator,
	)
	assert(!missingOK, "expected a missing grep pattern to be rejected")
	assert(missingCall.id == "", "expected rejected grep call to be empty")

	negativeCall, negativeOK := tool_call_from_ai(
		ai.Tool_Call {
			id = "call-grep-negative",
			name = "grep_search",
			arguments = `{"file_path":"src/main.odin","search_string":"main","max_results":-1}`,
		},
		context.allocator,
	)
	assert(!negativeOK, "expected a negative grep limit to be rejected")
	assert(negativeCall.id == "", "expected rejected grep call to be empty")
	_ = t
}


@(test)
test_approval_safety_model_prefers_explicit_selection :: proc(t: ^testing.T) {
	config := test_default_config()
	defer test_default_config_destroy(&config)
	config.safetyProvider = "ollama"
	config.safetyModel = "safety-model"

	safetyModel, safetyModelOK := approval_safety_model_from_config(
		config,
		settings.DEFAULT_CONFIG_PROVIDER,
		"chat-model",
	)
	assert(safetyModelOK, "expected explicit safety model to resolve")
	assert(safetyModel.provider.name == "ollama", "expected configured safety provider")
	assert(safetyModel.model == "safety-model", "expected configured safety model")
	_ = t
}


@(test)
test_approval_safety_model_falls_back_to_chat_selection :: proc(t: ^testing.T) {
	config := test_default_config()
	defer test_default_config_destroy(&config)

	safetyModel, safetyModelOK := approval_safety_model_from_config(
		config,
		settings.DEFAULT_CONFIG_PROVIDER,
		"chat-model",
	)
	assert(safetyModelOK, "expected empty safety selection to use chat model")
	assert(
		safetyModel.provider.name == settings.DEFAULT_CONFIG_PROVIDER,
		"expected chat provider fallback",
	)
	assert(safetyModel.model == "chat-model", "expected chat model fallback")
	_ = t
}


@(test)
test_approval_safety_model_rejects_partial_selection :: proc(t: ^testing.T) {
	config := test_default_config()
	defer test_default_config_destroy(&config)
	config.safetyProvider = "ollama"

	_, safetyModelOK := approval_safety_model_from_config(
		config,
		settings.DEFAULT_CONFIG_PROVIDER,
		"",
	)
	assert(!safetyModelOK, "expected partial safety selection to be unavailable")
	_ = t
}


@(test)
test_tool_definitions_include_ollama :: proc(t: ^testing.T) {
	ollamaTools := tool_definitions_for_provider(.Ollama, context.allocator)
	defer delete(ollamaTools)
	assert(len(ollamaTools) == 13, "expected Ollama to receive all built-in tools")

	_ = t
}


@(test)
test_embedding_client_requires_embedding_configuration :: proc(t: ^testing.T) {
	config := test_default_config()
	defer test_default_config_destroy(&config)
	_, clientError := session_embedding_client(&config)
	assert(
		clientError == .Invalid_Request,
		"expected missing embedding selection to reject client",
	)
	_ = t
}


@(test)
test_embedding_client_rejects_disabled_embedding_provider :: proc(t: ^testing.T) {
	state: struct {
		config: settings.Mimir_Config,
	}
	state.config.embeddingProvider = "embeddings"
	state.config.embeddingModel = "nomic-embed-text"
	state.config.providers = make([dynamic]settings.Provider_Config, 0, 1, context.temp_allocator)
	defer delete(state.config.providers)
	append(
		&state.config.providers,
		settings.Provider_Config {
			name = "embeddings",
			type = .Ollama,
			endpoint = "http://localhost:11434",
			enabled = false,
		},
	)

	_, clientError := session_embedding_client(&state.config)
	assert(clientError == .Interface_Not_Found, "expected disabled embedding provider rejection")
	_ = t
}


@(test)
test_transcript_build_messages_keeps_user_and_assistant_text :: proc(t: ^testing.T) {
	transcript := transcript_init(context.temp_allocator)
	defer transcript_destroy(&transcript)
	transcript_append_user(&transcript, "hello")
	transcript_append_assistant_text(&transcript, "h")
	transcript_append_assistant_text(&transcript, "i")
	transcript_end_assistant_text(&transcript)
	transcript_append_assistant_text(&transcript, "")
	transcript_append_assistant(&transcript, "")

	messages := transcript_build_messages(&transcript, "configured prompt", context.temp_allocator)
	assert(len(messages) == 3, "expected configured prompt, user, and assistant messages")
	assert(messages[0].role == ai.Message_Role.System, "expected system role first")
	assert(messages[0].content == "configured prompt", "expected configured prompt first")
	assert(messages[1].role == ai.Message_Role.User, "expected user role to map")
	assert(messages[2].role == ai.Message_Role.Assistant, "expected assistant role to map")
	assert(messages[2].content == "hi", "expected streamed assistant text in one message")
	_ = t
}


@(test)
test_transcript_build_messages_empty_system_prompt_preserves_order :: proc(t: ^testing.T) {
	transcript := transcript_init(context.temp_allocator)
	defer transcript_destroy(&transcript)
	transcript_append_user(&transcript, "hello")
	transcript_append_assistant_text(&transcript, "hi")
	transcript_end_assistant_text(&transcript)
	transcript_append_assistant_text(&transcript, "again")
	transcript_append_user(&transcript, "next")

	messages := transcript_build_messages(&transcript, "", context.temp_allocator)
	assert(len(messages) == 4, "expected only transcript messages without a system prompt")
	assert(messages[0].role == ai.Message_Role.User, "expected user message first")
	assert(messages[0].content == "hello", "expected user content to be preserved")
	assert(messages[1].content == "hi", "expected first assistant message")
	assert(messages[2].content == "again", "expected a new assistant message after the end")
	assert(messages[3].role == ai.Message_Role.User, "expected user message last")
	assert(messages[3].content == "next", "expected the last user content")
	_ = t
}


@(test)
test_system_prompt_effective_respects_customization_mode :: proc(t: ^testing.T) {
	modelName := "test-model"
	skills := []settings.Skill {
		{name = "demo", description = "Demo skill", path = "/skills/demo/SKILL.md"},
	}
	defaultPrompt := system_prompt_effective(
		modelName,
		skills,
		"",
		.Append,
		context.temp_allocator,
	)
	defer delete(defaultPrompt, context.temp_allocator)
	assert(
		strings.contains(defaultPrompt, modelName),
		"expected default system prompt to contain selected model",
	)
	assert(
		strings.contains(defaultPrompt, `<skill name="demo" filePath="/skills/demo/SKILL.md">`),
		"expected default system prompt to list the given skills",
	)
	assert(
		!strings.contains(defaultPrompt, "{model_name}"),
		"expected model name placeholder to be expanded",
	)
	assert(
		!strings.contains(defaultPrompt, "{{output_formatting}}") &&
		!strings.contains(defaultPrompt, "{{skills}}") &&
		!strings.contains(defaultPrompt, "{{attachments}}"),
		"expected prompt placeholders to be expanded",
	)

	appendedPrompt := system_prompt_effective(
		modelName,
		skills,
		"Use tabs.",
		.Append,
		context.temp_allocator,
	)
	defer delete(appendedPrompt, context.temp_allocator)
	assert(
		strings.contains(appendedPrompt, "Additional user instructions:\nUse tabs."),
		"expected append mode to retain custom instructions",
	)

	replacedPrompt := system_prompt_effective(
		modelName,
		skills,
		"Only user instructions.",
		.Replace,
		context.temp_allocator,
	)
	defer delete(replacedPrompt, context.temp_allocator)
	assert(
		replacedPrompt ==
		strings.concatenate(
			{"Only user instructions.", system_prompt_date(context.temp_allocator)},
			context.temp_allocator,
		),
		"expected replace mode to use custom prompt",
	)
	_ = t
}

