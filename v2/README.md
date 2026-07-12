# V2: multi-node benchmark on OVH MKS

V1 ran everything on one shared node. Its own caveats say the throughput ratios are the numbers
most likely to move on real multi-node hardware, because Mimir spreads its RF=3 ingesters across
machines while V1 stacked them on one box. V2 is a real multi-node cluster on OVH Managed
Kubernetes so ClickHouse shards/replicas and Mimir ingesters each sit on their own machine over a
real network.

No GitOps and no autoscaling: infrastructure is OpenTofu, the workloads are applied by hand with
`kubectl`, documented below.

## Architecture

- OVH Managed Kubernetes (MKS), region GRA9, hourly billed. Control plane, Cilium CNI, and a
  Cinder-backed StorageClass (`csi-cinder-high-speed-gen2`, default) are all provided by OVH, so
  there is nothing to bootstrap for control plane, networking, or storage.
- Two worker pools, `anti_affinity = true` (distinct hypervisors), each labelled so workloads pin
  to their own machines:

  | Pool | Node label | Runs | Flavor | Nodes |
  |---|---|---|---|---|
  | ch | `bench-pool=ch` | ClickHouse (2 shards x 2 replicas) + Keeper + tsbs driver | b3-8 | 3 |
  | mimir | `bench-pool=mimir` | Mimir ingesters (RF=3) + gateway + memcached + RustFS | b3-8 | 3 |

Cost: 6x b3-8 is roughly EUR 0.66/h (managed control plane is free). Spin up, run, destroy.

## Prerequisites

- OpenTofu (or Terraform), `kubectl`.
- OVH OpenStack credentials in `openrc.sh` (provides `OS_PROJECT_ID`) and OVH API credentials in
  `~/.ovh.conf` (section `[ovh-eu]`). The `ovh` provider reads `~/.ovh.conf` automatically.
- Never commit `openrc.sh`, `~/.ovh.conf`, `terraform.tfvars`, `*.kubeconfig`, or `.objstore.env`.

## 1. Provision the cluster (OpenTofu)

```bash
cd v2/infra
source ~/path/to/openrc.sh                 # sets OS_PROJECT_ID and friends
export TF_VAR_service_name="$OS_PROJECT_ID" # keeps the project id out of the repo

tofu init
tofu plan      # 1 cluster + 2 nodepools + local kubeconfig file
tofu apply
```

Knobs live in `variables.tf` (region, `node_flavor`, `ch_nodes`, `mimir_nodes`, `k8s_version`).
Copy `terraform.tfvars.example` to `terraform.tfvars` to override, or pass `-var`.

The kubeconfig is written to `v2/infra/.kubeconfigs/bench.kubeconfig` (gitignored).

```bash
export KUBECONFIG="$PWD/.kubeconfigs/bench.kubeconfig"
kubectl get nodes -L bench-pool     # 6 Ready nodes, labelled ch / mimir
```

### If apply is interrupted (state lock / orphaned resources)

Running `tofu apply` in the background and losing the process can leave OVH resources created but
absent from the local state (empty `terraform.tfstate`), plus a stale lock file. Recover without
creating duplicates:

```bash
rm -f .terraform.tfstate.lock.info          # stale lock from the dead process
# find the orphaned ids on OVH (cluster + nodepools), then import them:
tofu import ovh_cloud_project_kube.bench          "$OS_PROJECT_ID/<kube_id>"
tofu import ovh_cloud_project_kube_nodepool.ch    "$OS_PROJECT_ID/<kube_id>/<ch_pool_id>"
tofu import ovh_cloud_project_kube_nodepool.mimir "$OS_PROJECT_ID/<kube_id>/<mimir_pool_id>"
tofu plan                                    # should report: No changes
```

List the ids with the OVH API: `GET /cloud/project/{id}/kube` and
`GET /cloud/project/{id}/kube/{kube_id}/nodepool`. Prefer running `tofu apply` in the foreground so
the state is always written.

## 2. Deploy the benchmark stack by hand

The V1 manifests in `../k8s` assume a single node with `emptyDir`. For V2, apply them with two
changes: pin each workload to its pool and give the stateful ones real Cinder volumes.

```bash
kubectl apply -f ../k8s/00-namespace.yaml
```

Create the object-store secret (used by RustFS and Mimir). Keep the value in a local
`.objstore.env` (gitignored), do not inline it in a committed file:

```bash
kubectl -n bench-prom-ch create secret generic objstore-creds \
  --from-literal=access-key=benchuser \
  --from-literal=secret-key="$(openssl rand -hex 24)"
```

### Pin workloads to their pool (nodeSelector)

Add a `nodeSelector` to each pod template before applying:

| Manifest / workload | `nodeSelector` |
|---|---|
| `10-clickhouse.yaml` StatefulSet `chnode`, StatefulSet `chkeeper` | `bench-pool: ch` |
| `30-tsbs.yaml` Deployment `tsbs` | `bench-pool: ch` |
| `20-mimir.yaml` StatefulSet `mimir`, Deployments `rustfs` / `memcached`, Job `rustfs-init` | `bench-pool: mimir` |

Example (add under `spec.template.spec`):

```yaml
      nodeSelector:
        bench-pool: ch
```

ClickHouse's 4 chnode replicas spread over the 3 ch nodes (one node runs two); Keeper and tsbs are
light. Mimir's 3 ingesters land one per mimir node thanks to the pool split.

### Swap emptyDir for Cinder PVCs (persistence + real storage numbers)

For the StatefulSets, replace the `data` `emptyDir` volume with a `volumeClaimTemplate`. Remove the
`- { name: data, emptyDir: {...} }` line from `spec.template.spec.volumes` and add:

```yaml
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: csi-cinder-high-speed-gen2
        resources:
          requests:
            storage: 40Gi     # chnode; chkeeper 5Gi; mimir 60Gi
```

For the RustFS Deployment (single replica), replace its `emptyDir` with a PVC:

```yaml
# a PersistentVolumeClaim named rustfs-data (RWO, csi-cinder-high-speed-gen2, 30Gi),
# then in the pod: volumes: [{ name: data, persistentVolumeClaim: { claimName: rustfs-data } }]
```

tsbs can keep its `emptyDir` (scratch space for generated data).

Then apply and watch the pods spread across pools:

```bash
kubectl apply -f ../k8s/10-clickhouse.yaml
kubectl apply -f ../k8s/20-mimir.yaml
kubectl apply -f ../k8s/30-tsbs.yaml
kubectl -n bench-prom-ch get pods -o wide      # confirm ch-* on ch nodes, mimir on mimir nodes
```

## 3. Run the benchmark

The existing scripts already switch `docker exec` to `kubectl exec` with `RUNTIME=k8s`:

```bash
cd ..
export KUBECONFIG=v2/infra/.kubeconfigs/bench.kubeconfig
make k8s-smoke        # quick validation
make k8s-bench        # full run
```

What to re-check on multi-node (this is the point of V2):
- Mimir RF=3 write throughput and CPU with ingesters on separate machines (V1 predicted the
  throughput ratio narrows here).
- ClickHouse quorum write across a real network (V1 measured 0 cost because replicas were
  co-located) and distributed reads that can actually parallelize.
- Storage on real block volumes, post-compaction on both sides.

## 4. Tear down

```bash
cd v2/infra
tofu destroy
```

Check afterwards that no Cinder volumes are left behind (PVCs with `Delete` reclaim policy are
removed with their pods, but verify in the OVH console or via `openstack volume list`).
