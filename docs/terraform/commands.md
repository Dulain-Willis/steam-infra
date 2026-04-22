# Terraform Commands

Terraform manages MinIO bucket creation declaratively with state tracking. Run all commands from the project root — the `terraform` service mounts `infra/terraform/` as its working directory.

## Apply changes (init → plan → apply)

```bash
docker compose run --rm terraform init
docker compose run --rm terraform plan
docker compose run --rm terraform apply
```

`init` only needs to be run once (or after provider/module changes). For subsequent bucket changes, `plan` and `apply` are sufficient.

---

## MinIO Client (mc)

The `mc` service is an imperative alternative for one-off bucket operations. Unlike Terraform, it does not track state.

### Delete a bucket

```bash
docker compose run --rm --entrypoint="" mc sh -c \
  "mc alias set local http://minio:9000 minioadmin minioadmin && \
   mc rb --force local/<bucket-name>"
```

### Create a bucket

```bash
docker compose run --rm --entrypoint="" mc sh -c \
  "mc alias set local http://minio:9000 minioadmin minioadmin && \
   mc mb local/<bucket-name>"
```
