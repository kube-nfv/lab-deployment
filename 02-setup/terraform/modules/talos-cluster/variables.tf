variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "zone" {
  description = "GCP zone"
  type        = string
}

variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
}

variable "talos_image" {
  description = "Self-link or URI of the Talos OS GCE image for boot disks"
  type        = string
}

variable "master_machine_type" {
  description = "GCE machine type for master node"
  type        = string
}

variable "worker_machine_type" {
  description = "GCE machine type for worker node"
  type        = string
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to access Talos and Kubernetes API"
  type        = list(string)
}
