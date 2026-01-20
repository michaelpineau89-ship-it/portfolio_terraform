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

# 1. The Pool (The "Clubhouse" for external identities)
resource "google_iam_workload_identity_pool" "github_pool" {
  workload_identity_pool_id = "github-actions-pool"
  display_name              = "GitHub Actions Pool"
  description               = "Identity pool for GitHub Actions"
}

# 2. The Provider (The "Bouncer" verifying GitHub's OIDC tokens)
resource "google_iam_workload_identity_pool_provider" "github_provider" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github_pool.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Provider"
  
  # 1. Map GitHub's "assertion.repository" to GCP's "attribute.repository"
  # This makes the repository name available for IAM conditions later.
  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  # IMPORTANT: Do NOT include an 'attribute_condition' block here unless 
  # you want to block ALL repos except one at the front door.
  # We restrict access in the IAM Binding resource instead.
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