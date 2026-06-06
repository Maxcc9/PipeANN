# PipeANN Agent Notes

This file is the shortest path for future coding agents to re-orient in this
repository. Keep it factual and update it when architecture, build commands, or
important conventions change.

## Project Purpose

PipeANN is a C++17 and Python vector search system for low-latency,
billion-scale, SSD-resident graph ANN. The core index is a Vamana-style graph
stored on SSD, with pipelined asynchronous I/O, dynamic insert/delete support,
attribute-filtered search, optional OOD refinement, and optional SPDK backend.

## Main Code Paths

- `include/index.h`, `src/index.cpp`: in-memory graph index used for build,
  small dynamic indexes, and optional sampled navigation graph.
- `include/ssd_index.h`, `src/ssd_index.cpp`: SSD index loader/saver, metadata,
  search entry points, direct insert, delete merge, tag/page layout handling.
- `src/search/pipe_search.cpp`: primary PipeANN pipelined SSD search path.
- `src/search/spec_filter_search.cpp`: filtered search variants using selector
  trees and attribute indexes.
- `src/update/direct_insert.cpp`: OdinANN-style direct insert into the SSD index.
- `src/update/delete_merge.cpp`: materializes lazy deletes and in-place inserts
  into a compact saved version.
- `include/dynamic_index.h`: high-level typed dynamic index used by Python.
- `src/python/*.cpp`, `pipeann/*.py`: pybind11 module and Python-facing APIs.

## Build And Test

All Python commands for this repository must run inside the `diskann` conda
environment:

```bash
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate diskann
```

Preferred C++ build:

```bash
bash ./build.sh
```

Python extension build used by CI:

```bash
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate diskann
unset DEBUG
export CPLUS_INCLUDE_PATH="$CONDA_PREFIX/include${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
CMAKE_ARGS="-DCMAKE_POLICY_VERSION_MINIMUM=3.5" \
CMAKE_BUILD_PARALLEL_LEVEL=1 python setup.py build_ext --inplace
pytest -q tests_py
```

Before either build, `third_party/liburing` normally needs:

```bash
cd third_party/liburing
./configure
make -j"$(nproc)"
```

The CMake option `IO_ENGINE` accepts `uring`, `aio`, or `spdk`. The default tries
`uring` and falls back to `aio` if the compile/run probe fails. The Python setup
disables tcmalloc by default with `-DUSE_TCMALLOC=OFF`.

## Important Conventions

- Vector binary files use `uint32 npts`, `uint32 dim`, then row-major raw vector
  payload. See `docs/data-formats.md`.
- Public Python data types are `float32`, `uint8`, and `int8`.
- Public metrics are `l2`, `inner_product`/`mips`, and `cosine`.
- Tags are user-visible `uint32` IDs. If no tag file exists, most loaders assume
  `tag == internal id`.
- Disk index prefix files are named from an index prefix, especially
  `{prefix}_disk.index`, `{prefix}_disk.index.tags`, `{prefix}_mem.index`, and
  optional page-layout/attribute sidecars.
- Search beam width `L` must be at least `topk`; larger values trade latency for
  recall.
- Filtered and range search require a loaded disk index.
- `DynamicIndex` keeps small indexes in memory and automatically transforms to a
  disk index after `100000` points.

## Documentation Map

- `docs/architecture.md`: subsystem map and control flow.
- `docs/data-formats.md`: vector, tag, ground-truth, SSD node, attribute, and
  collection persistence formats.
- `docs/development-guide.md`: local build/test workflow and common edit points.
- `docs/local-diskann-data-workflow.md`: local workflow for reading datasets
  from `/home/gt/research/DiskANN/data`, writing PipeANN indexes to
  `/mnt/diskann_data/PipeANN`, and keeping result artifacts under repo-local
  `data/pipeann`.
- `docs/build-search-parameters.md`: practical build/search parameter tables
  for the local workflow, including exact fields written to `metadata.env`.
- `docs/repository-layout.md`: file and script inventory.
- `docs/cpp-interface.md`, `docs/python-interface.md`: user-facing APIs.

## Local DiskANN Dataset Workflow

Use `scripts/local/list_datasets.sh` to inspect available local datasets. Use
`scripts/local/build_index.sh` for C++ index builds and
`scripts/local/search_index.sh` for C++ searches. These scripts share
`scripts/local/pipeann_paths.sh` and default to:

```bash
PIPEANN_DATA_ROOT=/home/gt/research/DiskANN/data
PIPEANN_INDEX_ROOT=/mnt/diskann_data/PipeANN
PIPEANN_RESULTS_ROOT=$PWD/data/pipeann
```
