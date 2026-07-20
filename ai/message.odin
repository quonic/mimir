package ai

Message_Role :: enum {
	System,
	User,
	Assistant,
}

Message :: struct {
	role:    Message_Role,
	content: string,
}

Chat_Request :: struct {
	model:       string,
	messages:    []Message,
	temperature: f32,
	maxTokens:   int,
}

Chat_Response :: struct {
	content:      string,
	model:        string,
	finishReason: string,
}

Chat_Stream_Delta :: struct {
	content:      string,
	model:        string,
	finishReason: string,
	done:         bool,
}

Chat_Stream_Callback :: #type proc(delta: Chat_Stream_Delta) -> bool
Chat_Stream_Context_Callback :: #type proc(delta: Chat_Stream_Delta, userData: rawptr) -> bool

message_role_to_string :: proc(role: Message_Role) -> string {
	switch role {
	case .System:
		return "system"
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case:
		return "user"
	}
}

message_role_from_string :: proc(role: string) -> Message_Role {
	switch role {
	case "system":
		return .System
	case "assistant":
		return .Assistant
	case "user":
		fallthrough
	case:
		return .User
	}
}
