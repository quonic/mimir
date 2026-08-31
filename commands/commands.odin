package commands

import "core:slice"
import "core:strings"

Slash_Command :: enum int {
	None = 0,
	Exit,
	Config,
	Help,
	Stop,
	Clear,
	Unknown,
}

Parsed_Command :: struct {
	isCommand: bool,
	kind:      Slash_Command,
	name:      string,
	args:      string,
}

// Command_Spec is the single source of truth for a command's typeable names
// (names[0] is the primary/canonical form used in help text), its
// description, and whether it takes arguments (drives completion behavior).
Command_Spec :: struct {
	kind:        Slash_Command,
	names:       []string,
	description: string,
	takesArgs:   bool,
}

COMMAND_SPECS := []Command_Spec {
	{
		kind = .Exit,
		names = {"exit", "quit"},
		description = "Exit the application",
		takesArgs = false,
	},
	{kind = .Config, names = {"config"}, description = "Open configuration", takesArgs = false},
	{kind = .Help, names = {"help"}, description = "Show available commands", takesArgs = false},
	{
		kind = .Stop,
		names = {"stop", "cancel"},
		description = "Stop the active response",
		takesArgs = false,
	},
	{kind = .Clear, names = {"clear"}, description = "Clear input history", takesArgs = false},
}

parse_slash_command :: proc(input: string) -> Parsed_Command {
	if len(input) == 0 || input[0] != '/' {
		return Parsed_Command{kind = .None}
	}

	name_start := 1
	name_end := name_start
	for name_end < len(input) && input[name_end] != ' ' && input[name_end] != '\t' {
		name_end += 1
	}

	args_start := name_end
	for args_start < len(input) && (input[args_start] == ' ' || input[args_start] == '\t') {
		args_start += 1
	}

	name := input[name_start:name_end]
	args := input[args_start:]
	return Parsed_Command {
		isCommand = true,
		kind = slash_command_kind(name),
		name = name,
		args = args,
	}
}

slash_command_kind :: proc(name: string) -> Slash_Command {
	for spec in COMMAND_SPECS {
		for candidate in spec.names {
			if candidate == name {
				return spec.kind
			}
		}
	}
	return .Unknown
}

// command_spec_for_name looks up the spec owning `name` (case-insensitive).
command_spec_for_name :: proc(name: string) -> (Command_Spec, bool) {
	lowerName := strings.to_lower(name, context.temp_allocator)
	for spec in COMMAND_SPECS {
		for candidate in spec.names {
			lowerCandidate := strings.to_lower(candidate, context.temp_allocator)
			if lowerCandidate == lowerName {
				return spec, true
			}
		}
	}
	return Command_Spec{}, false
}

// command_completion_candidates returns every command name (across all
// commands and aliases) whose lowercase form starts with lowercase `prefix`,
// sorted alphabetically. An empty prefix returns every name.
command_completion_candidates :: proc(prefix: string, allocator := context.allocator) -> []string {
	lowerPrefix := strings.to_lower(prefix, context.temp_allocator)
	matches := make([dynamic]string, 0, 8, allocator)
	for spec in COMMAND_SPECS {
		for name in spec.names {
			lowerName := strings.to_lower(name, context.temp_allocator)
			if strings.has_prefix(lowerName, lowerPrefix) {
				append(&matches, name)
			}
		}
	}
	slice.sort(matches[:])
	return matches[:]
}

// help_text reproduces the canonical "/help" command listing from
// COMMAND_SPECS, using each command's primary (first) name.
help_text :: proc(allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, "Commands:")
	for spec, i in COMMAND_SPECS {
		if i > 0 {
			strings.write_string(&builder, ",")
		}
		strings.write_string(&builder, " /")
		strings.write_string(&builder, spec.names[0])
	}
	return strings.to_string(builder)
}
