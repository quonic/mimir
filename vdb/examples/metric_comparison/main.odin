package main

import "core:fmt"

import vdb "../.."

Candidate :: struct {
	id:   string,
	data: []f32,
}

main :: proc() {
	candidates := []Candidate {
		{"east", []f32{1.0, 0.0}},
		{"north", []f32{0.0, 1.0}},
		{"diagonal", []f32{0.7, 0.7}},
	}
	query := []f32{0.8, 0.2}

	compare_metric(.Cosine, "Cosine", candidates, query)
	compare_metric(.Euclidean, "Euclidean", candidates, query)
	compare_metric(.Dot_Product, "Dot product", candidates, query)
}

compare_metric :: proc(metric: vdb.Metric, name: string, candidates: []Candidate, query: []f32) {
	database: vdb.Database
	fmt.assertf(vdb.init(&database, len(query), metric) == .None, "could not initialize %s", name)
	defer vdb.destroy(&database)

	for candidate in candidates {
		fmt.assertf(
			vdb.add_vector(&database, candidate.data, candidate.id) == .None,
			"could not add %s",
			candidate.id,
		)
	}

	results, searchError := vdb.search(&database, query, len(candidates))
	fmt.assertf(searchError == .None, "could not search with %s: %v", name, searchError)
	defer vdb.result_set_destroy(&results)

	fmt.printf("%s:\n", name)
	for result, rank in results.results {
		fmt.printf("%d. %s (distance: %.3f)\n", rank + 1, result.id, result.distance)
	}
}
