#+build !windows
package builtin_tools

import "core:os"

// Runs the command of desc to completion and returns its exit code and output.
terminal_process_exec :: proc(
	desc: os.Process_Desc,
	allocator := context.allocator,
) -> (
	exitCode: int,
	stdout: []byte,
	stderr: []byte,
	err: os.Error,
) {
	state: os.Process_State
	state, stdout, stderr, err = os.process_exec(desc, allocator)
	return state.exit_code, stdout, stderr, err
}
