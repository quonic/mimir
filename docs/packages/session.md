# Session Package

The `session` package holds the agent loop of one conversation in one project
root. A front end (the terminal UI now, ACP later) creates a session, drives
it, and pulls its events. See
[ADR 0002](../adr/0002-split-agent-session-from-front-ends.md).

The package does not import `console`, `widgets`, `text_input` or package
`main`, so it holds no terminal state.

## What a Session Owns

- The project root, the config home (a copy), and the model and approval
  method of the session.
- The tool dispatcher and its session grants. The dispatcher reads the
  persistent grants through the shared config.
- The skill registry and the code index of the project root.
- The agent host: runtime, active agent, subagent stack, usage and context
  window size.
- The tool worker, the pending approval and the safety classifier.
- The transcript of earlier turns.

The config (`^settings.Mimir_Config`) is shared by reference. It must stay at
the same address for the life of the session.

## Interface

```odin
config := settings.default_ollama_config()
options := session.session_options_from_config(&config, projectRoot, configHome)
s, err := session.session_create(&config, options)
defer session.session_destroy(s)

if session.session_submit(s, "List the files") == .Busy {
	// A turn is active.
}
// In the main loop of the front end:
session.session_poll(s)
for {
	event, ok := session.session_next_event(s)
	if !ok {
		break
	}
	// Show the event, then free it with the allocator of the session.
	session.session_event_destroy(&event, s.allocator)
}
```

| Procedure | Purpose |
| --- | --- |
| `session_create` | Makes a session. With `requireUsableModel`, it returns `.No_Usable_Model` when no enabled provider or model is selected. |
| `session_destroy` | Frees the session. It is safe during a turn: it cancels the stream and waits for a running tool call. |
| `session_submit` | Starts a turn. It returns `.Busy` while a turn is active, and `.Start_Failed` with a `Notice` when the turn cannot start. |
| `session_cancel` | Cancels the active agent (the subagent while one runs; the parent then goes on). It denies a pending approval first. It returns `.Not_Active` when nothing runs. The terminal `/stop` uses it. |
| `session_cancel_turn` | Cancels the whole turn: the main agent and every running subagent. It denies a pending approval first. The turn ends with `Turn_Ended` `Canceled`, after a failed `Subagent_Finished` for each running subagent. It returns `.Not_Active` when nothing runs. ACP `session/cancel` uses it. |
| `session_resolve_approval` | Answers the pending approval. It returns `.Unknown_Tool_Call` for another ID, `.No_Pending_Approval` when nothing waits, and `.Approval_Not_Applied` when a grant cannot be added or saved (the approval stays pending). |
| `session_poll` | Advances the stream, the tool worker and the safety classifier. |
| `session_next_event` | Returns the next event. The caller owns it. |
| `session_event_destroy` | Frees an event. |
| `session_set_model`, `session_set_approval_method` | Change the model or the approval method of this session only. |
| `session_clear_transcript` | Removes the earlier turns (`/clear`). |
| `session_reload_skills` | Loads the skills again. It returns `.Busy` during a turn. |
| `session_apply_skill_settings` | Applies `config.disabledSkills`. During a tool call it waits until the call ends. |
| `session_rebuild_code_index` | Rebuilds the code index from the embedding selection. During a tool call it waits until the call ends. |

## Events

Events carry data, not display text. A tool call and its approval are
identified by a tool call ID that is unique in the session. It is the tool call
ID of the model when the session has not used that ID before. Models can
repeat their IDs (Ollama numbers the tool calls of each response from
`ollama-0`), so a repeated ID gets a suffix: `ollama-0`, then `ollama-0-2`,
`ollama-0-3` and so on. The agent runtime and the conversation sent to the
model keep the model's ID.

| Event | Data |
| --- | --- |
| `Message_Delta` | Text, subagent depth (0 for the main agent), and the `run_subagent` tool call ID of a subagent. |
| `Thinking_Changed` | Thinking flag, subagent depth. |
| `Usage_Updated` | Usage (`inputTokens` is the current context usage) and the context window size (0 when unknown). A turn starts with empty usage. |
| `Tool_Call_Started` | Tool call ID, tool ID, target, raw arguments. A `Tool_Call_Updated` with the first status follows. |
| `Tool_Call_Updated` | Tool call ID, status (`Awaiting_Approval`, `Running`, `Completed`, `Failed`, `Denied`), output. |
| `Approval_Requested` | Tool call ID, permission action, safety state. It comes after `Tool_Call_Started` of the same call. |
| `Approval_Safety_Updated` | Tool call ID, safety state. |
| `Approval_Resolved` | Tool call ID, choice. |
| `Subagent_Started` | Parent tool call ID, task. |
| `Subagent_Finished` | Parent tool call ID, task, result, failed flag, stream error text. |
| `Turn_Ended` | Reason (`Completed`, `Canceled`, `Failed`), error text. |
| `Notice` | Severity, text. |

The safety state has a status: `Not_Checked` (the approval method does not use
the classifier), `Checking` (an `Approval_Safety_Updated` follows),
`Unavailable`, or `Checked` with the verdict and the classifier response.

## Approval Method

The approval method runs inside the session:

- `Approve_All` and `Deny_All` settle a call without `Approval_Requested`.
  The front end sees only `Tool_Call_Updated`.
- `Always_Ask` emits `Approval_Requested`. For a shell command it also starts
  the safety classifier as advice.
- `Approve_Safe` emits `Approval_Requested` and starts the classifier. A safe
  verdict approves the call inside the session and emits `Approval_Resolved`.

## Fake Provider for Tests

`Fake_Provider` (`fake_provider.odin`) is an HTTP server on the loopback
interface that answers Ollama chat requests with queued responses. Tests of
the session and of front ends use it to run whole turns without a model:

```odin
provider: session.Fake_Provider
session.fake_provider_start(&provider, "my-test-provider")
defer session.fake_provider_stop(&provider)
append(&config.providers, session.fake_provider_config(&provider))
session.fake_provider_add_response(
	&provider,
	false,
	session.fake_provider_text_line("Hello"),
	session.fake_provider_text_line("", true),
)
```

It answers requests in order, one queued response per request, including the
requests of the safety classifier. Use a different interface name in each
test, because the AI interface registry is process-wide.
