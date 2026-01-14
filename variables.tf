variable "project_id" {
  description = "The GCP Project ID"
  type        = string
}

variable "region" {
  description = "Default GCP Region"
  type        = string
  default     = "us-central1"
}

variable "tf_service_account_email" {
  description = "The Service Account email responsible for deploying infrastructure (used for impersonation/auditing)"
  type        = string
}

variable "dataflow_sa_name" {
  description = "The name of the service account for the Dataflow workers"
  type        = string
  default     = "flash-crash-runner"
}