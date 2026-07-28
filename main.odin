package main

import "base:runtime"
import "core:debug/trace"
import "core:fmt"

main :: proc() {
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
