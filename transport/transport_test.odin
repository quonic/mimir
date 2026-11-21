package transport

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

// A one-shot HTTP server on the loopback interface. It accepts one connection,
// records the request, sends `parts` in order with a short pause between them,
// waits `holdOpen`, then closes the connection.
Test_Server :: struct {
	listener: net.TCP_Socket,
	port:     int,
	parts:    []string,
	holdOpen: time.Duration,
	request:  [dynamic]byte,
	worker:   ^thread.Thread,
}

test_server_start :: proc(server: ^Test_Server, parts: []string, holdOpen := time.Duration(0)) {
	listener, listenErr := net.listen_tcp(
		net.Endpoint{address = net.IP4_Loopback, port = 0},
		backlog = 1,
	)
	assert(listenErr == nil, fmt.tprintf("expected loopback listener, got %v", listenErr))
	endpoint, endpointErr := net.bound_endpoint(listener)
	assert(endpointErr == nil, fmt.tprintf("expected bound endpoint, got %v", endpointErr))

	server.listener = listener
	server.port = endpoint.port
	server.parts = parts
	server.holdOpen = holdOpen
	server.worker = thread.create_and_start_with_data(
		server,
		test_server_run,
		init_context = context,
	)
}

test_server_run :: proc(data: rawptr) {
	server := cast(^Test_Server)data
	client, _, acceptErr := net.accept_tcp(server.listener)
	if acceptErr != nil {
		return
	}
	defer net.close(client)

	test_server_read_request(server, client)

	for part, index in server.parts {
		if index > 0 {
			time.sleep(5 * time.Millisecond)
		}
		_, _ = net.send_tcp(client, transmute([]byte)part)
	}
	if server.holdOpen > 0 {
		time.sleep(server.holdOpen)
	}
}

// Read the request head and, if a content-length is given, the body.
test_server_read_request :: proc(server: ^Test_Server, client: net.TCP_Socket) {
	buf: [4096]byte
	bodyStart := -1
	bodyLength := 0
	for {
		n, recvErr := net.recv_tcp(client, buf[:])
		if recvErr != nil || n == 0 {
			return
		}
		append(&server.request, ..buf[:n])

		text := string(server.request[:])
		if bodyStart == -1 {
			headEnd := strings.index(text, "\r\n\r\n")
			if headEnd == -1 {
				continue
			}
			bodyStart = headEnd + 4
			lower := strings.to_lower(text[:headEnd], context.temp_allocator)
			if i := strings.index(lower, "content-length:"); i != -1 {
				rest := lower[i + len("content-length:"):]
				if lineEnd := strings.index(rest, "\r\n"); lineEnd != -1 {
					rest = rest[:lineEnd]
				}
				bodyLength, _ = strconv.parse_int(strings.trim_space(rest))
			}
		}
		if len(server.request) - bodyStart >= bodyLength {
			return
		}
	}
}

test_server_stop :: proc(server: ^Test_Server) {
	thread.join(server.worker)
	thread.destroy(server.worker)
	net.close(server.listener)
	delete(server.request)
}

test_server_url :: proc(server: ^Test_Server, path: string) -> string {
	return fmt.tprintf("http://127.0.0.1:%d%s", server.port, path)
}

// Collects stream chunks. Stops after `stopAfter` chunks when it is above zero.
Test_Collector :: struct {
	builder:   strings.Builder,
	chunks:    int,
	stopAfter: int,
}

test_collect_chunk :: proc(chunk: string, user: rawptr) -> bool {
	collector := cast(^Test_Collector)user
	strings.write_string(&collector.builder, chunk)
	collector.chunks += 1
	return collector.stopAfter <= 0 || collector.chunks < collector.stopAfter
}

@(test)
test_url_parse :: proc(t: ^testing.T) {
	full := url_parse("https://api.example.test:8443/v1/models?limit=5")
	assert(full.scheme == "https", fmt.tprintf("expected https scheme, got %q", full.scheme))
	assert(
		full.host == "api.example.test:8443",
		fmt.tprintf("expected host with port, got %q", full.host),
	)
	assert(full.path == "/v1/models", fmt.tprintf("expected /v1/models path, got %q", full.path))
	assert(full.query == "limit=5", fmt.tprintf("expected limit=5 query, got %q", full.query))

	bare := url_parse("http://localhost:11434")
	assert(bare.host == "localhost:11434", fmt.tprintf("expected host, got %q", bare.host))
	assert(bare.path == "", fmt.tprintf("expected empty path, got %q", bare.path))

	trailing := url_parse("http://localhost:11434/v1/")
	assert(trailing.path == "/v1/", fmt.tprintf("expected /v1/ path, got %q", trailing.path))
	assert(trailing.raw == "http://localhost:11434/v1/", "expected raw URL to be kept")

	noScheme := url_parse("localhost:11434")
	assert(noScheme.scheme == "", fmt.tprintf("expected no scheme, got %q", noScheme.scheme))
	assert(noScheme.host == "localhost:11434", fmt.tprintf("expected host, got %q", noScheme.host))
	_ = t
}

@(test)
test_status_classes :: proc(t: ^testing.T) {
	assert(status_is_success(.OK), "expected 200 to be success")
	assert(status_is_success(Status(299)), "expected 299 to be success")
	assert(!status_is_success(Status(300)), "expected 300 not to be success")
	assert(status_is_client_error(.Unauthorized), "expected 401 to be a client error")
	assert(!status_is_client_error(Status(500)), "expected 500 not to be a client error")
	assert(status_is_server_error(Status(503)), "expected 503 to be a server error")
	assert(!status_is_server_error(Status(600)), "expected 600 not to be a server error")
	_ = t
}

@(test)
test_set_timeouts_defaults_non_positive_values :: proc(t: ^testing.T) {
	connect, stall := get_timeouts()
	defer set_timeouts(connect, stall)

	set_timeouts(0, -1)
	gotConnect, gotStall := get_timeouts()
	assert(
		gotConnect == DEFAULT_CONNECT_TIMEOUT_SECONDS,
		fmt.tprintf("expected default connect timeout, got %d", gotConnect),
	)
	assert(
		gotStall == DEFAULT_STALL_TIMEOUT_SECONDS,
		fmt.tprintf("expected default stall timeout, got %d", gotStall),
	)
	_ = t
}

@(test)
test_request_buffered_post :: proc(t: ^testing.T) {
	server: Test_Server
	test_server_start(
		&server,
		[]string{"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nContent-Type: application/json\r\n\r\n",
			`{"ok":true}`},
	)
	defer test_server_stop(&server)

	payload := `{"model":"m"}`
	status, body, err := request(
		Request {
			method = .Post,
			target = test_server_url(&server, "/v1/chat"),
			headers = [][2]string{{"x-test", "yes"}, {"content-type", "application/json"}},
			body = transmute([]byte)payload,
		},
	)
	defer if body != "" {delete(body)}

	// The server read the whole request before it replied, so the capture is complete.
	assert(err == .None, fmt.tprintf("expected no error, got %v", err))
	assert(status == .OK, fmt.tprintf("expected 200 status, got %d", int(status)))
	assert(body == `{"ok":true}`, fmt.tprintf("expected JSON body, got %q", body))

	sent := strings.to_lower(string(server.request[:]), context.temp_allocator)
	assert(
		strings.has_prefix(sent, "post /v1/chat http/1.1\r\n"),
		fmt.tprintf("expected POST request line, got %q", sent),
	)
	assert(strings.contains(sent, "x-test: yes\r\n"), "expected custom header to be sent")
	assert(strings.has_suffix(sent, payload), "expected JSON payload to be sent")
	_ = t
}

@(test)
test_request_stream_chunked :: proc(t: ^testing.T) {
	server: Test_Server
	test_server_start(
		&server,
		[]string {
			"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
			"5\r\nhello\r\n",
			"6\r\n world\r\n",
			"0\r\n\r\n",
		},
	)
	defer test_server_stop(&server)

	collector: Test_Collector
	strings.builder_init(&collector.builder)
	defer strings.builder_destroy(&collector.builder)

	status, errorBody, err := request_stream(
		Request{method = .Post, target = test_server_url(&server, "/stream")},
		Stream_Handlers{on_data = test_collect_chunk, user = &collector},
	)
	defer if errorBody != "" {delete(errorBody)}

	collected := strings.to_string(collector.builder)
	assert(err == .None, fmt.tprintf("expected no error, got %v", err))
	assert(status == .OK, fmt.tprintf("expected 200 status, got %d", int(status)))
	assert(collected == "hello world", fmt.tprintf("expected decoded body, got %q", collected))
	assert(errorBody == "", "expected no error body for a 2xx stream")
	_ = t
}

@(test)
test_request_stream_content_length :: proc(t: ^testing.T) {
	server: Test_Server
	test_server_start(
		&server,
		[]string {
			"HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n",
			"{\"a\":1}\n",
			"{\"b\"}",
		},
	)
	defer test_server_stop(&server)

	collector: Test_Collector
	strings.builder_init(&collector.builder)
	defer strings.builder_destroy(&collector.builder)

	status, errorBody, err := request_stream(
		Request{method = .Post, target = test_server_url(&server, "/stream")},
		Stream_Handlers{on_data = test_collect_chunk, user = &collector},
	)
	defer if errorBody != "" {delete(errorBody)}

	collected := strings.to_string(collector.builder)
	assert(err == .None, fmt.tprintf("expected no error, got %v", err))
	assert(status == .OK, fmt.tprintf("expected 200 status, got %d", int(status)))
	assert(
		collected == "{\"a\":1}\n{\"b\"}",
		fmt.tprintf("expected full body, got %q", collected),
	)
	_ = t
}

@(test)
test_request_stream_error_status_returns_body :: proc(t: ^testing.T) {
	server: Test_Server
	test_server_start(
		&server,
		[]string{"HTTP/1.1 401 Unauthorized\r\nContent-Length: 13\r\n\r\n", `{"error":"x"}`},
	)
	defer test_server_stop(&server)

	collector: Test_Collector
	strings.builder_init(&collector.builder)
	defer strings.builder_destroy(&collector.builder)

	status, errorBody, err := request_stream(
		Request{method = .Post, target = test_server_url(&server, "/stream")},
		Stream_Handlers{on_data = test_collect_chunk, user = &collector},
	)
	defer if errorBody != "" {delete(errorBody)}

	assert(err == .None, fmt.tprintf("expected no transport error, got %v", err))
	assert(status == .Unauthorized, fmt.tprintf("expected 401 status, got %d", int(status)))
	assert(errorBody == `{"error":"x"}`, fmt.tprintf("expected error body, got %q", errorBody))
	assert(collector.chunks == 0, "expected no stream chunks for an error status")
	_ = t
}

@(test)
test_request_stream_stops_when_handler_returns_false :: proc(t: ^testing.T) {
	server: Test_Server
	test_server_start(
		&server,
		[]string {
			"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n",
			"5\r\nfirst\r\n",
			"6\r\nsecond\r\n",
			"0\r\n\r\n",
		},
	)
	defer test_server_stop(&server)

	collector := Test_Collector {
		stopAfter = 1,
	}
	strings.builder_init(&collector.builder)
	defer strings.builder_destroy(&collector.builder)

	_, errorBody, err := request_stream(
		Request{method = .Post, target = test_server_url(&server, "/stream")},
		Stream_Handlers{on_data = test_collect_chunk, user = &collector},
	)
	defer if errorBody != "" {delete(errorBody)}

	collected := strings.to_string(collector.builder)
	assert(err == .Canceled, fmt.tprintf("expected Canceled, got %v", err))
	assert(collector.chunks == 1, fmt.tprintf("expected one chunk, got %d", collector.chunks))
	assert(collected == "first", fmt.tprintf("expected first chunk only, got %q", collected))
	_ = t
}

@(test)
test_request_connection_refused_is_network_error :: proc(t: ^testing.T) {
	listener, listenErr := net.listen_tcp(
		net.Endpoint{address = net.IP4_Loopback, port = 0},
		backlog = 1,
	)
	assert(listenErr == nil, "expected loopback listener")
	endpoint, _ := net.bound_endpoint(listener)
	net.close(listener)

	status, body, err := request(
		Request {
			method = .Get,
			target = fmt.tprintf("http://127.0.0.1:%d/", endpoint.port),
		},
	)
	defer if body != "" {delete(body)}

	assert(err == .Network_Error, fmt.tprintf("expected Network_Error, got %v", err))
	assert(status == .Unknown, fmt.tprintf("expected unknown status, got %d", int(status)))
	_ = t
}

@(test)
test_tls_supported :: proc(t: ^testing.T) {
	assert(tls_supported(), "expected the linked libcurl to support TLS and https")
	_ = t
}

@(test)
test_request_stream_stall_timeout :: proc(t: ^testing.T) {
	server: Test_Server
	// Send the response head, then nothing until well after the stall timeout.
	test_server_start(
		&server,
		[]string{"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"},
		holdOpen = 4 * time.Second,
	)
	defer test_server_stop(&server)

	collector: Test_Collector
	strings.builder_init(&collector.builder)
	defer strings.builder_destroy(&collector.builder)

	start := time.tick_now()
	_, errorBody, err := request_stream(
		Request {
			method = .Post,
			target = test_server_url(&server, "/stream"),
			stallTimeoutSeconds = 1,
		},
		Stream_Handlers{on_data = test_collect_chunk, user = &collector},
	)
	defer if errorBody != "" {delete(errorBody)}
	elapsed := time.tick_since(start)

	assert(err == .Timeout, fmt.tprintf("expected Timeout, got %v", err))
	assert(
		elapsed < 3 * time.Second,
		fmt.tprintf("expected the stall timeout to fire within 3s, took %v", elapsed),
	)
	_ = t
}

// Cancels once the first chunk has arrived.
test_cancel_after_first_chunk :: proc(user: rawptr) -> bool {
	collector := cast(^Test_Collector)user
	return collector.chunks >= 1
}

@(test)
test_request_stream_cancel_while_idle :: proc(t: ^testing.T) {
	server: Test_Server
	// Send one chunk, then keep the connection open without sending more.
	test_server_start(
		&server,
		[]string{"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", "5\r\nfirst\r\n"},
		holdOpen = 4 * time.Second,
	)
	defer test_server_stop(&server)

	collector: Test_Collector
	strings.builder_init(&collector.builder)
	defer strings.builder_destroy(&collector.builder)

	start := time.tick_now()
	_, errorBody, err := request_stream(
		Request{method = .Post, target = test_server_url(&server, "/stream")},
		Stream_Handlers {
			on_data = test_collect_chunk,
			should_cancel = test_cancel_after_first_chunk,
			user = &collector,
		},
	)
	defer if errorBody != "" {delete(errorBody)}
	elapsed := time.tick_since(start)

	collected := strings.to_string(collector.builder)
	assert(err == .Canceled, fmt.tprintf("expected Canceled, got %v", err))
	assert(collected == "first", fmt.tprintf("expected first chunk, got %q", collected))
	assert(
		elapsed < 2500 * time.Millisecond,
		fmt.tprintf("expected cancel without waiting for more data, took %v", elapsed),
	)
	_ = t
}
