package main

import "core:fmt"
import "core:strings"
import "tool_policy"

// Agent output as data. The agent code (agent_host.odin, tool_orchestration.odin) reports what
// happened through app_show_agent_output, and only app_show_agent_output turns it into history
// lines and status text. When the agent code moves into the session package (ADR-0002), these
// values become session events and app_show_agent_output becomes the terminal UI's event drain.

Agent_Tool_Status :: enum int {
	Awaiting_Approval = 0,
	Running,
	// A run_subagent call whose child agent is running.
	Delegated,
	Completed,
	Failed,
	Denied,
}

// A status text, for example "Tool call denied".
Agent_Notice :: struct {
	text: string,
}

// The agent stream started; the front end shows a pending assistant entry.
Agent_Stream_Started :: struct {}

Agent_Message_Delta :: struct {
	text:       string,
	inSubagent: bool,
}

Agent_Thinking_Changed :: struct {
	thinking:   bool,
	inSubagent: bool,
}

Agent_Stream_End_Reason :: enum int {
	Completed = 0,
	Canceled,
	Failed,
}

// The stream of the agent that receives output (the main agent or a subagent) ended.
Agent_Stream_Ended :: struct {
	reason:    Agent_Stream_End_Reason,
	errorText: string,
}

// A tool call started or changed status.
Agent_Tool_Call :: struct {
	toolCallID:   string,
	toolID:       string,
	target:       string,
	status:       Agent_Tool_Status,
	output:       string,
	// The history line of this tool call, or -1 for a new line. This goes away when the
	// front end finds the line from toolCallID.
	historyIndex: int,
}

Agent_Subagent_Started :: struct {
	parentToolCallID: string,
	task:             string,
}

Agent_Subagent_Finished :: struct {
	parentToolCallID: string,
	task:             string,
	result:           string,
	failed:           bool,
}

// The runtime reported that a child agent completed.
Agent_Child_Completed :: struct {
	text: string,
}

Agent_Output :: union {
	Agent_Notice,
	Agent_Stream_Started,
	Agent_Message_Delta,
	Agent_Thinking_Changed,
	Agent_Stream_Ended,
	Agent_Tool_Call,
	Agent_Subagent_Started,
	Agent_Subagent_Finished,
	Agent_Child_Completed,
}

// Shows agent output in the history panel and the status text. For Agent_Tool_Call it returns
// the history line of the tool call; for all other output it returns -1.
app_show_agent_output :: proc(state: ^App_State, output: Agent_Output) -> int {
	switch value in output {
	case Agent_Notice:
		state.status = value.text
	case Agent_Stream_Started:
		// Placeholder entry gives the spinner somewhere to render while the provider is
		// processing.
		append_history(state, .Assistant, "")
		state.agentHost.historyIndex = len(state.history) - 1
		state.status = "Streaming assistant response"
	case Agent_Message_Delta:
		app_show_agent_message_delta(state, value)
	case Agent_Thinking_Changed:
		if value.thinking {
			if state.agentHost.historyIndex < 0 ||
			   state.agentHost.historyIndex >= len(state.history) {
				append_history(state, app_agent_message_role(value.inSubagent), "")
				state.agentHost.historyIndex = len(state.history) - 1
			}
			state.status = "Assistant thinking"
		}
	case Agent_Stream_Ended:
		switch value.reason {
		case .Completed:
			state.status = "Assistant response complete"
		case .Failed:
			append_history(state, .Assistant, value.errorText)
			state.status = "Assistant stream failed"
		case .Canceled:
			state.status = "Assistant stream canceled"
		}
		state.agentHost.historyIndex = -1
	case Agent_Tool_Call:
		return app_show_agent_tool_call(state, value)
	case Agent_Subagent_Started:
		append_history(state, .Subagent, fmt.tprintf("Subagent started: %s", value.task))
		state.status = "Subagent running"
	case Agent_Subagent_Finished:
		if value.failed {
			append_history(
				state,
				.Subagent,
				fmt.tprintf("Subagent failed (%s): %s", value.task, value.result),
			)
		} else {
			append_history(
				state,
				.Subagent,
				fmt.tprintf("Subagent completed (%s): %s", value.task, value.result),
			)
		}
		state.status = "Subagent finished"
	case Agent_Child_Completed:
		append_history(state, .Tool, value.text)
	}
	return -1
}

app_agent_message_role :: proc(inSubagent: bool) -> History_Role {
	if inSubagent {
		return .Subagent
	}
	return .Assistant
}

app_show_agent_message_delta :: proc(state: ^App_State, delta: Agent_Message_Delta) {
	if state.agentHost.historyIndex < 0 || state.agentHost.historyIndex >= len(state.history) {
		append_history(state, app_agent_message_role(delta.inSubagent), delta.text)
		state.agentHost.historyIndex = len(state.history) - 1
	} else {
		entry := &state.history[state.agentHost.historyIndex]
		updated := strings.concatenate({entry.content, delta.text}, context.allocator)
		delete(entry.content)
		entry.content = updated
		entry.cachedLineWidth = 0
		entry.cachedLineCount = 0
	}
	state.historyRenderOnly = true
}

app_show_agent_tool_call :: proc(state: ^App_State, toolCall: Agent_Tool_Call) -> int {
	content := app_tool_history_line(
		toolCall.toolID,
		toolCall.target,
		app_agent_tool_status_text(toolCall.status),
	)
	if toolCall.historyIndex < 0 {
		append_history(state, .Tool, content)
		return len(state.history) - 1
	}
	if toolCall.historyIndex >= len(state.history) {
		return toolCall.historyIndex
	}
	entry := &state.history[toolCall.historyIndex]
	if entry.content != "" {
		delete(entry.content, context.allocator)
	}
	entry.content = strings.clone(content, context.allocator)
	entry.cachedLineWidth = 0
	entry.cachedLineCount = 0
	state.historyScrollOffset = 0
	state.historySelection = {}
	return toolCall.historyIndex
}

app_agent_tool_status_text :: proc(status: Agent_Tool_Status) -> string {
	switch status {
	case .Awaiting_Approval:
		return "awaiting approval"
	case .Running:
		return "running"
	case .Delegated:
		return "delegated"
	case .Completed:
		return "completed"
	case .Failed:
		return "failed"
	case .Denied:
		return "denied"
	}
	return "unknown"
}

// The tool call field that the history line shows, for example the path of read_file.
app_tool_call_target :: proc(call: tool_policy.Tool_Call) -> string {
	switch call.id {
	case "read_file", "write_file", "get_file_info", "grep_search":
		return call.filePath
	case "list_directory":
		return call.directoryPath
	case "run_in_terminal":
		return call.command
	case "search_code", "find_code":
		return call.query
	case "run_subagent":
		return call.task
	}
	return ""
}

app_tool_history_line :: proc(toolID: string, target: string, status: string) -> string {
	if target == "" {
		return fmt.tprintf("%s (%s)", toolID, status)
	}
	displayTarget := approval_display_text(target, context.temp_allocator)
	return fmt.tprintf("%s: %s (%s)", toolID, displayTarget, status)
}

// Builds the tool call output for call.
app_agent_tool_call :: proc(
	call: tool_policy.Tool_Call,
	status: Agent_Tool_Status,
	historyIndex: int,
	output := "",
) -> Agent_Tool_Call {
	return Agent_Tool_Call {
		toolCallID = call.callID,
		toolID = call.id,
		target = app_tool_call_target(call),
		status = status,
		output = output,
		historyIndex = historyIndex,
	}
}
