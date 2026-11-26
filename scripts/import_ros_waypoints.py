#!/usr/bin/env python3
"""Import ROS/DSOR Farol vehicle trajectories into DESERT.            [Task B3.1]

Converts Farol navigation logs (NED) into a DESERT trajectory file (ENU,
Z <= 0) that simulations/replay_farol.tcl replays with Position/BM.

Input formats
-------------
1. `rostopic echo -p` CSV exports of Farol's filtered state, one file per
   vehicle, e.g.
       rostopic echo -p /mvector0/nav/filter/state > mvector0.csv
   Topic type is auv_msgs/NavigationStatus; the columns used are
   `%time` (ns) or `field.header.stamp` (ns), `field.position.north`,
   `field.position.east`, `field.position.depth`. The vehicle name is
   taken from the file name (or --vehicle-regex).
2. A single "long" CSV with header `time,vehicle,north,east,depth`
   (time in seconds).

Mapping (planner WP5)
---------------------
  vehicle mvectorK  ->  DESERT node index K  ->  IP address K+1
  NED (north, east, depth)  ->  DESERT ENU  x = east, y = north, z = -depth
  Depth is clamped so z <= 0 (vehicles cannot be above the surface).

Examples
--------
  python3 scripts/import_ros_waypoints.py logs/mvector*.csv -o simulations/trajectories/farol_run1.tcl
  python3 scripts/import_ros_waypoints.py --synthetic -o simulations/trajectories/farol_synthetic.tcl
"""
from __future__ import annotations

import argparse
import csv
import math
import re
import sys
from pathlib import Path

NED_COLS = {
    "north": ["field.position.north", "position.north", "north"],
    "east": ["field.position.east", "position.east", "east"],
    "depth": ["field.position.depth", "position.depth", "depth"],
}
TIME_COLS = ["field.header.stamp", "%time", "time", "t"]


def ned_to_enu(north: float, east: float, depth: float) -> tuple[float, float, float]:
    """Farol NED -> DESERT ENU. Depth is positive down; DESERT z is negative down."""
    return east, north, min(0.0, -depth)


def _pick(header: list[str], options: list[str]) -> str | None:
    low = {h.strip().lower(): h for h in header}
    for o in options:
        if o.lower() in low:
            return low[o.lower()]
    return None


def read_rostopic_csv(path: Path) -> list[tuple[float, float, float, float]]:
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return []
    hdr = list(rows[0].keys())
    tcol = _pick(hdr, TIME_COLS)
    cols = {k: _pick(hdr, v) for k, v in NED_COLS.items()}
    if tcol is None or None in cols.values():
        sys.exit(f"{path}: cannot find time / position.north / position.east / position.depth columns")
    out = []
    for r in rows:
        t = float(r[tcol])
        if t > 1e12:            # ROS stamps in nanoseconds
            t *= 1e-9
        out.append((t, float(r[cols["north"]]), float(r[cols["east"]]), float(r[cols["depth"]])))
    return out


def read_long_csv(path: Path) -> dict[str, list[tuple[float, float, float, float]]]:
    data: dict[str, list] = {}
    with path.open(newline="") as f:
        for r in csv.DictReader(f):
            data.setdefault(r["vehicle"], []).append(
                (float(r["time"]), float(r["north"]), float(r["east"]), float(r["depth"])))
    return data


def vehicle_index(name: str, regex: str) -> int:
    m = re.search(regex, name)
    if not m:
        sys.exit(f"vehicle name '{name}' does not match --vehicle-regex {regex!r}")
    return int(m.group(1))


def resample(track: list[tuple[float, float, float, float]], t0: float, t1: float, dt: float):
    """Linear interpolation of (t, n, e, d) on a uniform grid [t0, t1]."""
    track = sorted(track)
    out, j = [], 0
    t = t0
    while t <= t1 + 1e-9:
        while j + 1 < len(track) and track[j + 1][0] < t:
            j += 1
        if t <= track[0][0]:
            p = track[0][1:]
        elif j + 1 >= len(track):
            p = track[-1][1:]
        else:
            (ta, *a), (tb, *b) = track[j], track[j + 1]
            w = 0.0 if tb == ta else (t - ta) / (tb - ta)
            p = tuple(a[k] + w * (b[k] - a[k]) for k in range(3))
        out.append((t - t0, *p))
        t += dt
    return out


def synthetic_farol(n: int = 4, duration: float = 900.0, rate: float = 2.0,
                    speed: float = 1.5, spacing: float = 1000.0, breathe: float = 250.0,
                    period: float = 600.0) -> dict[str, list]:
    """Stand-in for a Farol cooperative path-following (CPF) run: n vehicles in
    line-abreast formation transiting north at <speed> m/s. The formation
    spacing "breathes" between spacing-breathe and spacing+breathe metres
    (750..1250 m by default, i.e. up to the ~1250 m acoustic range edge), so
    links come and go during the mission. Depth oscillates 45..55 m.
    Clearly SYNTHETIC -- replace with real ROS logs from the Farol team."""
    data = {}
    for k in range(n):
        tr, t = [], 0.0
        while t <= duration:
            sp = spacing + breathe * math.sin(2 * math.pi * t / period)
            north = speed * t + 30.0 * math.sin(2 * math.pi * t / 240.0)
            east = k * sp
            depth = 50.0 + 5.0 * math.sin(2 * math.pi * t / 300.0 + k)
            tr.append((t, north, east, depth))
            t += 1.0 / rate
        data[f"mvector{k}"] = tr
    return data


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="*", type=Path, help="rostopic CSV per vehicle, or one long CSV")
    ap.add_argument("-o", "--output", type=Path, required=True, help="output .tcl trajectory file")
    ap.add_argument("--dt", type=float, default=5.0, help="waypoint spacing in seconds (default 5)")
    ap.add_argument("--scale", type=float, default=1.0,
                    help="horizontal scale factor (Farol tank/sea-trial formations are often tens of "
                         "metres apart; scale up to acoustic multi-hop distances)")
    ap.add_argument("--recenter", action="store_true", help="shift so vehicle 0 starts at x=y=0")
    ap.add_argument("--vehicle-regex", default=r"mvector(\d+)", help="regex capturing the vehicle index")
    ap.add_argument("--synthetic", action="store_true", help="generate a synthetic 4-vehicle CPF run")
    a = ap.parse_args()

    if a.synthetic:
        data, source = synthetic_farol(), "SYNTHETIC cooperative path-following sample (not real Farol data)"
    elif len(a.inputs) == 1 and "vehicle" in a.inputs[0].read_text().splitlines()[0]:
        data, source = read_long_csv(a.inputs[0]), str(a.inputs[0])
    elif a.inputs:
        data = {p.stem: read_rostopic_csv(p) for p in a.inputs}
        source = ", ".join(str(p) for p in a.inputs)
    else:
        ap.error("give input CSV files or --synthetic")

    by_idx = {vehicle_index(name, a.vehicle_regex): tr for name, tr in data.items() if tr}
    idxs = sorted(by_idx)
    if idxs != list(range(len(idxs))):
        sys.exit(f"vehicle indices must be contiguous from 0 (got {idxs}); DESERT IPs are 1..N")

    t0 = max(tr[0][0] for tr in map(sorted, by_idx.values()))      # common window
    t1 = min(tr[-1][0] for tr in map(sorted, by_idx.values()))
    if t1 <= t0:
        sys.exit("vehicle logs do not overlap in time")

    tracks = {}
    for k in idxs:
        rs = resample(by_idx[k], t0, t1, a.dt)
        tracks[k] = [(t, *ned_to_enu(n * a.scale, e * a.scale, d)) for t, n, e, d in rs]
    if a.recenter:
        x0, y0 = tracks[0][0][1], tracks[0][0][2]
        tracks = {k: [(t, x - x0, y - y0, z) for t, x, y, z in tr] for k, tr in tracks.items()}

    a.output.parent.mkdir(parents=True, exist_ok=True)
    with a.output.open("w") as f:
        f.write("# DESERT trajectory generated by scripts/import_ros_waypoints.py\n")
        f.write(f"# source: {source}\n")
        f.write(f"# mapping: mvectorK -> node K -> IP K+1 ; NED->ENU x=east y=north z=-depth\n")
        f.write(f"# dt={a.dt}s scale={a.scale} recenter={a.recenter} duration={t1 - t0:.1f}s\n")
        f.write(f"set traj_nn {len(idxs)}\n")
        f.write(f"set traj_duration {t1 - t0:.3f}\n")
        for k in idxs:
            pts = " ".join(f"{{{t:.2f} {x:.2f} {y:.2f} {z:.2f}}}" for t, x, y, z in tracks[k])
            f.write(f"set traj({k}) {{{pts}}}\n")
    csv_path = a.output.with_suffix(".csv")
    with csv_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["time_s", "node", "ip", "x_east_m", "y_north_m", "z_m"])
        for k in idxs:
            for t, x, y, z in tracks[k]:
                w.writerow([f"{t:.2f}", k, k + 1, f"{x:.2f}", f"{y:.2f}", f"{z:.2f}"])
    print(f"wrote {a.output} and {csv_path}: {len(idxs)} vehicles, {len(tracks[0])} waypoints each, "
          f"{t1 - t0:.0f} s")


if __name__ == "__main__":
    main()
