#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/pipeann_paths.sh"

DATASET="${DATASET:-${1:-}}"
[[ -n "${DATASET}" ]] || pipeann_die "Usage: DATASET=sift1m EXPERIMENT_TAG=sift1m_test INDEX_TAG=... bash scripts/local/search_index.sh"

EXPERIMENT_TAG="${EXPERIMENT_TAG:-${DATASET}_pipeann}"
DATA_TYPE="${DATA_TYPE:-$(pipeann_dataset_type "${DATASET}")}"
METRIC="${METRIC:-$(pipeann_dataset_metric "${DATASET}")}"
NBR_TYPE="${NBR_TYPE:-pq}"

R="${R:-64}"
BUILD_L="${BUILD_L:-100}"
PQ_BYTES="${PQ_BYTES:-32}"
MEM_GB="${MEM_GB:-16}"
INDEX_TAG="${INDEX_TAG:-$(pipeann_index_tag "${DATASET}" "${R}" "${BUILD_L}" "${PQ_BYTES}" "${MEM_GB}")}"
INDEX_PREFIX="${INDEX_PREFIX:-$(pipeann_index_prefix "${EXPERIMENT_TAG}" "${INDEX_TAG}")}"

QUERY_FILE="${QUERY_FILE:-$(pipeann_dataset_query "${DATASET}")}"
GT_FILE="${GT_FILE:-$(pipeann_dataset_groundtruth "${DATASET}")}"
TOPK="${TOPK:-10}"
THREADS="${THREADS:-1}"
BEAM_WIDTH="${BEAM_WIDTH:-32}"
MODE="${MODE:-2}"
MEM_L="${MEM_L:-0}"
SEARCH_LS="${SEARCH_LS:-10 20 30 40 50 60 80 120 200}"
SEARCH_TAG="${SEARCH_TAG:-K${TOPK}_W${BEAM_WIDTH}_mode${MODE}_memL${MEM_L}_T${THREADS}}"

RESULT_DIR="$(pipeann_search_result_dir "${EXPERIMENT_TAG}" "${INDEX_TAG}" "${SEARCH_TAG}")"
LOG_FILE="${RESULT_DIR}/search.log"
CSV_FILE="${RESULT_DIR}/summary.csv"
METADATA_FILE="${RESULT_DIR}/metadata.env"

pipeann_require_exe "build/tests/search_disk_index"
pipeann_require_file "${INDEX_PREFIX}_disk.index"
pipeann_require_file "${QUERY_FILE}"
pipeann_require_file "${GT_FILE}"

mkdir -p "${RESULT_DIR}"

cat > "${METADATA_FILE}" <<EOF
DATASET=${DATASET}
EXPERIMENT_TAG=${EXPERIMENT_TAG}
INDEX_TAG=${INDEX_TAG}
DATA_TYPE=${DATA_TYPE}
METRIC=${METRIC}
NBR_TYPE=${NBR_TYPE}
INDEX_PREFIX=${INDEX_PREFIX}
QUERY_FILE=${QUERY_FILE}
GT_FILE=${GT_FILE}
TOPK=${TOPK}
THREADS=${THREADS}
BEAM_WIDTH=${BEAM_WIDTH}
MODE=${MODE}
MEM_L=${MEM_L}
SEARCH_LS=${SEARCH_LS}
EOF

read -r -a search_l_array <<< "${SEARCH_LS}"

cmd=(
  "${PIPEANN_ROOT}/build/tests/search_disk_index"
  "${DATA_TYPE}"
  "${INDEX_PREFIX}"
  "${THREADS}"
  "${BEAM_WIDTH}"
  "${QUERY_FILE}"
  "${GT_FILE}"
  "${TOPK}"
  "${METRIC}"
  "${NBR_TYPE}"
  "${MODE}"
  "${MEM_L}"
  "${search_l_array[@]}"
)

echo "Search metadata written to ${METADATA_FILE}"
echo "Search log will be written to ${LOG_FILE}"
echo "Search CSV will be written to ${CSV_FILE}"

{
  printf 'Command:'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  "${cmd[@]}"
} 2>&1 | tee "${LOG_FILE}"

awk '
  BEGIN {
    print "L,io_width,qps,mean_lat_us,p50_lat_us,p99_lat_us,mean_hops,mean_ios,recall"
  }
  /^[[:space:]]*[0-9]+[[:space:]]/ {
    recall = (NF >= 9 ? $9 : "")
    print $1 "," $2 "," $3 "," $4 "," $5 "," $6 "," $7 "," $8 "," recall
  }
' "${LOG_FILE}" > "${CSV_FILE}"

echo "Done. Results are under ${RESULT_DIR}"
