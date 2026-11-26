#!/usr/bin/env python3
"""Publication-grade error-bar figures for the UW-NDR evaluation sweeps.       [Task B2.2]

Reads results/<exp>_summary.csv (written by run_montecarlo.py) and writes PNG
+ PDF figures to results/figures/. Error bars are +/- 1 standard deviation
over seeds (the CSVs also carry 95% CIs: pass --ci to plot those instead).
Missing inputs are skipped, so the script works on partial result sets.

  python3 scripts/plot_sweeps.py            # all figures
  python3 scripts/plot_sweeps.py --ci       # 95% confidence intervals

Colour follows the protocol, never its rank (palette validated for
colour-vision deficiency; every series also has its own marker + direct label).
"""
from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
RES = REPO / "results"
FIG = RES / "figures"

INK, INK2, GRID, SURF = "#0b0b0b", "#52514e", "#e4e3df", "#fcfcfb"
STYLE = {  # fixed entity -> colour / marker / label
    "uwndr":            dict(color="#2a78d6", marker="o", ls="-",  label="UW-NDR (main)"),
    "uwndr_a11preview": dict(color="#eda100", marker="D", ls="--", label="UW-NDR + trial fix"),
    "flooding":         dict(color="#eb6834", marker="s", ls="-",  label="UW/FLOODING"),
    "static":           dict(color="#1baf7a", marker="^", ls="-",  label="StaticRouting (t=0 routes)"),
}
ORDER = ["uwndr", "uwndr_a11preview", "flooding", "static"]

plt.rcParams.update({
    "figure.facecolor": SURF, "axes.facecolor": SURF, "savefig.facecolor": SURF,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2, "ytick.color": INK2,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 0.8, "axes.axisbelow": True,
    "axes.spines.top": False, "axes.spines.right": False,
    "font.size": 10, "axes.titlesize": 11, "axes.titleweight": "bold", "axes.titlecolor": INK,
    "legend.frameon": False, "legend.fontsize": 9,
})


def load(name: str) -> list[dict]:
    p = RES / f"{name}_summary.csv"
    if not p.exists():
        return []
    with p.open() as f:
        return list(csv.DictReader(f))


def series(rows: list[dict], x: str, metric: str, err: str, filt=None, xf=float):
    """mode -> sorted (x, mean, err) triples."""
    out: dict[str, list] = {}
    for r in rows:
        if filt and not filt(r):
            continue
        if f"{metric}_mean" not in r or r[f"{metric}_mean"] == "":
            continue
        out.setdefault(r["mode"], []).append((xf(r[x]), float(r[f"{metric}_mean"]), float(r[f"{metric}_{err}"])))
    return {m: sorted(v) for m, v in out.items()}


def clipped(ys, es, lo=0.0, hi=None):
    """Asymmetric error bars that never cross a metric's physical bounds."""
    lower = [min(e, y - lo) for y, e in zip(ys, es)]
    upper = [e if hi is None else min(e, hi - y) for y, e in zip(ys, es)]
    return [lower, upper]


def draw(ax, data: dict, hi=None):
    for mode in ORDER:
        if mode not in data:
            continue
        st = STYLE[mode]
        xs, ys, es = zip(*data[mode])
        ax.errorbar(xs, ys, yerr=clipped(ys, es, 0.0, hi), color=st["color"], marker=st["marker"], ls=st["ls"], lw=2,
                    ms=7, mec=SURF, mew=1.5, capsize=3, elinewidth=1.2, label=st["label"])
    ax.legend(loc="best")


def save(fig, name: str, tight: bool = True):
    FIG.mkdir(parents=True, exist_ok=True)
    if tight:
        fig.tight_layout()
    for ext in ("png", "pdf"):
        fig.savefig(FIG / f"{name}.{ext}", dpi=200)
    plt.close(fig)
    print(f"  results/figures/{name}.png")


def merged(name: str) -> list[dict]:
    rows = load(name)
    for r in load(f"{name}_a11preview"):
        r = dict(r)
        r["mode"] = "uwndr_a11preview"
        rows.append(r)
    return rows


def fig_mobility(err):
    rows = merged("mobility")
    if not rows:
        return
    fig, axs = plt.subplots(1, 2, figsize=(10, 4))
    draw(axs[0], series(rows, "speed", "pdr_pct", err), hi=100)
    axs[0].axhline(85, color=INK2, lw=1, ls=":")
    axs[0].text(0.02, 86, "85 % acceptance target", color=INK2, fontsize=8)
    axs[0].set(title="Delivery under Gauss-Markov mobility", xlabel="Mean AUV speed (m/s)",
               ylabel="Packet delivery ratio (%)", ylim=(0, 105))
    draw(axs[1], series(rows, "speed", "mac_tx_total", err))
    axs[1].set(title="Channel load (all MAC transmissions)", xlabel="Mean AUV speed (m/s)",
               ylabel="MAC transmissions per 600 s run")
    axs[1].get_legend().remove()
    save(fig, "mobility_pdr_mactx")


def fig_failover(err):
    rows = merged("failover")
    if not rows:
        return
    fig, axs = plt.subplots(1, 2, figsize=(10, 4))
    departs = ["teleport", "drift"]
    modes = [m for m in ORDER if any(r["mode"] == m for r in rows)]
    w = 0.8 / len(modes)
    for j, (metric, title, ylab) in enumerate([
            ("post_pdr_pct", "Delivery after the primary relay leaves", "Post-failure PDR (%)"),
            ("max_gap_s", "Worst delivery outage after failure", "Largest delivery gap (s)")]):
        ax = axs[j]
        for i, m in enumerate(modes):
            for k, d in enumerate(departs):
                r = next((r for r in rows if r["mode"] == m and r["depart"] == d), None)
                if not r:
                    continue
                y, e = float(r[f"{metric}_mean"]), float(r[f"{metric}_{err}"])
                ax.bar(k + (i - (len(modes) - 1) / 2) * w, y, w * 0.92,
                       yerr=clipped([y], [e], 0.0, 100.0 if metric.endswith("pct") else None), color=STYLE[m]["color"], capsize=3,
                       label=STYLE[m]["label"] if k == 0 else None, error_kw=dict(ecolor=INK2, lw=1))
        ax.set_xticks(range(len(departs)), ["abrupt loss (t=200 s)", "drift 2 m/s (from t=200 s)"])
        ax.set(title=title, ylabel=ylab)
        ax.grid(axis="x", visible=False)
    axs[1].axhline(30, color=INK2, lw=1, ls=":")
    axs[1].text(1.42, 45, "30 s target", color=INK2, fontsize=8, ha="right")
    axs[0].set_ylim(0, 105)
    fig.legend(*axs[0].get_legend_handles_labels(), loc="lower center", ncol=4, fontsize=8)
    fig.subplots_adjust(bottom=0.2)
    fig.tight_layout(rect=(0, 0.08, 1, 1))
    save(fig, "failover_summary", tight=False)

    tl = RES / "failover_timeline.csv"
    if tl.exists():
        data: dict[str, list] = {}
        with tl.open() as f:
            for r in csv.DictReader(f):
                data.setdefault(r["variant"], []).append((float(r["arrival_s"]), int(r["cum_delivered"])))
        fig, ax = plt.subplots(figsize=(8, 4))
        ends = []
        for m in ORDER:
            if m in data:
                xs, ys = zip(*([(0, 0)] + data[m] + [(935, data[m][-1][1])]))
                ax.step(xs, ys, where="post", color=STYLE[m]["color"], lw=2, ls=STYLE[m]["ls"],
                        label=STYLE[m]["label"])
                ends.append([ys[-1], m])
        ends.sort()
        for i in range(1, len(ends)):          # keep end labels >= 3 packets apart
            ends[i][0] = max(ends[i][0], ends[i - 1][0] + 3)
        for y, m in ends:
            ax.text(945, y, STYLE[m]["label"], va="center", fontsize=8, color=INK)
        ax.axvline(200, color=INK2, lw=1, ls=":")
        ax.text(205, 2, "Node 1 (primary relay) lost", color=INK2, fontsize=8)
        ax.set(title="Cumulative deliveries 0 -> 3, seed 1", xlabel="Simulation time (s)",
               ylabel="Packets delivered", xlim=(0, 1200))
        ax.legend(loc="upper left", fontsize=8)
        save(fig, "failover_timeline")


def fig_swarm(err):
    rows = merged("swarm")
    if not rows:
        return
    periods = sorted({float(r["cbr_period"]) for r in rows})
    fig, axs = plt.subplots(2, len(periods), figsize=(4 * len(periods), 7), sharey="row")
    for j, cp in enumerate(periods):
        f = (lambda cp_: (lambda r: float(r["cbr_period"]) == cp_))(cp)
        draw(axs[0, j], series(rows, "nn", "pdr_pct", err, f), hi=100)
        axs[0, j].set(title=f"CBR every {cp:.0f} s", ylim=(0, 105))
        draw(axs[1, j], series(rows, "nn", "mac_tx_total", err, f))
        axs[1, j].set(xlabel="Swarm size (AUVs)")
        for ax in axs[:, j]:
            ax.set_xticks([4, 6, 8, 10])
            if j or ax is axs[1, j]:
                ax.get_legend().remove()
    axs[0, 0].set_ylabel("Aggregate PDR, 3 flows (%)")
    axs[1, 0].set_ylabel("MAC transmissions per run")
    fig.suptitle("Multi-flow swarm (0<->3, 4->2) under 1 m/s Gauss-Markov mobility, 10 seeds",
                 fontweight="bold", color=INK)
    save(fig, "swarm_matrix")


def fig_channel(err):
    noise, per = load("noise"), load("per")
    if not (noise or per):
        return
    fig, axs = plt.subplots(1, 2, figsize=(10, 4))
    if noise:
        draw(axs[0], series(noise, "windspeed", "pdr_pct", err,
                            xf=lambda w: 7.5 * math.sqrt(float(w))), hi=100)
        axs[0].set(title="Ambient-noise stress (Wenz wind term)", ylim=(0, 105),
                   xlabel="Added ambient noise vs calm sea (dB)", ylabel="Packet delivery ratio (%)")
    if per:
        draw(axs[1], series(per, "per_target", "pdr_pct", err), hi=100)
        axs[1].set(title="PER target with power control (7 dB margin)", ylim=(0, 105),
                   xlabel="PHY PER_target_", ylabel="Packet delivery ratio (%)", xscale="log")
        axs[1].get_legend().remove()
    save(fig, "channel_stress")


def fig_overhead(err):
    rows = load("swarm")
    if not rows:
        return
    fig, ax = plt.subplots(figsize=(6, 4))
    for cp, mk in zip(sorted({r["cbr_period"] for r in rows}, key=float), ["o", "s", "^"]):
        d = series(rows, "nn", "ctrl_byte_ratio_pct", err, lambda r, c=cp: r["cbr_period"] == c)
        if "uwndr" in d:
            xs, ys, es = zip(*d["uwndr"])
            ax.errorbar(xs, ys, yerr=es, color=STYLE["uwndr"]["color"], marker=mk, lw=2, ms=7, capsize=3,
                        alpha=0.55 + 0.15 * float(cp) / 20, label=f"CBR every {float(cp):.0f} s")
    ax.axhline(15, color=INK2, lw=1, ls=":")
    ax.text(4, 16, "15 % ctrl-byte target", color=INK2, fontsize=8)
    ax.set(title="UW-NDR control-byte overhead", xlabel="Swarm size (AUVs)",
           ylabel="Control bytes / delivered CBR bytes (%)", xticks=[4, 6, 8, 10])
    ax.legend()
    save(fig, "uwndr_ctrl_overhead")


def fig_farol(err):
    rows = merged("farol")
    if not rows:
        return
    fig, axs = plt.subplots(1, 2, figsize=(9, 3.6))
    modes = [m for m in ORDER if any(r["mode"] == m for r in rows)]
    for ax, metric, ylab in [(axs[0], "pdr_pct", "PDR (%)"), (axs[1], "mac_tx_total", "MAC transmissions")]:
        for i, m in enumerate(modes):
            r = next(r for r in rows if r["mode"] == m)
            ax.bar(i, float(r[f"{metric}_mean"]), 0.7, yerr=float(r[f"{metric}_{err}"]),
                   color=STYLE[m]["color"], capsize=3, error_kw=dict(ecolor=INK2, lw=1))
        ax.set_xticks(range(len(modes)), [STYLE[m]["label"].replace(" (", "\n(").replace(" + ", "\n+ ")
                                          for m in modes], fontsize=8)
        ax.set_ylabel(ylab)
        ax.grid(axis="x", visible=False)
    axs[0].set_title("Farol CPF replay (synthetic sample)")
    save(fig, "farol_replay")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ci", action="store_true", help="plot 95%% CI instead of +/-1 std")
    err = "ci95" if ap.parse_args().ci else "std"
    for f in (fig_mobility, fig_failover, fig_swarm, fig_channel, fig_overhead, fig_farol):
        f(err)


if __name__ == "__main__":
    main()
