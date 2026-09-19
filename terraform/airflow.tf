resource "helm_release" "airflow" {
  name       = "airflow"
  repository = "https://airflow.apache.org"
  chart      = "airflow"
  version    = "1.22.0"
  namespace  = "airflow"

  create_namespace = true
  timeout          = 900

  values = [file("${path.module}/../k8s/airflow/values.yaml")]

  # Default wait=true blocks on every Deployment/StatefulSet reaching Ready
  # before Helm runs post-install hooks. This chart's migration/create-user
  # jobs ARE post-install hooks, but the scheduler/webserver/worker pods'
  # init containers block on those migrations having already run -- a
  # deadlock. wait=false lets hooks run right after manifests are submitted,
  # same as plain `helm install`'s default behavior.
  wait = false
}

