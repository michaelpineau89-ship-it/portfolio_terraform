provider "google" {
  project = var.project_id
  region  = var.region
  # Optional: If you want Terraform to impersonate this SA directly
  # impersonate_service_account = var.tf_service_account_email
}