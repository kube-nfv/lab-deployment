variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "europe-central2"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "europe-central2-a"
}

variable "cluster_name" {
  description = "Name of the Talos cluster"
  type        = string
  default     = "setup02-cluster"
}

variable "talos_image" {
  description = "Self-link or URI of the Talos OS GCE image for boot disks"
  type        = string
}

variable "master_machine_type" {
  description = "GCE machine type for master node"
  type        = string
  default     = "e2-standard-4"
}

variable "worker_machine_type" {
  description = "GCE machine type for worker node"
  type        = string
  default     = "e2-standard-8"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to access Talos and Kubernetes API"
  type        = list(string)
}

variable "boot_assets_bucket_name" {
  description = "Name of the GCS bucket for boot assets (Talos kernel, initramfs, configs)"
  type        = string
  default     = "setup02-boot-assets"
}
