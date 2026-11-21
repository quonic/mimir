package transport

// Package transport is Mimir's HTTP client layer. The rest of the codebase talks to
// HTTP endpoints only through this package, so the backing library can change
// without touching the AI protocol code.

import "core:strings"
import "core:sync"

// A parsed URL. All fields are views into `raw`.
URL :: struct {
	raw:    string,
	scheme: string,
	// Host including the port, if one was given (for example "localhost:11434").
	host:   string,
	path:   string,
	query:  string,
}

// Parse a URL of the form `scheme://host[:port][/path][?query]`.
// Missing parts are left empty. The result borrows from `raw`.
url_parse :: proc(raw: string) -> (url: URL) {
	url.raw = raw
	s := raw

	// The query may contain ':' and '/', so split it off first.
	if i := strings.index_byte(s, '?'); i != -1 {
		url.query = s[i + 1:]
		s = s[:i]
	}

	if i := strings.index(s, "://"); i >= 0 {
		url.scheme = s[:i]
		s = s[i + 3:]
	}

	if i := strings.index_byte(s, '/'); i == -1 {
		url.host = s
	} else {
		url.host = s[:i]
		url.path = s[i:]
	}

	return
}

// HTTP status code. Values without a name are still valid.
Status :: enum int {
	Unknown           = 0,
	OK                = 200,
	Bad_Request       = 400,
	Unauthorized      = 401,
	Forbidden         = 403,
	Not_Found         = 404,
	Too_Many_Requests = 429,
	Internal_Error    = 500,
	Bad_Gateway       = 502,
	Unavailable       = 503,
}

status_is_success :: proc(status: Status) -> bool {
	return status >= Status(200) && status < Status(300)
}

status_is_client_error :: proc(status: Status) -> bool {
	return status >= Status(400) && status < Status(500)
}

status_is_server_error :: proc(status: Status) -> bool {
	return status >= Status(500) && status < Status(600)
}

Method :: enum {
	Get,
	Post,
}

Error :: enum {
	None,
	// The request could not be built or sent as given.
	Invalid_Request,
	// Connecting, sending, or receiving failed.
	Network_Error,
	// The response could not be read or decoded.
	Invalid_Response,
	// The connect or stall timeout expired.
	Timeout,
	// The caller stopped the transfer through a stream handler.
	Canceled,
}

Request :: struct {
	method:  Method,
	target:  string,
	// Header name/value pairs, sent as given. Use lowercase names.
	headers: [][2]string,
	body:    []byte,
	// Per-request overrides for set_timeouts. 0 uses the global value.
	connectTimeoutSeconds: int,
	stallTimeoutSeconds:   int,
}

// Receives one decoded piece of a 2xx response body. Return false to stop the transfer.
Stream_Data_Proc :: #type proc(chunk: string, user: rawptr) -> bool

// Polled during the transfer. Return true to abort it.
Stream_Cancel_Proc :: #type proc(user: rawptr) -> bool

Stream_Handlers :: struct {
	on_data:       Stream_Data_Proc,
	// Optional.
	should_cancel: Stream_Cancel_Proc,
	user:          rawptr,
}

DEFAULT_CONNECT_TIMEOUT_SECONDS :: 30
DEFAULT_STALL_TIMEOUT_SECONDS :: 300

@(private)
connectTimeoutSeconds: int = DEFAULT_CONNECT_TIMEOUT_SECONDS
@(private)
stallTimeoutSeconds: int = DEFAULT_STALL_TIMEOUT_SECONDS

// Set the timeouts used by later requests. A value of 0 or less selects the default.
// `stallSeconds` is how long a transfer may receive no data before it fails.
set_timeouts :: proc(connectSeconds: int, stallSeconds: int) {
	connect := connectSeconds if connectSeconds > 0 else DEFAULT_CONNECT_TIMEOUT_SECONDS
	stall := stallSeconds if stallSeconds > 0 else DEFAULT_STALL_TIMEOUT_SECONDS
	sync.atomic_store(&connectTimeoutSeconds, connect)
	sync.atomic_store(&stallTimeoutSeconds, stall)
}

get_timeouts :: proc() -> (connectSeconds: int, stallSeconds: int) {
	return sync.atomic_load(&connectTimeoutSeconds), sync.atomic_load(&stallTimeoutSeconds)
}
