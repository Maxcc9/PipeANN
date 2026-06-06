---
hide:
  - navigation
---

# Build And Search Parameters

This page records the parameters used by the local PipeANN workflow. It focuses
on the parameters that are actually passed to build/search scripts and recorded
in `metadata.env`.

## Local Roots

These variables decide where inputs, indexes, and result artifacts live.

| Variable | Default | Used by | Meaning |
|----------|---------|---------|---------|
| `PIPEANN_DATA_ROOT` | `/home/gt/research/DiskANN/data` | build, search | Dataset root. Each dataset is expected at `{root}/{dataset}/`. |
| `PIPEANN_INDEX_ROOT` | `/mnt/diskann_data/PipeANN` | build, search | PipeANN index root. Index files are written/read here. |
| `PIPEANN_RESULTS_ROOT` | `{repo}/data/pipeann` | build, search | Repo-local logs, metadata, CSV summaries, plots, and analysis outputs. |

Index files should be the only large build artifacts under
`PIPEANN_INDEX_ROOT`. Search outputs such as `.csv`, `.png`, and logs should
stay under `PIPEANN_RESULTS_ROOT`.

## Dataset Registry

Defined in `scripts/local/pipeann_paths.sh`.

| Dataset | `DATA_TYPE` | `METRIC` | Expected files |
|---------|-------------|----------|----------------|
| `siftsmall` | `float` | `l2` | `siftsmall_base.bin`, `siftsmall_query.bin`, `siftsmall_groundtruth.bin` |
| `sift1m` | `float` | `l2` | `sift1m_base.bin`, `sift1m_query.bin`, `sift1m_groundtruth.bin` |
| `sift100m` | `uint8` | `l2` | `sift100m_base.bin`, `sift100m_query.bin`, `sift100m_groundtruth.bin` |
| `deep1m` | `float` | `l2` | `deep1m_base.bin`, `deep1m_query.bin`, `deep1m_groundtruth.bin` |
| `deep100m` | `float` | `l2` | `deep100m_base.bin`, `deep100m_query.bin`, `deep100m_groundtruth.bin` |
| `gist1m` | `float` | `l2` | `gist1m_base.bin`, `gist1m_query.bin`, `gist1m_groundtruth.bin` |
| `spacev100m` | `int8` | `l2` | `spacev100m_base.bin`, `spacev100m_query.bin`, `spacev100m_groundtruth.bin` |
| `text2image1m` | `float` | `mips` | `text2image1m_base.bin`, `text2image1m_query.bin`, `text2image1m_groundtruth.bin` |

Check availability:

```bash
bash scripts/local/list_datasets.sh
```

## Build Parameters

Local entry point:

```bash
bash scripts/local/build_index.sh
```

The script records these fields in:

```text
data/pipeann/build/{EXPERIMENT_TAG}/{INDEX_TAG}/metadata.env
```

| Variable | Required | Default | Passed to C++ | Meaning |
|----------|----------|---------|---------------|---------|
| `DATASET` | yes | none | indirect | Dataset registry key. Can also be first positional argument. |
| `EXPERIMENT_TAG` | no | `${DATASET}_pipeann` | no | Top-level experiment folder under `PIPEANN_INDEX_ROOT` and `PIPEANN_RESULTS_ROOT`. |
| `INDEX_TAG` | no | `${DATASET}_R${R}_L${BUILD_L}_B${PQ_BYTES}_M${MEM_GB}` | no | Index configuration folder and prefix basename. |
| `DATA_TYPE` | no | registry value | arg 1 | Vector type: `float`, `int8`, `uint8`. |
| `BASE_FILE` | no | `{PIPEANN_DATA_ROOT}/{DATASET}/{DATASET}_base.bin` | arg 2 | Base vector file. |
| `INDEX_PREFIX` | derived | `{PIPEANN_INDEX_ROOT}/{EXPERIMENT_TAG}/{INDEX_TAG}/{INDEX_TAG}` | arg 3 | Output prefix. C++ writes `{prefix}_disk.index` and sidecars. |
| `R` | no | `64` | arg 4 | Graph max out-degree. |
| `BUILD_L` | no | `100` | arg 5 | Vamana build candidate list. If `L2 > 0`, this is PiPNN `L1`. |
| `PQ_BYTES` | no | `32` | arg 6 | PQ bytes per vector. |
| `MEM_GB` | no | `16` | arg 7 | Build memory budget in GB. |
| `THREADS` | no | `$(nproc)` | arg 8 | Build thread count. |
| `METRIC` | no | registry value | arg 9 | `l2`, `cosine`, or `mips`. |
| `NBR_TYPE` | no | `pq` | arg 10 | Neighbor codec, usually `pq`; also supports RaBitQ variants in C++. |
| `L2` | no | `0` | optional arg 11 | `0` means Vamana. `>0` enables PiPNN with `BUILD_L * L2` effective candidate work. |
| `BUILD_MEM_INDEX` | no | `0` | no | If `1`, also builds `{INDEX_PREFIX}_mem.index`. |
| `SAMPLE_RATE` | no | `0.01` | memory-index helper | Sampling probability for memory entry-point index. |
| `MEM_R` | no | `32` | memory-index arg | Memory index graph degree. |
| `MEM_BUILD_L` | no | `64` | memory-index arg | Memory index build L. |
| `MEM_ALPHA` | no | `1.2` | memory-index arg | Memory index pruning alpha. |

### Underlying Build Command

`scripts/local/build_index.sh` expands to:

```bash
build/tests/build_disk_index \
  "${DATA_TYPE}" \
  "${BASE_FILE}" \
  "${INDEX_PREFIX}" \
  "${R}" \
  "${BUILD_L}" \
  "${PQ_BYTES}" \
  "${MEM_GB}" \
  "${THREADS}" \
  "${METRIC}" \
  "${NBR_TYPE}" \
  ["${L2}" if L2 != 0]
```

If `BUILD_MEM_INDEX=1`, it additionally runs:

```bash
build/tests/utils/gen_random_slice \
  "${DATA_TYPE}" "${BASE_FILE}" "${INDEX_PREFIX}_SAMPLE_RATE_${SAMPLE_RATE}" "${SAMPLE_RATE}"

build/tests/build_memory_index \
  "${DATA_TYPE}" \
  "${INDEX_PREFIX}_SAMPLE_RATE_${SAMPLE_RATE}_data.bin" \
  "${INDEX_PREFIX}_SAMPLE_RATE_${SAMPLE_RATE}_ids.bin" \
  "${INDEX_PREFIX}_mem.index" \
  "${MEM_R}" "${MEM_BUILD_L}" "${MEM_ALPHA}" "${THREADS}" "${METRIC}"
```

## Search Parameters

Local entry point:

```bash
bash scripts/local/search_index.sh
```

The script records these fields in:

```text
data/pipeann/search/{EXPERIMENT_TAG}/{INDEX_TAG}/{SEARCH_TAG}/metadata.env
```

| Variable | Required | Default | Passed to C++ | Meaning |
|----------|----------|---------|---------------|---------|
| `DATASET` | yes | none | indirect | Dataset registry key. Can also be first positional argument. |
| `EXPERIMENT_TAG` | no | `${DATASET}_pipeann` | no | Must match build experiment unless `INDEX_PREFIX` is overridden. |
| `INDEX_TAG` | no | `${DATASET}_R${R}_L${BUILD_L}_B${PQ_BYTES}_M${MEM_GB}` | no | Must match build index tag unless `INDEX_PREFIX` is overridden. |
| `DATA_TYPE` | no | registry value | arg 1 | Query/index vector type: `float`, `int8`, `uint8`. |
| `INDEX_PREFIX` | no | `{PIPEANN_INDEX_ROOT}/{EXPERIMENT_TAG}/{INDEX_TAG}/{INDEX_TAG}` | arg 2 | Existing index prefix to search. |
| `THREADS` | no | `1` | arg 3 | Search thread count. |
| `BEAM_WIDTH` | no | `32` | arg 4 | I/O pipeline width. |
| `QUERY_FILE` | no | `{PIPEANN_DATA_ROOT}/{DATASET}/{DATASET}_query.bin` | arg 5 | Query vector file. |
| `GT_FILE` | no | `{PIPEANN_DATA_ROOT}/{DATASET}/{DATASET}_groundtruth.bin` | arg 6 | Ground-truth file. |
| `TOPK` | no | `10` | arg 7 | Top-k and recall@k. |
| `METRIC` | no | registry value | arg 8 | `l2`, `cosine`, or `mips`. |
| `NBR_TYPE` | no | `pq` | arg 9 | Neighbor codec used by the index. |
| `MODE` | no | `2` | arg 10 | Search algorithm mode. |
| `MEM_L` | no | `0` | arg 11 | Memory entry-point search L. `0` disables `{prefix}_mem.index`. |
| `SEARCH_LS` | no | `10 20 30 40 50 60 80 120 200` | args 12+ | One or more search L values. |
| `SEARCH_TAG` | no | `K${TOPK}_W${BEAM_WIDTH}_mode${MODE}_memL${MEM_L}_T${THREADS}` | no | Result folder name. |

Search modes:

| `MODE` | Algorithm |
|--------|-----------|
| `0` | DiskANN-style beam search |
| `1` | Page search |
| `2` | PipeANN pipelined search |
| `3` | Coroutine search |

### Underlying Search Command

`scripts/local/search_index.sh` expands to:

```bash
build/tests/search_disk_index \
  "${DATA_TYPE}" \
  "${INDEX_PREFIX}" \
  "${THREADS}" \
  "${BEAM_WIDTH}" \
  "${QUERY_FILE}" \
  "${GT_FILE}" \
  "${TOPK}" \
  "${METRIC}" \
  "${NBR_TYPE}" \
  "${MODE}" \
  "${MEM_L}" \
  ${SEARCH_LS}
```

It writes:

```text
data/pipeann/search/{EXPERIMENT_TAG}/{INDEX_TAG}/{SEARCH_TAG}/metadata.env
data/pipeann/search/{EXPERIMENT_TAG}/{INDEX_TAG}/{SEARCH_TAG}/search.log
data/pipeann/search/{EXPERIMENT_TAG}/{INDEX_TAG}/{SEARCH_TAG}/summary.csv
```

`summary.csv` columns:

| Column | Meaning |
|--------|---------|
| `L` | Search L used for this row. |
| `io_width` | Beam width / I/O width. |
| `qps` | Queries per second. |
| `avg_lat_us` | Average latency in microseconds. |
| `p99_lat_us` | 99th percentile latency in microseconds. |
| `mean_hops` | Mean graph hops. |
| `mean_ios` | Mean I/O count. |
| `recall` | Recall@`TOPK` if ground truth is available. |

## Smoke Example

The current smoke run used:

```bash
DATASET=siftsmall
EXPERIMENT_TAG=siftsmall_pipeann_smoke
R=32
BUILD_L=64
PQ_BYTES=16
MEM_GB=1
THREADS=2
```

Search used:

```bash
TOPK=10
THREADS=1
BEAM_WIDTH=8
MODE=2
MEM_L=0
SEARCH_LS="10 20 40 80"
```

Build metadata:

```text
data/pipeann/build/siftsmall_pipeann_smoke/siftsmall_R32_L64_B16_M1/metadata.env
```

Search metadata:

```text
data/pipeann/search/siftsmall_pipeann_smoke/siftsmall_R32_L64_B16_M1/K10_W8_mode2_memL0_T1/metadata.env
```

