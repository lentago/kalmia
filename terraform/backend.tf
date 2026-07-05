terraform {
  # Remote state in solidago's S3 backend — shared account, isolated key,
  # same pattern as drosera. Local applies authenticate as the cpitzi-iac
  # IAM user; a kalmia-scoped OIDC role (S3 r/w on this key + the lock
  # table) comes with the apply-on-merge phase. See README.md § Phases.
  backend "s3" {
    bucket         = "foundry-tfstate-365184644049"
    key            = "kalmia/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "foundry-tfstate-lock"
    encrypt        = true
  }
}
