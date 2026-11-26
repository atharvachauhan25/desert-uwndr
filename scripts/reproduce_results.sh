#!/usr/bin/env bash
# =============================================================================
# reproduce_results.sh -- one-command reproduction of every evaluation result
# =============================================================================
# Usage (from anywhere):
#   scripts/reproduce_results.sh            # 10 seeds, all cores (~2 min)
#   scripts/reproduce_results.sh --quick    # 3-seed smoke test (overwrites results/;
#                                            #  git checkout results/ to restore)
#   NDR_LIB=/path/to/branch/libuwndr.so scripts/reproduce_results.sh
#       # also produce *_a11preview results against an alternative build
#
# Needs: a built src/uwndr/libuwndr.so, DESERT on PATH (or $DESERT_ENV, or
# ../DESERT_Underwater/DESERT_buildCopy_LOCAL/environment), python3 + matplotlib.
# Outputs: results/*_raw.csv, results/*_summary.csv, results/figures/*.{png,pdf}
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}"
SEEDS=10
[[ "${1:-}" == "--quick" ]] && SEEDS=3

if ! command -v ns >/dev/null 2>&1; then
    ENV_FILE="${DESERT_ENV:-${REPO}/../DESERT_Underwater/DESERT_buildCopy_LOCAL/environment}"
    if [[ -f "${ENV_FILE}" ]]; then
        export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
        # shellcheck disable=SC1090
        source "${ENV_FILE}"
    else
        echo "ns not found and no DESERT environment at ${ENV_FILE}" >&2; exit 1
    fi
fi
[[ -f src/uwndr/libuwndr.so ]] || { echo "build src/uwndr/libuwndr.so first (cd src/uwndr && make)" >&2; exit 1; }
python3 -c "import matplotlib" 2>/dev/null || { echo "pip install matplotlib" >&2; exit 1; }

echo "== 1/4 trajectory import (synthetic Farol sample) =="
python3 scripts/import_ros_waypoints.py --synthetic -o simulations/trajectories/farol_synthetic.tcl

echo "== 2/4 Monte Carlo matrices (${SEEDS} seeds) =="
for exp in mobility failover swarm noise per farol; do
    python3 scripts/run_montecarlo.py "${exp}" --seeds "${SEEDS}"
done

TL_ARGS=()
if [[ -n "${NDR_LIB:-}" ]]; then
    echo "== 2b/4 alternative build: ${NDR_LIB} (ndr_lifetime=60) =="
    for exp in mobility failover swarm farol; do
        python3 scripts/run_montecarlo.py "${exp}" --seeds "${SEEDS}" --modes uwndr \
            --ndr-lib "${NDR_LIB}" --set ndr_lifetime=60 --suffix _a11preview
    done
    TL_ARGS=(--ndr-lib "${NDR_LIB}")
fi

echo "== 3/4 failover delivery timeline =="
python3 scripts/export_failover_timeline.py "${TL_ARGS[@]}"

echo "== 4/4 figures =="
python3 scripts/plot_sweeps.py
echo "done: see results/ and results/figures/"
