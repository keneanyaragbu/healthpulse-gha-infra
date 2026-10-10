# HealthPulse GHA — Infrastructure Repo

Terraform for the HealthPulse platform's EKS cluster. Managed via a PR-based GitОps
workflow: pull requests trigger `terraform plan` (posted to the PR for review); merging
to main triggers `terraform apply`. Parameterized per environment (dev/uat/prod) with
remote S3 state.
