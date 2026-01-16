# 🏗️ Portfolio Infrastructure (Terraform)

![Build Status](https://github.com/michaelpineau89-ship-it/portfolio_terraform/actions/workflows/terraform.yml/badge.svg)
![Terraform Version](https://img.shields.io/badge/Terraform-v1.6+-purple)
![Cloud Provider](https://img.shields.io/badge/GCP-US--Central1-blue)

This repository serves as the centralized **Infrastructure-as-Code (IaC)** foundation for my personal data engineering portfolio. It manages all cloud resources (Networking, IAM, Compute, Data) on **Google Cloud Platform (GCP)**.

## 📐 Architecture & Design Philosophy

### The "One-File-Per-Project" Strategy
Unlike a typical enterprise environment where projects are isolated by folder or state file, this repository intentionally uses a **Flat Structure** where each distinct portfolio project is defined in its own standalone `.tf` file (e.g., `flash-crash-detector.tf`).

**Why this approach?**
* **Agility:** Allows for rapid spinning up/down of experimental architectures without the overhead of bootstrapping new backends for every prototype.
* **Shared Foundation:** All projects share a common VPC and Network Security perimeter defined in `main.tf`.
* **Cost Control:** Centralized visibility makes it easier to track and destroy unused resources.

## 🚀 Active Projects

| Project File | Description | Key Services |
| :--- | :--- | :--- |
| **`flash-crash-detector.tf`** | Real-time stock market anomaly detection pipeline. | Pub/Sub, Dataflow (Apache Beam), BigQuery, Cloud NAT |
| **`main.tf`** | Core networking and shared security baseline. | VPC, Subnets, Firewalls, Service Accounts |

## 🛠️ Tech Stack

* **IaC:** Terraform
* **Provider:** Google Cloud Platform (GCP)
* **State Management:** GCS Remote Backend (Versioning Enabled)
* **CI/CD:** GitHub Actions (Automated Plan & Apply on merge)

## 🤖 CI/CD Pipeline

Infrastructure changes are managed via a GitOps workflow using **GitHub Actions**:

1.  **Pull Request:** Triggers `terraform plan`. The plan output is posted as a PR comment for review.
2.  **Merge to Main:** Triggers `terraform apply` to deploy changes to production.
3.  **State Locking:** Utilizes GCS locking to prevent race conditions during pipeline runs.

## 🏃‍♂️ Local Development

### Prerequisites
* [Terraform CLI](https://developer.hashicorp.com/terraform/downloads) (v1.6+)
* [Google Cloud SDK](https://cloud.google.com/sdk/docs/install)

### Setup
1.  **Clone the repo:**
    ```bash
    git clone [https://github.com/michaelpineau89-ship-it/portfolio_terraform.git](https://github.com/michaelpineau89-ship-it/portfolio_terraform.git)
    cd portfolio_terraform
    ```

2.  **Authenticate with GCP:**
    ```bash
    gcloud auth application-default login
    ```

3.  **Initialize Terraform:**
    *Connects to the remote GCS backend.*
    ```bash
    terraform init -backend-config="bucket=mike-personal-portfolio-tf-state"
    ```

4.  **Plan & Apply:**
    ```bash
    terraform plan
    terraform apply
    ```

---
*Maintained by Mike Pineau*