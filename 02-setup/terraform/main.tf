provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

module "talos_cluster" {
  source = "./modules/talos-cluster"

  project_id          = var.project_id
  region              = var.region
  zone                = var.zone
  cluster_name        = var.cluster_name
  talos_image         = var.talos_image
  master_machine_type = var.master_machine_type
  worker_machine_type = var.worker_machine_type
  allowed_cidrs       = var.allowed_cidrs
}

module "infrastructure" {
  source = "./modules/infrastructure"

  project_id              = var.project_id
  region                  = var.region
  cluster_name            = var.cluster_name
  boot_assets_bucket_name = var.boot_assets_bucket_name
}
