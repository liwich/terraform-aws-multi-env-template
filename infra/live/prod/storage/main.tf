module "example_bucket" {
  source = "../../../modules/s3-bucket"

  name          = local.example_bucket_name
  versioning    = true
  sse_algorithm = "AES256"
  tags          = local.default_tags
}
