# Registry for Strimzi's spec.build output image (Kafka Connect + Debezium
# Postgres + Snowflake connector plugins baked in, per #42). Terraform owns
# this because it's a plain AWS resource, not a k8s CRD (IaC boundary #28).
resource "aws_ecr_repository" "kafka_connect" {
  name = "steam-infra-kafka-connect"

  # Teardown-between-sessions discipline: every session rebuilds the image,
  # so old tags have no value and shouldn't block `tofu destroy`.
  force_delete = true

  tags = {
    Name = "steam-infra-kafka-connect"
  }
}
