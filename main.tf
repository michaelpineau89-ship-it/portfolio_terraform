terraform {
  # This empty block tells Terraform: "Expect to store state in GCS"
  # We will fill in the bucket name via the command line (Partial Configuration)
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = "mike-personal-portfolio"
  region  = "us-central1"
}
