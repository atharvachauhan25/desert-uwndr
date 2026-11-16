#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DESERT_ENV="${REPO_ROOT}/../DESERT_Underwater/DESERT_buildCopy_LOCAL/environment"

if [[ -f "${DESERT_ENV}" ]]; then
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
    # shellcheck disable=SC1090
    source "${DESERT_ENV}"
fi

RESULTS_DIR="${REPO_ROOT}/results"
mkdir -p "${RESULTS_DIR}"

BASE_CSV="${RESULTS_DIR}/baseline_comparison.csv"
SCALE_CSV="${RESULTS_DIR}/overhead_scaling.csv"

echo "mode,duration_s,sent,recv,pdr_pct,mean_ftt_s,goodput_bps,data_fwd,ctrl_pkts,mac_tx_total" > "${BASE_CSV}"
for m in static_broken static_oracle flooding uwndr; do
    echo "[Benchmark 1/2] Running baseline mode=${m} (duration=600s)..."
    ns "${SCRIPT_DIR}/compare_routing.tcl" "${m}" 605.0 \
        | grep '^RESULT_CSV,' \
        | sed 's/^RESULT_CSV,//' >> "${BASE_CSV}"
done

echo "mode,duration_s,sent,recv,pdr_pct,mean_ftt_s,goodput_bps,data_fwd,ctrl_pkts,mac_tx_total" > "${SCALE_CSV}"
for stop_t in 305.0 605.0 1205.0 1805.0; do
    for m in static_oracle flooding uwndr; do
        echo "[Benchmark 2/2] Running scaling mode=${m} (stoptime=${stop_t})..."
        ns "${SCRIPT_DIR}/compare_routing.tcl" "${m}" "${stop_t}" \
            | grep '^RESULT_CSV,' \
            | sed 's/^RESULT_CSV,//' >> "${SCALE_CSV}"
    done
done

echo "=== Baseline Comparison (600s) ==="
cat "${BASE_CSV}"
echo ""
echo "=== Overhead Scaling (300s - 1800s) ==="
cat "${SCALE_CSV}"
