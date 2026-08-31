package commands

import "core:testing"

@(test)
test_command_completion_candidates_empty_prefix_returns_all_names :: proc(t: ^testing.T) {
	candidates := command_completion_candidates("", context.temp_allocator)
	assert(len(candidates) == 7, "expected all 7 command names for an empty prefix")
	expected := []string{"cancel", "clear", "config", "exit", "help", "quit", "stop"}
	for name, i in expected {
		assert(candidates[i] == name, "expected sorted candidate list to match")
	}
	_ = t
}

@(test)
test_command_completion_candidates_matches_single_alias :: proc(t: ^testing.T) {
	candidates := command_completion_candidates("q", context.temp_allocator)
	assert(len(candidates) == 1, "expected only 'quit' to match prefix 'q'")
	assert(candidates[0] == "quit", "expected 'quit' to be the sole match")
	_ = t
}

@(test)
test_command_completion_candidates_matches_multiple :: proc(t: ^testing.T) {
	candidates := command_completion_candidates("c", context.temp_allocator)
	assert(len(candidates) == 3, "expected 'cancel', 'clear', 'config' to match prefix 'c'")
	assert(candidates[0] == "cancel", "expected sorted match order")
	assert(candidates[1] == "clear", "expected sorted match order")
	assert(candidates[2] == "config", "expected sorted match order")
	_ = t
}

@(test)
test_command_completion_candidates_no_matches :: proc(t: ^testing.T) {
	candidates := command_completion_candidates("xyz", context.temp_allocator)
	assert(len(candidates) == 0, "expected no matches for an unknown prefix")
	_ = t
}

@(test)
test_command_completion_candidates_is_case_insensitive :: proc(t: ^testing.T) {
	candidates := command_completion_candidates("EX", context.temp_allocator)
	assert(len(candidates) == 1, "expected case-insensitive prefix match")
	assert(candidates[0] == "exit", "expected 'exit' to match prefix 'EX'")
	_ = t
}

@(test)
test_command_spec_for_name_resolves_aliases :: proc(t: ^testing.T) {
	spec, ok := command_spec_for_name("quit")
	assert(ok, "expected 'quit' to resolve to a spec")
	assert(spec.kind == .Exit, "expected 'quit' to resolve to the Exit spec")
	assert(!spec.takesArgs, "expected no current command to take arguments")

	_, missing := command_spec_for_name("nope")
	assert(!missing, "expected unknown name to not resolve")
	_ = t
}

@(test)
test_parse_slash_command_recognizes_commands_and_aliases :: proc(t: ^testing.T) {
	exit := parse_slash_command("/exit")
	assert(exit.isCommand, "expected slash input to parse as command")
	assert(exit.kind == .Exit, "expected /exit to map to Exit command")
	assert(exit.name == "exit", "expected command name to exclude slash")

	quit := parse_slash_command("/quit")
	assert(quit.kind == .Exit, "expected /quit to map to Exit command")

	cancel := parse_slash_command("/cancel")
	assert(cancel.kind == .Stop, "expected /cancel to map to Stop command")

	_ = t
}

@(test)
test_parse_slash_command_preserves_whitespace_rules :: proc(t: ^testing.T) {
	with_spaces := parse_slash_command("/config   provider ollama")
	assert(with_spaces.kind == .Config, "expected /config to map to Config command")
	assert(with_spaces.args == "provider ollama", "expected leading spaces to be skipped")

	with_tabs := parse_slash_command("/config\t\tprovider ollama")
	assert(with_tabs.args == "provider ollama", "expected leading tabs to be skipped")

	empty_args := parse_slash_command("/help   \t")
	assert(empty_args.args == "", "expected whitespace-only arguments to be empty")

	_ = t
}

@(test)
test_parse_slash_command_handles_plain_and_unknown_input :: proc(t: ^testing.T) {
	empty := parse_slash_command("")
	assert(!empty.isCommand, "expected empty input to stay chat text")
	assert(empty.kind == .None, "expected empty input to have no command kind")

	chat := parse_slash_command("hello")
	assert(!chat.isCommand, "expected regular input to stay chat text")
	assert(chat.kind == .None, "expected regular input to have no command kind")

	unknown := parse_slash_command("/wat")
	assert(unknown.isCommand, "expected unknown slash input to be a command")
	assert(unknown.kind == .Unknown, "expected unknown slash command to be marked unknown")

	_ = t
}
