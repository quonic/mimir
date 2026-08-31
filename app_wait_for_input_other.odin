#+build !windows
package main

import "core:c"
import "core:os"
import "core:sys/posix"

app_wait_for_input :: proc(timeout_ms: int) -> (ready, ok: bool) {
	fds := [1]posix.pollfd{{fd = posix.FD(os.fd(os.stdin)), events = posix.Poll_Event{.IN}}}
	result := posix.poll(raw_data(fds[:]), posix.nfds_t(len(fds)), c.int(timeout_ms))
	if result < 0 {
		return false, false
	}
	if result == 0 {
		return false, true
	}
	return .IN in fds[0].revents, true
}
