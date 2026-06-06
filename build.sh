#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${CONDA_PREFIX:-}" ]]; then
  export CPLUS_INCLUDE_PATH="${CONDA_PREFIX}/include${CPLUS_INCLUDE_PATH:+:${CPLUS_INCLUDE_PATH}}"
fi

cmake -S . -B build -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
cmake --build build -j "${CMAKE_BUILD_PARALLEL_LEVEL:-$(nproc)}"
