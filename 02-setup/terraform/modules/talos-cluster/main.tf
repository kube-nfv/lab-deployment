# VPC Network
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  auto_create_subnetworks = false
}

# Subnet
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  ip_cidr_range = "10.1.0.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

# Firewall: allow Talos API from allowed CIDRs
resource "google_compute_firewall" "allow_talos_api" {
  name    = "${var.cluster_name}-allow-talos-api"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["50000"]
  }

  source_ranges = var.allowed_cidrs
  target_tags   = ["talos-node"]
}

# Firewall: allow Kubernetes API from allowed CIDRs
resource "google_compute_firewall" "allow_k8s_api" {
  name    = "${var.cluster_name}-allow-k8s-api"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  source_ranges = var.allowed_cidrs
  target_tags   = ["talos-node"]
}

# Firewall: allow all internal traffic between cluster nodes
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.cluster_name}-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "all"
  }

  source_ranges = [google_compute_subnetwork.subnet.ip_cidr_range]
  target_tags   = ["talos-node"]
}

# Static external IP for master node
resource "google_compute_address" "master" {
  name   = "${var.cluster_name}-master-ip"
  region = var.region
}

# Static external IP for worker node
resource "google_compute_address" "worker" {
  name   = "${var.cluster_name}-worker-ip"
  region = var.region
}

# Master node
resource "google_compute_instance" "master" {
  name         = "${var.cluster_name}-master-1"
  machine_type = var.master_machine_type
  zone         = var.zone
  tags         = ["talos-node"]

  boot_disk {
    initialize_params {
      image = var.talos_image
      size  = 50
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id

    access_config {
      nat_ip = google_compute_address.master.address
    }
  }
}

# Worker node
resource "google_compute_instance" "worker" {
  name         = "${var.cluster_name}-worker-1"
  machine_type = var.worker_machine_type
  zone         = var.zone
  tags         = ["talos-node"]

  boot_disk {
    initialize_params {
      image = var.talos_image
      size  = 50
      type  = "pd-standard"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id

    access_config {
      nat_ip = google_compute_address.worker.address
    }
  }
}
