module "landing_bucket" {
  source = "./modules/minio-bucket"

  bucket_name = "landing"
}

module "warehouse_bucket" {
  source      = "./modules/minio-bucket"
  bucket_name = "warehouse"
}
