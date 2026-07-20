package main

Slash_Command :: enum int {
	None = 0,
	Exit,
	Config,
	Help,
	Models,
	Skills,
	Stop,
	Unknown,
}

Parsed_Command :: struct {
	isCommand: bool,
	kind:      Slash_Command,
	name:      string,
	args:      string,
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
	switch name {
	case "exit", "quit":
		return .Exit
	case "config":
		return .Config
	case "help":
		return .Help
	case "models":
		return .Models
	case "skills":
		return .Skills
	case "stop", "cancel":
		return .Stop
	case:
		return .Unknown
	}
}
