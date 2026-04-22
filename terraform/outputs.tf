output "landing_bucket_name" {
  description = "Name of the raw landing zone bucket."
  value       = module.landing_bucket.bucket_name
}
