# notes.md — Layer 2 & Layer 3 Analytical Answers

## Task 2.3 — Network Q&A for Sarah

**Why does the Database Subnet have no route to the Internet Gateway?**

Because the data tier never needs to *initiate* an outbound connection to the
public internet, and it should never be reachable *from* the internet either.
The `aws_route_table.database` in `main.tf` has zero routes pointing at the
Internet Gateway or at any NAT device — its only entries are the local VPC
route. That means even if an attacker compromised an EC2 instance in the app
tier and pivoted toward the database, there is no network path for the
database to exfiltrate data to an external host, and no path for anything on
the internet to reach RDS directly, regardless of what a security group
allows. This is defense-in-depth: the security group (`rds_sg`) enforces
*who* can talk to the database, and the route table enforces *where its
traffic can physically go* — two independent controls, which is exactly what
last year's audit was pushing for. The one exception we added is the free S3
Gateway VPC Endpoint, which lets the database subnet reach S3 (for backup
traffic) without ever touching the public internet or a NAT device.

**What is the difference between Security Groups and NACLs?**

| | Security Groups | Network ACLs |
|---|---|---|
| Scope | Attached to ENIs/instances | Attached to a subnet, applies to everything in it |
| State | Stateful — a matching outbound response is auto-allowed | Stateless — inbound and outbound rules must both be defined explicitly |
| Rule type | Allow rules only | Allow **and** explicit deny rules |
| Evaluation | All rules evaluated, most permissive wins | Rules evaluated in numeric order, first match wins |

In this design, Security Groups do the primary least-privilege enforcement
(Task 2.2). The default NACL is left in its default "allow all" state, which
is standard practice — NACLs are reserved for subnet-wide emergency blocks
(e.g., blackholing a specific IP range during an incident), not day-to-day
access control.

---

## Task 3.3 — Auto Scaling Q&A for Sarah

**If CPU hits 60% on one instance, what happens next — step by step?**

1. CloudWatch has been collecting the `ASGAverageCPUUtilization` metric
   (average across *all* instances in the ASG, not any single instance) at
   1-minute resolution.
2. The Target Tracking policy (`aws_autoscaling_policy.cpu_target_tracking`
   in `compute.tf`) compares that rolling average against the 60% target.
3. If the sustained average is above target, the policy calculates how many
   additional instances are needed to bring the average back down to 60%,
   and calls `SetDesiredCapacity` on the ASG.
4. The ASG launches new instances from the Launch Template up to
   `asg_max_size` (10).
5. The ASG registers each new instance with the ALB target group.
6. Once the instance passes its health checks, the ALB starts routing live
   traffic to it, and the CPU average drops back toward target.

**When does a new instance start receiving traffic? Why not immediately?**

Not the moment it boots — only once it passes the ALB target group's health
check (`aws_lb_target_group.app_tg`, `/health`, 3 consecutive successes on a
30-second interval) **and** the ASG's `health_check_grace_period` (90
seconds) has elapsed. Sending traffic to an instance the instant it launches
would hit it before the OS has finished booting, the app process has started,
and any warm-up (opening DB connection pools, populating local caches) has
completed — that would produce a wave of 5xx errors right when the system is
already under load, which is the opposite of what scaling is trying to fix.

**Why did we choose `min = 2` instead of `min = 1`?**

Two reasons, both from Task 1.1's original brief:

1. **Multi-AZ redundancy at all times, not just at peak.** The two private
   subnets sit in separate Availability Zones. With `min = 1`, that single
   instance lives in exactly one AZ — if that AZ has an outage (power,
   networking, etc.), the entire site goes down, which is precisely the kind
   of Black-Friday-style outage this migration is meant to eliminate.
   `min = 2` guarantees at least one healthy instance in each AZ at all
   times.
2. **Zero-downtime deploys.** The CI/CD pipeline (Layer 5) does a rolling
   `instance_refresh` with `min_healthy_percentage = 90`. With only one
   instance, replacing it during a deploy means briefly having zero capacity.
   With two, the ASG can retire and replace one at a time while the other
   keeps serving traffic.

> **Cost note:** running 2 instances continuously uses more than the
> Free Tier's 750 shared t3.micro hours per month if kept running 24/7 (one
> instance alone = ~730 hrs/month, so two already exceeds the pool). This
> was kept at `min = 2` here because it's what the assignment explicitly
> specifies and it's the architecturally correct answer. For actual
> hands-on testing without incurring charges, either rely on `terraform
> plan` only (see Rules & Academic Integrity — plan output is sufficient for
> grading, no apply required), or apply with `environment = "demo"`, which
> drops this to `min = 1` / `desired = 1`, and run `terraform destroy` as
> soon as you're done testing.
