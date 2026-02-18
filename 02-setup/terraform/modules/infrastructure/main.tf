# GCS bucket for boot assets (Talos kernel, initramfs, machine configs)
resource "google_storage_bucket" "boot_assets" {
  name     = var.boot_assets_bucket_name
  location = var.region
  project  = var.project_id

  uniform_bucket_level_access = true

  force_destroy = true
}

# Service account for Cloud Run services (to be used later)
resource "google_service_account" "cloud_run" {
  account_id   = "${var.cluster_name}-cr-sa"
  display_name = "Cloud Run service account for ${var.cluster_name}"
  project      = var.project_id
}

# Grant Cloud Run SA read access to boot assets bucket
resource "google_storage_bucket_iam_member" "cloud_run_reader" {
  bucket = google_storage_bucket.boot_assets.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.cloud_run.email}"
}

# TODO: Cloud Run iPXE (Matchbox) and config server services will be added later
