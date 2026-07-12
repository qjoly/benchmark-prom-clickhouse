# OVH Managed Kubernetes (MKS). Control plane, Cilium CNI and the Cinder
# StorageClass are provided by OVH, so there is nothing to bootstrap for
# networking or block storage: only the worker pools are defined here.

resource "ovh_cloud_project_kube" "bench" {
  service_name  = var.service_name
  name          = var.cluster_name
  region        = var.region
  version       = var.k8s_version != "" ? var.k8s_version : null
  update_policy = "MINIMAL_DOWNTIME"
}

# ClickHouse pool: labelled bench-pool=ch, workloads pinned here by nodeSelector.
resource "ovh_cloud_project_kube_nodepool" "ch" {
  service_name  = var.service_name
  kube_id       = ovh_cloud_project_kube.bench.id
  name          = "ch"
  flavor_name   = var.node_flavor
  desired_nodes = var.ch_nodes
  min_nodes     = var.ch_nodes
  max_nodes     = var.ch_nodes
  autoscale     = false
  anti_affinity = true # spread across distinct hypervisors (real multi-node)

  template {
    metadata {
      labels      = { "bench-pool" = "ch" }
      annotations = {}
      finalizers  = []
    }
    spec {
      taints        = []
      unschedulable = false
    }
  }
}

# Mimir pool: labelled bench-pool=mimir.
resource "ovh_cloud_project_kube_nodepool" "mimir" {
  service_name  = var.service_name
  kube_id       = ovh_cloud_project_kube.bench.id
  name          = "mimir"
  flavor_name   = var.node_flavor
  desired_nodes = var.mimir_nodes
  min_nodes     = var.mimir_nodes
  max_nodes     = var.mimir_nodes
  autoscale     = false
  anti_affinity = true

  template {
    metadata {
      labels      = { "bench-pool" = "mimir" }
      annotations = {}
      finalizers  = []
    }
    spec {
      taints        = []
      unschedulable = false
    }
  }
}

resource "local_sensitive_file" "kubeconfig" {
  content         = ovh_cloud_project_kube.bench.kubeconfig
  filename        = "${path.module}/.kubeconfigs/bench.kubeconfig"
  file_permission = "0600"
}
