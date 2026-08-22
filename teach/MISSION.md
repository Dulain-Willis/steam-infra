# Mission: AWS Networking Fundamentals (via steam-infra)

## Why
Building real AWS infra for `steam-infra` in Terraform, but lost track of what the underlying AWS concepts actually are versus Terraform syntax. Need to understand VPC, subnets, gateways, and routing as raw AWS concepts so the Terraform reads as an obvious translation of a mental model, not magic incantations to copy-paste. This unblocks debugging, extending, and reasoning about the infra (bastion, RDS, future services) with confidence.

## Success looks like
- Can explain what a VPC, subnet, Availability Zone, Internet Gateway, and route table each are — in plain networking terms, no Terraform.
- Can look at any subnet in `steam-infra` and say whether it's "public" or "private" and *why*, by tracing its route table — not by trusting a name tag.
- Can predict, before running `terraform plan`, what a new resource will need wired up (which subnet, which route table, which security group) based on the network topology.
- Can read `steam-infra/terraform/*.tf` end to end and narrate the architecture out loud.

## Constraints
- Learning is happening alongside live infra work — lessons should be short, immediately applicable to the actual `steam-infra` code, not generic AWS tutorials.
- Prefers raw concepts explained separately from Terraform mechanics first, then mapped back to the `.tf` files.

## Out of scope
- Terraform language mechanics (state, modules, providers) — separate topic if it comes up.
- RDS internals — deferred until the bastion/security-group/IAM lesson lands (rds.tf exists in the repo, next after bastion.tf).
