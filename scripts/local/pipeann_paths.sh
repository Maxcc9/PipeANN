#!/usr/bin/env bash

# Local path and dataset conventions for using DiskANN-prepared datasets with
# PipeANN. Source this file from scripts instead of hard-coding machine paths.

PIPEANN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPEANN_ROOT="$(cd "${PIPEANN_SCRIPT_DIR}/../.." && pwd)"

PIPEANN_DATA_ROOT="${PIPEANN_DATA_ROOT:-/home/gt/research/DiskANN/data}"
PIPEANN_INDEX_ROOT="${PIPEANN_INDEX_ROOT:-/mnt/diskann_data/PipeANN}"
PIPEANN_RESULTS_ROOT="${PIPEANN_RESULTS_ROOT:-${PIPEANN_ROOT}/data/pipeann}"

pipeann_die() {
  echo "ERROR: $*" >&2
  exit 1
}

pipeann_dataset_type() {
  case "$1" in
    siftsmall|sift1m|deep1m|deep100m|gist1m|text2image1m)
      echo "float"
      ;;
    sift100m)
      echo "uint8"
      ;;
    spacev100m)
      echo "int8"
      ;;
    *)
      pipeann_die "Unknown dataset '$1'. Add it to scripts/local/pipeann_paths.sh."
      ;;
  esac
}

pipeann_dataset_metric() {
  case "$1" in
    text2image1m)
      echo "mips"
      ;;
    *)
      echo "l2"
      ;;
  esac
}

pipeann_dataset_base() {
  echo "${PIPEANN_DATA_ROOT}/$1/${1}_base.bin"
}

pipeann_dataset_query() {
  echo "${PIPEANN_DATA_ROOT}/$1/${1}_query.bin"
}

pipeann_dataset_groundtruth() {
  echo "${PIPEANN_DATA_ROOT}/$1/${1}_groundtruth.bin"
}

pipeann_index_tag() {
  local dataset="$1"
  local r="$2"
  local build_l="$3"
  local pq_bytes="$4"
  local mem_gb="$5"
  echo "${dataset}_R${r}_L${build_l}_B${pq_bytes}_M${mem_gb}"
}

pipeann_index_dir() {
  local experiment_tag="$1"
  local index_tag="$2"
  echo "${PIPEANN_INDEX_ROOT}/${experiment_tag}/${index_tag}"
}

pipeann_index_prefix() {
  local experiment_tag="$1"
  local index_tag="$2"
  echo "$(pipeann_index_dir "${experiment_tag}" "${index_tag}")/${index_tag}"
}

pipeann_build_result_dir() {
  local experiment_tag="$1"
  local index_tag="$2"
  echo "${PIPEANN_RESULTS_ROOT}/build/${experiment_tag}/${index_tag}"
}

pipeann_search_result_dir() {
  local experiment_tag="$1"
  local index_tag="$2"
  local search_tag="$3"
  echo "${PIPEANN_RESULTS_ROOT}/search/${experiment_tag}/${index_tag}/${search_tag}"
}

pipeann_require_file() {
  local file="$1"
  [[ -f "${file}" ]] || pipeann_die "Missing file: ${file}"
}

pipeann_require_exe() {
  local exe="$1"
  [[ -x "${PIPEANN_ROOT}/${exe}" ]] || pipeann_die "Missing executable: ${PIPEANN_ROOT}/${exe}. Run bash ./build.sh first."
}

pipeann_print_dataset_table() {
  printf "%-16s %-8s %-6s %-12s %-12s %-12s\n" "dataset" "type" "metric" "base" "query" "groundtruth"
  for dataset in siftsmall sift1m sift100m deep1m deep100m gist1m spacev100m text2image1m; do
    printf "%-16s %-8s %-6s %-12s %-12s %-12s\n" \
      "${dataset}" \
      "$(pipeann_dataset_type "${dataset}")" \
      "$(pipeann_dataset_metric "${dataset}")" \
      "$([[ -f "$(pipeann_dataset_base "${dataset}")" ]] && echo yes || echo no)" \
      "$([[ -f "$(pipeann_dataset_query "${dataset}")" ]] && echo yes || echo no)" \
      "$([[ -f "$(pipeann_dataset_groundtruth "${dataset}")" ]] && echo yes || echo no)"
  done
}

