variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
}

variable "cluster_name" {
  description = "Name of the cluster (used for resource naming)"
  type        = string
}

variable "boot_assets_bucket_name" {
  description = "Name of the GCS bucket for boot assets"
  type        = string
}
