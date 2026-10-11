terraform {
  backend "s3" {
    bucket         = "healthpulse-gha-tfstate-588738574057"
    key            = "healthpulse-gha/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "healthpulse-gha-tflock"
    encrypt        = true
  }
}
