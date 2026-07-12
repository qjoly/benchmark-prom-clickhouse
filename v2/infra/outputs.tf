output "kubeconfig_path" {
  description = "Path to the MKS kubeconfig written locally (gitignored)."
  value       = local_sensitive_file.kubeconfig.filename
}

output "cluster_id" {
  value = ovh_cloud_project_kube.bench.id
}

output "cluster_status" {
  value = ovh_cloud_project_kube.bench.status
}

output "region" {
  value = ovh_cloud_project_kube.bench.region
}
