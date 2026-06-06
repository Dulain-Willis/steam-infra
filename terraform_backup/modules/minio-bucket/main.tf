resource "minio_s3_bucket" "this" {
  bucket = var.bucket_name
}
