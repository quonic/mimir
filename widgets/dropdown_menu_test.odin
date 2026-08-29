package widgets

import console "../console"
import "core:strings"
import "core:testing"
import "core:time"

test_menu_items :: proc() -> []Menu_Item {
	items := make([]Menu_Item, 5, context.temp_allocator)
	items[0] = Menu_Item {
		label = "Copy",
	}
	items[1] = Menu_Item {
		label = "Paste",
	}
	items[2] = Menu_Item {
		is_separator = true,
	}
	items[3] = Menu_Item {
		label    = "Cut",
		disabled = true,
	}
	items[4] = Menu_Item {
		label = "Delete",
	}
	return items
}

@(test)
test_dropdown_core_init_highlights_first_selectable :: proc(t: ^testing.T) {
	core := dropdown_core_init(test_menu_items(), Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	assert(core.highlightIndex == 0, "expected first selectable item to be highlighted")
	_ = t
}

@(test)
test_dropdown_move_highlight_skips_separators_and_disabled :: proc(t: ^testing.T) {
	core := dropdown_core_init(test_menu_items(), Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	dropdown_move_highlight_down(&core) // Copy -> Paste
	assert(core.highlightIndex == 1, "expected highlight to move to Paste")
	dropdown_move_highlight_down(&core) // Paste -> skip separator, skip disabled Cut -> Delete
	assert(core.highlightIndex == 4, "expected highlight to skip separator and disabled item")
	dropdown_move_highlight_down(&core) // wraps back to Copy
	assert(core.highlightIndex == 0, "expected highlight to wrap to first selectable item")
	_ = t
}

@(test)
test_dropdown_mouse_press_outside_cancels :: proc(t: ^testing.T) {
	core := dropdown_core_init(test_menu_items(), Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	core.region = console.Region {
		top_row      = 5,
		left_column  = 5,
		bottom_row   = 9,
		right_column = 15,
	}

	handled, evt, _ := dropdown_handle_mouse(
		&core,
		console.Mouse_Event{row = 1, column = 1, kind = .Press},
	)
	assert(handled, "expected outside press to be handled")
	assert(evt == .Cancelled, "expected outside press to cancel the menu")
	_ = t
}

@(test)
test_dropdown_mouse_release_off_item_is_noop :: proc(t: ^testing.T) {
	core := dropdown_core_init(test_menu_items(), Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	core.region = console.Region {
		top_row      = 5,
		left_column  = 5,
		bottom_row   = 9,
		right_column = 15,
	}

	handled, evt, _ := dropdown_handle_mouse(
		&core,
		console.Mouse_Event{row = 1, column = 1, kind = .Release},
	)
	assert(handled, "expected outside release to be handled")
	assert(evt == .None, "expected outside release to leave the menu open untouched")
	_ = t
}

@(test)
test_dropdown_mouse_release_on_item_selects_and_starts_animation :: proc(t: ^testing.T) {
	core := dropdown_core_init(test_menu_items(), Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	core.region = console.Region {
		top_row      = 5,
		left_column  = 5,
		bottom_row   = 9,
		right_column = 15,
	}

	handled, evt, index := dropdown_handle_mouse(
	&core,
	console.Mouse_Event{row = 6, column = 6, kind = .Release}, // second row -> Paste
	)
	assert(handled, "expected release on item to be handled")
	assert(evt == .Selected, "expected release on selectable item to select it")
	assert(index == 1, "expected the Paste item to be selected")
	assert(core.anim.active, "expected selection to start the flip animation")
	_ = t
}

@(test)
test_dropdown_mouse_release_on_disabled_item_is_noop :: proc(t: ^testing.T) {
	core := dropdown_core_init(test_menu_items(), Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	core.region = console.Region {
		top_row      = 5,
		left_column  = 5,
		bottom_row   = 9,
		right_column = 15,
	}

	// row 8 -> index 3 -> disabled "Cut"
	handled, evt, _ := dropdown_handle_mouse(
		&core,
		console.Mouse_Event{row = 8, column = 6, kind = .Release},
	)
	assert(handled, "expected release on disabled item to be handled")
	assert(evt == .None, "expected release on a disabled item to be a no-op")
	_ = t
}

@(test)
test_dropdown_animation_segment_flips_three_times_then_finishes :: proc(t: ^testing.T) {
	flip0, done0 := dropdown_animation_segment(0)
	assert(flip0 == 0 && !done0, "expected animation to start on the highlighted flip")

	flip1, done1 := dropdown_animation_segment(MENU_ANIMATION_FLIP_INTERVAL)
	assert(flip1 == 1 && !done1, "expected animation to flip to normal after one interval")

	_, doneEnd := dropdown_animation_segment(
		MENU_ANIMATION_FLIP_COUNT * 2 * MENU_ANIMATION_FLIP_INTERVAL,
	)
	assert(doneEnd, "expected animation to finish after 3 full flips")
	_ = t
}

@(test)
test_dropdown_scroll_clamps_to_item_bounds :: proc(t: ^testing.T) {
	core := dropdown_core_init(test_menu_items(), Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	core.region = console.Region {
		top_row      = 1,
		left_column  = 1,
		bottom_row   = 2,
		right_column = 10,
	} 	// 2 visible rows

	dropdown_scroll(&core, -5)
	assert(core.scrollOffset == 0, "expected scroll to clamp at zero")

	dropdown_scroll(&core, 100)
	assert(core.scrollOffset == len(core.items) - 2, "expected scroll to clamp at max offset")
	_ = t
}

@(test)
test_dropdown_default_style_is_white_on_black_with_inverted_highlight :: proc(t: ^testing.T) {
	style := Menu_Style {
		normal = MENU_DEFAULT_NORMAL_STYLE,
	}
	highlight := menu_style_highlight(style)
	assert(
		highlight.foreground == .Black,
		"expected highlight foreground to be normal's background",
	)
	assert(
		highlight.background == .White,
		"expected highlight background to be normal's foreground",
	)
	_ = t
}

@(test)
test_dropdown_core_render_writes_items_and_highlight :: proc(t: ^testing.T) {
	items := make([]Menu_Item, 2, context.temp_allocator)
	items[0] = Menu_Item {
		label = "Item 1",
	}
	items[1] = Menu_Item {
		label = "Item 2",
	}

	core := dropdown_core_init(items, Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	core.region = console.Region {
		top_row      = 1,
		left_column  = 1,
		bottom_row   = 2,
		right_column = 10,
	}
	core.highlightIndex = 1

	batch := console.batch_init(context.temp_allocator)
	defer console.batch_destroy(&batch)
	dropdown_core_render(&batch, &core)

	sequence := console.batch_sequence(&batch)
	assert(strings.contains(sequence, "Item 1"), "expected first item label to be written")
	assert(strings.contains(sequence, "Item 2"), "expected second item label to be written")
	_ = t
}

@(test)
test_context_menu_open_clamps_to_terminal_bounds :: proc(t: ^testing.T) {
	items := make([]Menu_Item, 3, context.temp_allocator)
	items[0] = Menu_Item {
		label = "Copy",
	}
	items[1] = Menu_Item {
		label = "Paste",
	}
	items[2] = Menu_Item {
		label = "Cut",
	}

	menu := context_menu_init(items, Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	terminal := console.Region {
		top_row      = 1,
		left_column  = 1,
		bottom_row   = 24,
		right_column = 80,
	}

	// anchor near the bottom edge should flip the menu upward to stay on screen
	context_menu_open(&menu, 23, 5, terminal)
	assert(
		menu.core.region.bottom_row <= terminal.bottom_row,
		"expected menu to stay within terminal bottom edge",
	)
	assert(
		menu.core.region.top_row >= terminal.top_row,
		"expected menu to stay within terminal top edge",
	)
	_ = t
}

@(test)
test_dropdown_list_open_matches_anchor_width_below_anchor :: proc(t: ^testing.T) {
	items := make([]Menu_Item, 2, context.temp_allocator)
	items[0] = Menu_Item {
		label = "A",
	}
	items[1] = Menu_Item {
		label = "B",
	}

	list := dropdown_list_init(items, Menu_Style{normal = MENU_DEFAULT_NORMAL_STYLE})
	terminal := console.Region {
		top_row      = 1,
		left_column  = 1,
		bottom_row   = 24,
		right_column = 80,
	}
	anchor := console.Region {
		top_row      = 5,
		left_column  = 10,
		bottom_row   = 5,
		right_column = 20,
	}

	dropdown_list_open(&list, anchor, terminal)
	assert(
		list.core.region.top_row == 6,
		"expected dropdown list to open directly below the anchor",
	)
	assert(
		list.core.region.left_column == 10,
		"expected dropdown list to align with the anchor's left edge",
	)
	_ = t
}
