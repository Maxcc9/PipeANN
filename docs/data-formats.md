---
hide:
  - navigation
---

# Data Formats

This page documents the file formats and persistence layout used by PipeANN.
Unless otherwise noted, integer values are little-endian.

## Vector Binary Files

PipeANN's standard vector files use a compact row-major binary format:

| Field | Type | Description |
|-------|------|-------------|
| `npts` | `uint32` | Number of vectors. |
| `dim` | `uint32` | Vector dimension. |
| payload | `T[npts][dim]` | Row-major vector values. |

Supported vector payload types are:

- `float32`
- `uint8`
- `int8`

Python helpers in `tests_py/utils.py` implement this format as `bin_read()` and
`bin_write()`.

## Tag Files

Tags are user-facing IDs stored as `uint32`.

When a tag sidecar is present, it stores one tag per vector. When it is absent,
the code generally assumes an identity mapping:

```text
tag == internal vector id
```

Important tag-related files:

| File | Meaning |
|------|---------|
| `{prefix}_disk.index.tags` | Tags for the SSD index. |
| `{prefix}_mem.index.tags` | Tags for a saved memory-navigation index. |

## Ground Truth Files

Search benchmarks call `load_truthset()` and expect ground-truth IDs and
optional distances. Test utilities also use the same vector-style header for
simple integer ground truth arrays:

| Field | Type | Description |
|-------|------|-------------|
| `npts` | `uint32` | Number of queries. |
| `dim` | `uint32` | Ground-truth neighbors per query. |
| payload | usually `int32[npts][dim]` or `uint32[npts][dim]` | Neighbor IDs/tags. |

Some benchmark datasets include distances in a DiskANN-compatible truthset. Read
the relevant utility before generating new ground truth for a benchmark.

## SSD Index Prefix

Most APIs use an index prefix instead of a single path. The important files are:

| File | Producer | Description |
|------|----------|-------------|
| `{prefix}_disk.index` | disk build/save | Main SSD-resident node file. |
| `{prefix}_disk.index.tags` | disk build/save | Optional tag sidecar. |
| `{prefix}_mem.index` | `build_mem_index` or dynamic save | Optional sampled memory-navigation graph saved in SSD node format. |
| `{prefix}_mem.index.tags` | memory graph save | Tags for the memory-navigation graph. |
| `{prefix}_mem_data.bin` | dynamic memory-to-disk transform | Temporary vector file emitted before disk rebuild. |
| `{prefix}_shadow_*` | `DynamicIndex.load(copy_to_shadow=true)` | Shadow copy used to avoid modifying the original prefix. |
| `{prefix}_v2_*` | same-prefix save | Double-version save target before copying back. |

The exact set of files depends on whether tags, sampled memory graph, page
layout, updates, and native attributes are used.

## SSD Index Metadata

The first 4096-byte sector of `{prefix}_disk.index` stores
`SSDIndexMetadata<T>`.

Current metadata version writes:

| Field | Type | Meaning |
|-------|------|---------|
| `nr` | `uint32` | Metadata row/version marker, currently `9`. |
| `nc` | `uint32` | Metadata column marker, currently `1`. |
| `npoints` | `uint64` | Base number of vectors in the index. |
| `data_dim` | `uint64` | Vector dimension. |
| `entry_point` | `uint64` | Graph entry point ID. |
| `max_node_len` | `uint64` | Bytes reserved per disk node, including dense neighbors. |
| `nnodes_per_sector` | `uint64` | Number of nodes packed into one sector; `0` means one node spans one or more sectors. |
| `npts_cur_shard` | `uint64` | Points in current shard. Non-sharded loads reset this to `npoints`. |
| `attr_size` | `uint64` | Bytes reserved for serialized attributes per node. |
| `range` | `uint64` | Normal graph out-degree stored before attributes. |
| `R_ood` | `uint64` | Number of NGFix/OOD refine edge slots. |

Temporary fields such as `normal_node_len`, `range_dense`, `max_npts`, and
`entry_point_id` are recomputed after load and are not stored as independent
metadata fields.

## Disk Node Layout

Each disk node is a fixed-size record. The record is interpreted by
`DiskNode<T>` in `include/ssd_index_defs.h`.

```text
[ vector coords | nnbrs + n_dense_nbrs | normal neighbor IDs | attributes | dense neighbor IDs ]
```

Detailed layout:

| Segment | Type | Size |
|---------|------|------|
| coordinates | `T[data_dim]` | `data_dim * sizeof(T)` |
| neighbor counts | two `uint16` values | stored in the 4-byte count slot |
| normal neighbors | `uint32[range]` | graph edges used by normal search |
| attributes | raw bytes | `attr_size` |
| dense neighbors | `uint32[range_dense - range]` | extra edges for dense/filtered search |

`nnbrs` is the actual normal out-degree. `n_dense_nbrs` is the total dense
degree. The dense-neighbor area may include sampled 2-hop neighbors used by
filtered search.

Offset helpers:

| Helper | Meaning |
|--------|---------|
| `loc_sector_no(loc)` | Sector number for an internal location. Data starts at sector 1 because sector 0 stores metadata. |
| `sector_to_loc(sector, off)` | Reverse mapping from sector and packed-sector offset. |
| `u_loc_offset(loc)` | Unaligned byte offset of a node record. |
| `u_loc_offset_nbr(loc)` | Unaligned byte offset of the neighbor/count area. |

## Attribute Rows

An in-node `Attributes` payload is a map from `uint32 key` to a vector of
`uint32` values.

Serialized format:

```text
uint32 n_keys
repeat n_keys:
  uint32 key
  uint32 n_values
  uint32 values[n_values]
```

The reserved per-node attribute size is `attr_size`; writers must ensure each
serialized row fits in the reserved area.

## Attribute Index Files

Native attribute indexes are stored separately from the main disk nodes and are
loaded through `load_attr_index_from_file()`.

Supported logical types include:

| Type | Typical selector |
|------|------------------|
| label/inverted label | `LabelOrSelector`, `LabelAndSelector` |
| range/scalar | `RangeSelector` |

Attribute indexes maintain on-disk postings/statistics plus in-memory
approximate structures for speculative filtering. Inserted-but-unmerged
attributes are held in `AttrIndex::delta_attrs_` until save/merge materializes
them.

## Sparse Matrix Attribute Inputs

`load_spmat()` reads a CSR-like binary sparse matrix:

| Field | Type | Description |
|-------|------|-------------|
| `nrow` | `int64` | Number of rows. |
| `ncol` | `int64` | Number of columns. |
| `nnz` | `int64` | Number of nonzeros. |
| `indptr` | `int64[nrow + 1]` | Row pointer. |
| `indices` | `int32[nnz]` | Column IDs. |
| `data` | `float32[nnz]` | Values. |

The Python helper `write_spmat()` in `tests_py/utils.py` writes the same layout.

## Collection Persistence

`pipeann.Collection.save(base_dir)` stores a collection under:

```text
{base_dir}/{collection_name}/
  schema.json
  documents.db
  index_disk.index
  index_disk.index.tags
  index_mem.index        # optional
  index_mem.index.tags   # optional
```

`documents.db` contains:

| Column | Meaning |
|--------|---------|
| `id` | User-facing string ID. |
| `tag` | `uint32` tag stored in PipeANN. |
| `document` | Text payload. |
| `metadata` | JSON metadata string. |

`schema.json` stores collection identity:

```json
{
  "type": "collection",
  "config": {
    "data_dim": 128,
    "data_type": "float32",
    "metric": "l2"
  },
  "attr_indexes": {}
}
```

