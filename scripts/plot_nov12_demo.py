"""Generate comparison plots from DESERT routing benchmark CSV outputs."""

import csv
from pathlib import Path
import matplotlib.pyplot as plt
import numpy as np


def load_csv(path: Path) -> list[dict]:
    """Load benchmark CSV rows with numeric fields parsed cleanly."""
    rows = []
    with path.open("r", newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            rows.append(
                {
                    "mode": row["mode"],
                    "duration_s": float(row["duration_s"]),
                    "sent": int(row["sent"]),
                    "recv": int(row["recv"]),
                    "pdr_pct": float(row["pdr_pct"]),
                    "mean_ftt_s": float(row["mean_ftt_s"]),
                    "goodput_bps": float(row["goodput_bps"]),
                    "data_fwd": int(row["data_fwd"]),
                    "ctrl_pkts": int(row["ctrl_pkts"]),
                    "mac_tx_total": int(row["mac_tx_total"]),
                }
            )
    return rows


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    results_dir = repo_root / "results"
    base_csv = results_dir / "baseline_comparison.csv"
    scale_csv = results_dir / "overhead_scaling.csv"
    out_png = results_dir / "nov12_baseline_comparison.png"

    base_rows = {r["mode"]: r for r in load_csv(base_csv)}
    scale_rows = load_csv(scale_csv)

    order = ["static_broken", "static_oracle", "flooding", "uwndr"]
    labels = {
        "static_broken": "Static\n(Direct/Broken)",
        "static_oracle": "Static\n(Manual Oracle)",
        "flooding": "UW/FLOODING\n(Built-in)",
        "uwndr": "UW/NDR\n(Ours - Dynamic)",
    }
    colors = {
        "static_broken": "#c0392b",
        "static_oracle": "#5d6d7e",
        "flooding": "#e67e22",
        "uwndr": "#0e7c7b",
    }

    plt.rcParams.update(
        {
            "font.size": 10,
            "axes.titlesize": 11.5,
            "axes.titleweight": "bold",
            "axes.edgecolor": "#cccccc",
            "axes.linewidth": 0.8,
        }
    )

    fig, axes = plt.subplots(1, 3, figsize=(15.5, 4.9), constrained_layout=True)

    # Panel 1: Packet Delivery Ratio (%)
    ax = axes[0]
    x = np.arange(len(order))
    pdrs = [base_rows[m]["pdr_pct"] for m in order]
    bar_colors = [colors[m] for m in order]
    bars = ax.bar(x, pdrs, color=bar_colors, width=0.58, edgecolor="#222222", linewidth=0.6)
    ax.set_xticks(x)
    ax.set_xticklabels([labels[m] for m in order], fontsize=9)
    ax.set_ylim(0, 118)
    ax.set_ylabel("Packet Delivery Ratio (%)")
    ax.set_title("A. Multi-Hop Delivery Reliability (600 s)")
    ax.grid(axis="y", linestyle="--", alpha=0.3)
    for bar, m in zip(bars, order):
        r = base_rows[m]
        ax.text(
            bar.get_x() + bar.get_width() / 2.0,
            bar.get_height() + 2.5,
            f"{r['pdr_pct']:.2f}%\n({r['recv']}/{r['sent']})",
            ha="center",
            va="bottom",
            fontsize=8.5,
            fontweight="bold",
        )

    # Panel 2: MAC Layer Transmission Overhead Breakdown
    ax = axes[1]
    mac_tot = [base_rows[m]["mac_tx_total"] for m in order]
    fwd_vals = [base_rows[m]["data_fwd"] for m in order]
    ctrl_vals = [base_rows[m]["ctrl_pkts"] for m in order]
    orig_vals = [max(0, t - f - c) for t, f, c in zip(mac_tot, fwd_vals, ctrl_vals)]

    ax.bar(x, orig_vals, width=0.55, label="Originator TX", color="#34495e")
    ax.bar(x, fwd_vals, bottom=orig_vals, width=0.55, label="DATA Relay TX", color="#2980b9")
    bottom_ctrl = [o + f for o, f in zip(orig_vals, fwd_vals)]
    ax.bar(x, ctrl_vals, bottom=bottom_ctrl, width=0.55, label="Control (PROBE/REPLY)", color="#1abc9c")

    ax.set_xticks(x)
    ax.set_xticklabels([labels[m] for m in order], fontsize=9)
    ax.set_ylim(0, max(mac_tot) * 1.25)
    ax.set_ylabel("Total MAC Transmissions (Frames)")
    ax.set_title("B. Acoustic Channel Load (600 s)")
    ax.grid(axis="y", linestyle="--", alpha=0.3)
    ax.legend(loc="upper left", fontsize=8, frameon=True)
    for idx, m in enumerate(order):
        ftt_label = "No delivery" if base_rows[m]["recv"] == 0 else f"{base_rows[m]['mean_ftt_s']:.2f}s FTT"
        ax.text(
            idx,
            mac_tot[idx] + 2.5,
            f"{mac_tot[idx]} TX\n({ftt_label})",
            ha="center",
            va="bottom",
            fontsize=8.3,
            fontweight="bold",
        )

    # Panel 3: Scalability across mission duration
    ax = axes[2]
    scale_modes = [
        ("static_oracle", "Static (Manual Oracle)", "--", "s"),
        ("flooding", "UW/FLOODING (Built-in)", "-.", "^"),
        ("uwndr", "UW/NDR (Ours - Dynamic)", "-", "o"),
    ]
    for m, lbl, ls, mk in scale_modes:
        pts = sorted([r for r in scale_rows if r["mode"] == m], key=lambda r: r["duration_s"])
        durs = [p["duration_s"] for p in pts]
        txs = [p["mac_tx_total"] for p in pts]
        ax.plot(
            durs,
            txs,
            linestyle=ls,
            marker=mk,
            linewidth=2.2,
            markersize=6.5,
            color=colors[m],
            label=lbl,
        )
        if durs:
            y_off = -4 if m == "static_oracle" else 3
            ax.annotate(
                f"{txs[-1]} TX",
                xy=(durs[-1], txs[-1]),
                xytext=(7, y_off),
                textcoords="offset points",
                ha="left",
                va="center",
                fontsize=8.5,
                fontweight="bold",
                color=colors[m],
            )

    ax.set_xlim(220, 2040)
    ax.set_xlabel("Mission Duration (s)")
    ax.set_ylabel("Total MAC Transmissions (Frames)")
    ax.set_title("C. Overhead Scaling Over Mission Time")
    ax.grid(True, linestyle="--", alpha=0.3)
    ax.legend(loc="upper left", fontsize=8.5, frameon=True)

    fig.suptitle(
        "UW-NDR Prototype Validation in DESERT Underwater (5-Node 3000m Multi-Hop AUV Network, 25 kHz / 4.8 kbps)",
        fontsize=12.5,
        fontweight="bold",
    )

    fig.savefig(out_png, dpi=200)
    print(f"Saved comparison figure to: {out_png}")


if __name__ == "__main__":
    main()
