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

# Grant invoke access so Cloud Scheduler can call the functions' underlying Cloud Run services
resource "google_project_iam_member" "run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.pipeline_sa.email}"
}

# ==============================================================================
# 2. DIRECT FUNCTION TRIGGERS (Scheduler -> Cloud Functions)
# ==============================================================================

locals {
  market_tracker_functions = {
    fmp = {
      name        = "fmp-ingestor"
      description = "Triggers the FMP market ingestion function"
    }
    edgar = {
      name        = "edgar-ingestor"
      description = "Triggers the EDGAR market ingestion function"
    }
    finnhub = {
      name        = "finnhub-ingestor"
      description = "Triggers the Finnhub market ingestion function"
    }
    alphavantage = {
      name        = "alphavantage-ingestor"
      description = "Triggers the Alpha Vantage market ingestion function"
    }
  }
}

resource "google_cloud_scheduler_job" "market_ingestion_trigger" {
  for_each         = local.market_tracker_functions
  name             = "trigger-${each.value.name}-daily"
  description      = each.value.description
  schedule         = "0 18 * * 1-5" # 6 PM, Mon-Fri
  time_zone        = "America/New_York"
  attempt_deadline = "320s"

  http_target {
    http_method = "POST"
    uri         = "https://${var.region}-${var.project_id}.cloudfunctions.net/${each.value.name}"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode(jsonencode({
      source = "cloud-scheduler"
      job    = "daily-market-ingestion"
    }))

    oidc_token {
      service_account_email = google_service_account.pipeline_sa.email
      audience              = "https://${var.region}-${var.project_id}.cloudfunctions.net/${each.value.name}"
    }
  }
}

# ==============================================================================
# 3. SCHEDULED FUNCTIONS
# ==============================================================================