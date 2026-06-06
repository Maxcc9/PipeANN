---
hide:
  - navigation
---

# Architecture

This page describes how PipeANN is organized internally. It is intended for
contributors who need to change search, update, build, filtering, or Python API
behavior.

## High-Level Shape

PipeANN has three layers:

1. **Core C++ index layer** stores and searches graph indexes.
2. **Dynamic wrapper layer** selects memory vs. disk behavior and coordinates
   inserts, deletes, save, and load.
3. **Python application layer** exposes a FAISS-like index API, document
   collections, LangChain integration, and a Qdrant-compatible HTTP server.

The primary C++ abstractions are:

| Component | Files | Responsibility |
|-----------|-------|----------------|
| `Index<T, TagT>` | `include/index.h`, `src/index.cpp` | In-memory Vamana/PiPNN graph build, search, insert, lazy delete, tag mapping. |
| `SSDIndex<T, TagT>` | `include/ssd_index.h`, `src/ssd_index.cpp` | SSD index metadata, disk layout, async I/O buffers, search entry points, direct insert, merge/delete save path. |
| `DynamicIndex<T>` | `include/dynamic_index.h` | High-level lifecycle used by Python; routes between memory and disk index and handles auto disk conversion. |
| `PyIndexInterface` | `include/pyindex.h`, `src/python/pyindex.cpp` | Type-erased pybind bridge for `float`, `uint8_t`, and `int8_t`. |
| `Selector` / `AttrIndex` | `include/filter/*.h` | Attribute storage, selectivity estimates, speculative pre-filter/in-filter/post-filter logic. |
| `AbstractNeighbor<T>` | `include/nbr/*.h` | Neighbor vector compression and distance support, including PQ and RaBitQ. |
| `AlignedFileReader` | `include/aligned_file_reader.h`, `include/linux_aligned_file_reader.h`, `src/utils/linux_aligned_file_reader.cpp` | Async aligned I/O over AIO, io_uring, or SPDK depending on compile-time configuration. |

## Build Flow

The disk build path starts from a typed binary vector file:

1. A CLI (`tests/build_disk_index.cpp`) or Python API (`IndexPipeANN.build`) calls
   `build_disk_index<T, TagT>()` from `include/utils/index_build_utils.h`.
2. The builder loads vectors and builds an in-memory `Index<T, TagT>`.
3. Build parameters choose normal Vamana graph construction or PiPNN when `L2`
   is non-zero.
4. Optional OOD refinement uses `train_query_path`, `R_ood`, and `L_ood` to add
   NGFix refinement edges.
5. Optional attributes are serialized per node through an `AttrWriter`.
6. `SSDIndex<T, TagT>::save_from_mem()` writes `{prefix}_disk.index` and tag
   sidecars in SSD node format.
7. Optional `build_mem_index` creates `{prefix}_mem.index`, a sampled memory
   navigation graph used by pipelined SSD search.

`DynamicIndex<T>::build()` supplies conservative defaults when the caller leaves
parameters at zero:

| Parameter | Default behavior |
|-----------|------------------|
| `max_nbrs` | Based on dataset size, from 64 for small/medium data up to 128 around 1B points. |
| `build_L` | `max_nbrs + 32`. |
| `PQ_bytes` | `dim / 4`, clamped to `[32, 128]`. |
| `memory_use_GB` | 75% of system RAM. |
| `range_dense` | Auto-estimated for filtered search when attributes exist and dataset has at least 1M vectors. |
| `R_ood` | `max_nbrs / 2` when `train_query_path` is set and `R_ood == 0`. |

## Search Flow

Public Python search enters `IndexPipeANN.search()`, then `PyIndexInterface`,
then `DynamicIndex<T>::search()`.

Routing inside `DynamicIndex<T>::search()`:

| Condition | C++ path |
|-----------|----------|
| `selector != nullptr` | `SSDIndex::spec_filter_search()` |
| finite `range` | `SSDIndex::range_search()` |
| disk index loaded | `SSDIndex::pipe_search()` |
| memory-only index | `Index::search_with_tags()` |

`SSDIndex` also exposes older or alternative read-only search algorithms:

| Mode | Entry point | Notes |
|------|-------------|-------|
| `BEAM_SEARCH` | `beam_search()` | DiskANN-style best-first search. |
| `PAGE_SEARCH` | `page_search()` | Page-oriented Starling-style search. |
| `PIPE_SEARCH` | `pipe_search()` | Main PipeANN pipelined search path. |
| `CORO_SEARCH` | `coro_search()` | Coroutine-style batched multi-query path. |

The benchmark CLI `tests/search_disk_index.cpp` selects these by integer mode:
`0` beam, `1` page, `2` pipe, `3` coro.

## Pipelined SSD Search

The primary search implementation is in `src/search/pipe_search.cpp`, with
shared helpers in `src/search/pipe_search_common.h`.

At a high level, each query:

1. Pops a preallocated `QueryBuffer` from the per-index queue.
2. Normalizes the query if the metric is cosine.
3. Uses the entry point or optional memory navigation graph to seed candidate
   exploration.
4. Issues aligned asynchronous reads through `AlignedFileReader`.
5. Decodes vectors and compressed neighbor payloads via `AbstractNeighbor<T>`.
6. Maintains visited sets and candidate/result queues.
7. Writes result tags and distances, then returns the scratch buffer to the pool.

`QueryBuffer` owns scratch memory for sectors, coordinates, neighbor IDs,
compressed neighbor vectors, distance tables, and visited sets. The buffer is
allocated once per worker slot by `SSDIndex::init_buffers()`.

## Update Flow

Updates are coordinated by `DynamicIndex<T>` and implemented by `SSDIndex<T>`.

### Insert

1. `IndexPipeANN.add()` validates arrays and passes contiguous data into C++.
2. `DynamicIndex<T>::add()` parallelizes inserts with OpenMP.
3. If no disk index exists, inserts go to `Index<T>::insert_point()`.
4. Once a memory-only index exceeds `100000` points, `transform_mem_index_to_disk_index()` saves memory data, builds a disk index, and reloads it.
5. If a disk index exists, `SSDIndex::insert_in_place()` allocates a new internal ID/location, updates graph/page mappings, writes the new node, and updates attribute indexes if present.
6. If a sampled memory navigation graph is loaded, a random 1% of inserts are also inserted into it.

### Delete

Deletes are lazy:

1. `IndexPipeANN.remove()` calls `DynamicIndex<T>::remove()`.
2. Tags are recorded in `deleted_nodes_` and `deleted_nodes_set_`.
3. The memory graph also receives `lazy_delete()`.
4. Search filters deleted tags from the returned candidates.
5. `save()` materializes deletes with `SSDIndex::merge_deletes()`.

### Save And Merge

`DynamicIndex<T>::save(index_prefix)` compacts the current disk index:

1. Lock out concurrent save/update operations.
2. If saving over the current prefix, write to `{prefix}_v2` first.
3. `merge_deletes()` rewrites live nodes and returns an `old_id -> new_id` map.
4. Loaded native attribute indexes merge through the same ID map.
5. `reload()` opens the compacted index.
6. Same-prefix saves copy the compacted version back to the original prefix and reload again.
7. If the index is memory-only or has a sampled memory navigation graph, write `{prefix}_mem.index`.

## Attribute Filtering

Filtered search uses a selector tree:

| Selector | Meaning |
|----------|---------|
| `LabelOrSelector` | Target attribute contains at least one query label. |
| `LabelAndSelector` | Target attribute contains all query labels. |
| `RangeSelector` | Target scalar attribute is in `[left, right)`. |
| `AndSelector` / `OrSelector` / `NotSelector` | Boolean composition over child selectors. |

Each leaf selector points to an `AttrIndex`. Attribute indexes provide:

- selectivity and precision estimates;
- speculative pre-filtering that returns a superset of valid vector IDs;
- speculative in-filter preparation for rare/cold attribute values;
- approximate membership checks with no false negatives;
- exact membership verification using attributes serialized in SSD nodes.

`SSDIndex::spec_filter_search()` chooses among speculative pre-filter,
post-filter, and in-filter paths based on cost estimates.

## Python Layers

The Python package has three levels:

| File | API level |
|------|-----------|
| `pipeann/index.py` | `IndexPipeANN`, a FAISS-like vector index API over pybind. |
| `pipeann/filter.py` | Python-friendly attributes, attribute vectors, and selector classes. |
| `pipeann/collection.py` | Document/metadata layer backed by SQLite plus one `IndexPipeANN`. |
| `pipeann/client.py` | Multi-collection manager with disk auto-discovery. |
| `pipeann/langchain.py` | LangChain `VectorStore` adapter. |
| `pipeann/qdrant_server.py` | FastAPI server that implements a Qdrant-compatible subset. |

`Collection` persists user-facing IDs, documents, and JSON metadata in
`documents.db`. The ANN index stores only vector tags and optional native
attribute payloads.

