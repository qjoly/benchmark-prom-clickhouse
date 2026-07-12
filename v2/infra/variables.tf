variable "ovh_endpoint" {
  description = "OVH API endpoint. 'ovh-eu' for Europe."
  type        = string
  default     = "ovh-eu"
}

variable "service_name" {
  description = "OVH Public Cloud project ID (= OpenStack OS_PROJECT_ID). Pass via TF_VAR_service_name (from openrc.sh) to keep it out of the public repo."
  type        = string
}

variable "region" {
  description = "OVH MKS region. GRA9 is proven with b3 flavors in the reference setup."
  type        = string
  default     = "GRA9"
}

variable "cluster_name" {
  description = "MKS cluster name."
  type        = string
  default     = "bench-prom-ch"
}

variable "k8s_version" {
  description = "MKS Kubernetes version (MAJOR.MINOR). Empty = OVH default (latest supported)."
  type        = string
  default     = ""
}

variable "node_flavor" {
  description = "Flavor for both worker pools (balanced tier: b3-8 = 8 vCPU / 32 GB)."
  type        = string
  default     = "b3-8"
}

variable "ch_nodes" {
  description = "Nodes in the ClickHouse pool (2 shards x 2 replicas + Keeper)."
  type        = number
  default     = 3
}

variable "mimir_nodes" {
  description = "Nodes in the Mimir pool (RF=3 ingesters)."
  type        = number
  default     = 3
}
