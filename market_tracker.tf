# ==============================================================================
# 1. CORE FOUNDATION (Storage & Identity)
# ==============================================================================

# BigQuery Dataset
resource "google_bigquery_dataset" "market_tracker" {
  dataset_id                 = "market_tracker"
  friendly_name              = "Market Tracker Bronze Layer"
  description                = "Raw ELT ingestion tables for financial market data"
  location                   = "US"
  delete_contents_on_destroy = false
}

# The single identity used by all containers
resource "google_service_account" "pipeline_sa" {
  account_id   = "market-pipeline-sa"
  display_name = "Market Tracker Pipeline Service Account"
}

# Grant BQ access
resource "google_project_iam_member" "bq_data_editor" {
  project = var.project_id
  role    = "roles/bigquery.dataEditor"
  member  = "serviceAccount:${google_service_account.pipeline_sa.email}"
}

# Grant Secret Manager access (so containers can read the API keys)
resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.pipeline_sa.email}"
}

# Grant Cloud Run Invoke access (so Pub/Sub can trigger the containers)
resource "google_project_iam_member" "run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.pipeline_sa.email}"
}

# ==============================================================================
# 2. THE FAN-OUT HUB (Scheduler & Pub/Sub)
# ==============================================================================

resource "google_pubsub_topic" "market_ingestion_topic" {
  name = "daily-market-ingestion-trigger"
}

resource "google_cloud_scheduler_job" "daily_trigger" {
  name             = "trigger-market-ingestion-daily"
  description      = "Fires at 6 PM EST to fan-out all market ingestion containers"
  schedule         = "0 18 * * 1-5" # 6 PM, Mon-Fri
  time_zone        = "America/New_York"
  attempt_deadline = "320s"

  pubsub_target {
    topic_name = google_pubsub_topic.market_ingestion_topic.id
    data       = base64encode("{\"action\": \"start_daily_ingestion\"}")
  }
}

# ==============================================================================
# 3. CLOUD RUN SERVICE LOOKUPS (deployed & managed by gcp-financial-market-tracker repo)
# ==============================================================================

# ==============================================================================
# 4. THE SPOKES (Cloud Run Services & Push Subscriptions)
# ==============================================================================

# ------------------------------------------------------------------------------
# A. FMP (Fundamentals & 13F)
# ------------------------------------------------------------------------------
data "google_cloud_run_v2_service" "fmp_service" {
  name     = "fmp-ingestor"
  location = var.region
}

resource "google_pubsub_subscription" "fmp_push_sub" {
  name  = "fmp-push-sub"
  topic = google_pubsub_topic.market_ingestion_topic.name
  push_config {
    push_endpoint = data.google_cloud_run_v2_service.fmp_service.uri
    oidc_token { service_account_email = google_service_account.pipeline_sa.email }
  }
}

# ------------------------------------------------------------------------------
# B. EDGAR (SEC Filings & Whale Tracker)
# ------------------------------------------------------------------------------
data "google_cloud_run_v2_service" "edgar_service" {
  name     = "edgar-ingestor"
  location = var.region
}

resource "google_pubsub_subscription" "edgar_push_sub" {
  name  = "edgar-push-sub"
  topic = google_pubsub_topic.market_ingestion_topic.name
  push_config {
    push_endpoint = data.google_cloud_run_v2_service.edgar_service.uri
    oidc_token { service_account_email = google_service_account.pipeline_sa.email }
  }
}

# ------------------------------------------------------------------------------
# C. Finnhub (Alternative Data & News)
# ------------------------------------------------------------------------------
data "google_cloud_run_v2_service" "finnhub_service" {
  name     = "finnhub-ingestor"
  location = var.region
}

resource "google_pubsub_subscription" "finnhub_push_sub" {
  name  = "finnhub-push-sub"
  topic = google_pubsub_topic.market_ingestion_topic.name
  push_config {
    push_endpoint = data.google_cloud_run_v2_service.finnhub_service.uri
    oidc_token { service_account_email = google_service_account.pipeline_sa.email }
  }
}

# ------------------------------------------------------------------------------
# D. Alpha Vantage (Daily Market Pricing)
# ------------------------------------------------------------------------------
data "google_cloud_run_v2_service" "alphavantage_service" {
  name     = "alphavantage-ingestor"
  location = var.region
}

resource "google_pubsub_subscription" "alphavantage_push_sub" {
  name  = "alphavantage-push-sub"
  topic = google_pubsub_topic.market_ingestion_topic.name
  push_config {
    push_endpoint = data.google_cloud_run_v2_service.alphavantage_service.uri
    oidc_token { service_account_email = google_service_account.pipeline_sa.email }
  }
}