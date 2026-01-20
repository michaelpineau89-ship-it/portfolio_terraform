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

# 1. The Pool (V3 - Final Clean Slate)
resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-actions-pool-v3" # Changed ID
  display_name              = "GitHub Actions Pool V3"
  description               = "Identity pool for GitHub Actions"
}

# 2. The Provider (V3 - With Explicit Condition)
resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider-v3" # Changed ID
  display_name                       = "GitHub Provider V3"

  # A. Map the repository claim so we can use it
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
  }

  # B. EXPLICIT CONDITION (The Fix)
  # Instead of leaving this blank (which causes the error), we explicitly 
  # check the repo name here. This satisfies the "must reference a claim" rule.
  attribute_condition = "assertion.repository == 'michaelpineau89-ship-it/flash_crash_detector'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# 3. The Permission (Allowing the GitHub Repo to act as the Service Account)
resource "google_service_account_iam_member" "wif_binding" {
  service_account_id = google_service_account.dataflow_sa.name
  role               = "roles/iam.workloadIdentityUser"

  # TRUST ONLY THIS REPO:
  member = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github_pool.name}/attribute.repository/${var.project_id}/flash_crash_detector"
}

# Output the Provider Name (You need this for the GitHub Action)
output "wif_provider_name" {
  value = google_iam_workload_identity_pool_provider.github_provider.name
}