---
hide:
  - navigation
---

# Development Guide

This page is for contributors changing PipeANN internals or Python-facing
behavior.

## Local Prerequisites

All Python-facing development in this checkout should use the `diskann` conda
environment. Activate it before running `python`, `pip`, `pytest`, `setup.py`,
or Python examples:

```bash
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate diskann
```

On Ubuntu 22.04 or newer:

```bash
sudo apt install make cmake g++ libaio-dev libgoogle-perftools-dev \
                 clang-format libmkl-full-dev libeigen3-dev
pip install "pybind11[global]" numpy pytest ninja
```

OpenBLAS can be used instead of MKL. CI uses `libopenblas-dev`.

Build `liburing` before the main project:

```bash
cd third_party/liburing
./configure
make -j"$(nproc)"
cd ../..
```

## C++ Build

The simple project build is:

```bash
bash ./build.sh
```

Equivalent explicit CMake flow:

```bash
cmake -S . -B build
cmake --build build -j"$(nproc)"
```

Useful CMake options:

| Option | Values | Default | Notes |
|--------|--------|---------|-------|
| `IO_ENGINE` | `uring`, `aio`, `spdk` | `uring`, with fallback to `aio` | `spdk` requires `third_party/spdk` with built pkg-config files. |
| `USE_TCMALLOC` | `ON`, `OFF` | `ON` | Python setup forces `OFF`. |
| `BUILD_PYTHON_INTERFACE` | `ON`, `OFF` | `OFF` | Builds pybind module `pipeann.C`. |

The top-level CMake probes CPU SIMD support and adds AVX512, AVX512 VPOPCNTDQ,
or AVX2 definitions when both compiler and runtime CPU support are present.

## Python Build

CI builds the extension in-place with:

```bash
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate diskann
unset DEBUG
export CPLUS_INCLUDE_PATH="$CONDA_PREFIX/include${CPLUS_INCLUDE_PATH:+:$CPLUS_INCLUDE_PATH}"
CMAKE_ARGS="-DCMAKE_POLICY_VERSION_MINIMUM=3.5" \
CMAKE_BUILD_PARALLEL_LEVEL=1 python setup.py build_ext --inplace
```

Editable install for local use:

```bash
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate diskann
pip install -e .
```

`setup.py` passes these CMake flags:

```text
-DBUILD_PYTHON_INTERFACE=ON
-DUSE_TCMALLOC=OFF
```

Additional CMake flags can be supplied with `CMAKE_ARGS`, for example:

```bash
CMAKE_ARGS="-DIO_ENGINE=aio" pip install -e .
```

The local `diskann` environment currently uses CMake 4.x, so builds need
`-DCMAKE_POLICY_VERSION_MINIMUM=3.5` until the project raises its
`cmake_minimum_required()` version. Eigen is installed inside the conda
environment, so `CPLUS_INCLUDE_PATH` must include `$CONDA_PREFIX/include` for
headers such as `eigen3/Eigen/Dense`.

## Test Commands

Python tests:

```bash
source "$(conda info --base)/etc/profile.d/conda.sh"
conda activate diskann
pytest -q tests_py
```

C++ benchmark/test binaries are built under `build/tests/` and
`build/tests/utils/`.

Common commands:

```bash
build/tests/build_disk_index uint8 data.bin index_prefix 64 96 32 8 32 l2 pq
build/tests/search_disk_index uint8 index_prefix 1 32 query.bin gt.bin 10 l2 pq 2 0 50
```

The large evaluation scripts in `scripts/` assume hard-coded paths under
`/mnt/nvme` and `/mnt/nvme2`. Edit those scripts or create matching symlinks
before running paper reproduction experiments.

## Continuous Integration

`.github/workflows/ci.yml` performs:

1. Ubuntu 22.04 checkout.
2. Python 3.12 setup.
3. System dependency install: build tools, CMake, AIO, Eigen, OpenBLAS.
4. `third_party/liburing` build.
5. Python dependency install, including pytest, Qdrant client, FastAPI,
   Uvicorn, and LangChain Core.
6. `python setup.py build_ext --inplace`.
7. `pytest -q tests_py`.

`.github/workflows/pages.yml` builds the MkDocs site with `mkdocs build
--strict`.

## Common Edit Points

| Goal | Files |
|------|-------|
| Change memory graph build/search | `include/index.h`, `src/index.cpp` |
| Change SSD search behavior | `include/ssd_index.h`, `src/search/*.cpp` |
| Change pipelined search scheduling | `src/search/pipe_search.cpp`, `src/search/pipe_search_common.h` |
| Change direct insert behavior | `src/update/direct_insert.cpp`, `include/ssd_index.h` |
| Change delete/save compaction | `src/update/delete_merge.cpp`, `include/dynamic_index.h` |
| Change disk layout/metadata | `include/ssd_index_defs.h`, `src/ssd_index.cpp`, build/save helpers |
| Change attribute filtering | `include/filter/attribute.h`, `include/filter/selector.h`, `src/search/spec_filter_search.cpp` |
| Change Python vector API | `pipeann/index.py`, `include/pyindex.h`, `src/python/pyindex.cpp`, `src/python/pybind.cpp` |
| Change collection persistence | `pipeann/collection.py`, `pipeann/client.py` |
| Change integrations | `pipeann/langchain.py`, `pipeann/qdrant_server.py` |

## Adding A Python-Facing Feature

Use this path when adding a new feature that crosses C++ and Python:

1. Add or update the typed C++ method on `DynamicIndex<T>` if the feature needs
   memory/disk routing.
2. Add a type-erased wrapper method to `PyIndexInterface`.
3. Bind it in `src/python/pybind.cpp`.
4. Add Python validation and documentation in `pipeann/index.py` or
   `pipeann/filter.py`.
5. Add a focused test in `tests_py/`.

Keep array inputs contiguous at the Python boundary with
`np.ascontiguousarray()`. If C++ work is long-running or parallel, release the
GIL in the pybind layer.

## Adding Or Changing Disk Format

Disk format changes require extra care:

1. Update `SSDIndexMetadata<T>` and preserve backward-compatible loading when
   possible.
2. Update `DiskNode<T>` offsets if the node record changes.
3. Update `save_from_mem()`, `load()`, `merge_deletes()`, and any update path
   that writes nodes.
4. Update `docs/data-formats.md`.
5. Add a test that builds, loads, searches, saves, reloads, and searches again.

Avoid changing record layout unless the search and merge paths are updated
together.

## Adding Search Modes Or Metrics

For a new search mode:

1. Add an enum value in `include/ssd_index.h`.
2. Add an `SSDIndex` entry point.
3. Update `tests/search_disk_index.cpp`.
4. Add or update docs that show the mode number and intended use.

For a new metric:

1. Update `Metric` parsing and distance implementation in `include/distance.h`
   and `src/utils/distance.cpp`.
2. Check PQ/RaBitQ neighbor handlers.
3. Expose it in `src/python/pybind.cpp` and `pipeann/index.py`.
4. Add Python and C++ smoke coverage.

## Performance Notes

- `L` and beam width dominate the latency/recall tradeoff in search.
- `mem_L > 0` uses `{prefix}_mem.index` as a sampled navigation graph for the
  disk index.
- `range_dense` increases node size but gives filtered search more candidate
  edges.
- `IO_ENGINE=spdk` is the highest-performance I/O path but requires external
  SPDK setup.
- `USE_TCMALLOC=ON` is the C++ default, but Python extension builds disable it
  for simpler packaging.
