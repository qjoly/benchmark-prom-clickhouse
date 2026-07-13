#!/usr/bin/env python3
"""Render V2 (multi-node OVH MKS) benchmark charts from the measured results.

Values are the measured figures from the V2 run documented in v2/README.md
(ClickHouse and Mimir on separate b3-16 machines, real network). Re-run the
benchmark and edit them to refresh.

Usage: python3 v2/plots.py   (needs matplotlib)
Outputs to v2/docs/charts/.
"""
import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CH = "#f4b400"       # ClickHouse (amber)
MI = "#e2543b"       # Mimir (orange-red)
CH1 = "#f7d074"      # ClickHouse V1 (lighter)
MI1 = "#eea08f"      # Mimir V1 (lighter)
OUT = os.path.join(os.path.dirname(__file__), "docs", "charts")
os.makedirs(OUT, exist_ok=True)


def save(fig, name):
    p = os.path.join(OUT, name)
    fig.tight_layout()
    fig.savefig(p, dpi=130, bbox_inches="tight")
    plt.close(fig)
    print("wrote", os.path.relpath(p))


def annotate(ax, bars, fmt):
    for r in bars:
        h = r.get_height()
        ax.annotate(fmt(h), (r.get_x() + r.get_width() / 2, h),
                    ha="center", va="bottom", fontsize=8,
                    xytext=(0, 2), textcoords="offset points")


# 1) Write throughput, V1 (single node) vs V2 (multi-node), log scale.
# The headline: Mimir RF=3 roughly doubles once each ingester gets its own node.
fig, ax = plt.subplots(figsize=(7, 4))
groups = ["Mimir RF=3\n(samples/s)", "ClickHouse client\n(points/s)"]
v1 = [205e3, 3.95e6]
v2 = [430e3, 5.62e6]
x = range(len(groups)); w = 0.38
b1 = ax.bar([i - w/2 for i in x], v1, w, color=[MI1, CH1], label="V1 (1 node)")
b2 = ax.bar([i + w/2 for i in x], v2, w, color=[MI, CH], label="V2 (multi-node)")
for bs in (b1, b2):
    annotate(ax, bs, lambda h: f"{h/1e6:.2f}M" if h >= 1e6 else f"{h/1e3:.0f}k")
ax.set_yscale("log")
ax.set_xticks(list(x)); ax.set_xticklabels(groups)
ax.set_ylabel("throughput (log)")
ax.set_title("Write throughput: single node vs multi-node")
ax.legend()
save(fig, "write_v1_v2.png")

# 2) Mimir write scaling with client concurrency: V1 flat vs V2 scales.
fig, ax = plt.subplots(figsize=(7, 4))
v1_w = [8, 16, 32, 48]; v1_t = [180, 188, 185, 183]
v2_w = [4, 8, 16];       v2_t = [360, 415, 424]
ax.plot(v1_w, v1_t, "s--", color=MI1, label="V1 (1 node): flat")
ax.plot(v2_w, v2_t, "o-", color=MI, label="V2 (multi-node): scales")
for wk, t in zip(v1_w, v1_t):
    ax.annotate(f"{t}k", (wk, t), fontsize=8, xytext=(0, -12), textcoords="offset points", ha="center")
for wk, t in zip(v2_w, v2_t):
    ax.annotate(f"{t}k", (wk, t), fontsize=8, xytext=(0, 6), textcoords="offset points", ha="center")
ax.set_ylim(0, 480)
ax.set_xlabel("client workers (concurrency)")
ax.set_ylabel("Mimir write (k samples/s)")
ax.set_title("Mimir write vs concurrency: multi-node raises the ceiling")
ax.legend()
save(fig, "mimir_write_scaling.png")

# 3) Reads on Mimir's own query shapes: cold block vs fresh head, p50 ms, log.
fig, ax = plt.subplots(figsize=(8, 4.2))
qs = ["latest value\nall 10k hosts", "selective\n1 host", "rate()-style\nall hosts"]
mi_block = [1364, 9, 1060]; ch_block = [396, 13, 175]
mi_head = [264, 5, 161];    ch_head = [19, 9, 25]
x = range(len(qs)); w = 0.2
series = [("Mimir (block)", mi_block, MI1), ("ClickHouse (block)", ch_block, CH1),
          ("Mimir (head)", mi_head, MI), ("ClickHouse (head)", ch_head, CH)]
for k, (lbl, vals, col) in enumerate(series):
    bars = ax.bar([i + (k - 1.5) * w for i in x], vals, w, color=col, label=lbl)
    annotate(ax, bars, lambda h: f"{h:.0f}")
ax.set_yscale("log")
ax.set_xticks(list(x)); ax.set_xticklabels(qs)
ax.set_ylabel("p50 latency (ms, log)")
ax.set_title("Reads on Mimir's axis: block vs fresh head (100k series)")
ax.legend(fontsize=8, ncol=2)
save(fig, "reads_mimir_axis.png")

# 4) Read under concurrency at C=64, V1 vs V2: QPS (left) and p95 (right).
fig, (axq, axp) = plt.subplots(1, 2, figsize=(9, 4))
labels = ["Mimir\nV1", "Mimir\nV2", "CH\nV1", "CH\nV2"]
cols = [MI1, MI, CH1, CH]
qps = [390, 547, 316, 539]
p95 = [120, 57, 245, 69]
b = axq.bar(labels, qps, color=cols); annotate(axq, b, lambda h: f"{h:.0f}")
axq.set_ylabel("QPS at C=64"); axq.set_title("Read throughput under load")
b = axp.bar(labels, p95, color=cols); annotate(axp, b, lambda h: f"{h:.0f}")
axp.set_ylabel("p95 latency (ms)"); axp.set_title("Tail latency under load")
fig.suptitle("Read under concurrency (single-series point query), C=64")
save(fig, "read_concurrency_v1_v2.png")

# 5) Storage at 1.08 B on Cinder (multi-node), GiB.
fig, ax = plt.subplots(figsize=(6.5, 4))
b = ax.bar(["ClickHouse\n(1 copy, 4.2x)", "ClickHouse\n(RF=2)", "Mimir blocks\n(RF=3, fresh)"],
           [3.04, 6.51, 11.0], color=[CH, CH, MI])
annotate(ax, b, lambda h: f"{h:.2f} GiB")
ax.set_ylabel("on-disk size (GiB)")
ax.set_title("Storage for 1.08 B points (fresh, pre-full-dedup)")
save(fig, "storage_scale.png")

# 6) Resting memory footprint with full datasets loaded.
fig, ax = plt.subplots(figsize=(5.5, 4))
b = ax.bar(["ClickHouse\n(4 chnode)", "Mimir\n(3 ingesters)"], [8.3, 1.8], color=[CH, MI])
annotate(ax, b, lambda h: f"{h:.1f} GiB")
ax.set_ylabel("resident memory (GiB)")
ax.set_title("Memory at rest (ClickHouse 108M rows, Mimir 1.08 B in blocks)")
save(fig, "resting_memory.png")

# 7) High cardinality (1M active series): selective vs broad read latency, log.
fig, ax = plt.subplots(figsize=(7, 4))
qs = ["selective\n1 host of 100k", "broad\ncount all series"]
mi = [5.3, 1587]; ch = [9.9, 17]
x = range(len(qs)); w = 0.38
b1 = ax.bar([i - w/2 for i in x], mi, w, color=MI, label="Mimir")
b2 = ax.bar([i + w/2 for i in x], ch, w, color=CH, label="ClickHouse")
for bs in (b1, b2):
    annotate(ax, bs, lambda h: f"{h:.0f}" if h >= 100 else f"{h:.1f}")
ax.set_yscale("log")
ax.set_xticks(list(x)); ax.set_xticklabels(qs)
ax.set_ylabel("p50 latency (ms, log)")
ax.set_title("Reads at 1M active series: index-flat vs columnar scan")
ax.legend()
save(fig, "high_cardinality.png")

print("done")
