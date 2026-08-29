---
title: Corrected two follow-up misreads on Lesson 4
date: 2026-08-24
---

## Misread 1: "kafka needs 3 nodes at all times" as a Kubernetes/EKS requirement

Not accurate — nothing in K8s or EKS mandates a node count. `min=max=desired=3` is the
operator pinning the pool to avoid autoscaling churn, because Kafka brokers are
stateful (local disk, fixed identity) and losing a node mid-broker risks data loss. The
"3" tracks Kafka's own replication-factor convention (durability), one broker per
dedicated node — a Kafka design choice mirrored in Terraform config, not enforced by
the platform. Worth being precise about this distinction if EKS lessons continue: EKS
node groups have no opinion on what runs on them; all guarantees come from how the
operator configures min/max/desired plus taints.

## Misread 2: assumed "public subnet" was a single dedicated slot (the bastion's)

Corrected: "public" is a route table property (`0.0.0.0/0 → igw`), and multiple
subnets can associate to the *same* route table concurrently. `eks_a`/`eks_b` didn't
repurpose the bastion's subnet — they're separate subnets sharing the same
`aws_route_table.public` via their own associations. Good sign this needed correcting
at all — means [[0001-subnet-mechanics-confirmed-eks-adjacent]]'s confirmed model was
solid on the *mechanics* (association = link, route table = rules) but hadn't yet
generalized to "route table is shared infrastructure, not 1:1 with a subnet." Watch for
this gap resurfacing if a lesson introduces a *third* route table later — check they
partition multiple subnets across it correctly, not just single-subnet cases.
