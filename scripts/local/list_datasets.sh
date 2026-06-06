#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/pipeann_paths.sh"

echo "PIPEANN_DATA_ROOT=${PIPEANN_DATA_ROOT}"
echo "PIPEANN_INDEX_ROOT=${PIPEANN_INDEX_ROOT}"
echo "PIPEANN_RESULTS_ROOT=${PIPEANN_RESULTS_ROOT}"
echo
pipeann_print_dataset_table

