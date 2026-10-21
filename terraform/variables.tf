variable "aws_region" {
  description = "AWS region for the environment"
  type        = string
  default     = "us-east-1"
}

# Dirty-data injection knobs (#130): one variable per env var generator/dirty.py
# reads, default matching that module's own code default, so a plain `tofu
# apply` reproduces default behavior and a `-var`/`TF_VAR_*` override forces a
# fault to appear at bring-up without rebuilding the generator image. Adding a
# knob (#133/#136/#138/#139/#140) means one variable here plus one line each
# in generator.tf's templatefile() call and generator_user_data.sh.tpl's
# `docker run` -- the same three-line addition this ticket's knobs make.
variable "refund_reason_null_rate" {
  description = "REFUND_REASON_NULL_RATE override for the generator container"
  type        = string
  default     = "0.15"
}

variable "duplicate_rate_wishlist_items" {
  description = "DUPLICATE_RATE_WISHLIST_ITEMS override for the generator container"
  type        = string
  default     = "0.02"
}

variable "duplicate_rate_playtime_sessions" {
  description = "DUPLICATE_RATE_PLAYTIME_SESSIONS override for the generator container"
  type        = string
  default     = "0.01"
}

variable "purchase_recorded_at_jitter_max_seconds" {
  description = "PURCHASE_RECORDED_AT_JITTER_MAX_SECONDS override for the generator container"
  type        = string
  default     = "30"
}

variable "review_recorded_at_jitter_max_seconds" {
  description = "REVIEW_RECORDED_AT_JITTER_MAX_SECONDS override for the generator container"
  type        = string
  default     = "60"
}

variable "snapshot_recorded_at_jitter_max_seconds" {
  description = "SNAPSHOT_RECORDED_AT_JITTER_MAX_SECONDS override for the generator container"
  type        = string
  default     = "240"
}
