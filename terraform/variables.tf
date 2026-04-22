variable "project" {
  description = "Short name for this project, used as a prefix for resources."
  type        = string
  default     = "steamspy"
}

variable "environment" {
  description = "Deployment environment (e.g., dev, prod)."
  type        = string
  default     = "dev"
}

variable "minio_endpoint" {
  description = "URL of the MinIO server."
  type        = string
}

variable "minio_access_key" {
  description = "Access key for MinIO."
  type        = string
  sensitive   = true
}

variable "minio_secret_key" {
  description = "Secret key for MinIO."
  type        = string
  sensitive   = true
}
