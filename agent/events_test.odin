package agent

import "core:testing"

@(test)
test_agent_event_clone_retains_routing_and_payload :: proc(t: ^testing.T) {
	original := Agent_Event {
		type = .Tool_Requested,
		agentID = Agent_ID(7),
		parentID = Agent_ID(3),
		requestID = "request-1",
		content = "read_file",
		toolRequest = Tool_Request {
			id = "request-1",
			name = "read_file",
			arguments = `{"file_path":"README.md"}`,
		},
	}
	clone := agent_event_clone(original, context.temp_allocator)
	defer agent_event_destroy(&clone, context.temp_allocator)

	assert(clone.type == .Tool_Requested, "expected event type to be retained")
	assert(clone.agentID == Agent_ID(7), "expected agent ID to be retained")
	assert(clone.parentID == Agent_ID(3), "expected parent ID to be retained")
	assert(clone.requestID == "request-1", "expected request ID to be retained")
	assert(clone.content == "read_file", "expected event content to be retained")
	assert(clone.toolRequest.name == "read_file", "expected tool request to be retained")
	_ = t
}
