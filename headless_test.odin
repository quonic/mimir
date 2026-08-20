package main

import json "core:encoding/json"
import "core:testing"
import "settings"

@(test)
test_headless_parse_request_reads_id_and_action :: proc(t: ^testing.T) {
	request, message, ok := headless_parse_request(
		`{"id":"1","action":"get_history"}`,
		context.allocator,
	)
	defer headless_request_destroy(&request, context.allocator)

	assert(ok, "expected request to parse")
	assert(message == "", "expected no parse error message")
	assert(request.hasID, "expected request id to be present")
	assert(request.id == "1", "expected id to round-trip")
	assert(request.action == "get_history", "expected action to round-trip")
	_ = t
}

@(test)
test_headless_parse_request_rejects_missing_action :: proc(t: ^testing.T) {
	request, message, ok := headless_parse_request(`{"id":"1"}`, context.allocator)
	defer headless_request_destroy(&request, context.allocator)

	assert(!ok, "expected missing action to fail")
	assert(message == "missing action", "expected missing action error")
	_ = t
}

@(test)
test_headless_config_scalar_get_set :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		headless_set_config_value(&state, "approvalMethod", json.String("approveAll")),
		"expected approval method set to succeed",
	)
	assert(
		state.config.approvalMethod == settings.Approval_Method.Approve_All,
		"expected approval method to update",
	)

	value, ok := headless_config_value(&state, "approvalMethod", context.temp_allocator)
	assert(ok, "expected approval method path to read")
	assert(value.(json.String) == "approveAll", "expected approval method to round-trip")

	assert(
		headless_set_config_value(&state, "toolContinuations", json.Integer(42)),
		"expected tool continuation set to succeed",
	)
	assert(state.config.toolContinuations == 42, "expected tool continuation value to update")
	_ = t
}

@(test)
test_headless_config_rejects_unknown_path_and_bad_value :: proc(t: ^testing.T) {
	state := app_init(context.allocator)
	defer app_destroy(&state)

	assert(
		!headless_set_config_value(&state, "wat", json.String("value")),
		"expected unknown path to fail",
	)
	assert(
		!headless_set_config_value(&state, "approvalMethod", json.String("wat")),
		"expected invalid approval method to fail",
	)
	assert(
		!headless_set_config_value(&state, "toolContinuations", json.Integer(-1)),
		"expected negative tool continuation value to fail",
	)
	_ = t
}
