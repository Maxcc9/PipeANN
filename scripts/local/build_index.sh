#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/pipeann_paths.sh"

DATASET="${DATASET:-${1:-}}"
[[ -n "${DATASET}" ]] || pipeann_die "Usage: DATASET=sift1m EXPERIMENT_TAG=sift1m_test bash scripts/local/build_index.sh"

EXPERIMENT_TAG="${EXPERIMENT_TAG:-${DATASET}_pipeann}"
DATA_TYPE="${DATA_TYPE:-$(pipeann_dataset_type "${DATASET}")}"
METRIC="${METRIC:-$(pipeann_dataset_metric "${DATASET}")}"
NBR_TYPE="${NBR_TYPE:-pq}"

R="${R:-64}"
BUILD_L="${BUILD_L:-100}"
PQ_BYTES="${PQ_BYTES:-32}"
MEM_GB="${MEM_GB:-16}"
THREADS="${THREADS:-$(nproc)}"
L2="${L2:-0}"

BUILD_MEM_INDEX="${BUILD_MEM_INDEX:-0}"
SAMPLE_RATE="${SAMPLE_RATE:-0.01}"
MEM_R="${MEM_R:-32}"
MEM_BUILD_L="${MEM_BUILD_L:-64}"
MEM_ALPHA="${MEM_ALPHA:-1.2}"

BASE_FILE="${BASE_FILE:-$(pipeann_dataset_base "${DATASET}")}"
INDEX_TAG="${INDEX_TAG:-$(pipeann_index_tag "${DATASET}" "${R}" "${BUILD_L}" "${PQ_BYTES}" "${MEM_GB}")}"
INDEX_DIR="$(pipeann_index_dir "${EXPERIMENT_TAG}" "${INDEX_TAG}")"
INDEX_PREFIX="$(pipeann_index_prefix "${EXPERIMENT_TAG}" "${INDEX_TAG}")"
RESULT_DIR="$(pipeann_build_result_dir "${EXPERIMENT_TAG}" "${INDEX_TAG}")"
LOG_FILE="${RESULT_DIR}/build.log"
METADATA_FILE="${RESULT_DIR}/metadata.env"

pipeann_require_file "${BASE_FILE}"
pipeann_require_exe "build/tests/build_disk_index"
if [[ "${BUILD_MEM_INDEX}" == "1" ]]; then
  pipeann_require_exe "build/tests/utils/gen_random_slice"
  pipeann_require_exe "build/tests/build_memory_index"
fi

mkdir -p "${INDEX_DIR}" "${RESULT_DIR}"

cat > "${METADATA_FILE}" <<EOF
DATASET=${DATASET}
EXPERIMENT_TAG=${EXPERIMENT_TAG}
INDEX_TAG=${INDEX_TAG}
DATA_TYPE=${DATA_TYPE}
METRIC=${METRIC}
NBR_TYPE=${NBR_TYPE}
BASE_FILE=${BASE_FILE}
INDEX_DIR=${INDEX_DIR}
INDEX_PREFIX=${INDEX_PREFIX}
R=${R}
BUILD_L=${BUILD_L}
PQ_BYTES=${PQ_BYTES}
MEM_GB=${MEM_GB}
THREADS=${THREADS}
L2=${L2}
BUILD_MEM_INDEX=${BUILD_MEM_INDEX}
SAMPLE_RATE=${SAMPLE_RATE}
EOF

echo "Build metadata written to ${METADATA_FILE}"
echo "Index files will be written under ${INDEX_DIR}"
echo "Build log will be written to ${LOG_FILE}"

cmd=(
  "${PIPEANN_ROOT}/build/tests/build_disk_index"
  "${DATA_TYPE}"
  "${BASE_FILE}"
  "${INDEX_PREFIX}"
  "${R}"
  "${BUILD_L}"
  "${PQ_BYTES}"
  "${MEM_GB}"
  "${THREADS}"
  "${METRIC}"
  "${NBR_TYPE}"
)

if [[ "${L2}" != "0" ]]; then
  cmd+=("${L2}")
fi

{
  printf 'Command:'
  printf ' %q' "${cmd[@]}"
  printf '\n'
  "${cmd[@]}"
} 2>&1 | tee "${LOG_FILE}"

if [[ "${BUILD_MEM_INDEX}" == "1" ]]; then
  SAMPLE_PREFIX="${INDEX_PREFIX}_SAMPLE_RATE_${SAMPLE_RATE}"
  MEM_LOG_FILE="${RESULT_DIR}/build_mem.log"
  {
    "${PIPEANN_ROOT}/build/tests/utils/gen_random_slice" \
      "${DATA_TYPE}" "${BASE_FILE}" "${SAMPLE_PREFIX}" "${SAMPLE_RATE}"
    "${PIPEANN_ROOT}/build/tests/build_memory_index" \
      "${DATA_TYPE}" \
      "${SAMPLE_PREFIX}_data.bin" \
      "${SAMPLE_PREFIX}_ids.bin" \
      "${INDEX_PREFIX}_mem.index" \
      "${MEM_R}" "${MEM_BUILD_L}" "${MEM_ALPHA}" "${THREADS}" "${METRIC}"
  } 2>&1 | tee "${MEM_LOG_FILE}"
fi

echo "Done. INDEX_PREFIX=${INDEX_PREFIX}"

