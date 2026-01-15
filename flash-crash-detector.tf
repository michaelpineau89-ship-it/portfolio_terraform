# ==========================================
# 1. NETWORKING & SECURITY (The Foundation)
# ==========================================

# Custom VPC so we have full control over the network
resource "google_compute_network" "vpc" {
  name                    = "flash-crash-vpc"
  auto_create_subnetworks = false
}

# Subnet for Dataflow Workers
resource "google_compute_subnetwork" "subnet" {
  name          = "dataflow-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = "us-central1"
  network       = google_compute_network.vpc.id

  # Important: simple access to Google APIs (like Pub/Sub) without going over public internet
  private_ip_google_access = true
}

# CLOUD NAT: This allows private Dataflow workers to talk to the Vendor API
resource "google_compute_router" "router" {
  name    = "dataflow-router"
  network = google_compute_network.vpc.id
  region  = "us-central1"
}

resource "google_compute_router_nat" "nat" {
  name                               = "dataflow-nat"
  router                             = google_compute_router.router.name
  region                             = "us-central1"
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# FIREWALL: Dataflow workers need to talk to EACH OTHER (Shuffle)
resource "google_compute_firewall" "dataflow_internal" {
  name    = "allow-dataflow-internal"
  network = google_compute_network.vpc.id

  allow {
    protocol = "tcp"
    ports    = ["12345-12346"] # Critical ports for Dataflow shuffle
  }

  source_tags = ["dataflow"]
  target_tags = ["dataflow"]
}

# ==========================================
# 2. IAM & SERVICE ACCOUNTS
# ==========================================

# Dedicated Service Account for the Pipeline (Best Practice)
resource "google_service_account" "dataflow_sa" {
  account_id   = "flash-crash-runner"
  display_name = "Flash Crash Dataflow Runner"
}

# Grant Permissions
resource "google_project_iam_member" "dataflow_worker" {
  for_each = toset([
    "roles/dataflow.worker",
    "roles/dataflow.admin",
    "roles/pubsub.editor",
    "roles/bigquery.dataEditor",
    "roles/storage.objectAdmin"
  ])
  role    = each.key
  member  = "serviceAccount:${google_service_account.dataflow_sa.email}"
}

# ==========================================
# 3. DATA INFRASTRUCTURE
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

# Pub/Sub Topic for Raw Stock Data
resource "google_pubsub_topic" "stock_ticks" {
  name = "stock-ticks-topic"
}

# Subscription for Dataflow to read from
resource "google_pubsub_subscription" "stock_ticks_sub" {
  name  = "stock-ticks-sub"
  topic = google_pubsub_topic.stock_ticks.name

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
  {
    "name": "symbol",
    "type": "STRING",
    "mode": "REQUIRED"
  },
  {
    "name": "window_start",
    "type": "TIMESTAMP",
    "mode": "NULLABLE"
  },
  {
    "name": "price_avg",
    "type": "FLOAT",
    "mode": "NULLABLE"
  },
  {
    "name": "volatility_index",
    "type": "FLOAT",
    "mode": "NULLABLE"
  }
]
EOF
}
