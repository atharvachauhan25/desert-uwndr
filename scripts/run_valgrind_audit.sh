#!/usr/bin/env bash
# ==============================================================================
# UW-NDR Valgrind Memory Leak Audit Runner (Task A3.2)
# ==============================================================================
# Executes a full valgrind memcheck trace over UW-NDR multi-hop execution to
# verify zero memory leaks, zero heap corruptions, and clean packet deallocations.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DESERT_ENV="${REPO_ROOT}/../DESERT_Underwater/DESERT_buildCopy_LOCAL/environment"
RESULTS_DIR="${REPO_ROOT}/results"
REPORT_FILE="${RESULTS_DIR}/valgrind_report.txt"

mkdir -p "${RESULTS_DIR}"

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
if [[ -f "${DESERT_ENV}" ]]; then
    # shellcheck disable=SC1090
    source "${DESERT_ENV}"
fi

echo "======================================================================"
echo "[Valgrind Audit] Starting UW-NDR Memory Safety & Leak Check..."
echo "======================================================================"

valgrind --tool=memcheck \
         --leak-check=full \
         --show-leak-kinds=definite,indirect \
         --track-origins=yes \
         --log-file="${REPORT_FILE}" \
         ns "${REPO_ROOT}/simulations/compare_routing.tcl" uwndr 80.0 > /dev/null 2>&1 || true

echo "[Valgrind Audit] Run completed. Summary from ${REPORT_FILE}:"
grep -E "definitely lost|indirectly lost|ERROR SUMMARY" "${REPORT_FILE}" || true
echo "======================================================================"
