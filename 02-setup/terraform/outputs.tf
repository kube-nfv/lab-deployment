# Talos cluster outputs
output "master_external_ip" {
  description = "External IP of the master node"
  value       = module.talos_cluster.master_external_ip
}

output "worker_external_ip" {
  description = "External IP of the worker node"
  value       = module.talos_cluster.worker_external_ip
}

# Infrastructure outputs
output "boot_assets_bucket" {
  description = "GCS bucket name for boot assets"
  value       = module.infrastructure.boot_assets_bucket
}
