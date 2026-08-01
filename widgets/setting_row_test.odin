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
	_ = t
}
