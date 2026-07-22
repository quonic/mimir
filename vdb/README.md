# VDB

`vdb` is Mimir's native Odin vector database package. It performs exact
nearest-neighbor searches using cosine, Euclidean, or dot-product distance.

## Lifecycle

Initialize a caller-owned `Database` with `init` and release it with `destroy`.
`add_vector` copies vector data, IDs, and metadata into the database using the
allocator supplied at initialization.

## Borrowed Reads

`get_vector` returns a `Vector_View`, and `search` returns a `Result_Set`.
Both borrow their vector data, IDs, and metadata from the database. They retain
a shared read lock until `vector_view_destroy` or `result_set_destroy` is
called. Release each view or result set before mutating or destroying the
database, especially on the same thread.

The database uses `sync.RW_Mutex` by default. Searches and views may coexist;
adding, removing, loading, and destroying require exclusive access.

## Persistence

`save` and `load` use a portable VDB v1 binary format with fixed-width
little-endian fields. It persists the metric, dimensions, vector data, IDs, and
UTF-8 metadata strings.

## Examples

basic_search/main.odin: add labeled vectors and print nearest matches with metadata.

persistence/main.odin: save a cosine-metric database, reload it, then query the reloaded data. It creates vectors.vdb in the working directory when run.

metric_comparison/main.odin: compare cosine, Euclidean, and dot-product ranking behavior for one query.
