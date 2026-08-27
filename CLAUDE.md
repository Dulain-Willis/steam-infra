## Agent skills

### Issue tracker

Issues tracked as GitHub issues in this repo (via `gh` CLI). See `docs/agents/issue-tracker.md`.

### Domain docs

Single-context layout — `CONTEXT.md` + `docs/adr/` at repo root. See `docs/agents/domain.md`.

### Terraform targeted applies

Before running any `tofu apply -target=...`, see `docs/agents/terraform.md` —
`-target` doesn't pull in resources that aren't attribute-referenced by the
target (e.g. EKS subnets' route-table associations), which silently breaks
node group creation.
