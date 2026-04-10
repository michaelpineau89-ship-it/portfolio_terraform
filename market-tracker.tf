# Data source for project number (needed for Pub/Sub OIDC token creator binding)
data "google_project" "project" {}


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

# Grant BQ job execution (required to run load/query jobs, not just write rows)
resource "google_project_iam_member" "bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.pipeline_sa.email}"
}

# Allow the Eventarc service agent to mint OIDC tokens as pipeline_sa when invoking Cloud Run
resource "google_service_account_iam_member" "eventarc_token_creator" {
  service_account_id = google_service_account.pipeline_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-eventarc.iam.gserviceaccount.com"
}

# Allow pipeline_sa to receive Eventarc events (required for trigger delivery)
resource "google_project_iam_member" "eventarc_event_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.pipeline_sa.email}"
}

# Enable Eventarc API
resource "google_project_service" "eventarc_api" {
  project            = var.project_id
  service            = "eventarc.googleapis.com"
  disable_on_destroy = false
}

# Artifact Registry repo for all market-tracker container images
resource "google_artifact_registry_repository" "financial_trackers" {
  location      = var.region
  repository_id = "financial-trackers"
  description   = "Docker images for market tracker ingestion pipelines"
  format        = "DOCKER"
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

resource "google_eventarc_trigger" "fmp_trigger" {
  name            = "fmp-ingestor-trigger"
  location        = var.region
  service_account = google_service_account.pipeline_sa.email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  transport {
    pubsub {
      topic = google_pubsub_topic.market_ingestion_topic.id
    }
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.fmp_service.name
      region  = var.region
    }
  }

  depends_on = [google_project_service.eventarc_api]
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

resource "google_eventarc_trigger" "edgar_trigger" {
  name            = "edgar-ingestor-trigger"
  location        = var.region
  service_account = google_service_account.pipeline_sa.email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  transport {
    pubsub {
      topic = google_pubsub_topic.market_ingestion_topic.id
    }
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.edgar_service.name
      region  = var.region
    }
  }

  depends_on = [google_project_service.eventarc_api]
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

resource "google_eventarc_trigger" "finnhub_trigger" {
  name            = "finnhub-ingestor-trigger"
  location        = var.region
  service_account = google_service_account.pipeline_sa.email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  transport {
    pubsub {
      topic = google_pubsub_topic.market_ingestion_topic.id
    }
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.finnhub_service.name
      region  = var.region
    }
  }

  depends_on = [google_project_service.eventarc_api]
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
    timeout         = "1800s" 

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

resource "google_eventarc_trigger" "alphavantage_trigger" {
  name            = "alphavantage-ingestor-trigger"
  location        = var.region
  service_account = google_service_account.pipeline_sa.email

  matching_criteria {
    attribute = "type"
    value     = "google.cloud.pubsub.topic.v1.messagePublished"
  }

  transport {
    pubsub {
      topic = google_pubsub_topic.market_ingestion_topic.id
    }
  }

  destination {
    cloud_run_service {
      service = google_cloud_run_v2_service.alphavantage_service.name
      region  = var.region
    }
  }

  depends_on = [google_project_service.eventarc_api]
}