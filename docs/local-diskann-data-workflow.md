---
hide:
  - navigation
---

# Local DiskANN Data Workflow

This repository can reuse datasets prepared under the local DiskANN checkout:

```text
/home/gt/research/DiskANN/data
```

PipeANN index files are written under:

```text
/mnt/diskann_data/PipeANN
```

Search/build logs, CSV summaries, plots, and other result artifacts stay inside
this repository under:

```text
data/pipeann
```

`data/*` is ignored by git, so local experiment outputs do not pollute commits.

## Directory Convention

The local scripts follow the same idea as DiskANN's runbook:

```text
/mnt/diskann_data/PipeANN/{EXPERIMENT_TAG}/{INDEX_TAG}/{INDEX_TAG}_disk.index
data/pipeann/build/{EXPERIMENT_TAG}/{INDEX_TAG}/build.log
data/pipeann/search/{EXPERIMENT_TAG}/{INDEX_TAG}/{SEARCH_TAG}/summary.csv
```

`INDEX_TAG` defaults to:

```text
{dataset}_R{R}_L{BUILD_L}_B{PQ_BYTES}_M{MEM_GB}
```

Example:

```text
sift1m_R64_L100_B32_M16
```

## Dataset Registry

The registry lives in `scripts/local/pipeann_paths.sh`.

Current defaults:

| Dataset | Type | Metric |
|---------|------|--------|
| `siftsmall` | `float` | `l2` |
| `sift1m` | `float` | `l2` |
| `sift100m` | `uint8` | `l2` |
| `deep1m` | `float` | `l2` |
| `deep100m` | `float` | `l2` |
| `gist1m` | `float` | `l2` |
| `spacev100m` | `int8` | `l2` |
| `text2image1m` | `float` | `mips` |

List available local datasets:

```bash
bash scripts/local/list_datasets.sh
```

## Build An Index

Build binaries first:

```bash
bash ./build.sh
```

Then build an index. This writes index files only under
`/mnt/diskann_data/PipeANN`.

```bash
DATASET=sift1m \
EXPERIMENT_TAG=sift1m_pipeann_test \
R=64 BUILD_L=100 PQ_BYTES=32 MEM_GB=16 THREADS=$(nproc) \
bash scripts/local/build_index.sh
```

Useful options:

| Variable | Default | Meaning |
|----------|---------|---------|
| `DATASET` | required | Dataset name in the registry. |
| `EXPERIMENT_TAG` | `{DATASET}_pipeann` | Top-level output folder under `/mnt/diskann_data/PipeANN`. |
| `R` | `64` | Graph out-degree. |
| `BUILD_L` | `100` | Build candidate pool. |
| `PQ_BYTES` | `32` | PQ bytes. |
| `MEM_GB` | `16` | Build memory budget in GB. |
| `THREADS` | `nproc` | Build threads. |
| `DATA_TYPE` | registry value | Override type. |
| `METRIC` | registry value | Override metric. |
| `BUILD_MEM_INDEX` | `0` | Set to `1` to also build `{prefix}_mem.index`. |

See [Build And Search Parameters](build-search-parameters.md) for the full
parameter table and the exact underlying C++ command.

## Search An Index

Search results are written inside the repository:

```bash
DATASET=sift1m \
EXPERIMENT_TAG=sift1m_pipeann_test \
R=64 BUILD_L=100 PQ_BYTES=32 MEM_GB=16 \
TOPK=10 THREADS=1 BEAM_WIDTH=32 MODE=2 MEM_L=0 \
SEARCH_LS="10 20 30 40 50 80 120" \
bash scripts/local/search_index.sh
```

Outputs:

```text
data/pipeann/search/{EXPERIMENT_TAG}/{INDEX_TAG}/{SEARCH_TAG}/metadata.env
data/pipeann/search/{EXPERIMENT_TAG}/{INDEX_TAG}/{SEARCH_TAG}/search.log
data/pipeann/search/{EXPERIMENT_TAG}/{INDEX_TAG}/{SEARCH_TAG}/summary.csv
```

Search modes match `build/tests/search_disk_index`:

| Mode | Algorithm |
|------|-----------|
| `0` | DiskANN-style beam search |
| `1` | page search |
| `2` | PipeANN pipelined search |
| `3` | coroutine search |

See [Build And Search Parameters](build-search-parameters.md) for every search
parameter recorded in `metadata.env`.

## Override Roots

The local scripts can be redirected without editing files:

```bash
PIPEANN_DATA_ROOT=/path/to/data \
PIPEANN_INDEX_ROOT=/mnt/diskann_data/PipeANN \
PIPEANN_RESULTS_ROOT=/home/gt/research/PipeANN/data/pipeann \
DATASET=siftsmall \
bash scripts/local/build_index.sh
```
