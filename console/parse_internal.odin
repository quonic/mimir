package console

_parse_csi_prefix :: proc(response: string) -> (int, bool) {
	if len(response) == 0 {
		return 0, false
	}
	if response[0] == escape[0] {
		if len(response) < 2 || response[1] != '[' {
			return 0, false
		}
		return 2, true
	}
	if response[0] == 0x9b {
		return 1, true
	}
	return 0, false
}
