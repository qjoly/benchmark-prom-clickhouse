# V2: multi-node benchmark on OVH MKS

V1 ran everything on one shared 12 vCPU node. Its caveats predicted the throughput ratios would
narrow on real multi-node hardware, because Mimir spreads its RF=3 ingesters across machines while
V1 stacked them on one box. V2 confirms that write prediction on a real multi-node cluster (OVH
Managed Kubernetes, ClickHouse and Mimir on separate machines, over a real network) and, just as
usefully, shows where multi-node does *not* change the picture. See the Results summary.

No GitOps and no autoscaling: infrastructure is OpenTofu, workloads are applied by hand with
`kubectl`. This is the procedure as it actually ran, gotchas included.

## Architecture (as built)

- OVH Managed Kubernetes (MKS), region GRA9, k8s 1.35, hourly billed. Control plane, Cilium CNI,
  and a Cinder StorageClass (`csi-cinder-high-speed-gen2`, default) are provided by OVH, so there
  is nothing to bootstrap for control plane, networking, or storage.
- Two worker pools, `anti_affinity = true` (distinct hypervisors), labelled so workloads pin to
  their own machines:

  | Pool | Node label | Runs | Flavor | Nodes |
  |---|---|---|---|---|
  | ch | `bench-pool=ch` | ClickHouse (2 shards x 2 replicas) + Keeper + tsbs | b3-16 (4 vCPU / 16 GB) | 3 |
  | mimir | `bench-pool=mimir` | Mimir ingesters (RF=3) + RustFS + memcached | b3-16 (4 vCPU / 16 GB) | 3 |

  OVH flavor naming: `b3-N` is N GB of RAM, not N vCPU. `b3-16` is 4 vCPU / 16 GB. (We started on
  `b3-8` = 2 vCPU, found it too small, and resized to `b3-16`.)
- Persistence: every stateful component uses a Cinder PVC (ClickHouse 40Gi each, Keeper 5Gi,
  Mimir 60Gi each, RustFS 30Gi), so data survives pod restarts and storage numbers are real.
- Cost: 6x b3-16 is roughly EUR 0.73/h (managed control plane is free).

## Prerequisites

- OpenTofu, `kubectl`.
- OVH OpenStack credentials in an `openrc.sh` (gives `OS_PROJECT_ID`) and OVH API credentials in
  `~/.ovh.conf` (section `[ovh-eu]`; the `ovh` provider reads it automatically).
- Never commit `openrc.sh`, `~/.ovh.conf`, `terraform.tfvars`, `*.kubeconfig`, `.objstore.env`.

## 1. Provision the cluster

```bash
cd v2/infra
source ~/path/to/openrc.sh
export TF_VAR_service_name="$OS_PROJECT_ID"   # keeps the project id out of the repo
tofu init
tofu apply                                     # cluster + 2 nodepools + local kubeconfig
export KUBECONFIG="$PWD/.kubeconfigs/bench.kubeconfig"
kubectl get nodes -L bench-pool               # 6 Ready nodes, labelled ch / mimir
```

Knobs are in `variables.tf` (`region`, `node_flavor`, `ch_nodes`, `mimir_nodes`, `k8s_version`).

**Gotcha: run apply in the foreground.** MKS cluster + nodepools take several minutes. If the
apply process is killed before it writes state (a background job dropped on session teardown, or a
2 minute command timeout), OVH keeps the created resources but they are absent from the local
state (empty `terraform.tfstate`), and a rerun tries to create duplicates. Recover by importing
the orphans instead of recreating:

```bash
rm -f .terraform.tfstate.lock.info
# ids from the OVH API: GET /cloud/project/{id}/kube and .../kube/{kube_id}/nodepool
tofu import ovh_cloud_project_kube.bench          "$OS_PROJECT_ID/<kube_id>"
tofu import ovh_cloud_project_kube_nodepool.ch    "$OS_PROJECT_ID/<kube_id>/<ch_pool_id>"
tofu import ovh_cloud_project_kube_nodepool.mimir "$OS_PROJECT_ID/<kube_id>/<mimir_pool_id>"
tofu plan   # expect: No changes
```

Changing `node_flavor` forces a nodepool replacement (destroy + recreate). The Cinder PVCs survive
and reattach to the new nodes.

## 2. Deploy the benchmark stack

The manifests in `v2/k8s/` are the V1 stack adapted for multi-node: a `nodeSelector` per pool,
`emptyDir` swapped for Cinder `volumeClaimTemplates`, pod anti-affinity, and no CPU limit on Mimir.

```bash
kubectl apply -f ../k8s/00-namespace.yaml
kubectl -n bench-prom-ch create secret generic objstore-creds \
  --from-literal=access-key=benchuser \
  --from-literal=secret-key="$(openssl rand -hex 24)"
kubectl apply -f 10-clickhouse.yaml
kubectl apply -f 20-mimir.yaml
kubectl apply -f 30-tsbs.yaml
```

**Gotcha: pod anti-affinity is required, not optional.** Without it the scheduler put all three
Mimir ingesters on a single mimir node, which is exactly the single-box situation V2 exists to
avoid. `20-mimir.yaml` sets a required anti-affinity (`app=mimir`, `topologyKey=hostname`) so the
3 ingesters land one per node; `10-clickhouse.yaml` uses a preferred one to spread the 4 chnodes
over 3 nodes. Verify:

```bash
kubectl -n bench-prom-ch get pods -o wide   # 1 mimir per mimir-node; ch spread over ch-nodes
```

## 3. Run the benchmark

The scripts switch `docker exec` to `kubectl exec` with `RUNTIME=k8s`:

```bash
cd ..
export KUBECONFIG=v2/infra/.kubeconfigs/bench.kubeconfig
make k8s-smoke
make k8s-bench
```

Or drive it by hand, as this run did (generate a now-anchored dataset in the `tsbs` pod, load into
Mimir over remote-write and into ClickHouse with `tsbs_load_clickhouse`, measure per-pod CPU via
each pod's `process_cpu_seconds_total`).

## 4. Tear down

```bash
cd v2/infra
tofu destroy
```

The stack's PVCs use `Delete` reclaim, so deleting the `bench-prom-ch` namespace before
`tofu destroy` lets the Cinder CSI remove the block volumes; otherwise they can be orphaned. Then
confirm none are left behind in the OVH console or with `openstack volume list`.

## Results

Headline: on real multi-node hardware the **write** gap narrows sharply (Mimir's RF=3 write roughly
doubles to ~430k samples/s with one ingester per node) and ClickHouse **distributed reads** flip
from losing (V1, one node) to winning at scale. The **qualitative verdict still holds**: ClickHouse
wins bulk ingest, analytical/wide reads, and raw read latency even on Mimir's own query shapes;
Mimir wins selective/point queries, high-concurrency reads, resilience with zero read downtime, and
resting memory (data offloaded to object storage), and it keeps selective latency flat as
cardinality grows. Details below, from a first 15M slice through the full 1.08 B run.

### First pass (15M-point now-anchored slice, SCALE=10000 / 100k series)

A 15M-point slice on the 4 vCPU nodes, enough to show the multi-node effect before the full run.
Compare to the same slice on V1's single node.

| Metric | V1 (single node) | V2 (multi-node) | Effect |
|---|---|---|---|
| Mimir write (RF=3) | 205-212 k samples/s | **427 k samples/s** | ~2x: ingesters on 3 nodes |
| Mimir write CPU | ~24 µcore-s/sample | ~16 µcore-s/sample | less contention |
| ClickHouse client write | 3.95 M pts/s (full run) | 5.22 M pts/s (15M burst) | fast either way |
| ClickHouse quorum write (RF=3) | +0 s (replicas co-located) | +1 s / ~2x vs async | quorum costs over a real network |
| Read single series (p50) | Mimir ~4 / CH ~6 ms | Mimir 5.8 / CH 13.5 ms | Mimir wins point queries |
| Read 1 metric / all hosts (p50) | CH ~3-5x faster | CH 61 vs Mimir 534 ms (~8.7x) | ClickHouse wins fan-out |

Takeaways:
- **The write throughput gap narrows on multi-node, as V1 predicted.** Mimir roughly doubled
  (205k to 427k samples/s) once its three RF=3 ingesters each had their own machine. V1's single
  node was the bottleneck, not the remote-write protocol alone.
- **Quorum replication is not free on a real network.** V1 measured 0 cost because the replicas
  were co-located on one node; with replicas on distinct machines, `insert_quorum=2` roughly
  doubled the (small) insert wall time. The reviewer was right that this matters off a single box.
- **The qualitative verdict holds.** Mimir still wins high-concurrency point queries, ClickHouse
  still wins wide aggregations (by even more here). Multi-node moved the write and quorum numbers,
  not the direction of the read results.

### Deep-dive at scale (108M rows / 1.08 B points loaded into ClickHouse)

Five follow-up measurements on the multi-node cluster:

- **Full-scale ClickHouse write:** 108M rows loaded at **5.62 M points/s** on one b3-16 node (vs
  3.95 M on V1's 12 vCPU box; larger batches and the Cinder high-speed disk help).
- **Distributed reads win at scale.** On the full 108M, a `Distributed` query over the 2 shards on
  separate machines beat the single-node table: heavy 10-metric aggregation **1.46 s vs 1.90 s**
  (~1.3x), one-metric fan-out **0.22 s vs 0.33 s** (~1.5x). This is the opposite of V1, where the
  distributed read was slower on one physical node. At 15M it was still slower (coordination
  overhead dominates a tiny scan); the benefit needs scale.
- **Mimir write scales with client concurrency on multi-node.** With **disjoint** now-anchored
  slices (avoiding the duplicate-append head short-circuit a reviewer flagged): 4 workers 360k/s,
  8 workers 415k/s, 16 workers **424k samples/s**. V1's single-node sweep stayed flat at
  ~180-188k regardless of workers, so multi-node raises both the ceiling and the scaling.
- **Read concurrency gap narrows.** Single-series point query at C=64: Mimir **547 QPS / 57 ms
  p95** vs ClickHouse **539 QPS / 69 ms** (V1 was 390/120 vs 316/245). Both scale well now, Mimir
  marginally ahead.
- **ClickHouse storage on Cinder (108M):** 3.04 GiB one copy (4.17x), **6.51 GiB at cluster RF=2**,
  matching V1's numbers on real block volumes.

Full-scale Mimir backfill (1.08 B points, 30h now-anchored window, out-of-order):

- **Multi-node Mimir write holds at scale: 430,420 samples/s** for the full 1.08 B (2,509 s / ~42
  min), ~18,010 core-seconds, no OOM. That matches the 15M slice (427k) and the sweep (424k), so
  the ~2x over V1's 205k/s is confirmed on the full run, and the per-sample CPU is lower (~16.7
  vs V1's ~24-27 µcore-s/sample: less contention on separate nodes). Run detached inside the pod
  (`setsid`) so it survives `kubectl exec` disconnects; note `tsbs_load_prometheus` fails fast if
  the generated window is older than Mimir's 40h out-of-order limit, so the range must be anchored
  to "now".
- **Mimir storage and the RF=3-dedup question (reviewer was right).** Once the ingester heads
  flushed, the `mimir-blocks` bucket settled around **11 GiB across 104 blocks** for the full
  1.08 B, and stayed there: Mimir's split-and-merge compaction converges over hours, not minutes
  (7 group compactions, block count flat at 104, nothing marked for deletion in the window we
  watched). Two things follow. First, **that 11 GiB is larger than ClickHouse's 6.51 GiB at RF=2**,
  and much larger than the V1 "6.0 GiB" figure, so the shipped Mimir footprint still carries
  RF=3 block copies that only dedup down over a long compaction horizon. Second, the V1 storage
  claim that ClickHouse is "~2x smaller per copy" is **compaction-state-dependent and should be
  softened**: at 1.08 B, freshly shipped, Mimir is the larger of the two. A clean post-dedup Mimir
  number needs many hours of compactor time, which was not run to completion here.

### Reads on Mimir's axis (reviewer round 2)

The read gradient elsewhere grows ClickHouse's analytical axis. Here are the metrics-store query
shapes instead, run on cold block data and on fresh in-head data, each engine on its own copy,
HTTP p50 in ms:

| Query | Mimir (block) | ClickHouse (block) | Mimir (head) | ClickHouse (head) |
|---|---|---|---|---|
| latest value, all 10k hosts (instant) | 1364 | 396 | 264 | 19 |
| selective, 1 host (instant) | 9 | 13 | 5 | 9 |
| rate()-style, all hosts | 1060 | 175 | 161 | 25 |

Findings, and they are a bit counterintuitive:
- **Fresh head data helps Mimir a lot** (instant-all 1364 to 264 ms), confirming the reviewer's
  data-age point, **but ClickHouse still wins every all-series query**, on head or block, because a
  columnar scan of this (small) dataset beats Mimir iterating over 10k series.
- **Mimir wins only the selective single-series lookup** (5 vs 9 ms on head), which is the
  dashboard / point-query pattern and lines up with V1's high-concurrency win.
- **rate():** one PromQL function versus a SQL `argMax/argMin/time` expression (a true per-scrape
  rate needs window functions, more painful still). ClickHouse is faster but the query is far
  harder to write. `cpu-only` is gauges, so the rate values are meaningless here; the point is the
  query-path cost and the ergonomics.
- **Net:** even on its own turf, Mimir's edge is selective queries, high concurrency, PromQL
  ergonomics, and the Prometheus ecosystem, not raw single-query latency. That sharpens the
  verdict rather than softening it.

### Resilience (making the ops tests symmetric)

V1 exercised ClickHouse ops (compaction, replica rebuild in 6 s). The Mimir side:

- **Ingester loss.** Killed one of the three RF=3 ingesters. Reads kept working through the outage
  (the query for a series returned correctly on every attempt, served by the two surviving
  replicas): **zero read downtime**. The pod came back Ready in **56 s** (recreate + WAL replay +
  ring rejoin). Different mechanism from ClickHouse's part refetch, but both tolerate a node loss
  without losing reads.

### Resource footprint at rest (full datasets loaded)

`kubectl top`, holding ClickHouse's 108M rows and Mimir's 1.08 B in blocks:

| Engine | CPU | Memory |
|---|---|---|
| ClickHouse (4 chnode) | 281m | **8.3 GiB** |
| Mimir (3 ingesters) | 284m | **1.8 GiB** |

Mimir's resting memory is **~4.7x lower**: its data is offloaded to object storage (blocks) and
paged in via the store-gateway on demand, while ClickHouse keeps data on local disk with in-memory
marks/caches. CPU is comparable at rest. Under active query load the gap narrows (ClickHouse's
caches earn their memory on reads, and the store-gateway pulls blocks into memory), but the
architectural point stands: at scale Mimir trades RAM for object-storage latency.

### High cardinality (1M active series)

Ingested SCALE=100000 (1M series, 10 metrics x 100k hosts) into both engines:

- Both ingested without rejection (Mimir 416k samples/s, ClickHouse 4.66 M points/s).
- **Mimir memory jumped to ~4.2 GiB per ingester** (1.1M series in head; RF=3 means each ingester
  holds every series), roughly 3-4 KB/series. This is the classic Prometheus/Mimir cardinality
  cost: RAM scales with active series (~12 GiB across the 3 ingesters for 1M series). ClickHouse's
  memory did not balloon (cardinality is just more rows/tags).
- Query latency at 1M series (p50/p95 ms):

  | Query | Mimir | ClickHouse |
  |---|---|---|
  | selective, 1 host of 100k | **5.3 / 5.7** | 9.9 / 10.3 |
  | broad, count all series | 1587 / 1664 | **17 / 21** |

- **Mimir's selective-query latency stays flat with cardinality** (5 ms at 1M series, same as at
  10k): its inverted index makes point lookups independent of total cardinality. That is its
  genuine home-turf win. ClickHouse crushes the broad count (columnar, ~94x).
- **Churn** (series appearing and disappearing over time) was not simulated: TSBS has no native
  churn generator. It remains an open gap and is the other half of Mimir's home turf.

Net: high cardinality is where Mimir's selective reads shine (index-flat latency) but its memory
cost bites; ClickHouse takes the cardinality in stride on memory and stays fast on wide queries.
