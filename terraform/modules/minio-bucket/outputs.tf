output "bucket_name" {
  description = "The name of the bucket."
  value       = minio_s3_bucket.this.bucket
}
