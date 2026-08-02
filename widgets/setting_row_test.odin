package widgets

import "core:testing"

@(test)
test_setting_row_formats_control_labels :: proc(t: ^testing.T) {
	assert(
		setting_row_checkbox("Enabled", true, context.temp_allocator) == "[x] Enabled",
		"expected checked checkbox label",
	)
	assert(
		setting_row_checkbox("Enabled", false, context.temp_allocator) == "[ ] Enabled",
		"expected unchecked checkbox label",
	)
	assert(
		setting_row_button("Refresh models", context.temp_allocator) == "[ Refresh models ]",
		"expected button label",
	)
	assert(
		setting_row_choice("Approval method", "Always ask", context.temp_allocator) ==
		"Approval method: < Always ask >",
		"expected choice label",
	)
	assert(
		setting_row_value("Endpoint", "http://localhost:11434", context.temp_allocator) ==
		"Endpoint: http://localhost:11434",
		"expected value label",
	)
	assert(
		setting_row_option("ollama / chat", true, context.temp_allocator) == "* ollama / chat",
		"expected selected option label",
	)
	assert(
		setting_row_option("ollama / chat", false, context.temp_allocator) == "  ollama / chat",
		"expected unselected option label",
	)
	_ = t
}
