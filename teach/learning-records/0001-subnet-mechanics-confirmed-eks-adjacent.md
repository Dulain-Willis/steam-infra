---
title: Subnet/route-table mechanics confirmed correct; EKS/K8s scheduling entered as adjacent territory
date: 2026-08-24
---

## What happened

Reviewing PR #49 (EKS cluster + node groups, `steam-infra`), the user narrated their
own understanding of the new `eks_a`/`eks_b` subnets before asking for help: `/24` = 256
addresses, route table holds the `0.0.0.0/0 → igw` route, and a route table association
is the explicit link that makes a subnet public. All three were correct, unprompted —
confirms Lesson 1's core model has stuck (see [[../MISSION.md]] success criteria: "can
look at any subnet and say public/private and why, by tracing its route table").

## What was actually new

Two things outside prior lessons' scope:

1. `kubernetes.io/role/elb = "1"` — a Kubernetes tooling convention (AWS Load Balancer
   Controller subnet auto-discovery), not an AWS-native mechanism. Not derivable from
   the AWS networking mental model alone.
2. EKS node groups, taints, and labels — Kubernetes scheduling concepts, not AWS
   networking. Taught as a one-off in Lesson 4 because it's what's blocking
   comprehension of the current PR, not because the mission has formally expanded.

## Zone of proximal development note

Mission scope (`MISSION.md`) is explicitly AWS networking, with Terraform mechanics and
(implicitly) Kubernetes out of scope. Lesson 4 stepped slightly outside that to unblock
PR #49 review. If more Kubernetes-specific lessons get requested (scheduling, Services,
controllers), that's a real mission fork worth confirming with the user rather than
silently expanding — flag it next time rather than assuming.
