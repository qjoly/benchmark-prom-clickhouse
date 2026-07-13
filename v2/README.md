# V2: multi-node benchmark on OVH MKS

V1 ran everything on one shared 12 vCPU node. Its caveats predicted the throughput ratios would
narrow on real multi-node hardware, because Mimir spreads its RF=3 ingesters across machines while
V1 stacked them on one box. V2 confirms that prediction on a real multi-node cluster: OVH Managed
Kubernetes, ClickHouse and Mimir on separate machines, over a real network.

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

## Results (15M-point now-anchored slice, SCALE=10000 / 100k series)

Not the full 1.08 B run: a 15M-point slice on the 4 vCPU nodes, enough to show the multi-node
effect. Compare to the same slice on V1's single node.

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

## Deep-dive at scale (108M rows / 1.08 B points loaded into ClickHouse)

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
- **Mimir storage and the RF=3-dedup question (reviewer was right).** After the head flushed, the
  `mimir-blocks` bucket was 8.9 GiB with the compactor actively deduplicating: 79 compactor runs,
  12 blocks marked for deletion. So the raw bucket number **includes pre-dedup RF=3 block copies**
  that the compactor is still merging away; the fully-deduped footprint is lower and only settles
  after the compactor's deletion delay. The V1 "6.0 GiB / ~2x smaller per copy" storage claim
  should be read with that caveat until a post-dedup number is captured.

## 4. Tear down

```bash
cd v2/infra
tofu destroy
```

Then confirm no Cinder volumes are left behind (PVCs use `Delete` reclaim, but verify in the OVH
console or `openstack volume list`).
