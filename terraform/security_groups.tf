# ---------------------------------------------------------------------------
# Task 2.2 - Least-privilege Security Groups
#
# FIX (terraform plan was failing with "Cycle: aws_security_group.alb_sg,
# aws_security_group.rds_sg, aws_security_group.app_sg, aws_security_group.redis_sg"):
#
# The previous version put ingress/egress rules INSIDE each aws_security_group
# block, and those inline rules pointed at each other's .id (alb_sg's egress
# pointed at app_sg.id, app_sg's ingress pointed at alb_sg.id, etc). That
# makes every SG resource depend on the next one, all the way around the
# chain -> a dependency cycle, which Terraform correctly refuses to build a
# graph for.
#
# THE FIX: split each Security Group into (1) a bare aws_security_group with
# NO inline rules, and (2) separate aws_vpc_security_group_ingress_rule /
# aws_vpc_security_group_egress_rule resources. Now the 4 SGs have zero
# dependencies on each other - only the individual *rule* resources depend
# on two SGs each, which is fine (rules aren't part of the SG resource
# itself, so there's no cycle). This is also the AWS provider's own current
# best-practice recommendation over inline ingress/egress blocks: rules can
# be added/removed independently without forcing a diff on the whole SG.
# ---------------------------------------------------------------------------

# ============================================================================
# Security Groups (no inline rules - see note above)
# ============================================================================

resource "aws_security_group" "alb_sg" {
  name        = "${var.project_name}-alb-sg"
  description = "Public-facing ALB: HTTPS from the internet (plus HTTP:80 fallback while acm_certificate_arn is unset)"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-alb-sg" }
}

resource "aws_security_group" "app_sg" {
  name        = "${var.project_name}-app-sg"
  description = "Application tier: 8080 from the ALB only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-app-sg" }
}

resource "aws_security_group" "rds_sg" {
  name        = "${var.project_name}-rds-sg"
  description = "RDS MySQL: 3306 from the application tier only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-rds-sg" }
}

resource "aws_security_group" "redis_sg" {
  count       = var.enable_redis ? 1 : 0
  name        = "${var.project_name}-redis-sg"
  description = "ElastiCache Redis: 6379 from the application tier only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${var.project_name}-redis-sg" }
}

# ============================================================================
# alb_sg rules - HTTPS (443) inbound from the internet only (Task 2.2 spec)
# ============================================================================

resource "aws_vpc_security_group_ingress_rule" "alb_https_in" {
  security_group_id = aws_security_group.alb_sg.id
  description        = "HTTPS from anywhere"
  from_port          = 443
  to_port            = 443
  ip_protocol        = "tcp"
  cidr_ipv4          = "0.0.0.0/0"
}

# Task 2.2 spec is HTTPS-only. This HTTP:80 rule exists only because there's
# no ACM cert yet (acm_certificate_arn = null -> compute.tf serves plain
# HTTP so the stack is testable with zero domain/cert setup). Once a real
# cert is set, this rule stops being created (count = 0) - drop it manually
# too if you want to hard-enforce HTTPS-only at that point.
resource "aws_vpc_security_group_ingress_rule" "alb_http_fallback_in" {
  count              = var.acm_certificate_arn == null ? 1 : 0
  security_group_id = aws_security_group.alb_sg.id
  description        = "HTTP fallback - no ACM cert configured yet"
  from_port          = 80
  to_port            = 80
  ip_protocol        = "tcp"
  cidr_ipv4          = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id           = aws_security_group.alb_sg.id
  description                 = "Forward to the app tier only"
  from_port                   = 8080
  to_port                     = 8080
  ip_protocol                 = "tcp"
  referenced_security_group_id = aws_security_group.app_sg.id
}

# ============================================================================
# app_sg rules - 8080 from alb_sg only, never directly from the internet
# ============================================================================

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id           = aws_security_group.app_sg.id
  description                 = "App traffic from ALB only"
  from_port                   = 8080
  to_port                     = 8080
  ip_protocol                 = "tcp"
  referenced_security_group_id = aws_security_group.alb_sg.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_rds" {
  security_group_id           = aws_security_group.app_sg.id
  description                 = "MySQL to RDS"
  from_port                   = 3306
  to_port                     = 3306
  ip_protocol                 = "tcp"
  referenced_security_group_id = aws_security_group.rds_sg.id
}

resource "aws_vpc_security_group_egress_rule" "app_to_redis" {
  count                        = var.enable_redis ? 1 : 0
  security_group_id           = aws_security_group.app_sg.id
  description                 = "Redis to ElastiCache"
  from_port                   = 6379
  to_port                     = 6379
  ip_protocol                 = "tcp"
  referenced_security_group_id = aws_security_group.redis_sg[0].id
}

resource "aws_vpc_security_group_egress_rule" "app_https_out" {
  security_group_id = aws_security_group.app_sg.id
  description        = "HTTPS out via NAT (OS/package updates, ECR pulls, S3 endpoint)"
  from_port          = 443
  to_port            = 443
  ip_protocol        = "tcp"
  cidr_ipv4          = "0.0.0.0/0"
}

# ============================================================================
# rds_sg rules - 3306 from app_sg only
# ============================================================================

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id           = aws_security_group.rds_sg.id
  description                 = "MySQL from app tier only"
  from_port                   = 3306
  to_port                     = 3306
  ip_protocol                 = "tcp"
  referenced_security_group_id = aws_security_group.app_sg.id
}

# No egress rule needed to the internet; RDS reaches S3 for
# snapshot/backup traffic via the free VPC Gateway Endpoint (main.tf).
resource "aws_vpc_security_group_egress_rule" "rds_vpc_return" {
  security_group_id = aws_security_group.rds_sg.id
  description        = "Allow return traffic within the VPC (S3 gateway endpoint)"
  ip_protocol        = "-1"
  cidr_ipv4          = var.vpc_cidr
}

# ============================================================================
# redis_sg rules - 6379 from app_sg only
# ============================================================================

resource "aws_vpc_security_group_ingress_rule" "redis_from_app" {
  count                        = var.enable_redis ? 1 : 0
  security_group_id           = aws_security_group.redis_sg[0].id
  description                 = "Redis from app tier only"
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.app_sg.id
}
