package transport

// HTTP client backed by libcurl (vendor:curl).
//
// Each request uses its own easy handle, so requests on different threads do not
// share state. libcurl decodes chunked transfer encoding and compressed bodies;
// the handlers only see the decoded body bytes.

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import curl "vendor:curl"

// Send a request and read the whole response body.
// The caller owns `body` and must delete it when it is not empty.
request :: proc(
	req: Request,
	allocator := context.allocator,
) -> (
	status: Status,
	body: string,
	err: Error,
) {
	state: Transfer_State
	strings.builder_init(&state.buffer, allocator)

	err = perform(req, &state)
	return state.status, take_buffer(&state.buffer, err == .None), err
}

// Send a request and pass the decoded body of a 2xx response to `handlers.on_data`
// as it arrives. For any other status the body is buffered and returned as
// `errorBody`, which the caller owns.
//
// Returns .Canceled when `on_data` returns false or `should_cancel` returns true.
// libcurl polls `should_cancel` about once per second while the transfer is idle.
request_stream :: proc(
	req: Request,
	handlers: Stream_Handlers,
	allocator := context.allocator,
) -> (
	status: Status,
	errorBody: string,
	err: Error,
) {
	if handlers.on_data == nil {
		return .Unknown, "", .Invalid_Request
	}

	state := Transfer_State {
		handlers  = handlers,
		streaming = true,
	}
	strings.builder_init(&state.buffer, allocator)

	err = perform(req, &state)
	keep := err == .None && !status_is_success(state.status)
	return state.status, take_buffer(&state.buffer, keep), err
}

// Report whether the linked libcurl supports TLS and the https scheme.
tls_supported :: proc() -> bool {
	info := curl.version_info(curl.VERSION_NOW)
	if info == nil || info.features & curl.VERSION_SSL == 0 {
		return false
	}
	for i := 0; info.protocols[i] != nil; i += 1 {
		if info.protocols[i] == "https" {
			return true
		}
	}
	return false
}

// State shared with the libcurl callbacks for one transfer.
@(private)
Transfer_State :: struct {
	ctx:         runtime.Context,
	handle:      ^curl.CURL,
	handlers:    Stream_Handlers,
	// Pass 2xx bodies to handlers.on_data instead of buffering them.
	streaming:   bool,
	statusKnown: bool,
	status:      Status,
	// The whole body for buffered requests, or the error body for streams.
	buffer:      strings.Builder,
	// on_data asked to stop.
	stopped:     bool,
	// should_cancel asked to abort.
	canceled:    bool,
}

@(private)
curlInitOnce: sync.Once
@(private)
curlInitCode: curl.code

@(private)
curl_global_init :: proc() -> bool {
	sync.once_do(&curlInitOnce, proc() {
		curlInitCode = curl.global_init(curl.GLOBAL_ALL)
	})
	return curlInitCode == .E_OK
}

@(private)
perform :: proc(req: Request, state: ^Transfer_State) -> Error {
	if req.target == "" {
		return .Invalid_Request
	}
	if !curl_global_init() {
		return .Network_Error
	}

	handle := curl.easy_init()
	if handle == nil {
		return .Network_Error
	}
	defer curl.easy_cleanup(handle)

	state.ctx = context
	state.handle = handle

	headers: ^curl.slist
	defer if headers != nil {
		curl.slist_free_all(headers)
	}
	for header in req.headers {
		headers = curl.slist_append(headers, fmt.ctprintf("%s: %s", header[0], header[1]))
	}
	// Disable "Expect: 100-continue", which delays large POST bodies.
	headers = curl.slist_append(headers, "Expect:")

	connectSeconds, stallSeconds := get_timeouts()
	if req.connectTimeoutSeconds > 0 {
		connectSeconds = req.connectTimeoutSeconds
	}
	if req.stallTimeoutSeconds > 0 {
		stallSeconds = req.stallTimeoutSeconds
	}

	curl.easy_setopt(handle, .URL, strings.clone_to_cstring(req.target, context.temp_allocator))
	curl.easy_setopt(handle, .HTTPHEADER, headers)
	// Signals are not safe with multiple threads.
	curl.easy_setopt(handle, .NOSIGNAL, c.long(1))
	// An empty string enables every encoding libcurl was built with.
	curl.easy_setopt(handle, .ACCEPT_ENCODING, cstring(""))
	curl.easy_setopt(handle, .CONNECTTIMEOUT, c.long(connectSeconds))
	// Fail when less than 1 byte per second arrives for stallSeconds. A total timeout
	// would cut off long streams.
	curl.easy_setopt(handle, .LOW_SPEED_LIMIT, c.long(1))
	curl.easy_setopt(handle, .LOW_SPEED_TIME, c.long(stallSeconds))
	curl.easy_setopt(handle, .WRITEFUNCTION, transfer_write)
	curl.easy_setopt(handle, .WRITEDATA, rawptr(state))
	curl.easy_setopt(handle, .NOPROGRESS, c.long(0))
	curl.easy_setopt(handle, .XFERINFOFUNCTION, transfer_progress)
	curl.easy_setopt(handle, .XFERINFODATA, rawptr(state))

	switch req.method {
	case .Get:
		curl.easy_setopt(handle, .HTTPGET, c.long(1))
	case .Post:
		curl.easy_setopt(handle, .POST, c.long(1))
		curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(len(req.body)))
		// A nil POSTFIELDS makes libcurl read the body from stdin.
		if len(req.body) > 0 {
			curl.easy_setopt(handle, .POSTFIELDS, rawptr(raw_data(req.body)))
		} else {
			curl.easy_setopt(handle, .POSTFIELDS, cstring(""))
		}
	}

	code := curl.easy_perform(handle)
	if !state.statusKnown {
		read_status(state)
	}

	#partial switch code {
	case .E_OK:
		return .None
	case .E_WRITE_ERROR:
		return .Canceled if state.stopped else .Network_Error
	case .E_ABORTED_BY_CALLBACK:
		return .Canceled if state.canceled else .Network_Error
	case .E_OPERATION_TIMEDOUT:
		return .Timeout
	case .E_URL_MALFORMAT, .E_UNSUPPORTED_PROTOCOL:
		return .Invalid_Request
	case .E_BAD_CONTENT_ENCODING:
		return .Invalid_Response
	}
	return .Network_Error
}

@(private)
read_status :: proc(state: ^Transfer_State) {
	code: c.long
	if curl.easy_getinfo(state.handle, .RESPONSE_CODE, &code) == .E_OK {
		state.status = Status(code)
	}
	state.statusKnown = true
}

@(private)
transfer_write :: proc "c" (
	data: [^]byte,
	size: c.size_t,
	count: c.size_t,
	user: rawptr,
) -> c.size_t {
	state := cast(^Transfer_State)user
	context = state.ctx

	n := int(size * count)
	if !state.statusKnown {
		read_status(state)
	}
	if n == 0 {
		return 0
	}

	chunk := string(data[:n])
	if state.streaming && status_is_success(state.status) {
		if !state.handlers.on_data(chunk, state.handlers.user) {
			state.stopped = true
			return 0
		}
		return c.size_t(n)
	}

	strings.write_string(&state.buffer, chunk)
	return c.size_t(n)
}

@(private)
transfer_progress :: proc "c" (
	user: rawptr,
	downloadTotal: curl.off_t,
	downloadNow: curl.off_t,
	uploadTotal: curl.off_t,
	uploadNow: curl.off_t,
) -> c.int {
	state := cast(^Transfer_State)user
	context = state.ctx

	if state.handlers.should_cancel != nil && state.handlers.should_cancel(state.handlers.user) {
		state.canceled = true
		return 1
	}
	return 0
}

// Return the builder's contents as an owned string, or free them and return "".
@(private)
take_buffer :: proc(buffer: ^strings.Builder, keep: bool) -> string {
	if keep && strings.builder_len(buffer^) > 0 {
		return strings.to_string(buffer^)
	}
	strings.builder_destroy(buffer)
	return ""
}
