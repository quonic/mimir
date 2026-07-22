package main

import "core:fmt"

import vdb "../.."

main :: proc() {
	database: vdb.Database
	fmt.assertf(vdb.init(&database, 2, .Euclidean) == .None, "could not initialize database")
	defer vdb.destroy(&database)

	fmt.assertf(
		vdb.add_vector(&database, []f32{1.0, 0.0}, "coffee", "category:drink") == .None,
		"could not add coffee",
	)
	fmt.assertf(
		vdb.add_vector(&database, []f32{0.8, 0.2}, "espresso", "category:drink") == .None,
		"could not add espresso",
	)
	fmt.assertf(
		vdb.add_vector(&database, []f32{0.0, 1.0}, "book", "category:reading") == .None,
		"could not add book",
	)

	results, searchError := vdb.search(&database, []f32{0.82, 0.18}, 2)
	fmt.assertf(searchError == .None, "could not search: %v", searchError)
	defer vdb.result_set_destroy(&results)

	fmt.println("Nearest matches:")
	for result, rank in results.results {
		fmt.printf(
			"%d. %s (distance: %.3f, %s)\n",
			rank + 1,
			result.id,
			result.distance,
			result.metadata,
		)
	}
}
