output "master_external_ip" {
  description = "External IP of the master node"
  value       = google_compute_address.master.address
}

output "worker_external_ip" {
  description = "External IP of the worker node"
  value       = google_compute_address.worker.address
}

output "vpc_network" {
  description = "VPC network self-link"
  value       = google_compute_network.vpc.self_link
}

output "subnet" {
  description = "Subnet self-link"
  value       = google_compute_subnetwork.subnet.self_link
}
