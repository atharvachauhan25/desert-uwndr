#!/usr/bin/env python3
"""Export per-packet delivery instants for the failover demo.     [Task B1.3]

Runs demo_failover.tcl once per protocol (seed 1, teleport departure) with
print_arrivals=1 and writes results/failover_timeline.csv with columns
variant,arrival_s,cum_delivered. Used by plot_sweeps.py for the timeline figure.

  python3 scripts/export_failover_timeline.py [--ndr-lib /path/to/preview/libuwndr.so]
"""
import argparse
import csv
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_montecarlo import RESULTS, SIM, ns_environment  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--ndr-lib", help="optional trial-fix / feature-branch libuwndr.so")
ap.add_argument("--preview-lifetime", default="60")
a = ap.parse_args()

variants = [("static", []), ("flooding", []), ("uwndr", [])]
if a.ndr_lib:
    variants.append(("uwndr_a11preview", [f"ndr_lib={Path(a.ndr_lib).resolve()}",
                                          f"ndr_lifetime={a.preview_lifetime}"]))
env = ns_environment()
rows = []
for name, extra in variants:
    mode = name.split("_")[0]
    out = subprocess.run(["ns", str(SIM / "demo_failover.tcl"), f"mode={mode}", "print_arrivals=1", *extra],
                         capture_output=True, text=True, env=env, cwd=SIM).stdout
    line = next(l for l in out.splitlines() if l.startswith("ARRIVALS,0,"))
    times = [float(x) for x in line.split(",", 2)[2].split()]
    rows += [(name, t, i + 1) for i, t in enumerate(times)]
    print(f"{name}: {len(times)} deliveries")
RESULTS.mkdir(exist_ok=True)
with (RESULTS / "failover_timeline.csv").open("w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["variant", "arrival_s", "cum_delivered"])
    w.writerows(rows)
print("wrote results/failover_timeline.csv")
