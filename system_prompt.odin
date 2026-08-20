package main

import "core:strings"
import "settings"

DEFAULT_SYSTEM_PROMPT :: `You are Mimir, a repository-aware coding agent.

Work directly on the user's requested task. Inspect the relevant code before making changes. Use available tools deliberately, preserve user changes, and request approval when required. Keep changes focused, validate them with the most relevant available checks, and report the result concisely.`

// Subagents have no access to the parent's conversation, only the task given as the first user message.
SUBAGENT_SYSTEM_PROMPT :: `You are a subagent spawned by another agent to complete one self-contained task. You have no access to the parent's conversation history. Use only the tools you were granted. When finished, reply with a single final message containing your complete answer.`

system_prompt_effective :: proc(
	customPrompt: string,
	mode: settings.System_Prompt_Mode,
	allocator := context.allocator,
) -> string {
	switch mode {
	case .Replace:
		return strings.clone(customPrompt, allocator)
	case .Append:
		if customPrompt == "" {
			return strings.clone(DEFAULT_SYSTEM_PROMPT, allocator)
		}
		return strings.concatenate(
			{DEFAULT_SYSTEM_PROMPT, "\n\nAdditional user instructions:\n", customPrompt},
			allocator,
		)
	}
	return strings.clone(DEFAULT_SYSTEM_PROMPT, allocator)
}
