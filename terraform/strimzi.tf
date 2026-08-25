# Strimzi Cluster Operator, installed via Terraform per #28's IaC boundary
# (Terraform owns the operator; Kafka/Connect/connectors are Strimzi CRDs
# applied with kubectl, not Terraform). See #40.
resource "helm_release" "strimzi" {
  name       = "strimzi-cluster-operator"
  repository = "oci://quay.io/strimzi-helm"
  chart      = "strimzi-kafka-operator"
  version    = "1.2.0"
  namespace  = "kafka"

  create_namespace = true

  # Restrict the operator to the kafka namespace instead of watching all
  # namespaces cluster-wide.
  set {
    name  = "watchNamespaces[0]"
    value = "kafka"
  }
}
