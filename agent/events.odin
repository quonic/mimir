package agent

import "core:mem"
import "core:strings"

Agent_Event_Type :: enum int {
	None,
	Text_Delta,
	Thinking_Changed,
	Tool_Requested,
	Tool_Resolved,
	Completed,
	Failed,
	Canceled,
	Child_Completed,
}

Tool_Request :: struct {
	id:        string,
	name:      string,
	arguments: string,
}

Agent_Event :: struct {
	type:        Agent_Event_Type,
	agentID:     Agent_ID,
	parentID:    Agent_ID,
	requestID:   string,
	content:     string,
	toolRequest: Tool_Request,
	isError:     bool,
}

tool_request_clone :: proc(request: Tool_Request, allocator := context.allocator) -> Tool_Request {
	return Tool_Request {
		id = strings.clone(request.id, allocator),
		name = strings.clone(request.name, allocator),
		arguments = strings.clone(request.arguments, allocator),
	}
}

tool_request_destroy :: proc(request: ^Tool_Request, allocator := context.allocator) {
	delete(request.id, allocator)
	delete(request.name, allocator)
	delete(request.arguments, allocator)
	request^ = {}
}

agent_event_clone :: proc(event: Agent_Event, allocator := context.allocator) -> Agent_Event {
	return Agent_Event {
		type = event.type,
		agentID = event.agentID,
		parentID = event.parentID,
		requestID = strings.clone(event.requestID, allocator),
		content = strings.clone(event.content, allocator),
		toolRequest = tool_request_clone(event.toolRequest, allocator),
		isError = event.isError,
	}
}

agent_event_destroy :: proc(event: ^Agent_Event, allocator := context.allocator) {
	delete(event.requestID, allocator)
	delete(event.content, allocator)
	tool_request_destroy(&event.toolRequest, allocator)
	event^ = {}
}
