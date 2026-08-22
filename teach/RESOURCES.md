# AWS Networking Resources

## Knowledge

- [AWS VPC User Guide — "What is Amazon VPC?"](https://docs.aws.amazon.com/vpc/latest/userguide/what-is-amazon-vpc.html)
  Official primary source. Use for: authoritative definitions of VPC, subnet, route table, internet gateway.
- [AWS VPC User Guide — "Subnets for your VPC"](https://docs.aws.amazon.com/vpc/latest/userguide/configure-subnets.html)
  Use for: how public vs. private subnets actually work (it's the route table, not a label).
- [AWS VPC User Guide — "Route tables for your VPC"](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html)
  Use for: main route table vs. custom route tables, why explicit associations matter.
- [RFC 1918 — Address Allocation for Private Internets](https://www.rfc-editor.org/rfc/rfc1918)
  Use for: why 10.0.0.0/16 is a private range, where the other private ranges are.
- [AWS EC2 User Guide — "Security groups for your instances"](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-security-groups.html)
  Use for: stateful firewall behavior, inbound vs. outbound rules.
- [AWS Systems Manager User Guide — "Session Manager"](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
  Use for: how SSM gives shell access without SSH or open inbound ports.
- [AWS IAM User Guide — "IAM roles"](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
  Use for: roles vs. users, trust policies, AssumeRole.
- [AWS IAM User Guide — "Instance profiles"](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html)
  Use for: why EC2 needs an instance profile wrapper to use a role.

## Wisdom (Communities)

- [r/aws](https://reddit.com/r/aws)
  Use for: sanity-checking real-world VPC layouts, "is this over-engineered for my use case" questions.

## Gaps
- No community source yet for Terraform-specific AWS networking patterns — revisit once Terraform mechanics become the mission.
