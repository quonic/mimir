#+vet explicit-allocators
package main

import "ai"
import "core:mem"
import "core:strings"

// The conversation that later turns send to the model: the user text and the assistant text of
// the main agent. Tool calls, tool results, subagent text and notes are not part of it. The
// transcript is separate from the history panel, so the agent code does not read UI history.
Transcript :: struct {
	allocator:     mem.Allocator,
	entries:       [dynamic]Transcript_Entry,
	// True while streamed assistant text is added to the last entry.
	assistantOpen: bool,
}

Transcript_Entry :: struct {
	role:    ai.Message_Role,
	content: string,
}

transcript_init :: proc(allocator := context.allocator) -> Transcript {
	return Transcript {
		allocator = allocator,
		entries = make([dynamic]Transcript_Entry, 0, 16, allocator),
	}
}

transcript_destroy :: proc(transcript: ^Transcript) {
	transcript_clear(transcript)
	delete(transcript.entries)
	transcript^ = {}
}

transcript_clear :: proc(transcript: ^Transcript) {
	for &entry in transcript.entries {
		delete(entry.content, transcript.allocator)
		entry = {}
	}
	clear(&transcript.entries)
	transcript.assistantOpen = false
}

transcript_append_user :: proc(transcript: ^Transcript, text: string) {
	transcript.assistantOpen = false
	transcript_append_entry(transcript, .User, text)
}

// Adds a complete assistant message, for example the error text of a failed stream.
transcript_append_assistant :: proc(transcript: ^Transcript, text: string) {
	transcript.assistantOpen = false
	transcript_append_entry(transcript, .Assistant, text)
}

// Adds streamed assistant text. Text that arrives before transcript_end_assistant_text goes
// into the same assistant message.
transcript_append_assistant_text :: proc(transcript: ^Transcript, text: string) {
	if text == "" {
		return
	}
	if !transcript.assistantOpen || len(transcript.entries) == 0 {
		transcript_append_entry(transcript, .Assistant, text)
		transcript.assistantOpen = true
		return
	}
	entry := &transcript.entries[len(transcript.entries) - 1]
	updated := strings.concatenate({entry.content, text}, transcript.allocator)
	delete(entry.content, transcript.allocator)
	entry.content = updated
}

// Ends the streamed assistant message. The next streamed text starts a new message.
transcript_end_assistant_text :: proc(transcript: ^Transcript) {
	transcript.assistantOpen = false
}

transcript_append_entry :: proc(transcript: ^Transcript, role: ai.Message_Role, text: string) {
	if text == "" {
		return
	}
	if transcript.allocator.procedure == nil {
		transcript.allocator = context.allocator
	}
	append(
		&transcript.entries,
		Transcript_Entry{role = role, content = strings.clone(text, transcript.allocator)},
	)
}

// Builds the model messages for a new turn: the system prompt, then the transcript in order.
transcript_build_messages :: proc(
	transcript: ^Transcript,
	systemPrompt: string,
	allocator := context.allocator,
) -> [dynamic]ai.Message {
	messages := make([dynamic]ai.Message, 0, len(transcript.entries) + 1, allocator)
	if systemPrompt != "" {
		append(
			&messages,
			ai.Message{role = .System, content = strings.clone(systemPrompt, allocator)},
		)
	}
	for entry in transcript.entries {
		if entry.content == "" {
			continue
		}
		append(
			&messages,
			ai.Message{role = entry.role, content = strings.clone(entry.content, allocator)},
		)
	}
	return messages
}
