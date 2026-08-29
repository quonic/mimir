package widgets

import console "../console"
import "core:strings"
import "core:time"

// Shared core for the two dropdown-style widgets (Context_Menu, Dropdown_List).
// Both wrap this in a distinct public struct so their `_open` positioning differs
// while sharing highlight/scroll/animation/render/input behavior.

Menu_Item :: struct {
	label:        string,
	disabled:     bool,
	is_separator: bool,
}

Menu_Event :: enum int {
	None = 0,
	Selected,
	Cancelled,
}

Menu_Style :: struct {
	normal:       console.Style,
	highlight:    console.Style,
	highlightSet: bool,
}

MENU_DEFAULT_NORMAL_STYLE :: console.Style {
	foreground     = .White,
	background     = .Black,
	use_foreground = true,
	use_background = true,
}

MENU_ANIMATION_FLIP_COUNT :: 3
MENU_ANIMATION_FLIP_INTERVAL :: 120 * time.Millisecond

Menu_Animation :: struct {
	active:    bool,
	start:     time.Tick,
	flipIndex: int,
}

Dropdown_Core :: struct {
	items:          []Menu_Item,
	highlightIndex: int,
	scrollOffset:   int,
	style:          Menu_Style,
	anim:           Menu_Animation,
	region:         console.Region,
}

// menu_style_highlight returns the caller's highlight style, or the normal
// style with foreground/background swapped when no highlight was set.
menu_style_highlight :: proc(style: Menu_Style) -> console.Style {
	if style.highlightSet {
		return style.highlight
	}
	return console.Style {
		foreground = style.normal.background,
		background = style.normal.foreground,
		use_foreground = style.normal.use_background,
		use_background = style.normal.use_foreground,
		attributes = style.normal.attributes,
	}
}

dropdown_core_init :: proc(items: []Menu_Item, style: Menu_Style) -> Dropdown_Core {
	core := Dropdown_Core {
		items          = items,
		style          = style,
		highlightIndex = -1,
	}
	core.highlightIndex = dropdown_first_selectable(core.items, 0, 1)
	return core
}

dropdown_item_selectable :: proc(item: Menu_Item) -> bool {
	return !item.disabled && !item.is_separator
}

// dropdown_first_selectable walks from `from` in `step` direction (wrapping)
// looking for a selectable item, returning -1 if none exist.
dropdown_first_selectable :: proc(items: []Menu_Item, from, step: int) -> int {
	if len(items) == 0 {
		return -1
	}
	index := from
	for _ in 0 ..< len(items) {
		for index < 0 {
			index += len(items)
		}
		for index >= len(items) {
			index -= len(items)
		}
		if dropdown_item_selectable(items[index]) {
			return index
		}
		index += step
	}
	return -1
}

dropdown_move_highlight :: proc(core: ^Dropdown_Core, delta: int) {
	if len(core.items) == 0 {
		return
	}
	start := core.highlightIndex + delta
	next := dropdown_first_selectable(core.items, start, delta)
	if next >= 0 {
		core.highlightIndex = next
	}
}

dropdown_move_highlight_up :: proc(core: ^Dropdown_Core) {
	dropdown_move_highlight(core, -1)
}

dropdown_move_highlight_down :: proc(core: ^Dropdown_Core) {
	dropdown_move_highlight(core, 1)
}

// dropdown_activate_highlighted starts the selection animation and reports
// Selected immediately; the caller acts on the selection right away and the
// widget keeps rendering the flip animation until dropdown_tick reports done.
dropdown_activate_highlighted :: proc(core: ^Dropdown_Core) -> (Menu_Event, int) {
	if core.highlightIndex < 0 || core.highlightIndex >= len(core.items) {
		return .None, -1
	}
	if !dropdown_item_selectable(core.items[core.highlightIndex]) {
		return .None, -1
	}
	core.anim = Menu_Animation {
		active = true,
		start  = time.tick_now(),
	}
	return .Selected, core.highlightIndex
}

dropdown_cancel :: proc(core: ^Dropdown_Core) -> Menu_Event {
	return .Cancelled
}

dropdown_region_contains :: proc(region: console.Region, row, column: int) -> bool {
	return(
		row >= region.top_row &&
		row <= region.bottom_row &&
		column >= region.left_column &&
		column <= region.right_column \
	)
}

// dropdown_visible_row_count returns how many item rows fit given scrolling.
dropdown_visible_row_count :: proc(core: ^Dropdown_Core) -> int {
	rows := console.region_height(core.region)
	if rows < 0 {
		return 0
	}
	return rows
}

dropdown_ensure_highlight_visible :: proc(core: ^Dropdown_Core) {
	visible := dropdown_visible_row_count(core)
	if visible <= 0 || core.highlightIndex < 0 {
		return
	}
	if core.highlightIndex < core.scrollOffset {
		core.scrollOffset = core.highlightIndex
	} else if core.highlightIndex >= core.scrollOffset + visible {
		core.scrollOffset = core.highlightIndex - visible + 1
	}
	maxOffset := len(core.items) - visible
	if maxOffset < 0 {
		maxOffset = 0
	}
	if core.scrollOffset > maxOffset {
		core.scrollOffset = maxOffset
	}
	if core.scrollOffset < 0 {
		core.scrollOffset = 0
	}
}

dropdown_scroll :: proc(core: ^Dropdown_Core, delta: int) {
	visible := dropdown_visible_row_count(core)
	maxOffset := len(core.items) - visible
	if maxOffset < 0 {
		maxOffset = 0
	}
	core.scrollOffset += delta
	if core.scrollOffset < 0 {
		core.scrollOffset = 0
	}
	if core.scrollOffset > maxOffset {
		core.scrollOffset = maxOffset
	}
}

// dropdown_row_item_index maps an absolute screen row to an item index, or -1.
dropdown_row_item_index :: proc(core: ^Dropdown_Core, row: int) -> int {
	if !dropdown_region_contains(core.region, row, core.region.left_column) {
		return -1
	}
	index := core.scrollOffset + (row - core.region.top_row)
	if index < 0 || index >= len(core.items) {
		return -1
	}
	return index
}

// dropdown_handle_mouse applies the widget's interaction rules:
//   - a Press outside the region cancels the menu
//   - a Release outside the region is ignored (menu stays open untouched)
//   - a Release on a selectable item selects it (starts the flip animation)
//   - Motion inside the region updates the hovered highlight
//   - Wheel scrolls the visible window
dropdown_handle_mouse :: proc(
	core: ^Dropdown_Core,
	event: console.Mouse_Event,
) -> (
	handled: bool,
	menuEvent: Menu_Event,
	selectedIndex: int,
) {
	inside := dropdown_region_contains(core.region, event.row, event.column)

	switch event.kind {
	case .Press:
		if !inside {
			return true, .Cancelled, -1
		}
		return true, .None, -1
	case .Release:
		if !inside {
			return true, .None, -1
		}
		index := dropdown_row_item_index(core, event.row)
		if index < 0 || !dropdown_item_selectable(core.items[index]) {
			return true, .None, -1
		}
		core.highlightIndex = index
		evt, selected := dropdown_activate_highlighted(core)
		return true, evt, selected
	case .Motion:
		if !inside {
			return true, .None, -1
		}
		index := dropdown_row_item_index(core, event.row)
		if index >= 0 && dropdown_item_selectable(core.items[index]) {
			core.highlightIndex = index
		}
		return true, .None, -1
	case .Wheel:
		switch event.button {
		case .Wheel_Up:
			dropdown_scroll(core, -1)
		case .Wheel_Down:
			dropdown_scroll(core, 1)
		case .None, .Left, .Middle, .Right, .Wheel_Left, .Wheel_Right:
		}
		return true, .None, -1
	}
	return true, .None, -1
}

// dropdown_animation_segment converts elapsed animation time into a flip
// index (0=highlighted, 1=normal, 2=highlighted, ...) and whether all flips
// are done. Pulled out of dropdown_tick so it's testable without real delays.
dropdown_animation_segment :: proc(elapsed: time.Duration) -> (flipIndex: int, finished: bool) {
	totalSegments := MENU_ANIMATION_FLIP_COUNT * 2
	segment := int(elapsed / MENU_ANIMATION_FLIP_INTERVAL)
	if segment >= totalSegments {
		return totalSegments, true
	}
	return segment, false
}

// dropdown_tick advances the selection flip animation and reports true once
// it has completed all flips (caller should then pop/close the widget).
dropdown_tick :: proc(core: ^Dropdown_Core) -> bool {
	if !core.anim.active {
		return false
	}
	flipIndex, finished := dropdown_animation_segment(time.tick_since(core.anim.start))
	if finished {
		core.anim.active = false
		return true
	}
	core.anim.flipIndex = flipIndex
	return false
}

dropdown_core_render :: proc(batch: ^console.Batch, core: ^Dropdown_Core) {
	width := console.region_width(core.region)
	if width <= 0 || core.region.top_row > core.region.bottom_row {
		return
	}
	dropdown_ensure_highlight_visible(core)
	visible := dropdown_visible_row_count(core)

	highlightStyle := menu_style_highlight(core.style)
	// during the flip animation, an even segment shows highlight, odd shows normal
	animatingHighlighted := core.anim.active && core.anim.flipIndex % 2 == 0

	for row := 0; row < visible; row += 1 {
		index := core.scrollOffset + row
		if index >= len(core.items) {
			break
		}
		item := core.items[index]
		screenRow := core.region.top_row + row

		style := core.style.normal
		text := dropdown_padded_label(item.label, width)

		if item.is_separator {
			text = strings.repeat("─", width, context.temp_allocator)
		} else if item.disabled {
			style = dropdown_disabled_style(core.style.normal)
		} else if index == core.highlightIndex {
			if core.anim.active {
				style = animatingHighlighted ? highlightStyle : core.style.normal
			} else {
				style = highlightStyle
			}
		}

		console.batch_move_to(batch, screenRow, core.region.left_column)
		console.batch_write_styled_text(batch, style, text)
	}
}

dropdown_disabled_style :: proc(normal: console.Style) -> console.Style {
	attributes := make(
		[]console.Text_Attribute,
		len(normal.attributes) + 1,
		context.temp_allocator,
	)
	copy(attributes, normal.attributes)
	attributes[len(normal.attributes)] = .Dim
	return console.Style {
		foreground = normal.foreground,
		background = normal.background,
		use_foreground = normal.use_foreground,
		use_background = normal.use_background,
		attributes = attributes,
	}
}

dropdown_padded_label :: proc(label: string, width: int) -> string {
	if len(label) >= width {
		return label[:width]
	}
	padding := strings.repeat(" ", width - len(label), context.temp_allocator)
	return strings.concatenate({label, padding}, context.temp_allocator)
}

// dropdown_compute_region self-clamps a menu of `itemCount` rows and `width`
// columns so it never renders off-screen, flipping to the opposite side of
// the anchor when there isn't enough room in the preferred direction.
dropdown_compute_region :: proc(
	anchorRow, anchorColumn, itemCount, width: int,
	openAbove: bool,
	terminal: console.Region,
) -> console.Region {
	height := itemCount
	maxHeight := console.region_height(terminal)
	if height > maxHeight {
		height = maxHeight
	}
	if height < 1 {
		height = 1
	}

	top := anchorRow
	if openAbove {
		top = anchorRow - height
		if top < terminal.top_row {
			top = anchorRow + 1
		}
	} else {
		if anchorRow + height - 1 > terminal.bottom_row {
			top = anchorRow - height
			if top < terminal.top_row {
				top = terminal.top_row
			}
		}
	}
	if top < terminal.top_row {
		top = terminal.top_row
	}
	bottom := top + height - 1
	if bottom > terminal.bottom_row {
		bottom = terminal.bottom_row
		top = bottom - height + 1
		if top < terminal.top_row {
			top = terminal.top_row
		}
	}

	left := anchorColumn
	right := left + width - 1
	if right > terminal.right_column {
		right = terminal.right_column
		left = right - width + 1
		if left < terminal.left_column {
			left = terminal.left_column
		}
	}
	if left < terminal.left_column {
		left = terminal.left_column
	}

	return console.Region {
		top_row = top,
		left_column = left,
		bottom_row = bottom,
		right_column = right,
	}
}

dropdown_menu_width :: proc(items: []Menu_Item) -> int {
	width := 0
	for item in items {
		if len(item.label) > width {
			width = len(item.label)
		}
	}
	return width
}

// Context_Menu opens at a mouse point (e.g. a right-click), flipping to the
// opposite side of the point if it would otherwise overflow the terminal.
Context_Menu :: struct {
	core: Dropdown_Core,
}

context_menu_init :: proc(items: []Menu_Item, style: Menu_Style) -> Context_Menu {
	return Context_Menu{core = dropdown_core_init(items, style)}
}

context_menu_open :: proc(
	menu: ^Context_Menu,
	anchorRow, anchorColumn: int,
	terminal: console.Region,
) {
	width := dropdown_menu_width(menu.core.items)
	openAbove := anchorRow + len(menu.core.items) > terminal.bottom_row
	menu.core.region = dropdown_compute_region(
		anchorRow,
		anchorColumn,
		len(menu.core.items),
		width,
		openAbove,
		terminal,
	)
	menu.core.scrollOffset = 0
}

// Dropdown_List opens directly below an anchor region (e.g. a setting row),
// matching the anchor's width, flipping above it if there isn't enough room.
Dropdown_List :: struct {
	core: Dropdown_Core,
}

dropdown_list_init :: proc(items: []Menu_Item, style: Menu_Style) -> Dropdown_List {
	return Dropdown_List{core = dropdown_core_init(items, style)}
}

dropdown_list_open :: proc(
	list: ^Dropdown_List,
	anchor: console.Region,
	terminal: console.Region,
) {
	width := console.region_width(anchor)
	below := anchor.bottom_row + 1
	openAbove := below + len(list.core.items) > terminal.bottom_row
	anchorRow := openAbove ? anchor.top_row : below
	list.core.region = dropdown_compute_region(
		anchorRow,
		anchor.left_column,
		len(list.core.items),
		width,
		openAbove,
		terminal,
	)
	list.core.scrollOffset = 0
}
