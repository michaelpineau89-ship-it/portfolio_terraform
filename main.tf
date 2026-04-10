terraform {
  # This empty block tells Terraform: "Expect to store state in GCS"
  # We will fill in the bucket name via the command line (Partial Configuration)
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = "mike-personal-portfolio"
  region  = "us-central1"
}

# Temporary: re-added so Terraform can decode prior flash-crash state and plan destroys.
# Remove this block after a successful apply cleans up the orphaned resources.
provider "google-beta" {
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

# 2. The Provider (V3 - Updated for Multi-Repo Support)
resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider-v3"
  display_name                       = "GitHub Provider V3"

  # Map the claims so we can use them in IAM
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
    # Added Owner mapping just in case we need it for IAM later
    "attribute.owner" = "assertion.repository_owner"
  }

  # THE FIX: Allow ANY repo owned by 'michaelpineau89-ship-it'
  # This lets 'portfolio_terraform', 'flash_crash_detector', and future projects authenticate.
  attribute_condition = "assertion.repository_owner == 'michaelpineau89-ship-it'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}


# Output the Provider Name (You need this for the GitHub Action)
output "wif_provider_name" {
  value = google_iam_workload_identity_pool_provider.github_provider.name
}