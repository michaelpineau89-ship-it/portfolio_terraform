provider "google-beta" {
  project = var.project_id
}

locals {
  dataflow_roles = [
    "roles/dataflow.worker",
    "roles/dataflow.admin",
    "roles/pubsub.subscriber",
    "roles/pubsub.viewer",
    "roles/pubsub.editor",
    "roles/bigquery.dataEditor",
    "roles/bigquery.jobUser",
    "roles/artifactregistry.reader",
    "roles/artifactregistry.writer",
    "roles/storage.objectAdmin"
  ]
}

# ==========================================
# 1. NETWORKING & SECURITY (The Foundation)
# ==========================================

resource "google_project_service" "container_scanning_api" {
  project            = var.project_id
  service            = "containerscanning.googleapis.com"
  disable_on_destroy = false 
}

resource "google_project_iam_member" "dataflow_worker_bindings" {
  for_each = toset(local.dataflow_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.dataflow_worker_sa.email}"
}

# Custom VPC so we have full control over the network
resource "google_compute_network" "vpc" {
  name                    = "flash-crash-vpc"
  auto_create_subnetworks = false
}

# Subnet for Dataflow Workers
resource "google_compute_subnetwork" "subnet" {
  name          = "dataflow-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region_dataflow
  network       = google_compute_network.vpc.id

  # Important: simple access to Google APIs (like Pub/Sub) without going over public internet
  private_ip_google_access = true
}

# CLOUD NAT: This allows private Dataflow workers to talk to the Vendor API
resource "google_compute_router" "router" {
  name    = "dataflow-router"
  network = google_compute_network.vpc.id
  region  = var.region_dataflow
}

resource "google_compute_router_nat" "nat" {
  name                               = "dataflow-nat"
  router                             = google_compute_router.router.name
  region                             = var.region_dataflow
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ==========================================
# 2. IAM & SERVICE ACCOUNTS
# ==========================================

# Dedicated Service Account for the Pipeline (Best Practice)
resource "google_service_account" "dataflow_worker_sa" {
  account_id   = "flash-crash-worker"
  display_name = "Dataflow Least Privilege Worker SA"
  description  = "Strictly scoped account for running the crypto ingestion pipeline"
}


# ==========================================
# 3. DATAFLOW
# ==========================================
# 1. The GCS Bucket for the Template Spec
resource "google_storage_bucket" "dataflow_templates" {
  name          = "flash-crash-templates-${random_id.bucket_suffix.hex}"
  location      = var.region_dataflow
  force_destroy = true
}

resource "google_dataflow_flex_template_job" "flash_crash_job" {
  provider                = google-beta
  name                    = "flash-crash-detector-job"
  project                 = var.project_id
  region                  = var.region_dataflow
  
  # This should point to the metadata.json file your Action uploads
  container_spec_gcs_path = "gs://flash-crash-staging-9ea112ba/templates/flash_crash_template.json"
   
  
  # 1. Force the cheapest, most available machines for BOTH the launcher and worker
  max_workers           = 1
  machine_type          = "e2-medium"
  launcher_machine_type = "e2-medium"
  
  # 2. The Networking Fix (Stops it from requesting a Public IP)
  ip_configuration      = "WORKER_IP_PRIVATE"
  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.subnet.self_link

  # -----------------------------------------------------------------

  service_account_email   = google_service_account.dataflow_worker_sa.email

  parameters = {
    input_subscription = google_pubsub_subscription.crypto_ticks_sub.id
    output_table       = "${var.project_id}:flash_crash_data.aggregated_stats"
  }

  depends_on = [
    google_project_iam_member.dataflow_worker_bindings
  ]
}

# ==========================================
# 4. DATA INFRASTRUCTURE
# ==========================================

# GCS Bucket for Dataflow Staging/Temp files
resource "google_storage_bucket" "temp_bucket" {
  name          = "flash-crash-staging-${random_id.bucket_suffix.hex}"
  location      = "US"
  force_destroy = true
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Pub/Sub Topic for Raw crypto Data
resource "google_pubsub_topic" "crypto_ticks" {
  name = "crypto-ticks"
}

# Subscription for Dataflow to read from
resource "google_pubsub_subscription" "crypto_ticks_sub" {
  name  = "crypto-ticks-sub"
  topic = google_pubsub_topic.crypto_ticks.name

  # Enable exactly-once delivery if your logic requires strict accuracy
  enable_exactly_once_delivery = true
}

# BigQuery Dataset
resource "google_bigquery_dataset" "dataset" {
  dataset_id = "flash_crash_data"
  location   = "US"
}

# BigQuery Table (Aggregated Data)
resource "google_bigquery_table" "table" {
  dataset_id = google_bigquery_dataset.dataset.dataset_id
  table_id   = "aggregated_stats"

schema = <<EOF
  [
  { "name": "ticker", "type": "STRING", "mode": "REQUIRED" },
  { "name": "window_start", "type": "STRING", "mode": "NULLABLE" },
  { "name": "window_end", "type": "STRING", "mode": "NULLABLE" },
  { "name": "trade_count", "type": "INTEGER", "mode": "NULLABLE" },
  { "name": "avg_price", "type": "FLOAT", "mode": "NULLABLE" },
  { "name": "max_price", "type": "FLOAT", "mode": "NULLABLE" },
  { "name": "min_price", "type": "FLOAT", "mode": "NULLABLE" },
  { "name": "drop_pct", "type": "FLOAT", "mode": "NULLABLE" },
  { "name": "flash_crash_detected", "type": "BOOLEAN", "mode": "NULLABLE" }
  ]
EOF
}
