package commands

import "core:testing"

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