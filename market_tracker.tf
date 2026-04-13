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
# 3. SECRETS LOOKUP
# ==============================================================================

data "google_secret_manager_secret_version" "fmp_api_key" {
  secret  = "fmp-api-key"
  version = "latest"
}

data "google_secret_manager_secret_version" "finnhub_api_key" {
  secret  = "finnhub-api-key"
  version = "latest"
}

data "google_secret_manager_secret_version" "alphavantage_api_key" {
  secret  = "alphavantage-api-key"
  version = "latest"
}

# ==============================================================================
# 4. THE SPOKES (Cloud Run Services & Push Subscriptions)
# ==============================================================================

# ------------------------------------------------------------------------------
# A. FMP (Fundamentals & 13F)
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "fmp_service" {
  name     = "fmp-ingestor"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.pipeline_sa.email
    timeout         = "600s" # 10 mins

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/financial-trackers/fmp-ingestor:latest"
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "FMP_API_KEY"
        value = data.google_secret_manager_secret_version.fmp_api_key.secret_data
      }
    }
  }
}

resource "google_pubsub_subscription" "fmp_push_sub" {
  name  = "fmp-push-sub"
  topic = google_pubsub_topic.market_ingestion_topic.name
  push_config {
    push_endpoint = google_cloud_run_v2_service.fmp_service.uri
    oidc_token { service_account_email = google_service_account.pipeline_sa.email }
  }
}

# ------------------------------------------------------------------------------
# B. EDGAR (SEC Filings & Whale Tracker)
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "edgar_service" {
  name     = "edgar-ingestor"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.pipeline_sa.email
    timeout         = "600s"

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/financial-trackers/edgar-ingestor:latest"
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      # No API key needed for SEC EDGAR
    }
  }
}

resource "google_pubsub_subscription" "edgar_push_sub" {
  name  = "edgar-push-sub"
  topic = google_pubsub_topic.market_ingestion_topic.name
  push_config {
    push_endpoint = google_cloud_run_v2_service.edgar_service.uri
    oidc_token { service_account_email = google_service_account.pipeline_sa.email }
  }
}

# ------------------------------------------------------------------------------
# C. Finnhub (Alternative Data & News)
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "finnhub_service" {
  name     = "finnhub-ingestor"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.pipeline_sa.email
    timeout         = "600s"

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/financial-trackers/finnhub-ingestor:latest"
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "FINNHUB_API_KEY"
        value = data.google_secret_manager_secret_version.finnhub_api_key.secret_data
      }
    }
  }
}

resource "google_pubsub_subscription" "finnhub_push_sub" {
  name  = "finnhub-push-sub"
  topic = google_pubsub_topic.market_ingestion_topic.name
  push_config {
    push_endpoint = google_cloud_run_v2_service.finnhub_service.uri
    oidc_token { service_account_email = google_service_account.pipeline_sa.email }
  }
}

# ------------------------------------------------------------------------------
# D. Alpha Vantage (Daily Market Pricing)
# ------------------------------------------------------------------------------
resource "google_cloud_run_v2_service" "alphavantage_service" {
  name     = "alphavantage-ingestor"
  location = var.region
  ingress  = "INGRESS_TRAFFIC_INTERNAL_ONLY"

  template {
    service_account = google_service_account.pipeline_sa.email
    # Alpha Vantage has strict rate limits, this container takes the longest
    timeout = "1800s"

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project_id}/financial-trackers/alphavantage-ingestor:latest"
      env {
        name  = "PROJECT_ID"
        value = var.project_id
      }
      env {
        name  = "ALPHA_VANTAGE_API_KEY"
        value = data.google_secret_manager_secret_version.alphavantage_api_key.secret_data
      }
    }
  }
}

resource "google_pubsub_subscription" "alphavantage_push_sub" {
  name  = "alphavantage-push-sub"
  topic = google_pubsub_topic.market_ingestion_topic.name
  push_config {
    push_endpoint = google_cloud_run_v2_service.alphavantage_service.uri
    oidc_token { service_account_email = google_service_account.pipeline_sa.email }
  }
}