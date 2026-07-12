#!/usr/bin/env python3
"""Render benchmark charts (PNG) from the measured results.

The values below are the measured figures from the 1.08 billion point run on the
mocha cluster (see README). Re-run the benchmark and edit them to refresh.

Usage: python3 scripts/plots.py   (needs matplotlib)
Outputs to docs/charts/.
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CH = "#f4b400"      # ClickHouse (amber)
MI = "#e2543b"      # Mimir (orange-red)
OUT = os.path.join(os.path.dirname(__file__), "..", "docs", "charts")
os.makedirs(OUT, exist_ok=True)


def save(fig, name):
    p = os.path.join(OUT, name)
    fig.tight_layout()
    fig.savefig(p, dpi=130, bbox_inches="tight")
    plt.close(fig)
    print("wrote", os.path.relpath(p))


def bars(ax, labels, values, colors, valfmt):
    b = ax.bar(labels, values, color=colors)
    for rect, v in zip(b, values):
        ax.annotate(valfmt(v), (rect.get_x() + rect.get_width() / 2, v),
                    ha="center", va="bottom", fontsize=9,
                    xytext=(0, 2), textcoords="offset points")
    return b


# 1) Write throughput (points/s), log scale.
fig, ax = plt.subplots(figsize=(7, 4))
labels = ["ClickHouse\nclient (RF=1)", "ClickHouse\ncluster RF=2\n(server-side)",
          "Mimir mono\n(RF=1)", "Mimir cluster\n(RF=3)"]
vals = [3.95e6, 22e6, 0.296e6, 0.205e6]
bars(ax, labels, vals, [CH, CH, MI, MI], lambda v: f"{v/1e6:.2f}M" if v >= 1e6 else f"{v/1e3:.0f}k")
ax.set_yscale("log")
ax.set_ylabel("points / second (log)")
ax.set_title("Write throughput - same 1.08 B points")
save(fig, "write_throughput.png")

# 2) CPU-time to ingest the full dataset (core-seconds), log scale.
fig, ax = plt.subplots(figsize=(6.5, 4))
bars(ax, ["ClickHouse\n(ingest+RF=3)", "Mimir mono\n(RF=1)", "Mimir cluster\n(RF=3)"],
     [590, 10800, 28700], [CH, MI, MI], lambda v: f"{v:,.0f}")
ax.set_yscale("log")
ax.set_ylabel("CPU-time (core-seconds, log)")
ax.set_title("CPU cost to ingest 1.08 B points")
save(fig, "cpu_time.png")

# 3) Read latency gradient (ms), grouped bars, log scale.
fig, ax = plt.subplots(figsize=(7.5, 4))
groups = ["single series\n1h", "1 metric / all hosts\n1h", "1 metric / all hosts\n4h"]
mimir = [4, 753, 2524]
ch = [6, 245, 451]
x = range(len(groups))
w = 0.38
b1 = ax.bar([i - w/2 for i in x], mimir, w, color=MI, label="Mimir (PromQL)")
b2 = ax.bar([i + w/2 for i in x], ch, w, color=CH, label="ClickHouse (SQL)")
for bs in (b1, b2):
    for r in bs:
        ax.annotate(f"{r.get_height():.0f}", (r.get_x()+r.get_width()/2, r.get_height()),
                    ha="center", va="bottom", fontsize=8, xytext=(0, 2), textcoords="offset points")
ax.set_yscale("log")
ax.set_xticks(list(x)); ax.set_xticklabels(groups)
ax.set_ylabel("latency (ms, log)")
ax.set_title("Read latency p50 - mirrored queries, HTTP both sides (100k series)")
ax.legend()
save(fig, "read_gradient.png")

# 4) Concurrency sweep: throughput flat while Mimir CPU rises.
fig, ax = plt.subplots(figsize=(7, 4))
workers = [8, 16, 32, 48]
tput = [180, 188, 185, 183]           # k samples/s
ax.plot(workers, tput, "o-", color=MI, label="Mimir throughput")
for wk, t in zip(workers, tput):
    ax.annotate(f"{t}k", (wk, t), fontsize=8, xytext=(0, 6), textcoords="offset points", ha="center")
ax.set_ylim(0, 260)
ax.set_xlabel("client workers (concurrency)")
ax.set_ylabel("throughput (k samples/s)", color=MI)
ax.set_title("Mimir write: more concurrency does not help")
ax2 = ax.twinx()
ax2.plot([8, 48], [3.16, 5.14], "s--", color="#555", label="Mimir CPU (3 pods)")
ax2.set_ylabel("Mimir CPU (cores)", color="#555")
ax2.set_ylim(0, 8)
ax.set_xticks(workers)
lines = ax.get_lines() + ax2.get_lines()
ax.legend(lines, [l.get_label() for l in lines], loc="center right")
save(fig, "concurrency_sweep.png")

# 6) Read under concurrency: QPS (solid) and p95 (dashed) vs concurrency.
fig, ax = plt.subplots(figsize=(7, 4))
conc = [1, 4, 16, 64]
mi_qps = [82, 268, 377, 390]; ch_qps = [72, 244, 325, 316]
mi_p95 = [5, 9, 32, 120]; ch_p95 = [7, 11, 52, 245]
ax.plot(conc, mi_qps, "o-", color=MI, label="Mimir QPS")
ax.plot(conc, ch_qps, "o-", color=CH, label="ClickHouse QPS")
ax.set_xscale("log", base=2); ax.set_xticks(conc); ax.set_xticklabels(conc)
ax.set_xlabel("concurrent clients"); ax.set_ylabel("QPS")
ax.set_title("Read under concurrency (single-series point query)")
ax2 = ax.twinx()
ax2.plot(conc, mi_p95, "s--", color=MI, alpha=0.5, label="Mimir p95")
ax2.plot(conc, ch_p95, "s--", color=CH, alpha=0.5, label="ClickHouse p95")
ax2.set_ylabel("p95 latency (ms, dashed)")
l1 = ax.get_lines() + ax2.get_lines()
ax.legend(l1, [l.get_label() for l in l1], loc="upper left", fontsize=8)
save(fig, "read_concurrency.png")

# 5) Storage footprint (GiB).
fig, ax = plt.subplots(figsize=(5.5, 4))
bars(ax, ["ClickHouse\n(1 copy, 4.4x)", "Mimir\n(RustFS blocks)"], [2.88, 6.0], [CH, MI],
     lambda v: f"{v:.2f} GiB")
ax.set_ylabel("on-disk size (GiB)")
ax.set_title("Storage for 1.08 B points")
save(fig, "storage.png")

print("done")
