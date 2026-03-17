variable "project_id" {
  description = "The GCP Project ID"
  type        = string
  default     = "mike-personal-portfolio"
}

variable "region" {
  description = "Default GCP Region"
  type        = string
  default     = "us-east1"
}

variable "preferred_zone" {
  description = "Preferred zone needed to be used in dataflow"
  type        = string
  default     = "us-east1-b"
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
