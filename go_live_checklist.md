# go_live_checklist.md — Layer 5

## Task 5.2 — CloudWatch Alarms

| Alarm Name | Metric | Threshold | Action |
|---|---|---|---|
| High Latency | ALB P95 Latency | > 800ms for 5 minutes | Publish to `retailedge-alerts` SNS topic → pages on-call engineer; auto-triggers a diagnostic Lambda that snapshots current ASG instance count/CPU for the incident channel |
| High Error Rate | ALB 5xx Rate | > 1% | Publish to `retailedge-alerts` SNS topic (Slack + PagerDuty); if sustained > 5 minutes, also triggers CodeDeploy/instance-refresh rollback to the previous known-good AMI/task definition |
| DB CPU Spike | RDS CPUUtilization | > 80% | Publish to `retailedge-alerts` SNS topic; on Single-AZ this is a manual-response alarm (no automatic remediation) since there's no standby to fail to — the on-call engineer decides whether to scale the instance class or investigate a runaway query |
| Low Cache Hit Rate | ElastiCache Hit Rate | < 70% | Publish to `retailedge-alerts` SNS topic (warning severity, not paging) — signals the cache may need a TTL/key-strategy review, since a sustained drop pushes load back onto RDS |

All four alarms publish to a single `retailedge-alerts` SNS topic, fanned out
to Slack (informational) and PagerDuty (paging) subscriptions, so severity is
controlled at the subscription level rather than needing a different alarm
per channel.

## Task 5.3 — Go-Live Checklist

**The 5 things to verify before flipping DNS:**

1. **Health checks are green across both AZs** — the ALB target group shows
   all registered targets `healthy`, with at least one instance in each AZ.
2. **DMS replication lag is 0** and the CDC task has been stopped per the
   cutover plan (`migration_plan.md`, Phase 3) — confirms RDS has every
   record from on-prem.
3. **Smoke test against the ALB's DNS name directly** (bypassing Route 53) —
   log in, browse a product, complete a test checkout, confirm session
   persistence (validates Redis) and order writes (validates RDS) all work
   end-to-end before any real traffic is routed there.
4. **CloudWatch alarms and the SNS topic are active and subscribed** — you
   want alerting live *before* cutover, not discovered missing during an
   incident.
5. **Rollback path is ready** — the on-prem server is still up, DNS TTL has
   already been lowered in advance (see below), and the team knows the
   one-command way to revert.

**How to perform the DNS cutover safely — Route 53 Weighted Routing:**

1. Days before cutover, lower the existing DNS record's TTL to something
   short (60s) so any later change propagates quickly.
2. Create two weighted records for the domain: one pointing at the old
   on-prem IP, one pointing at the new ALB (via an alias record). Start the
   ALB record's weight at a small value (e.g., 5%) and the on-prem record at
   95%.
3. Watch the CloudWatch alarms above with real production traffic hitting
   the new stack at low volume. If clean, gradually shift the weight — e.g.
   5% → 25% → 50% → 100% — over a period of hours, not all at once.
4. Once the AWS side is at 100% and stable, remove the on-prem weighted
   record entirely (leaving a single alias record to the ALB), keeping the
   on-prem server running as the rollback target per Phase 4 of the
   migration plan.

This is deliberately safer than an instant A-record swap: a bad deploy or an
unexpected load pattern only ever affects the small percentage of traffic
currently weighted onto AWS, and rolling back is just editing the weights
back to 0, not another DNS propagation wait.

---

## Task 5.4 (Bonus) — Cost Optimization Report for Sarah

**Savings Plans / Reserved Instances for RDS**
A 1-year "All Upfront" Reserved Instance on `db.t3.micro` is what the
original Layer 1 TCO table already assumes, and it's Free-Tier-eligible
regardless for the first 12 months on an eligible account — so there's
effectively nothing to reserve yet. Revisit this the month the Free Tier
year expires: at that point a 1-year RI typically saves ~30-40% over
On-Demand for the same instance class.

**S3 Intelligent-Tiering for static assets**
The product-image / static-asset bucket is a good Intelligent-Tiering
candidate once traffic patterns stabilize post-launch — it automatically
moves objects that haven't been accessed in 30+ days to a cheaper tier with
no retrieval fee, no manual lifecycle rules to babysit. For the *backup*
bucket (`aws_s3_bucket.backups` in `data.tf`), a fixed lifecycle rule
(7 days → Standard-IA, 30 days → expire) is already configured directly,
since backup access patterns are predictable enough not to need
Intelligent-Tiering's per-object monitoring fee.

**AWS Compute Optimizer recommendations**
Turn on Compute Optimizer after the first 2 weeks of real traffic (it needs
history to give useful recommendations) and review its EC2 and RDS sizing
suggestions monthly. On a `t3.micro` fleet there's not much room to size
*down*, but it's the right early-warning signal for the moment traffic
outgrows the Free Tier and it's time to right-size `instance_type` up to
something like `t3.small` or `m6i.large` deliberately, instead of
discovering it via a billing surprise.

**Biggest lever available right now:** the NAT instance vs. NAT Gateway
choice (`use_nat_instance` in `variables.tf`) and the ElastiCache node count
(`redis_num_nodes`) are the two knobs most worth revisiting as traffic
grows — a managed NAT Gateway and a 2-node Redis cluster are both the
*more resilient* choice long-term, they just aren't the *free* choice today.
