terraform {
  backend "gcs" {
    bucket       = "gcp-log-pipeline-tfstate-lausbelphegor"
    prefix       = "log-pipeline/state"
    use_lockfile = true
  }
}
