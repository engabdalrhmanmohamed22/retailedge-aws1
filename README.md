# RetailEdge AWS Migration — Completed Submission

Solutions Architect capstone (RetailEdge Inc., AWS Three-Tier Migration) —
all 5 layers, adapted to run inside the AWS Free Tier wherever the
architecture allows it to.

## What's in this folder

| File | Layer | Covers |
|---|---|---|
| `ARCHITECTURE.md` | Layer 1 | Diagram (Task 1.1), migration strategy table (Task 1.2), Free-Tier-adapted TCO (Task 1.3), and a full table of what changed vs. the original design and why |
| `terraform/main.tf` | Layer 2 | VPC, subnets, CIDRs (Task 2.1), NAT instance/VPC endpoint |
| `terraform/security_groups.tf` | Layer 2 | `alb_sg`, `app_sg`, `rds_sg`, `redis_sg` (Task 2.2) |
| `notes.md` | Layer 2 + 3 | Written answers (Task 2.3, Task 3.3) |
| `terraform/compute.tf` | Layer 3 | Launch template, ASG, target-tracking scaling policy (Task 3.1/3.2), scheduled scaling bonus (Task 3.4) |
| `terraform/data.tf` | Layer 4 | RDS Single-AZ + S3 backup Lambda + ElastiCache (Task 4.1) |
| `lambda/db_backup.py` | Layer 4 | The nightly `mysqldump → S3` backup function referenced from `data.tf` |
| `migration_plan.md` | Layer 4 | DMS cutover plan (Task 4.2), RPO/RTO answers (Task 4.3), cache diagram bonus (Task 4.4) |
| `.github/workflows/deploy.yml` | Layer 5 | Test → Build → manual-approval Deploy pipeline with auto-rollback (Task 5.1) |
| `go_live_checklist.md` | Layer 5 | Alarms table (Task 5.2), go-live checklist + DNS cutover method (Task 5.3), cost optimization report bonus (Task 5.4) |
| `terraform/variables.tf` / `outputs.tf` | all | Shared inputs/outputs — every Free-Tier substitution is a named variable with a comment explaining the trade-off |

## The Free Tier adaptation, in one place

You asked for three specific changes plus a general "stay inside Free Tier"
constraint. Here's exactly what was done about each:

1. **EC2 instance type = `m7i-flex.large`.** Correction from an earlier pass:
   `m7i-flex.large` genuinely IS "Free tier eligible" — but only for AWS
   accounts created on/after July 15, 2025, and only in the sense that it
   draws down a $100-$200 promotional credit (6-month window) rather than
   giving unlimited free hours the way `t3.micro` does on legacy accounts.
   At `asg_min_size = 2`, that credit covers roughly 20 days of
   `m7i-flex.large` vs. 200+ days of `t3.micro`. Kept as the default here
   because this project only runs for about a week; swap `instance_type`
   back to `t3.micro` in `variables.tf` if you plan to keep it up longer.
2. **RDS Single-AZ.** Done exactly as requested — `db_multi_az = false` in
   `variables.tf`, `db.t3.micro`, 20GB storage, all inside the Free Tier for
   the first 12 months.
3. **Backups to S3.** RDS's own 7-day automated backups stay on (free, part
   of the RDS Free Tier storage allowance), and a nightly Lambda
   (`lambda/db_backup.py`) additionally dumps the database and uploads it to
   the S3 bucket in `data.tf`, with a lifecycle rule so it doesn't grow
   unbounded.
4. **General Free Tier fit.** The one component with genuinely no Free Tier
   path at any size is **ElastiCache Redis** (~$11-13/mo for even the
   smallest node) — flagged explicitly in `variables.tf`, `ARCHITECTURE.md`,
   and `go_live_checklist.md` rather than silently left out of the cost
   picture. The managed **NAT Gateway** was swapped for a self-managed NAT
   *instance* for the same reason (NAT Gateway is never Free-Tier eligible,
   ~$32-45/mo minimum) — see `main.tf`'s `use_nat_instance` variable.

Everything else in this stack (VPC, subnets, security groups, RDS, S3,
CloudFront, Lambda, the ASG itself at 1-2 instances) fits comfortably inside
the standard 12-month Free Tier.

## Before you run it

Good news: after this update, **all four previously-manual items now have safe
automatic defaults** — `terraform init && terraform plan` works immediately
with zero editing. Nothing below is required; it's what to change *if* you
want to move past the defaults.

| Item | Default behavior now | Change it when... |
|---|---|---|
| `golden_ami_id` | `null` → auto-uses the latest Amazon Linux 2023 AMI (`data.aws_ami.amazon_linux` in `main.tf`) | You've baked your own Golden AMI with Apache/PHP pre-installed — set this to its real `ami-xxxxxxxx` |
| `backup_bucket_name` | `"retailedge-backups"` → an 8-char random hex suffix is appended automatically (`random_id.backup_bucket_suffix` in `data.tf`), so the bucket name is always globally unique | Never — it just works |
| `acm_certificate_arn` | `null` → the ALB listens on plain `HTTP:80` instead of `HTTPS:443` (see `aws_lb_listener.http` in `compute.tf`, and the matching port-80 rule in `alb_sg`) | You own a real domain and have a validated ACM certificate — set this and the stack automatically switches to `HTTPS:443` |
| `key_name` | `null` → no SSH key pair attached; use **SSM Session Manager** instead (already wired up via the IAM role in `compute.tf` — no open port 22, no key to lose) | You specifically want traditional SSH — create a Key Pair in EC2 console first, then set this to its name |

- `deploy.yml`'s `ACCOUNT_ID` placeholder still needs your real AWS account ID
  for the GitHub Actions OIDC role ARN once you wire up the CI/CD pipeline.
- Per the assignment's own grading rules: **`terraform plan` output is
  sufficient for grading — you do not need to `apply`.** If you do want to
  apply it for a live demo, set `environment = "demo"` (drops the ASG to a
  single instance) and run `terraform destroy` as soon as you're done to
  avoid any charges accumulating past the demo window.

```bash
cd terraform
terraform init
terraform plan
```
