# V2: multi-node benchmark on OVH OpenStack

## Why

V1 ran everything on one shared 12 vCPU Talos node. Its own caveats say the throughput ratios
are the numbers most likely to move on real multi-node hardware, because Mimir is built to spread
its RF=3 ingesters across machines while it was stacked on one box. V2 fixes exactly that: a real
multi-node Kubernetes cluster on OVH Public Cloud, so Mimir's ingesters and ClickHouse's shards
and replicas each sit on their own machine, over a real network.

Everything is code: infrastructure with OpenTofu, cluster with Talos, workloads with GitOps
(ArgoCD reading this public repo). Spin up, run, tear down.

## Target platform (reused from karpenter-talos-capi-ovh)

- OVH Public Cloud, OpenStack API `https://auth.cloud.ovh.net/`, Identity v3.
- Project `OS_PROJECT_ID` (same project as the reference repo), region **EU-WEST-PAR** (Octavia
  load balancer, healthy security-group quotas).
- Auth: source the existing `openrc.sh` (OpenStack user) for OpenTofu; OVH API keys only needed
  if we touch OVH-native resources (we will not, we stay pure OpenStack).
- Talos image already present in the project: `talos-v1.13.2-openstack-amd64`.

## Architecture decision: OVH Managed Kubernetes (MKS)

We use **MKS** directly (not raw Talos instances, not Cluster API). OVH manages the control plane
for free, ships Cilium as the CNI, and provides a Cinder-backed StorageClass out of the box. So
there is nothing to bootstrap for the control plane, networking, or block storage: OpenTofu only
declares the worker pools.

- `ovh_cloud_project_kube` creates the cluster (region GRA9, hourly billed).
- Two `ovh_cloud_project_kube_nodepool` resources, `ch` and `mimir`, each labelled
  (`bench-pool=ch` / `bench-pool=mimir`) and with `anti_affinity = true` so the nodes land on
  distinct hypervisors (real multi-node).
- The cluster `kubeconfig` is exported to a local (gitignored) file.

Simplest of the options, and the managed control plane plus built-in CNI and CSI remove three
bootstrap steps.

## Node topology (a cost knob, see below)

Chosen tier: **balanced**. The MKS control plane is managed (free), so there is no control-plane
instance to pay for. Two labelled worker pools:

| Pool | Label | Role | Flavor | Count |
|---|---|---|---|---|
| ch | `bench-pool=ch` | ClickHouse (2 shards x 2 replicas) + Keeper + tsbs driver | b3-8 (8 vCPU / 32 GB) | 3 |
| mimir | `bench-pool=mimir` | Mimir ingesters (RF=3) + gateway | b3-8 (8 vCPU / 32 GB) | 3 |

ClickHouse and Mimir never share a node (pinned by `bench-pool` nodeSelector). Within the ch pool
the 4 chnode pods spread over 3 nodes (one node runs two), Keeper is tiny, and the tsbs driver
rides the ch pool (it drives ClickHouse client-side, and during Mimir tests the ch nodes are
otherwise idle). This is the balanced compromise: real multi-node isolation between the two
engines at 6 nodes instead of the 9 a fully-isolated-plus-driver layout would need.

Rough cost (GRA9, hourly, excl. VAT, approximate): b3-8 ~EUR 0.11/h, so 6 nodes ~EUR 0.66/h
(~EUR 16/day). Managed control plane is free. Block volumes add a little. We spin up, run, and
destroy, so a campaign is a few euros.

## Storage

Real persistence, not emptyDir. MKS ships a Cinder-backed StorageClass, so ClickHouse, Mimir, and
RustFS just request PVCs (block volumes). No CSI to install. This makes storage numbers meaningful
and survives pod restarts (V1's Mimir data loss on restart is what forced re-ingestion). RustFS
keeps providing the S3 layer for Mimir blocks, on its own PVC.

## GitOps layout (all in this public repo)

```
v2/
  infra/            OpenTofu: OpenStack network + instances + Talos cluster
    versions.tf     provider pins (openstack ~>3.0, talos, local, null)
    variables.tf    region, project, flavors, pool sizes, image name
    network.tf      private net + subnet + router + security groups + floating IPs
    images.tf       data source for the existing Talos image (or upload if missing)
    nodes.tf        instances per pool (control-plane, ch, mimir, driver)
    talos.tf        machine secrets, configs, apply, bootstrap, kubeconfig export
    outputs.tf      kubeconfig path, talosconfig, node IPs, LB IP
    terraform.tfvars.example   committed; real terraform.tfvars is gitignored
  bootstrap/        cluster addons applied right after the cluster is up
    argocd/         ArgoCD install (kustomize) + root app-of-apps
                    (no CNI/CSI here: MKS provides Cilium + Cinder StorageClass)
  gitops/           ArgoCD Applications = desired workload state
    root-app.yaml   app-of-apps pointing at gitops/apps
    apps/
      benchmark.yaml  ArgoCD Application -> v2/gitops/benchmark-stack
    benchmark-stack/  kustomize overlay of ../../k8s with multi-node patches:
                      nodeSelector per pool, pod anti-affinity, PVCs (Cinder),
                      resource requests sized to the flavors, no CPU limits on Mimir
  README.md         runbook (up / bootstrap / run / down)
```

GitOps flow:
1. `tofu apply` in `v2/infra` brings up the cluster and writes `kubeconfig`.
2. `v2/bootstrap` installs Cilium, Cinder CSI, and ArgoCD (one `kubectl apply -k`).
3. ArgoCD syncs `v2/gitops/root-app.yaml` (app-of-apps), which deploys the benchmark stack from
   this repo. Since the repo is public, ArgoCD needs no credentials.
4. Run the existing benchmark scripts with `RUNTIME=k8s` against the new kubeconfig. The scripts
   already switch `docker exec` to `kubectl exec`, so most work unchanged; targets (service
   names, node counts) get parameterized.
5. `tofu destroy` tears everything down.

## What changes in the benchmark itself (the point of V2)

- Mimir RF=3 ingesters on 3 separate machines: re-test the ~205k/s write ceiling and the ~49x CPU
  gap with real network fan-out. This is where V1 predicted the throughput ratio would narrow.
- ClickHouse 2 shards x 2 replicas on 4 machines: quorum write now crosses a real network (V1
  measured 0 cost because replicas were co-located), and distributed reads can actually
  parallelize across nodes (V1 saw them slower on one box).
- Storage measured on real block volumes, post-compaction on both sides.
- Reads mirrored and fair (idiomatic SQL, hostname join) as fixed in V1.

## Secrets and the public repo

This repo is public. So:
- `terraform.tfvars`, `*.kubeconfig`, `talosconfig`, `openrc.sh`, `clouds.yaml` are gitignored;
  only `*.example` files are committed.
- No project IDs, IPs, or credentials committed. OpenTofu reads them from the sourced `openrc.sh`
  environment and from the local (gitignored) tfvars.

## Execution phases

1. Confirm the cost knobs (topology tier, flavors). [needs user]
2. Write `v2/infra` OpenTofu, `tofu init`, `tofu plan` (no cost), review.
3. `tofu apply` (spends money), verify `kubectl get nodes` shows the multi-node cluster.
4. Write and apply `v2/bootstrap` (Cilium, Cinder CSI, ArgoCD).
5. Write `v2/gitops` overlays, let ArgoCD deploy the stack, verify pods spread across pools.
6. Run the benchmark, collect results, update the README with a V2 section.
7. `tofu destroy`.

Money is only spent at step 3, and only for as long as the cluster is up.
