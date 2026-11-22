package main

import "acp"
import "core:debug/trace"
import "core:fmt"
import "core:os"

main :: proc() {
	acpMode := acp_flag_present(os.args)
	if acpMode && headless_json_flag_present(os.args) {
		fmt.eprintln("mimir: --acp and --headless-json cannot be used together")
		os.exit(2)
	}
	if acpMode {
		os.exit(acp.run())
	}
	if headless_json_flag_present(os.args) {
		run_headless_jsonl()
		return
	}

	when ODIN_DEBUG {
		track: trace.Tracking_Allocator
		trace.tracking_allocator_init(&track, context.allocator)
		defer trace.tracking_allocator_destroy(&track)

		context.allocator = trace.tracking_allocator(&track)
		defer trace.tracking_allocator_print_results(&track)

		context.assertion_failure_proc = trace.assertion_failure_proc
	}

	run_app()

	when ODIN_DEBUG {
		// Print any memory leaks detected by the tracking allocator
		for _, leak in track.allocation_map {
			fmt.printf("%v leaked %m\n", leak.location, leak.size)
		}
	}
}

// Reports whether the command line asks for the ACP front end (mimir --acp).
acp_flag_present :: proc(args: []string) -> bool {
	for arg in args[1:] {
		if arg == "--acp" {
			return true
		}
	}
	return false
}
