package main

import "console"
import "core:fmt"
import "core:strings"

MIN_HISTORY_PANEL_HEIGHT :: 3
MIN_INPUT_PANEL_HEIGHT :: 3

App_Layout :: struct {
	historyPanel: console.Region,
	inputPanel:   console.Region,
	statusBar:    console.Region,
}

HISTORY_TITLE :: " History "
INPUT_TITLE :: " Input "

compute_app_layout :: proc(rows, columns, inputLines: int) -> App_Layout {
	row_count := rows
	if row_count < 3 {
		row_count = 3
	}
	column_count := columns
	if column_count < 1 {
		column_count = 1
	}
	line_count := inputLines
	if line_count < 1 {
		line_count = 1
	}

	status_row := row_count
	available_panel_height := row_count - 1
	input_height := line_count + 2
	if input_height < MIN_INPUT_PANEL_HEIGHT {
		input_height = MIN_INPUT_PANEL_HEIGHT
	}

	max_input_height := available_panel_height - MIN_HISTORY_PANEL_HEIGHT
	if max_input_height < MIN_INPUT_PANEL_HEIGHT {
		max_input_height = MIN_INPUT_PANEL_HEIGHT
	}
	if input_height > max_input_height {
		input_height = max_input_height
	}

	history_height := available_panel_height - input_height
	if history_height < 1 {
		history_height = 1
	}

	return App_Layout {
		historyPanel = console.Region {
			top_row = 1,
			left_column = 1,
			bottom_row = history_height,
			right_column = column_count,
		},
		inputPanel = console.Region {
			top_row = history_height + 1,
			left_column = 1,
			bottom_row = available_panel_height,
			right_column = column_count,
		},
		statusBar = console.Region {
			top_row = status_row,
			left_column = 1,
			bottom_row = status_row,
			right_column = column_count,
		},
	}
}

render_app_frame_sequence :: proc(
	state: ^App_State,
	rows, columns: int,
	allocator := context.allocator,
) -> string {
	input_width := columns - 2
	if input_width < 1 {
		input_width = 1
	}
	input_lines := wrapped_text_line_count(input_buffer_string(&state.input), input_width)
	layout := compute_app_layout(rows, columns, input_lines)
	batch := console.batch_init(allocator)
	defer console.batch_destroy(&batch)

	console.batch_write_sequence(&batch, console.clear_screen_home_sequence())
	console.batch_draw_panel(
		&batch,
		console.Panel{region = layout.historyPanel, title = HISTORY_TITLE, fill_interior = true},
	)
	console.batch_draw_panel(
		&batch,
		console.Panel{region = layout.inputPanel, title = INPUT_TITLE, fill_interior = true},
	)

	render_history(
		&batch,
		console.panel_interior(console.Panel{region = layout.historyPanel}),
		state,
	)
	render_input(&batch, console.panel_interior(console.Panel{region = layout.inputPanel}), state)
	if state.mode == .Models {
		render_models_modal(&batch, layout.historyPanel, state)
	} else if state.mode == .Config {
		render_config_modal(&batch, layout.historyPanel, state)
	} else if state.mode == .Approval {
		render_approval_modal(&batch, layout.historyPanel, state)
	}
	render_status(&batch, layout.statusBar, state)

	return console.batch_sequence(&batch)
}

render_approval_modal :: proc(batch: ^console.Batch, parent: console.Region, state: ^App_State) {
	modal := config_modal_region(parent)
	panel := console.Panel {
		region        = modal,
		title         = " Tool Permission ",
		fill_interior = true,
	}
	console.batch_draw_panel(batch, panel)
	interior := console.panel_interior(panel)
	width := console.region_width(interior)
	if width <= 0 {
		return
	}

	row := interior.top_row
	write_clipped_line(batch, row, interior.left_column, width, "Approve this tool call?")
	row += 2
	if state.approval.preparedOwned {
		action := state.approval.prepared.action
		write_clipped_line(
			batch,
			row,
			interior.left_column,
			width,
			approval_effect_label(action.effect),
		)
		row += 1
		switch action.effect {
		case .Read, .Write:
			displayPath := approval_display_text(action.targetPath, context.temp_allocator)
			write_clipped_line(batch, row, interior.left_column, width, displayPath)
		case .Execute:
			displayCommand := approval_display_text(action.command, context.temp_allocator)
			write_clipped_line(batch, row, interior.left_column, width, displayCommand)
			row += 1
			displayDirectory := approval_display_text(
				action.workingDirectory,
				context.temp_allocator,
			)
			write_clipped_line(batch, row, interior.left_column, width, displayDirectory)
		case .Remote:
			displayServer := approval_display_text(action.mcpServer, context.temp_allocator)
			write_clipped_line(batch, row, interior.left_column, width, displayServer)
		}
		row += 2
	}

	labels := [4]string{"Allow once", "Allow session", "Allow always", "Deny"}
	for label, index in labels {
		if row > interior.bottom_row {
			break
		}
		prefix := "  "
		if int(state.approval.choice) == index {
			prefix = "> "
		}
		line := strings.concatenate({prefix, label}, context.temp_allocator)
		write_clipped_line(batch, row, interior.left_column, width, line)
		row += 1
	}
}

approval_effect_label :: proc(effect: Permission_Effect) -> string {
	switch effect {
	case .Read:
		return "Read"
	case .Write:
		return "Write"
	case .Execute:
		return "Run command"
	case .Remote:
		return "Remote tool"
	}
	return "Tool"
}

approval_display_text :: proc(text: string, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	hex := "0123456789ABCDEF"
	for index := 0; index < len(text); index += 1 {
		value := text[index]
		switch value {
		case '\n':
			strings.write_string(&builder, "\\n")
		case '\r':
			strings.write_string(&builder, "\\r")
		case '\t':
			strings.write_string(&builder, "\\t")
		case 0x1b:
			strings.write_string(&builder, "\\e")
		case:
			if value < 0x20 || value == 0x7f {
				strings.write_string(&builder, "\\x")
				strings.write_byte(&builder, hex[value >> 4])
				strings.write_byte(&builder, hex[value & 0x0f])
			} else {
				strings.write_byte(&builder, value)
			}
		}
	}
	return strings.to_string(builder)
}

render_app_input_panel_sequence :: proc(
	state: ^App_State,
	rows, columns: int,
	allocator := context.allocator,
) -> string {
	input_width := columns - 2
	if input_width < 1 {
		input_width = 1
	}
	input_lines := wrapped_text_line_count(input_buffer_string(&state.input), input_width)
	layout := compute_app_layout(rows, columns, input_lines)
	batch := console.batch_init(allocator)
	defer console.batch_destroy(&batch)

	console.batch_draw_panel(
		&batch,
		console.Panel{region = layout.inputPanel, title = INPUT_TITLE, fill_interior = true},
	)
	render_input(&batch, console.panel_interior(console.Panel{region = layout.inputPanel}), state)

	return console.batch_sequence(&batch)
}

render_app_history_panel_sequence :: proc(
	state: ^App_State,
	rows, columns: int,
	allocator := context.allocator,
) -> string {
	input_width := columns - 2
	if input_width < 1 {
		input_width = 1
	}
	input_lines := wrapped_text_line_count(input_buffer_string(&state.input), input_width)
	layout := compute_app_layout(rows, columns, input_lines)
	batch := console.batch_init(allocator)
	defer console.batch_destroy(&batch)

	console.batch_draw_panel(
		&batch,
		console.Panel{region = layout.historyPanel, title = HISTORY_TITLE, fill_interior = true},
	)
	render_history(
		&batch,
		console.panel_interior(console.Panel{region = layout.historyPanel}),
		state,
	)

	return console.batch_sequence(&batch)
}

render_history :: proc(batch: ^console.Batch, region: console.Region, state: ^App_State) {
	if state.mode == .Setup {
		render_setup(batch, region, state)
		return
	}

	lines_available := console.region_height(region)
	if lines_available <= 0 || len(state.history) == 0 {
		return
	}

	width := console.region_width(region)
	total_lines := history_line_count(state, width)
	maximum_offset := total_lines - lines_available
	if maximum_offset < 0 {
		maximum_offset = 0
	}
	if state.historyScrollOffset < 0 {
		state.historyScrollOffset = 0
	} else if state.historyScrollOffset > maximum_offset {
		state.historyScrollOffset = maximum_offset
	}

	first_visible_line := total_lines - lines_available - state.historyScrollOffset
	if first_visible_line < 0 {
		first_visible_line = 0
	}
	last_visible_line := first_visible_line + lines_available
	entry_first_line := 0
	row := region.top_row
	for index := 0; index < len(state.history) && row <= region.bottom_row; index += 1 {
		entry := &state.history[index]
		entry_line_count := history_entry_line_count(entry, width)
		entry_last_line := entry_first_line + entry_line_count
		if entry_last_line > first_visible_line && entry_first_line < last_visible_line {
			skip_lines := first_visible_line - entry_first_line
			if skip_lines < 0 {
				skip_lines = 0
			}
			visible_lines := entry_last_line - entry_first_line - skip_lines
			remaining_visible := last_visible_line - (entry_first_line + skip_lines)
			if visible_lines > remaining_visible {
				visible_lines = remaining_visible
			}
			line := history_entry_line(entry^, context.temp_allocator)
			row += write_text_lines_from_row_window(
				batch,
				region,
				row,
				line,
				skip_lines,
				visible_lines,
			)
		}
		entry_first_line = entry_last_line
	}
}

history_line_count :: proc(state: ^App_State, width: int) -> int {
	total := 0
	for index := 0; index < len(state.history); index += 1 {
		total += history_entry_line_count(&state.history[index], width)
	}
	return total
}

history_entry_line_count :: proc(entry: ^History_Entry, width: int) -> int {
	if entry.cachedLineWidth == width && entry.cachedLineCount > 0 {
		return entry.cachedLineCount
	}

	line := history_entry_line(entry^, context.temp_allocator)
	entry.cachedLineWidth = width
	entry.cachedLineCount = wrapped_text_line_count(line, width)
	return entry.cachedLineCount
}

render_setup :: proc(batch: ^console.Batch, region: console.Region, state: ^App_State) {
	text := "Setup\nEnter Ollama endpoint, or press Enter for http://localhost:11434."
	if state.setupStep == .API_Key {
		text = "Setup\nEnter optional API key, or press Enter to skip."
	}
	write_text_lines(batch, region, text)
}

render_models_modal :: proc(batch: ^console.Batch, parent: console.Region, state: ^App_State) {
	modal := model_modal_region(parent)
	console.batch_draw_panel(
		batch,
		console.Panel{region = modal, title = " Select Model ", fill_interior = true},
	)

	interior := console.panel_interior(console.Panel{region = modal})
	width := console.region_width(interior)
	if width <= 0 {
		return
	}

	row := interior.top_row
	write_clipped_line(batch, row, interior.left_column, width, "Use arrows/j/k, Enter, Esc")
	row += 1
	if row <= interior.bottom_row {
		row += 1
	}

	for entry, index in state.models {
		if row > interior.bottom_row {
			break
		}

		line := model_modal_entry_line(state, entry, index, context.temp_allocator)
		write_clipped_line(batch, row, interior.left_column, width, line)
		row += 1
	}
}

render_config_modal :: proc(batch: ^console.Batch, parent: console.Region, state: ^App_State) {
	modal := config_modal_region(parent)
	panel := console.Panel {
		region        = modal,
		title         = " Configuration ",
		fill_interior = true,
	}
	console.batch_draw_panel(batch, panel)

	interior := console.panel_interior(panel)
	if console.region_width(interior) <= 0 || console.region_height(interior) <= 0 {
		return
	}
	categoryRegion, dividerColumn, settingsRegion, footerRow := config_modal_regions(interior)
	render_config_categories(batch, categoryRegion, state)
	if dividerColumn >= interior.left_column && dividerColumn <= interior.right_column {
		for row := interior.top_row; row < footerRow; row += 1 {
			console.batch_move_to(batch, row, dividerColumn)
			console.batch_write_text(batch, "|")
		}
	}
	render_config_settings(batch, settingsRegion, state)
	if footerRow <= interior.bottom_row {
		write_clipped_line(
			batch,
			footerRow,
			interior.left_column,
			console.region_width(interior),
			config_modal_footer(state),
		)
	}
}

config_modal_region :: proc(parent: console.Region) -> console.Region {
	normalized := console.region_normalized(parent)
	parentWidth := console.region_width(normalized)
	parentHeight := console.region_height(normalized)

	width := 88
	if parentWidth - 4 < width {
		width = parentWidth - 4
	}
	if width < 32 {
		width = parentWidth
	}
	if width < 1 {
		width = 1
	}

	height := 22
	if parentHeight - 2 < height {
		height = parentHeight - 2
	}
	if height < 7 {
		height = parentHeight
	}
	if height < 1 {
		height = 1
	}

	top := normalized.top_row + (parentHeight - height) / 2
	left := normalized.left_column + (parentWidth - width) / 2
	return console.Region {
		top_row = top,
		left_column = left,
		bottom_row = top + height - 1,
		right_column = left + width - 1,
	}
}

config_modal_regions :: proc(
	interior: console.Region,
) -> (
	console.Region,
	int,
	console.Region,
	int,
) {
	width := console.region_width(interior)
	categoryWidth := 20
	if width < 50 {
		categoryWidth = width / 3
	}
	if categoryWidth < 10 {
		categoryWidth = 10
	}
	if categoryWidth > width - 3 {
		categoryWidth = width - 3
	}
	if categoryWidth < 1 {
		categoryWidth = 1
	}
	divider := interior.left_column + categoryWidth
	settingsLeft := divider + 2
	if settingsLeft > interior.right_column {
		settingsLeft = interior.right_column
	}
	footer := interior.bottom_row
	return console.Region {
			top_row = interior.top_row,
			left_column = interior.left_column,
			bottom_row = footer - 1,
			right_column = divider - 1,
		},
		divider,
		console.Region {
			top_row = interior.top_row,
			left_column = settingsLeft,
			bottom_row = footer - 1,
			right_column = interior.right_column,
		},
		footer
}

render_config_categories :: proc(
	batch: ^console.Batch,
	region: console.Region,
	state: ^App_State,
) {
	width := console.region_width(region)
	if width <= 0 || region.top_row > region.bottom_row {
		return
	}
	write_clipped_line(batch, region.top_row, region.left_column, width, "Categories")
	for categoryIndex := 0;
	    categoryIndex <= int(Config_Category.Embedding_Model);
	    categoryIndex += 1 {
		category := Config_Category(categoryIndex)
		row := region.top_row + 2 + categoryIndex
		if row > region.bottom_row {
			break
		}
		cursor := "  "
		if category == state.configCategory {
			cursor = "* "
			if state.configFocus == .Categories {
				cursor = "> "
			}
		}
		write_clipped_line(
			batch,
			row,
			region.left_column,
			width,
			config_prefixed_line(cursor, config_category_label(category)),
		)
	}
}

config_category_label :: proc(category: Config_Category) -> string {
	switch category {
	case .Providers:
		return "Providers"
	case .Chat_Model:
		return "Chat Model"
	case .Embedding_Model:
		return "Embedding Model"
	}
	return ""
}

render_config_settings :: proc(batch: ^console.Batch, region: console.Region, state: ^App_State) {
	width := console.region_width(region)
	if width <= 0 || region.top_row > region.bottom_row {
		return
	}
	write_clipped_line(
		batch,
		region.top_row,
		region.left_column,
		width,
		config_category_label(state.configCategory),
	)
	row := region.top_row + 2
	for setting, index in state.configSettings {
		if row > region.bottom_row {
			break
		}
		cursor := "  "
		if state.configFocus == .Settings && index == state.configSettingCursor {
			cursor = "> "
		}
		write_clipped_line(
			batch,
			row,
			region.left_column,
			width,
			config_prefixed_line(cursor, config_setting_line(state, setting)),
		)
		row += 1
	}
}

config_setting_line :: proc(state: ^App_State, setting: Config_Setting) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	if state.configEditing &&
	   setting.id == state.configEditingSetting.id &&
	   setting.providerIndex == state.configEditingSetting.providerIndex {
		strings.write_string(&builder, config_setting_label(setting.id))
		strings.write_string(&builder, ": ")
		strings.write_string(&builder, input_buffer_string(&state.configEdit))
		return strings.to_string(builder)
	}

	if (setting.id == .Chat_Model || setting.id == .Embedding_Model) &&
	   setting.modelIndex >= 0 &&
	   setting.modelIndex < len(state.models) {
		entry := state.models[setting.modelIndex]
		active := " "
		if setting.id == .Chat_Model &&
		   entry.providerName == state.config.selectedProvider &&
		   entry.model == state.config.selectedModel {
			active = "*"
		}
		if setting.id == .Embedding_Model &&
		   entry.providerName == state.config.embeddingProvider &&
		   entry.model == state.config.embeddingModel {
			active = "*"
		}
		strings.write_string(&builder, active)
		strings.write_string(&builder, " ")
		strings.write_string(&builder, entry.providerName)
		strings.write_string(&builder, " / ")
		strings.write_string(&builder, entry.model)
		return strings.to_string(builder)
	}
	if setting.providerIndex < 0 || setting.providerIndex >= len(state.config.providers) {
		return config_setting_label(setting.id)
	}

	provider := state.config.providers[setting.providerIndex]
	#partial switch setting.id {
	case .Provider:
		strings.write_string(&builder, "Provider: < ")
		strings.write_string(&builder, provider.name)
		strings.write_string(&builder, " >")
	case .Provider_Name:
		strings.write_string(&builder, "Name: ")
		strings.write_string(&builder, provider.name)
	case .Provider_Type:
		strings.write_string(&builder, "Type: < ")
		strings.write_string(&builder, provider_type_to_string(provider.type))
		strings.write_string(&builder, " >")
	case .Provider_Endpoint:
		strings.write_string(&builder, "Endpoint: ")
		strings.write_string(&builder, provider.endpoint)
	case .Provider_API_Key:
		strings.write_string(&builder, "API key: ")
		strings.write_string(&builder, config_masked_value(provider.apiKey))
	case .Provider_Model:
		strings.write_string(&builder, "Configured model: ")
		strings.write_string(&builder, provider.model)
	case .Provider_Context_Window:
		strings.write_string(&builder, "Context window tokens: ")
		strings.write_string(
			&builder,
			fmt.tprintf(
				"%d",
				config_context_window_tokens(&state.config, provider.name, provider.model),
			),
		)
	case .Provider_Enabled:
		if provider.enabled {
			return "[x] Enabled"
		}
		return "[ ] Enabled"
	case .Refresh_Models, .Add_Provider, .Remove_Provider:
		strings.write_string(&builder, "[ ")
		strings.write_string(&builder, config_setting_label(setting.id))
		strings.write_string(&builder, " ]")
	case:
		return config_setting_label(setting.id)
	}
	return strings.to_string(builder)
}

config_prefixed_line :: proc(prefix, text: string, allocator := context.temp_allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, prefix)
	strings.write_string(&builder, text)
	return strings.to_string(builder)
}

config_setting_label :: proc(id: Config_Setting_ID) -> string {
	switch id {
	case .Provider:
		return "Provider"
	case .Provider_Name:
		return "Name"
	case .Provider_Type:
		return "Type"
	case .Provider_Endpoint:
		return "Endpoint"
	case .Provider_API_Key:
		return "API key"
	case .Provider_Model:
		return "Configured model"
	case .Provider_Context_Window:
		return "Context window tokens"
	case .Provider_Enabled:
		return "Enabled"
	case .Refresh_Models:
		return "Refresh models"
	case .Add_Provider:
		return "Add provider"
	case .Remove_Provider:
		return "Remove provider"
	case .Chat_Model:
		return "Chat model"
	case .Embedding_Model:
		return "Embedding model"
	}
	return ""
}

config_masked_value :: proc(value: string) -> string {
	if value == "" {
		return "(not set)"
	}
	return "********"
}

config_modal_footer :: proc(state: ^App_State) -> string {
	if state.configEditing {
		return "Enter save  Esc cancel  Ctrl-A/Ctrl-E move cursor"
	}
	return "Arrows move  Tab change pane  Enter select/edit  Esc close"
}

model_modal_region :: proc(parent: console.Region) -> console.Region {
	normalized := console.region_normalized(parent)
	parent_width := console.region_width(normalized)
	parent_height := console.region_height(normalized)

	width := 64
	if parent_width - 4 < width {
		width = parent_width - 4
	}
	if width < 24 {
		width = parent_width
	}
	if width < 1 {
		width = 1
	}

	height := 16
	if parent_height - 2 < height {
		height = parent_height - 2
	}
	if height < 5 {
		height = parent_height
	}
	if height < 1 {
		height = 1
	}

	top := normalized.top_row + (parent_height - height) / 2
	left := normalized.left_column + (parent_width - width) / 2
	return console.Region {
		top_row = top,
		left_column = left,
		bottom_row = top + height - 1,
		right_column = left + width - 1,
	}
}

model_modal_entry_line :: proc(
	state: ^App_State,
	entry: Model_Select_Entry,
	index: int,
	allocator := context.allocator,
) -> string {
	cursor := "  "
	if index == state.modelCursor {
		cursor = "> "
	}
	active := " "
	if entry.providerName == state.config.selectedProvider &&
	   entry.model == state.config.selectedModel {
		active = "*"
	}

	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, cursor)
	strings.write_string(&builder, active)
	strings.write_byte(&builder, ' ')
	strings.write_string(&builder, entry.providerName)
	strings.write_string(&builder, " / ")
	strings.write_string(&builder, entry.model)
	return strings.to_string(builder)
}

render_input :: proc(batch: ^console.Batch, region: console.Region, state: ^App_State) {
	text := input_buffer_string(&state.input)
	if !state.cursorBlinkOn {
		write_text_lines(batch, region, text)
		return
	}
	render_input_with_cursor(batch, region, text, input_buffer_cursor_position(&state.input))
}

render_input_with_cursor :: proc(
	batch: ^console.Batch,
	region: console.Region,
	text: string,
	cursorPosition: int,
) {
	width := console.region_width(region)
	if width <= 0 {
		return
	}

	row := region.top_row
	start := 0
	lineStartGrapheme := 0
	for index := 0; index <= len(text) && row <= region.bottom_row; index += 1 {
		if index == len(text) || text[index] == '\n' || text[index] == '\r' {
			lineGraphemes := unicode_grapheme_count(text[start:index])
			cursorInLine := -1
			if cursorPosition >= lineStartGrapheme &&
			   cursorPosition <= lineStartGrapheme + lineGraphemes {
				cursorInLine = cursorPosition - lineStartGrapheme
			}
			row += render_wrapped_input_line(batch, region, row, text[start:index], cursorInLine)
			start = index + 1
			lineStartGrapheme += lineGraphemes + 1
		}
	}
}

render_wrapped_input_line :: proc(
	batch: ^console.Batch,
	region: console.Region,
	startRow: int,
	text: string,
	cursorInLine: int,
) -> int {
	width := console.region_width(region)
	if width <= 0 || startRow > region.bottom_row {
		return 0
	}

	if len(text) == 0 {
		console.batch_move_to(batch, startRow, region.left_column)
		if cursorInLine == 0 {
			render_input_cursor_cell(batch, " ")
		}
		return 1
	}

	row := startRow
	rows_written := 0
	start := 0
	startGrapheme := 0
	for start < len(text) && row <= region.bottom_row {
		finish, next := wrapped_text_slice(text, start, width)
		sliceGraphemes := unicode_grapheme_count(text[start:finish])
		nextGraphemes := unicode_grapheme_count(text[start:next])
		cursorInSlice := -1
		if cursorInLine >= startGrapheme && cursorInLine <= startGrapheme + nextGraphemes {
			cursorInSlice = cursorInLine - startGrapheme
			if cursorInSlice > sliceGraphemes {
				cursorInSlice = sliceGraphemes
			}
		}
		render_input_slice(batch, region, row, text, start, finish, next, cursorInSlice)
		row += 1
		rows_written += 1
		if next <= start {
			break
		}
		startGrapheme += unicode_grapheme_count(text[start:next])
		start = next
	}
	return rows_written
}

render_input_slice :: proc(
	batch: ^console.Batch,
	region: console.Region,
	row: int,
	text: string,
	start, finish, next, cursorInLine: int,
) {
	width := console.region_width(region)
	console.batch_move_to(batch, row, region.left_column)
	slice := text[start:finish]
	sliceGraphemes := unicode_grapheme_count(slice)
	if cursorInLine < 0 || cursorInLine > sliceGraphemes {
		console.batch_write_text(batch, text[start:finish])
		return
	}

	if cursorInLine < sliceGraphemes {
		cursorStart, cursorFinish := unicode_grapheme_byte_range(slice, cursorInLine)
		console.batch_write_text(batch, slice[:cursorStart])
		render_input_cursor_cell(batch, slice[cursorStart:cursorFinish])
		console.batch_write_text(batch, slice[cursorFinish:])
		return
	}

	console.batch_write_text(batch, slice)
	if cursorInLine == sliceGraphemes {
		cursorColumn := unicode_text_width(slice)
		if cursorColumn >= width {
			cursorColumn = width - 1
			console.batch_move_to(batch, row, region.left_column + cursorColumn)
		}
		render_input_cursor_cell(batch, " ")
	}
}

render_input_cursor_cell :: proc(batch: ^console.Batch, text: string) {
	console.batch_write_styled_text(
		batch,
		console.Style {
			foreground = .Black,
			background = .Bright_Cyan,
			use_foreground = true,
			use_background = true,
		},
		text,
	)
}

render_status :: proc(batch: ^console.Batch, region: console.Region, state: ^App_State) {
	console.batch_fill_region(batch, region, ' ')
	width := console.region_width(region)
	if width <= 0 {
		return
	}
	contextUsage := app_context_usage_status_text(state, context.temp_allocator)
	contextUsage = right_clipped_text(contextUsage, width)
	contextWidth := text_display_width(contextUsage)
	if contextWidth > 0 {
		contextColumn := region.right_column - contextWidth + 1
		write_clipped_line(
			batch,
			region.top_row,
			region.left_column,
			contextColumn - region.left_column,
			state.status,
		)
		write_clipped_line(batch, region.top_row, contextColumn, contextWidth, contextUsage)
		return
	}
	write_clipped_line(batch, region.top_row, region.left_column, width, state.status)
}

text_display_width :: proc(text: string) -> int {
	width := 0
	for index := 0; index < len(text); {
		width += unicode_grapheme_width_at(text, index)
		next := unicode_next_grapheme_offset(text, index)
		if next <= index {
			break
		}
		index = next
	}
	return width
}

right_clipped_text :: proc(text: string, width: int) -> string {
	if width <= 0 || text == "" {
		return ""
	}
	totalWidth := text_display_width(text)
	start := 0
	for totalWidth > width && start < len(text) {
		graphemeWidth := unicode_grapheme_width_at(text, start)
		next := unicode_next_grapheme_offset(text, start)
		if next <= start {
			break
		}
		totalWidth -= graphemeWidth
		start = next
	}
	return text[start:]
}

history_entry_line :: proc(entry: History_Entry, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	strings.write_string(&builder, history_role_label(entry.role))
	strings.write_string(&builder, ": ")
	strings.write_string(&builder, entry.content)
	return strings.to_string(builder)
}

history_role_label :: proc(role: History_Role) -> string {
	switch role {
	case .System:
		return "system"
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case .Tool:
		return "tool"
	}
	return "system"
}

first_line :: proc(text: string) -> string {
	for index := 0; index < len(text); index += 1 {
		if text[index] == '\n' || text[index] == '\r' {
			return text[:index]
		}
	}
	return text
}

write_text_lines :: proc(batch: ^console.Batch, region: console.Region, text: string) {
	_ = write_text_lines_from_row(batch, region, region.top_row, text)
}

write_text_lines_from_row :: proc(
	batch: ^console.Batch,
	region: console.Region,
	start_row: int,
	text: string,
) -> int {
	width := console.region_width(region)
	if width <= 0 || start_row > region.bottom_row {
		return 0
	}

	row := start_row
	rows_written := 0
	start := 0
	for index := 0; index <= len(text) && row <= region.bottom_row; index += 1 {
		if index == len(text) || text[index] == '\n' || text[index] == '\r' {
			written := write_wrapped_line(batch, region, row, text[start:index])
			row += written
			rows_written += written
			start = index + 1
		}
	}
	return rows_written
}

write_text_lines_from_row_window :: proc(
	batch: ^console.Batch,
	region: console.Region,
	start_row: int,
	text: string,
	skip_lines, line_limit: int,
) -> int {
	width := console.region_width(region)
	if width <= 0 || start_row > region.bottom_row || line_limit <= 0 {
		return 0
	}

	row := start_row
	line_index := 0
	start := 0
	for index := 0; index <= len(text) && row <= region.bottom_row; index += 1 {
		if index != len(text) && text[index] != '\n' && text[index] != '\r' {
			continue
		}

		logical_line := text[start:index]
		if len(logical_line) == 0 {
			if line_index >= skip_lines && row <= region.bottom_row {
				console.batch_move_to(batch, row, region.left_column)
				row += 1
			}
			line_index += 1
		} else {
			wrapped_start := 0
			for wrapped_start < len(logical_line) && row <= region.bottom_row {
				finish, next := wrapped_text_slice(logical_line, wrapped_start, width)
				if line_index >= skip_lines {
					console.batch_move_to(batch, row, region.left_column)
					console.batch_write_text(batch, logical_line[wrapped_start:finish])
					row += 1
				}
				line_index += 1
				if next <= wrapped_start {
					break
				}
				wrapped_start = next
			}
		}

		if row - start_row >= line_limit {
			break
		}
		start = index + 1
	}
	return row - start_row
}

write_wrapped_line :: proc(
	batch: ^console.Batch,
	region: console.Region,
	start_row: int,
	text: string,
) -> int {
	width := console.region_width(region)
	if width <= 0 || start_row > region.bottom_row {
		return 0
	}

	if len(text) == 0 {
		console.batch_move_to(batch, start_row, region.left_column)
		return 1
	}

	row := start_row
	rows_written := 0
	start := 0
	for start < len(text) && row <= region.bottom_row {
		finish, next := wrapped_text_slice(text, start, width)
		console.batch_move_to(batch, row, region.left_column)
		console.batch_write_text(batch, text[start:finish])
		row += 1
		rows_written += 1
		if next <= start {
			break
		}
		start = next
	}
	return rows_written
}

wrapped_text_line_count :: proc(text: string, width: int) -> int {
	if width <= 0 {
		return 0
	}

	line_count := 0
	start := 0
	for index := 0; index <= len(text); index += 1 {
		if index == len(text) || text[index] == '\n' || text[index] == '\r' {
			line_count += wrapped_logical_line_count(text[start:index], width)
			start = index + 1
		}
	}
	return line_count
}

wrapped_logical_line_count :: proc(text: string, width: int) -> int {
	if width <= 0 {
		return 0
	}
	if len(text) == 0 {
		return 1
	}

	line_count := 0
	start := 0
	for start < len(text) {
		_, next := wrapped_text_slice(text, start, width)
		line_count += 1
		if next <= start {
			break
		}
		start = next
	}
	return line_count
}

wrapped_text_slice :: proc(text: string, start, width: int) -> (finish, next: int) {
	finish = start
	next = start
	if width <= 0 || start >= len(text) {
		return
	}

	break_index := -1
	break_next := -1
	currentWidth := 0
	index := start
	for index < len(text) {
		graphemeFinish := unicode_next_grapheme_offset(text, index)
		graphemeWidth := unicode_grapheme_width_at(text, index)
		if graphemeFinish <= index {
			break
		}

		if currentWidth + graphemeWidth > width {
			if is_wrap_space(text[index]) {
				finish = index
				next = skip_wrap_spaces(text, graphemeFinish)
				return
			}
			if break_index > start {
				finish = break_index
				next = break_next
				return
			}
			if index == start {
				finish = graphemeFinish
				next = graphemeFinish
				return
			}
			finish = index
			next = index
			return
		}

		if is_wrap_space(text[index]) {
			break_index = index
			break_next = skip_wrap_spaces(text, graphemeFinish)
		}
		currentWidth += graphemeWidth
		index = graphemeFinish
	}

	finish = len(text)
	next = len(text)
	return
}

skip_wrap_spaces :: proc(text: string, start: int) -> int {
	index := start
	for index < len(text) && is_wrap_space(text[index]) {
		index += 1
	}
	return index
}

is_wrap_space :: proc(value: byte) -> bool {
	return value == ' ' || value == '\t'
}

write_clipped_line :: proc(batch: ^console.Batch, row, column, width: int, text: string) {
	if width <= 0 {
		return
	}
	finish := 0
	remaining := width
	for finish < len(text) && remaining > 0 {
		next := unicode_next_grapheme_offset(text, finish)
		graphemeWidth := unicode_grapheme_width_at(text, finish)
		if next <= finish || graphemeWidth > remaining {
			break
		}
		remaining -= graphemeWidth
		finish = next
	}
	console.batch_move_to(batch, row, column)
	console.batch_write_text(batch, text[:finish])
}
