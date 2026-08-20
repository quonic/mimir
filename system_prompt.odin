package main

import "core:fmt"
import "core:strings"
import "core:time"
import "settings"

DEFAULT_SYSTEM_PROMPT :: `You are Mimir, a repository-aware coding agent.

Work directly on the user's requested task. Inspect the relevant code before making changes. Use available tools deliberately, preserve user changes, and request approval when required. Keep changes focused, validate them with the most relevant available checks, and report the result concisely.`

// Subagents have no access to the parent's conversation, only the task given as the first user message.
SUBAGENT_SYSTEM_PROMPT :: `You are a subagent spawned by another agent to complete one self-contained task. You have no access to the parent's conversation history or ability to ask clarifying questions — make reasonable assumptions and proceed. If the task requires a tool you were not given, say so explicitly instead of guessing. When finished, reply with a single final message containing your complete answer, concise enough for the parent agent to use directly.`

system_prompt_effective :: proc(
	customPrompt: string,
	mode: settings.System_Prompt_Mode,
	allocator := context.allocator,
) -> string {
	switch mode {
	case .Replace:
		return strings.concatenate({customPrompt, system_prompt_date(allocator)}, allocator)
	case .Append:
		if customPrompt == "" {
			return strings.concatenate(
				{DEFAULT_SYSTEM_PROMPT, system_prompt_date(allocator)},
				allocator,
			)
		}
		return strings.concatenate(
			{
				DEFAULT_SYSTEM_PROMPT,
				"\n\nAdditional user instructions:\n",
				customPrompt,
				system_prompt_date(allocator),
			},
			allocator,
		)
	}
	return strings.concatenate({DEFAULT_SYSTEM_PROMPT, system_prompt_date(allocator)}, allocator)
}

system_prompt_date :: proc(allocator := context.allocator) -> string {
	year, month, day := time.date(time.now())
	date_line := fmt.aprintf(
		"\n\nCurrent date: %4d-%02d-%02d",
		year,
		int(month),
		day,
		allocator = allocator,
	)
	defer delete(date_line, allocator)
	return date_line
}
