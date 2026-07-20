package main

import "core:unicode/utf8"

unicode_grapheme_count :: proc(text: string) -> int {
	graphemes, _, _ := utf8.grapheme_count(text)
	return graphemes
}

unicode_grapheme_to_byte_offset :: proc(text: string, graphemeIndex: int) -> int {
	if graphemeIndex <= 0 {
		return 0
	}

	index := 0
	it := utf8.decode_grapheme_iterator_make(text)
	for _, grapheme in utf8.decode_grapheme_iterate(&it) {
		if index == graphemeIndex {
			return grapheme.byte_index
		}
		index += 1
	}
	return len(text)
}

unicode_clamp_grapheme_index :: proc(text: string, graphemeIndex: int) -> int {
	if graphemeIndex < 0 {
		return 0
	}
	count := unicode_grapheme_count(text)
	if graphemeIndex > count {
		return count
	}
	return graphemeIndex
}

unicode_grapheme_byte_range :: proc(text: string, graphemeIndex: int) -> (start, finish: int) {
	start = unicode_grapheme_to_byte_offset(text, graphemeIndex)
	finish = unicode_grapheme_to_byte_offset(text, graphemeIndex + 1)
	return
}

unicode_text_width :: proc(text: string) -> int {
	_, _, width := utf8.grapheme_count(text)
	return width
}

unicode_next_grapheme_offset :: proc(text: string, start: int) -> int {
	if start >= len(text) {
		return len(text)
	}

	graphemes, _, _, _ := utf8.decode_grapheme_clusters(text[start:], true, context.temp_allocator)
	if len(graphemes) <= 1 {
		return len(text)
	}
	return start + graphemes[1].byte_index
}

unicode_grapheme_width_at :: proc(text: string, start: int) -> int {
	if start >= len(text) {
		return 0
	}

	graphemes, _, _, _ := utf8.decode_grapheme_clusters(text[start:], true, context.temp_allocator)
	if len(graphemes) == 0 {
		return 0
	}
	return graphemes[0].width
}
