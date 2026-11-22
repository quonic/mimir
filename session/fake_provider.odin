package session

import "../ai"
import "../builtin_tools"
import "../settings"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// Fake_Provider is a provider for tests: an HTTP server on the loopback interface that answers
// Ollama chat requests with canned responses. Tests of the session and of front ends use it to
// run whole turns without a real model. It answers the requests in order, one queued response
// per request. A request with no queued response gets a completed, empty response.
Fake_Provider :: struct {
	allocator:    mem.Allocator,
	listener:     net.TCP_Socket,
	port:         int,
	name:         string,
	mutex:        sync.Mutex,
	responses:    [dynamic]Fake_Response,
	requestCount: int,
	stopping:     bool,
	worker:       ^thread.Thread,
}

Fake_Response :: struct {
	// Ollama JSON lines, each ending with a newline.
	body:     string,
	// Keep the connection open after the body until the client closes it, so the stream only
	// ends when the client cancels it.
	holdOpen: bool,
	// Wait this long before answering, for example to keep the safety classifier running.
	delay:    time.Duration,
}

FAKE_PROVIDER_MODEL :: "fake-model"

// Starts the fake provider and registers it as the AI interface name. It returns false when
// the loopback listener could not start.
fake_provider_start :: proc(
	provider: ^Fake_Provider,
	name: string,
	allocator := context.allocator,
) -> bool {
	listener, listenErr := net.listen_tcp(
		net.Endpoint{address = net.IP4_Loopback, port = 0},
		backlog = 4,
	)
	if listenErr != nil {
		return false
	}
	endpoint, endpointErr := net.bound_endpoint(listener)
	if endpointErr != nil {
		net.close(listener)
		return false
	}
	provider.allocator = allocator
	provider.listener = listener
	provider.port = endpoint.port
	provider.name = strings.clone(name, allocator)
	provider.responses = make([dynamic]Fake_Response, 0, 4, allocator)
	{
		// The AI interface registry is process-wide and outlives the test, so it must not use
		// the allocator of one test.
		context.allocator = runtime.heap_allocator()
		ai.add_interface(name, .Ollama, fake_provider_endpoint(provider, context.temp_allocator))
	}
	// The server thread uses its own default context, so it does not share the temporary
	// allocator of the test.
	provider.worker = thread.create_and_start_with_data(provider, fake_provider_run)
	return true
}

// Stops the server and frees the provider. The AI interface stays registered.
fake_provider_stop :: proc(provider: ^Fake_Provider) {
	if provider.allocator.procedure == nil {
		// Not started, or already stopped.
		return
	}
	if provider.worker != nil {
		if sync.mutex_guard(&provider.mutex) {
			provider.stopping = true
		}
		// Wake up the accept call of the server.
		wake, wakeErr := net.dial_tcp(
			net.Endpoint{address = net.IP4_Loopback, port = provider.port},
		)
		if wakeErr == nil {
			net.close(wake)
		}
		thread.join(provider.worker)
		thread.destroy(provider.worker)
		provider.worker = nil
	}
	net.close(provider.listener)
	for response in provider.responses {
		delete(response.body, provider.allocator)
	}
	delete(provider.responses)
	delete(provider.name, provider.allocator)
	provider^ = {}
}

fake_provider_endpoint :: proc(
	provider: ^Fake_Provider,
	allocator := context.allocator,
) -> string {
	return fmt.aprintf("http://127.0.0.1:%d", provider.port, allocator = allocator)
}

// Returns a provider config for the fake provider, for config.providers. The strings are
// borrowed from provider.
fake_provider_config :: proc(provider: ^Fake_Provider) -> settings.Provider_Config {
	return settings.Provider_Config {
		name = provider.name,
		type = .Ollama,
		endpoint = "http://127.0.0.1",
		model = FAKE_PROVIDER_MODEL,
		enabled = true,
	}
}

// Queues the response to the next unanswered request. lines are Ollama JSON lines, for example
// from fake_provider_text_line.
fake_provider_add_response :: proc(provider: ^Fake_Provider, holdOpen: bool, lines: ..string) {
	builder: strings.Builder
	strings.builder_init(&builder, provider.allocator)
	for line in lines {
		strings.write_string(&builder, line)
		strings.write_byte(&builder, '\n')
	}
	if sync.mutex_guard(&provider.mutex) {
		append(
			&provider.responses,
			Fake_Response{body = strings.to_string(builder), holdOpen = holdOpen},
		)
	}
}

// Queues a response like fake_provider_add_response that is sent only after delay. The provider
// answers one request at a time, so later requests wait too.
fake_provider_add_delayed_response :: proc(
	provider: ^Fake_Provider,
	delay: time.Duration,
	lines: ..string,
) {
	fake_provider_add_response(provider, false, ..lines)
	if sync.mutex_guard(&provider.mutex) {
		provider.responses[len(provider.responses) - 1].delay = delay
	}
}

// Returns the number of chat requests that the provider received.
fake_provider_request_count :: proc(provider: ^Fake_Provider) -> int {
	sync.mutex_lock(&provider.mutex)
	defer sync.mutex_unlock(&provider.mutex)
	return provider.requestCount
}

// An Ollama stream line with assistant text. done ends the response, with token usage.
fake_provider_text_line :: proc(
	text: string,
	done := false,
	allocator := context.temp_allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, `{"model":"`)
	strings.write_string(&builder, FAKE_PROVIDER_MODEL)
	strings.write_string(&builder, `","message":{"role":"assistant","content":`)
	builtin_tools.write_json_string(&builder, text)
	strings.write_string(&builder, `},"done":`)
	if done {
		strings.write_string(&builder, `true,"prompt_eval_count":12,"eval_count":3}`)
	} else {
		strings.write_string(&builder, `false}`)
	}
	return strings.to_string(builder)
}

// An Ollama stream line with one tool call. argumentsJSON is a JSON object. The call ID is
// "ollama-<n>", where n counts the tool calls of the response from 0.
fake_provider_tool_call_line :: proc(
	toolName: string,
	argumentsJSON: string,
	allocator := context.temp_allocator,
) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, `{"model":"`)
	strings.write_string(&builder, FAKE_PROVIDER_MODEL)
	strings.write_string(
		&builder,
		`","message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":`,
	)
	builtin_tools.write_json_string(&builder, toolName)
	strings.write_string(&builder, `,"arguments":`)
	strings.write_string(&builder, argumentsJSON)
	strings.write_string(&builder, `}}]},"done":false}`)
	return strings.to_string(builder)
}

fake_provider_run :: proc(data: rawptr) {
	provider := cast(^Fake_Provider)data
	for {
		client, _, acceptErr := net.accept_tcp(provider.listener)
		stopping := false
		if sync.mutex_guard(&provider.mutex) {
			stopping = provider.stopping
		}
		if acceptErr != nil || stopping {
			if acceptErr == nil {
				net.close(client)
			}
			return
		}
		fake_provider_answer(provider, client)
		net.close(client)
		free_all(context.temp_allocator)
	}
}

fake_provider_answer :: proc(provider: ^Fake_Provider, client: net.TCP_Socket) {
	if !fake_provider_read_request(client) {
		return
	}
	response := Fake_Response {
		body = fake_provider_text_line("", true, context.temp_allocator),
	}
	responseOwned := false
	if sync.mutex_guard(&provider.mutex) {
		provider.requestCount += 1
		if len(provider.responses) > 0 {
			response = provider.responses[0]
			ordered_remove(&provider.responses, 0)
			responseOwned = true
		}
	}
	defer if responseOwned {
		delete(response.body, provider.allocator)
	}
	if response.delay > 0 {
		time.sleep(response.delay)
	}
	head := "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nConnection: close\r\n\r\n"
	_, _ = net.send_tcp(client, transmute([]byte)head)
	_, _ = net.send_tcp(client, transmute([]byte)response.body)
	if response.holdOpen {
		// Wait until the client closes the connection.
		buffer: [256]byte
		for {
			count, recvErr := net.recv_tcp(client, buffer[:])
			if recvErr != nil || count <= 0 {
				return
			}
		}
	}
}

// Reads the request head and, when a content length is given, the body.
fake_provider_read_request :: proc(client: net.TCP_Socket) -> bool {
	request := make([dynamic]byte, 0, 4096, context.temp_allocator)
	buffer: [4096]byte
	bodyStart := -1
	bodyLength := 0
	for {
		count, recvErr := net.recv_tcp(client, buffer[:])
		if recvErr != nil || count <= 0 {
			return false
		}
		append(&request, ..buffer[:count])
		text := string(request[:])
		if bodyStart == -1 {
			headEnd := strings.index(text, "\r\n\r\n")
			if headEnd == -1 {
				continue
			}
			bodyStart = headEnd + 4
			lower := strings.to_lower(text[:headEnd], context.temp_allocator)
			if index := strings.index(lower, "content-length:"); index != -1 {
				rest := lower[index + len("content-length:"):]
				if lineEnd := strings.index(rest, "\r\n"); lineEnd != -1 {
					rest = rest[:lineEnd]
				}
				bodyLength, _ = strconv.parse_int(strings.trim_space(rest))
			}
		}
		if len(request) - bodyStart >= bodyLength {
			return true
		}
	}
}
