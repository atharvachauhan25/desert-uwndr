#!/usr/bin/env python3
"""Automated N-seed Monte Carlo sweep runner for UW-NDR experiments. [Task B2.1]

Runs a named experiment grid (mode x parameter values x seeds) through `ns`,
collects every RESULT_CSV line into results/<exp>_raw.csv and writes
mean / std / 95% CI per grid point to results/<exp>_summary.csv.

Examples
--------
  python3 scripts/run_montecarlo.py mobility            # 10 seeds, all cores
  python3 scripts/run_montecarlo.py swarm --seeds 10 --jobs 2
  python3 scripts/run_montecarlo.py all
  python3 scripts/run_montecarlo.py failover --ndr-lib /path/to/branch/libuwndr.so
  python3 scripts/run_montecarlo.py mobility --set ndr_lifetime=60

`ns` is taken from PATH; if it is missing, the DESERT environment file is
sourced from $DESERT_ENV or ../DESERT_Underwater/DESERT_buildCopy_LOCAL/environment
(relative to the repo root).
"""
from __future__ import annotations

import argparse
import csv
import itertools
import math
import os
import shutil
import statistics
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SIM = REPO / "simulations"
RESULTS = REPO / "results"

MODES = ["static", "flooding", "uwndr"]

# Each experiment: script, the grid of swept parameters, fixed parameters and
# the metrics to aggregate. Grid keys become columns in the summary CSV.
EXPERIMENTS: dict[str, dict] = {
    "mobility": {  # WP2 / B1.2
        "script": "sweep_mobility.tcl",
        "grid": {"mode": MODES, "speed": [0.0, 0.5, 1.0, 1.5, 2.0]},
        "fixed": {"stoptime": 605},
    },
    "failover": {  # WP2 / B1.3
        "script": "demo_failover.tcl",
        "grid": {"mode": MODES, "depart": ["teleport", "drift"]},
        "fixed": {"stoptime": 905},
    },
    "swarm": {  # WP3 / B2.1
        "script": "swarm_matrix.tcl",
        "grid": {"mode": MODES, "nn": [4, 6, 8, 10], "cbr_period": [10, 20, 40]},
        "fixed": {"stoptime": 605, "speed": 1.0},
    },
    "noise": {  # WP4 / B2.3 -- wind-driven ambient noise (Wenz model)
        # At 25 kHz the wind term dominates and grows by 7.5*sqrt(w) dB, so
        # w = (dB/7.5)^2 gives +0..6 dB of extra noise in 1 dB steps.
        "script": "sweep_mobility.tcl",
        "grid": {"mode": MODES, "windspeed": [round((d / 7.5) ** 2, 4) for d in range(7)]},
        "fixed": {"stoptime": 605, "speed": 0.0, "tag": "noise"},
    },
    "per": {  # WP4 / B2.3 -- PER target with SPL (power) optimisation enabled
        "script": "sweep_mobility.tcl",
        "grid": {"mode": MODES, "per_target": [0.001, 0.01, 0.02, 0.05, 0.10]},
        "fixed": {"stoptime": 605, "speed": 0.0, "tag": "per", "spl_opt": 1, "spl_margin": 7},
    },
    "farol": {  # WP5 / B3.2 -- replay of imported ROS waypoints
        "script": "replay_farol.tcl",
        "grid": {"mode": MODES},
        "fixed": {},
    },
}

METRICS = [
    "pdr_pct", "mean_ftt_s", "mac_tx_total", "ctrl_pkts", "ctrl_bytes",
    "ctrl_byte_ratio_pct", "energy_tx_j", "energy_rx_j", "energy_per_bit_j",
    "max_gap_s", "recovery_s", "recovered", "post_pdr_pct", "min_flow_pdr_pct",
]


def ns_environment() -> dict[str, str]:
    env = dict(os.environ)
    if shutil.which("ns"):
        return env
    candidates = [os.environ.get("DESERT_ENV", ""),
                  str(REPO.parent / "DESERT_Underwater" / "DESERT_buildCopy_LOCAL" / "environment")]
    for c in candidates:
        if c and Path(c).is_file():
            out = subprocess.run(["bash", "-c", f'source "{c}" >/dev/null 2>&1 && env -0'],
                                 capture_output=True, check=True).stdout
            for item in out.split(b"\0"):
                if b"=" in item:
                    k, v = item.split(b"=", 1)
                    env[k.decode()] = v.decode(errors="replace")
            if shutil.which("ns", path=env.get("PATH")):
                return env
    sys.exit("ns not found: source your DESERT environment or set DESERT_ENV")


def run_one(script: Path, params: dict, env: dict) -> tuple[dict | None, str]:
    args = ["ns", str(script)] + [f"{k}={v}" for k, v in params.items()]
    proc = subprocess.run(args, capture_output=True, text=True, env=env, cwd=SIM)
    hdr = vals = None
    for line in proc.stdout.splitlines():
        if line.startswith("RESULT_HDR,"):
            hdr = line.split(",")[1:]
        elif line.startswith("RESULT_CSV,"):
            vals = line.split(",")[1:]
    if hdr is None or vals is None or len(hdr) != len(vals):
        return None, " ".join(args) + "\n" + proc.stdout[-800:] + proc.stderr[-800:]
    return dict(zip(hdr, vals)), ""


def ci95(xs: list[float]) -> float:
    # Student-t 97.5% quantiles for small n (n-1 dof); normal beyond 30
    t = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571, 6: 2.447, 7: 2.365,
         8: 2.306, 9: 2.262, 10: 2.228, 15: 2.131, 20: 2.086, 29: 2.045}
    n = len(xs)
    if n < 2:
        return 0.0
    q = t.get(n - 1) or (1.96 if n > 30 else t[min(t, key=lambda k: abs(k - (n - 1)))])
    return q * statistics.stdev(xs) / math.sqrt(n)


def summarise(rows: list[dict], grid_keys: list[str]) -> list[dict]:
    groups: dict[tuple, list[dict]] = {}
    for r in rows:
        groups.setdefault(tuple(r[k] for k in grid_keys), []).append(r)
    out = []
    for key, rs in groups.items():
        s = dict(zip(grid_keys, key))
        s["n_seeds"] = len(rs)
        for m in METRICS:
            xs = [float(r[m]) for r in rs if m in r and r[m] not in ("", "-")]
            if not xs:
                continue
            s[f"{m}_mean"] = round(statistics.fmean(xs), 6)
            s[f"{m}_std"] = round(statistics.stdev(xs), 6) if len(xs) > 1 else 0.0
            s[f"{m}_ci95"] = round(ci95(xs), 6)
        out.append(s)
    return out


def write_csv(path: Path, rows: list[dict]) -> None:
    cols: list[str] = []
    for r in rows:
        cols += [c for c in r if c not in cols]
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)


def run_experiment(name: str, seeds: int, jobs: int, extra: dict, env: dict, suffix: str = "") -> None:
    spec = EXPERIMENTS[name]
    script = SIM / spec["script"]
    keys = list(spec["grid"])
    combos = list(itertools.product(*spec["grid"].values()))
    tasks = []
    for combo in combos:
        for seed in range(1, seeds + 1):
            p = dict(spec["fixed"])
            p.update(dict(zip(keys, combo)))
            p.update(extra)
            p["seed"] = seed
            tasks.append(p)
    print(f"[{name}] {len(combos)} grid points x {seeds} seeds = {len(tasks)} runs ({jobs} jobs)")
    t0 = time.time()
    rows, failures = [], []
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        futs = {ex.submit(run_one, script, p, env): p for p in tasks}
        for i, fut in enumerate(as_completed(futs), 1):
            res, err = fut.result()
            if res is None:
                failures.append(err)
            else:
                for k in keys:            # grid values exactly as requested
                    res[k] = str(futs[fut][k])
                rows.append(res)
            if i % 25 == 0 or i == len(tasks):
                print(f"  {i}/{len(tasks)} done ({time.time() - t0:.0f}s)")
    if failures:
        print(f"[{name}] {len(failures)} run(s) failed; first failure:\n{failures[0]}")
    rows.sort(key=lambda r: tuple(r[k] for k in keys) + (int(r["seed"]),))
    RESULTS.mkdir(exist_ok=True)
    stem = f"{name}{suffix}"
    write_csv(RESULTS / f"{stem}_raw.csv", rows)
    write_csv(RESULTS / f"{stem}_summary.csv", summarise(rows, keys))
    print(f"[{name}] wrote results/{stem}_raw.csv and results/{stem}_summary.csv")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("experiment", choices=list(EXPERIMENTS) + ["all"])
    ap.add_argument("--seeds", type=int, default=10)
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--ndr-lib", help="alternative libuwndr.so (e.g. a feature-branch build)")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                    help="extra scenario option passed to every run")
    ap.add_argument("--suffix", default="", help="append to output file stem, e.g. _a11")
    ap.add_argument("--modes", help="comma-separated subset of modes (default: all)")
    a = ap.parse_args()
    extra = dict(kv.split("=", 1) for kv in a.set)
    if a.ndr_lib:
        extra["ndr_lib"] = str(Path(a.ndr_lib).resolve())
    if a.modes:
        sel = a.modes.split(",")
        for spec in EXPERIMENTS.values():
            spec["grid"]["mode"] = [m for m in spec["grid"]["mode"] if m in sel]
    env = ns_environment()
    names = [n for n in EXPERIMENTS if n != "farol"] if a.experiment == "all" else [a.experiment]
    for n in names:
        if n == "farol" and not (SIM / "replay_farol.tcl").exists():
            continue
        run_experiment(n, a.seeds, a.jobs, extra, env, a.suffix)


if __name__ == "__main__":
    main()
