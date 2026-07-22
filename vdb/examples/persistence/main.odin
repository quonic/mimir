package main

import "core:fmt"

import vdb "../.."

main :: proc() {
	path := "vectors.vdb"

	database: vdb.Database
	fmt.assertf(vdb.init(&database, 3, .Cosine) == .None, "could not initialize database")
	defer vdb.destroy(&database)

	fmt.assertf(
		vdb.add_vector(&database, []f32{1.0, 0.0, 0.0}, "red", "color:red") == .None,
		"could not add red",
	)
	fmt.assertf(
		vdb.add_vector(&database, []f32{0.0, 1.0, 0.0}, "green", "color:green") == .None,
		"could not add green",
	)
	fmt.assertf(vdb.save(&database, path) == .None, "could not save %s", path)

	loaded: vdb.Database
	fmt.assertf(vdb.load(&loaded, path) == .None, "could not load %s", path)
	defer vdb.destroy(&loaded)

	results, searchError := vdb.search(&loaded, []f32{0.9, 0.1, 0.0}, 1)
	fmt.assertf(searchError == .None, "could not search loaded database: %v", searchError)
	defer vdb.result_set_destroy(&results)

	bestMatch := results.results[0]
	fmt.printf("Saved %d vectors to %s\n", vdb.count(&loaded), path)
	fmt.printf(
		"Best match after reload: %s (distance: %.3f, %s)\n",
		bestMatch.id,
		bestMatch.distance,
		bestMatch.metadata,
	)
}
