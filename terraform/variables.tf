variable "project_name" {
  description = "Prefix used on every resource name/tag"
  type        = string
  default     = "retailedge"
}

variable "environment" {
  description = "Deployment environment (production | demo). 'demo' is used for low-cost hands-on testing."
  type        = string
  default     = "production"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

# ---------------------------------------------------------------------------
# NETWORKING (Layer 2)
# ---------------------------------------------------------------------------
variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  description = "Two Availability Zones for the Multi-AZ layout"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Application tier subnets (no direct route to the Internet Gateway)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "database_subnet_cidrs" {
  description = "Isolated data tier subnets (no route to the Internet Gateway at all)"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

variable "use_nat_instance" {
  description = <<-EOT
    true  = use a single self-managed t3.micro NAT instance (cheap, Free-Tier-eligible EC2 hours, single point of failure)
    false = use a managed NAT Gateway (highly available, but NEVER covered by Free Tier: ~$32-45/mo + data fees even idle)
    Default is true to respect the Free Tier constraint on this project.
  EOT
  type    = bool
  default = true
}

# ---------------------------------------------------------------------------
# COMPUTE (Layer 3)
# ---------------------------------------------------------------------------
variable "golden_ami_id" {
  description = <<-EOT
    AMI ID baked with Apache/PHP (Golden AMI). Leave as null to auto-use the latest
    Amazon Linux 2023 base AMI (via data.aws_ami.amazon_linux in main.tf) so `terraform
    plan`/`apply` works immediately with zero manual editing. Once you bake your own
    Golden AMI, set this to its real ami-xxxxxxxx ID to use it instead.
  EOT
  type    = string
  default = null
}

variable "instance_type" {
  description = <<-EOT
    EC2 instance type for the application tier.

    CORRECTED NOTE: Free Tier eligibility depends on when the AWS account was created
    (AWS changed the program on July 15, 2025):
      - Accounts created BEFORE July 15, 2025: only t2.micro/t3.micro are Free Tier eligible,
        as ~750 shared hours/month for 12 months.
      - Accounts created ON/AFTER July 15, 2025: Free Tier eligible types expanded to
        t3.micro, t3.small, t4g.micro, t4g.small, c7i-flex.large, AND m7i-flex.large - but
        the model changed from "free hours" to a $100-$200 CREDIT balance that lasts up to
        6 months (whichever runs out first), not unlimited hours.

    m7i-flex.large (~$0.10175/hr Linux On-Demand) burns that credit roughly 10x faster than
    t3.micro (~$0.0104/hr): with asg_min_size=2, a $100 credit covers ~20 days of m7i-flex.large
    vs. ~200+ days of t3.micro. Set to m7i-flex.large here because the project will only run for
    about a week - well inside that ~20-day credit window. If you plan to keep this running
    longer, switch back to t3.micro to make the credit last the full 6-month Free Plan.
  EOT
  type    = string
  default = "m7i-flex.large"
}

variable "asg_min_size" {
  description = "Per Task 1.1 spec: min 2 for cross-AZ redundancy even outside peak hours."
  type        = number
  default     = 2
}

variable "asg_max_size" {
  type    = number
  default = 10
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "demo_min_size" {
  description = "Lower-cost footprint for var.environment == \"demo\": 1 instance, well inside the 750 Free Tier hours."
  type        = number
  default     = 1
}

variable "asg_target_cpu" {
  type    = number
  default = 60
}

# ---------------------------------------------------------------------------
# DATA TIER (Layer 4)
# ---------------------------------------------------------------------------
variable "db_engine_version" {
  type    = string
  default = "8.0"
}

variable "db_instance_class" {
  description = "Free Tier covers db.t3.micro / db.t4g.micro: 750 hrs/month, 20 GB storage, 20 GB backup storage (single instance only - no Multi-AZ)."
  type        = string
  default     = "db.t3.micro"
}

variable "db_multi_az" {
  description = "Per explicit request: Single-AZ to remain inside the Free Tier (RDS Multi-AZ is never Free-Tier eligible - it bills as two instances)."
  type        = bool
  default     = false
}

variable "db_allocated_storage" {
  description = "GB. Capped at 20 to stay inside the Free Tier storage allowance."
  type        = number
  default     = 20
}

variable "db_name" {
  type    = string
  default = "retailedge"
}

variable "db_username" {
  type      = string
  default   = "admin"
  sensitive = true
}

variable "db_backup_retention_days" {
  description = <<-EOT
    FREE-TIER ADAPTATION (updated): Legacy Free Tier accounts (created before
    July 15, 2025) allow up to 7 days of RDS automated-backup retention at no
    extra cost. Newer "Free Plan" accounts (created on/after July 15, 2025)
    enforce a stricter cap and reject 7 with:
      "FreeTierRestrictionError: The specified backup retention period
      exceeds the maximum available to free tier customers."
    Defaulted to 1 (the same value RDS itself uses as the default when a DB
    instance is created via the API/CLI with no retention period specified)
    to stay safely under that cap on either account type. The nightly Lambda
    -> S3 mysqldump (data.tf) is the real long-term backup path for this
    project anyway, so native RDS retention only needs to cover a same-day
    restore window here. Raise this back to 7 once running on a standard
    (non-Free-Plan) account or after upgrading past the Free Plan period.
  EOT
  type    = number
  default = 1
}

variable "enable_redis" {
  description = <<-EOT
    ElastiCache for Redis has NO AWS Free Tier allowance (verified: no free tier exists for
    Redis/Memcached on any instance size). A single cache.t3.micro node runs roughly $11-13/month.
    Defaulted to true to preserve the 3-tier architecture required by Task 1.1, but this is the
    one line item in this stack that is never $0. Set to false to omit it entirely.
  EOT
  type    = bool
  default = true
}

variable "redis_node_type" {
  type    = string
  default = "cache.t3.micro"
}

variable "redis_num_nodes" {
  description = "1 node by default (not 2) to minimize the one paid component. Set to 2 to match the original Layer-1 diagram's cluster failover design."
  type        = number
  default     = 1
}

variable "backup_bucket_name" {
  description = <<-EOT
    Base prefix for the S3 backup bucket. A random 8-character suffix is appended
    automatically in data.tf (aws_s3_bucket.backups) so the final bucket name is always
    globally unique with zero manual editing - no need to hand-pick a unique name.
  EOT
  type    = string
  default = "retailedge-backups"
}

variable "domain_name" {
  type    = string
  default = "retailedge.example.com"
}

variable "acm_certificate_arn" {
  description = <<-EOT
    ACM certificate ARN for the ALB HTTPS listener. Leave as null (the default) and the
    ALB will run on plain HTTP:80 instead of HTTPS:443 - fine for training/testing on
    the ALB's own DNS name, since you don't own a real domain to issue a cert for yet.
    Once you have a domain + validated ACM cert, set this and the HTTPS:443 listener
    (compute.tf) activates automatically instead.
  EOT
  type    = string
  default = null
}

variable "key_name" {
  description = <<-EOT
    Name of an existing EC2 Key Pair for SSH access to app instances (created separately
    in the AWS Console/CLI: EC2 > Key Pairs > Create key pair). Leave as null (the
    default) to launch with no key pair - SSM Session Manager (already wired up via
    aws_iam_role_policy_attachment.ssm in compute.tf) works for shell access with no
    key pair and no open port 22 needed at all. Only set this if you specifically want
    traditional SSH.
  EOT
  type    = string
  default = null
}
