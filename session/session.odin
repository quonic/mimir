package session

import "../agent"
import "../ai"
import "../code_index"
import "../input_history"
import "../settings"
import "../tool_policy"
import "core:mem"
import "core:strings"

// A Session holds all state of one conversation in one project root: the agent loop, the tool
// dispatcher and its session grants, the skill registry, the code index, the tool worker, the
// pending approval and the transcript. A front end drives it with the session_* procedures and
// pulls what happened with session_next_event. A session never calls front-end code.
//
// The config and the config home are shared with the front end. The front end must not change
// the config while a tool runs, except through the session procedures.
Session :: struct {
	allocator:               mem.Allocator,
	config:                  ^settings.Mimir_Config,
	configHome:              string,
	projectRoot:             string,
	// The model of this session. They start from Session_Options; an empty model uses the
	// model of the provider.
	providerName:            string,
	model:                   string,
	approvalMethod:          settings.Approval_Method,
	dispatcher:              tool_policy.Tool_Dispatcher,
	dispatcherReady:         bool,
	skills:                  settings.Skill_Registry,
	// The disabled skills of the config changed while a tool ran.
	skillSettingsPending:    bool,
	codeIndex:               code_index.Code_Index,
	codeIndexReady:          bool,
	codeIndexRebuildPending: bool,
	host:                    Agent_Host,
	toolExecution:           Tool_Execution_State,
	approval:                Pending_Approval,
	transcript:              Transcript,
	events:                  [dynamic]Session_Event,
}

Session_Options :: struct {
	projectRoot:        string,
	configHome:         string,
	providerName:       string,
	model:              string,
	approvalMethod:     settings.Approval_Method,
	// When true, session_create fails with .No_Usable_Model unless the provider is enabled and
	// a model is selected. The terminal UI creates its session without a model, for setup.
	requireUsableModel: bool,
}

Session_Error :: enum int {
	None = 0,
	// A turn is active.
	Busy,
	// An argument is missing or invalid.
	Invalid_Argument,
	// No enabled provider or no model is selected (see Session_Options.requireUsableModel).
	No_Usable_Model,
	// The turn could not start. A Notice event says why.
	Start_Failed,
	// There is no active turn.
	Not_Active,
	// There is no pending approval.
	No_Pending_Approval,
	// The tool call ID does not match the pending approval.
	Unknown_Tool_Call,
	// The approval choice could not be applied, for example because a grant was not saved.
	// The call stays pending, and a Notice event says why.
	Approval_Not_Applied,
}

// Returns the session options from the current selections of config.
session_options_from_config :: proc(
	config: ^settings.Mimir_Config,
	projectRoot, configHome: string,
) -> Session_Options {
	return Session_Options {
		projectRoot = projectRoot,
		configHome = configHome,
		providerName = config.selectedProvider,
		model = config.selectedModel,
		approvalMethod = config.approvalMethod,
	}
}

session_create :: proc(
	config: ^settings.Mimir_Config,
	options: Session_Options,
	allocator := context.allocator,
) -> (
	^Session,
	Session_Error,
) {
	if config == nil {
		return nil, .Invalid_Argument
	}
	if options.requireUsableModel {
		provider, providerOK := settings.config_find_provider(config^, options.providerName)
		model := options.model
		if model == "" {
			model = provider.model
		}
		if !providerOK || !provider.enabled || model == "" {
			return nil, .No_Usable_Model
		}
	}
	session := new(Session, allocator)
	session.allocator = allocator
	session.config = config
	session.configHome = strings.clone(options.configHome, allocator)
	session.projectRoot = strings.clone(options.projectRoot, allocator)
	session.providerName = strings.clone(options.providerName, allocator)
	session.model = strings.clone(options.model, allocator)
	session.approvalMethod = options.approvalMethod
	session.events = make([dynamic]Session_Event, 0, 16, allocator)
	session.host = agent_host_init(allocator)
	session.transcript = transcript_init(allocator)
	session.toolExecution.allocator = allocator
	session.skills = settings.skill_registry_init(allocator)
	settings.skill_registry_load(&session.skills, session.configHome, session.projectRoot)
	settings.skill_registry_apply_disabled(&session.skills, config.disabledSkills[:])
	// The dispatcher reads the persistent grants through the shared config, so a grant that is
	// added to the config is seen without a resync.
	session.dispatcher, session.dispatcherReady = tool_policy.tool_dispatcher_init(
		session.projectRoot,
		&config.permissionGrants,
		allocator,
	)
	session_rebuild_code_index(session)
	return session, .None
}

// Frees the session. It is safe while a turn runs: it cancels the stream and waits for a
// running tool call and the safety classifier to finish.
session_destroy :: proc(session: ^Session) {
	if session == nil {
		return
	}
	allocator := session.allocator
	// The tool worker uses the dispatcher, the skills and the code index. Join it first.
	tool_execution_destroy(&session.toolExecution)
	pending_approval_destroy(&session.approval, session.dispatcher.allocator)
	agent_host_destroy(&session.host)
	transcript_destroy(&session.transcript)
	session_events_destroy(&session.events, allocator)
	if session.dispatcherReady {
		tool_policy.tool_dispatcher_destroy(&session.dispatcher)
	}
	if session.codeIndexReady {
		code_index.code_index_destroy(&session.codeIndex, allocator)
	}
	settings.skill_registry_destroy(&session.skills)
	delete(session.configHome, allocator)
	delete(session.projectRoot, allocator)
	delete(session.providerName, allocator)
	delete(session.model, allocator)
	free(session, allocator)
}

// Starts a turn with the user text text. It returns .Busy while a turn is active, and
// .Start_Failed (with a Notice event) when the turn could not start. The user text stays in the
// transcript when the turn could not start.
session_submit :: proc(session: ^Session, text: string) -> Session_Error {
	if session == nil {
		return .Invalid_Argument
	}
	if session_turn_active(session) {
		return .Busy
	}
	transcript_append_user(&session.transcript, text)
	if !session_start_turn(session) {
		return .Start_Failed
	}
	return .None
}

// Cancels the active agent: the main agent, or the subagent that runs for it. A pending
// approval is denied first.
session_cancel :: proc(session: ^Session) -> Session_Error {
	if session == nil {
		return .Invalid_Argument
	}
	if pending_approval_active(&session.approval) {
		_ = session_apply_approval_choice(session, session.approval.agentRequestID, .Deny)
	}
	activeID := session.host.activeAgentID
	if agent.agent_id_is_none(activeID) ||
	   agent.runtime_cancel(&session.host.runtime, activeID) != .None {
		session_emit_notice(session, "No assistant stream to cancel", .Warning)
		return .Not_Active
	}
	session_emit_notice(session, "Canceling assistant stream")
	return .None
}

// Answers the pending approval with the tool call ID toolCallID. Allow_Session adds a grant to
// the dispatcher of the session; Allow_Always appends a grant to the shared config and saves
// the config.
session_resolve_approval :: proc(
	session: ^Session,
	toolCallID: string,
	choice: Approval_Choice,
) -> Session_Error {
	if session == nil {
		return .Invalid_Argument
	}
	return session_apply_approval_choice(session, toolCallID, choice)
}

// Advances the tool worker, the agent stream and the safety classifier. It returns true when
// something changed, for example when new events are ready.
session_poll :: proc(session: ^Session) -> bool {
	if session == nil {
		return false
	}
	eventCount := len(session.events)
	changed := session_poll_tool_execution(session)
	changed = session_poll_agent_host(session) || changed
	changed = session_poll_pending_approval(session) || changed
	return changed || len(session.events) != eventCount
}

// Reports whether a turn is active: the active agent has not ended.
session_turn_active :: proc(session: ^Session) -> bool {
	if session == nil {
		return false
	}
	activeID := session.host.activeAgentID
	if agent.agent_id_is_none(activeID) {
		return false
	}
	activeState, activeOK := agent.runtime_state(&session.host.runtime, activeID)
	return activeOK && !agent.agent_state_is_terminal(activeState)
}

// Reports whether a tool call runs on the tool worker.
session_tool_running :: proc(session: ^Session) -> bool {
	return session != nil && session.toolExecution.active
}

// Sets the model of this session. The next turn uses it.
session_set_model :: proc(session: ^Session, providerName, model: string) {
	if session == nil {
		return
	}
	if session.providerName != providerName {
		delete(session.providerName, session.allocator)
		session.providerName = strings.clone(providerName, session.allocator)
	}
	if session.model != model {
		delete(session.model, session.allocator)
		session.model = strings.clone(model, session.allocator)
	}
}

// Sets the approval method of this session. The next approval request uses it.
session_set_approval_method :: proc(session: ^Session, method: settings.Approval_Method) {
	if session == nil {
		return
	}
	session.approvalMethod = method
}

// Removes all earlier turns from the transcript.
session_clear_transcript :: proc(session: ^Session) {
	if session == nil {
		return
	}
	transcript_clear(&session.transcript)
}

// Loads the skill registry again from the config home and the project root. It returns .Busy
// while a turn is active.
session_reload_skills :: proc(session: ^Session) -> Session_Error {
	if session == nil {
		return .Invalid_Argument
	}
	if session_turn_active(session) || session.toolExecution.active {
		return .Busy
	}
	settings.skill_registry_load(&session.skills, session.configHome, session.projectRoot)
	settings.skill_registry_apply_disabled(&session.skills, session.config.disabledSkills[:])
	session.skillSettingsPending = false
	return .None
}

// Applies the disabled skills of the config to the skill registry. A running tool can read the
// registry, so the session applies them when the tool call ends.
session_apply_skill_settings :: proc(session: ^Session) {
	if session == nil {
		return
	}
	if session.toolExecution.active {
		session.skillSettingsPending = true
		return
	}
	session.skillSettingsPending = false
	settings.skill_registry_apply_disabled(&session.skills, session.config.disabledSkills[:])
}

// Rebuilds the code index from the embedding selection of the config. A running tool call can
// use the code index, so the session rebuilds it when the tool call ends.
session_rebuild_code_index :: proc(session: ^Session) {
	if session == nil {
		return
	}
	allocator := session.allocator
	if session.toolExecution.active {
		session.codeIndexRebuildPending = true
		return
	}
	session.codeIndexRebuildPending = false
	if session.codeIndexReady {
		code_index.code_index_destroy(&session.codeIndex, allocator)
		session.codeIndexReady = false
	}
	config := session.config
	if session.configHome == "" ||
	   session.projectRoot == "" ||
	   config.embeddingProvider == "" ||
	   config.embeddingModel == "" {
		return
	}

	cacheDir := input_history.cache_directory(session.configHome, allocator)
	defer delete(cacheDir, allocator)
	index, initError := code_index.code_index_init(
		session.projectRoot,
		cacheDir,
		config.embeddingProvider,
		config.embeddingModel,
		allocator,
	)
	if initError != .None {
		return
	}
	session.codeIndex = index
	session.codeIndexReady = true
	_ = code_index.code_index_load(&session.codeIndex, allocator)
}

// Returns the client for the embedding model of the config.
session_embedding_client :: proc(config: ^settings.Mimir_Config) -> (ai.Client, ai.AI_Error) {
	if config == nil || config.embeddingProvider == "" || config.embeddingModel == "" {
		return ai.Client{}, .Invalid_Request
	}
	provider, providerOK := settings.config_find_provider(config^, config.embeddingProvider)
	if !providerOK || !provider.enabled {
		return ai.Client{}, .Interface_Not_Found
	}
	if provider.type != .Ollama && provider.type != .OpenAI {
		return ai.Client{}, .Unsupported_Interface
	}
	return ai.new_client(provider.name, provider.apiKey)
}
