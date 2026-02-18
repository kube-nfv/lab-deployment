output "boot_assets_bucket" {
  description = "GCS bucket name for boot assets"
  value       = google_storage_bucket.boot_assets.name
}

output "cloud_run_service_account_email" {
  description = "Service account email for Cloud Run services"
  value       = google_service_account.cloud_run.email
}
