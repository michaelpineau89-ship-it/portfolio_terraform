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
  region        = "us-east1"
  network       = google_compute_network.vpc.id

  # Important: simple access to Google APIs (like Pub/Sub) without going over public internet
  private_ip_google_access = true
}

# CLOUD NAT: This allows private Dataflow workers to talk to the Vendor API
resource "google_compute_router" "router" {
  name    = "dataflow-router"
  network = google_compute_network.vpc.id
  region  = "us-east1"
}

resource "google_compute_router_nat" "nat" {
  name                               = "dataflow-nat"
  router                             = google_compute_router.router.name
  region                             = "us-east1"
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
    "roles/storage.objectAdmin",
    "roles/artifactregistry.writer"
  ])
  role   = each.key
  member = "serviceAccount:${google_service_account.dataflow_sa.email}"
  # usage: coalesce(value1, value2) -> takes the first one that isn't null/empty
  project = coalesce(var.project_id, "mike-personal-portfolio")
}

# ==========================================
# 3. DATAFLOW
# ==========================================
# 1. The GCS Bucket for the Template Spec
resource "google_storage_bucket" "dataflow_templates" {
  name          = "flash-crash-templates-${random_id.bucket_suffix.hex}"
  location      = var.region
  force_destroy = true
}

# 2. The Dataflow Job (Flex Template)
resource "google_dataflow_flex_template_job" "flash_crash_job" {
  provider                = google-beta
  name                    = "flash-crash-detector-live"
  region                  = var.region
  project                 = var.project_id
  container_spec_gcs_path = "gs://${google_storage_bucket.dataflow_templates.name}/templates/flash_crash_spec.json"

  service_account_email = google_service_account.dataflow_sa.email

  # Parameters to pass to your pipeline.py
  parameters = {
    workerRegion       = "us-east1"
    workerZone         = "us-east1-b"
    input_subscription = google_pubsub_subscription.stock_ticks_sub.id
    output_table       = "${var.project_id}:flash_crash_data.crashes"
  }

}

# ==========================================
# 4. CLOUD FUNCTIONS
# ==========================================
resource "google_cloud_run_v2_service" "ingestion_service" {
  name                = "stock-ingestion-service"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    containers {
      # Terraform will deploy whatever image tag is currently "latest" 
      # or you can pass a variable for specific SHA
      image = "${var.region}-docker.pkg.dev/${var.project_id}/flash-crash-repo/ingestion-service:latest"

      env {
        name  = "mike-personal-portfolio"
        value = var.project_id
      }
    }
    service_account = google_service_account.dataflow_sa.email
  }
}

resource "google_cloud_scheduler_job" "poller_trigger" {
  name             = "every-minute-trigger"
  schedule         = "* * * * *"
  attempt_deadline = "30s"

  http_target {
    http_method = "POST"
    uri         = google_cloud_run_v2_service.ingestion_service.uri

    oidc_token {
      service_account_email = google_service_account.dataflow_sa.email
    }
  }
}
# ==========================================
# 5. DATA INFRASTRUCTURE
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
