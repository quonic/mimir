# 0001: Use libcurl (vendor:curl) for HTTP

- Status: Accepted
- Date: 2026-11-21

## Context

Mimir sent provider requests through odin-http (laytan/odin-http), included as
a git submodule. Two problems made it hard to keep:

- New Odin compilers broke it, and fixes reached the submodule slowly. With
  `dev-2026-11`, odin-http no longer compiles, because `json.marshal_to_writer`
  now takes its options by value.
- It binds OpenSSL directly and asserts version 3.x at startup, so it aborts on
  systems with OpenSSL 4.
- Its client streams the response through a private scanner (`Response._body`).
  Mimir decoded chunked transfer encoding by hand on top of that scanner.
- It could not abort a request in progress, so `/stop` waited for the next
  chunk.

Odin's core library has no TLS, so an HTTP client written only with `core:net`
would still need its own TLS bindings.

## Decision

Use libcurl through Odin's `vendor:curl` package. All HTTP traffic goes through
the `transport` package (`transport/`), which is the only package that imports
`vendor:curl`. The `ai` package uses only the `transport` types and procedures.

- Each request uses its own easy handle, so requests on different threads do
  not share state.
- libcurl handles chunked encoding, compression and TLS. Stream handlers
  receive decoded body bytes.
- A progress callback polls for cancellation, so `/stop` aborts a request
  within about one second.
- `connectTimeoutSeconds` and `stallTimeoutSeconds` map to libcurl's connect
  timeout and low-speed limit. Mimir sets no total transfer timeout, so long
  streams are not cut off.

## Consequences

- `vendor:curl` ships with the Odin compiler, so the HTTP layer stays in step
  with the compiler.
- Linux builds need the libcurl development package, and Linux binaries link
  `libcurl.so.4` at runtime. Windows links the static libcurl that ships with
  Odin, which uses Schannel for TLS.
- The odin-http submodule is removed. Anyone building from source must install
  libcurl headers on Linux. A clone no longer needs `--recursive`.
- libcurl options are set through a C varargs call. Option values must have the
  exact C type, for example `c.long` for numbers. The compiler does not check
  this.
