terraform {
  # This empty block tells Terraform: "Expect to store state in GCS"
  # We will fill in the bucket name via the command line (Partial Configuration)
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = "mike-personal-portfolio"
  region  = "us-central1"
}

# Create the "Warehouse" for your docker images
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "flash-crash-repo"
  description   = "Docker repository for Flash Crash Detector artifacts"
  format        = "DOCKER"
}