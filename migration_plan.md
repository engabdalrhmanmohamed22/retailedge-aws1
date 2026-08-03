# migration_plan.md — Layer 4: Data Migration Cutover Plan

## Constraint recap (from Sarah)
- 8 years of customer/order data — **zero data loss** tolerated.
- **≤ 30 minutes** of downtime allowed for the cutover.

## Phase 1 — Full Load
AWS DMS performs a one-time full copy of every existing table from the
on-premises MySQL instance to the new RDS MySQL target, while the
on-premises database keeps serving live production traffic untouched.

- **Estimated time: ~4–6 hours**, based on the current dataset (8 years of
  customer/order data). This runs entirely in the background with no
  application downtime — DMS reads from the source without locking tables.

## Phase 2 — Change Data Capture (CDC)
Once the full load finishes, DMS switches to CDC mode: it tails the source
database's binary log and continuously replicates every insert/update/delete
that happens on-prem into RDS in near-real time, closing the gap that opened
while Phase 1 was copying.

## Phase 3 — Cutover
**When replication lag < 5 seconds**, do the following, in order:

1. Put the site into a brief maintenance/read-only mode (this is the only
   part of the plan with real downtime).
2. Confirm DMS reports 0 seconds of CDC lag remaining (drain the last few
   seconds of changes).
3. Stop the DMS task.
4. Point the application's DB connection string at the new RDS endpoint
   (via a Secrets Manager secret / environment variable — no code deploy
   needed).
5. Take the site out of maintenance mode.

Because Phases 1–2 already moved 99.9%+ of the data in the background, this
final step is measured in **minutes, not hours** — comfortably inside the
30-minute budget.

## Phase 4 — Rollback
**If a problem is discovered within 48 hours** of cutover:

1. Do **not** delete or stop the old on-prem MySQL server for 48 hours after
   cutover — it stays warm as the rollback target.
2. Re-point the application's connection string back to the on-prem
   endpoint.
3. Because writes may have landed on the *new* RDS instance after cutover,
   run a reverse DMS task (RDS → on-prem) in CDC mode during those 48 hours
   so the on-prem copy stays current and rollback doesn't lose any
   post-cutover writes.
4. After 48 hours with no issues, decommission the on-prem database and
   stop the reverse-replication task.

---

## Task 4.3 — RPO / RTO

**RPO (Recovery Point Objective)** — the maximum amount of data (measured in
time) you can afford to lose in a failure. "RPO of 5 minutes" means: in the
worst case, you lose the last 5 minutes of writes.

**RTO (Recovery Time Objective)** — the maximum amount of time you can afford
to be *down* before service is restored.

**Expected values for this configuration (Single-AZ, per the Free-Tier
adaptation):**

| | Single-AZ (this build) | Multi-AZ (original diagram) |
|---|---|---|
| **RPO** | Near-zero for planned events (clean shutdown flushes to disk); **up to the last few minutes of writes** in an unplanned crash, recovered from the most recent automated backup / transaction logs (7-day `backup_retention_period` is enabled either way) | Effectively zero — synchronous replication to the standby means committed writes are never lost |
| **RTO** | **Minutes to tens of minutes** — AWS has to launch a fresh instance from the latest automated backup / snapshot and replay logs before it's reachable again | **Under 60 seconds** — automatic failover to an already-running, already-in-sync standby |

This is the direct trade-off of choosing Single-AZ to stay in the Free Tier:
Multi-AZ was designed specifically to get RTO under 60 seconds (per the
original Layer 1 doc). Single-AZ still protects against **data loss** (daily
backups + transaction logs give you a real recovery point), but an actual
instance failure now means real customer-facing downtime while RDS
provisions a replacement, rather than an instant, invisible failover. Given
this is a training project rather than the live production cutover, that
trade-off is reasonable here — but it should be called out explicitly to
Sarah if this build were ever promoted to production.

---

## Task 4.4 (Bonus) — Why ElastiCache alongside RDS?

Redis absorbs the read-heavy, repeat traffic (product pages, session lookups)
so it never touches the database at all, which is exactly what protects RDS
during a Black-Friday-style spike.

```
Cache HIT flow:
  User -> ALB -> App instance -> Redis  (data found, ~1ms)
                                   |
                                   v
                              Response to user
                     (RDS is never touched)

Cache MISS flow:
  User -> ALB -> App instance -> Redis  (not found)
                                   |
                                   v
                              RDS MySQL (query runs, ~10-50ms)
                                   |
                                   v
                     App instance writes result back into Redis
                                   |
                                   v
                              Response to user
             (next request for the same data is now a HIT)
```

Without this layer, every single page view during peak traffic — 15,000
concurrent users, per the brief — would hit RDS directly. Task 1.1's own
math shows that's ~333 queries/second at peak; Redis is what keeps the
*repeat* portion of that load off the database entirely.
