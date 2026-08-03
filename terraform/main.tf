terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ---------------------------------------------------------------------------
# Task 2.1 - VPC + 3 subnet tiers across 2 AZs
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr # 10.0.0.0/16
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

# Public subnets -- 10.0.1.0/24 (AZ-a) | 10.0.2.0/24 (AZ-b)
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.project_name}-public-${count.index == 0 ? "a" : "b"}"
    Tier = "web"
  }
}

# Private (application) subnets -- 10.0.11.0/24 (AZ-a) | 10.0.12.0/24 (AZ-b)
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags = {
    Name = "${var.project_name}-private-${count.index == 0 ? "a" : "b"}"
    Tier = "application"
  }
}

# Database (isolated) subnets -- 10.0.21.0/24 (AZ-a) | 10.0.22.0/24 (AZ-b)
resource "aws_subnet" "database" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.database_subnet_cidrs[count.index]
  availability_zone = var.azs[count.index]
  tags = {
    Name = "${var.project_name}-database-${count.index == 0 ? "a" : "b"}"
    Tier = "data"
  }
}

# ---------------------------------------------------------------------------
# Public route table -> Internet Gateway
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# Outbound path for the private (app) tier.
#
# FREE-TIER ADAPTATION: a managed NAT Gateway is NEVER covered by the Free
# Tier (~$32-45/month + per-GB processing, billed from minute one, whether
# idle or not). Instead we default to a single self-managed NAT *instance*
# (t3.micro), which draws from the same 750 Free-Tier EC2 hours as the app
# fleet. It's a single point of failure - acceptable for a training project,
# not for production. Set use_nat_instance = false to switch to a real NAT
# Gateway if this ever goes to production.
# ---------------------------------------------------------------------------
resource "aws_security_group" "nat_instance_sg" {
  count       = var.use_nat_instance ? 1 : 0
  name        = "${var.project_name}-nat-instance-sg"
  description = "Allow the private subnets to route outbound traffic through the NAT instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "All traffic from inside the VPC only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-nat-instance-sg" }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "nat" {
  count                       = var.use_nat_instance ? 1 : 0
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = "t3.micro" # stays inside Free Tier hours
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.nat_instance_sg[0].id]
  source_dest_check           = false # required for a host that forwards traffic
  associate_public_ip_address = true

  user_data = <<-EOF
    #!/bin/bash
    sysctl -w net.ipv4.ip_forward=1
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
  EOF

  tags = { Name = "${var.project_name}-nat-instance" }
}

resource "aws_eip" "nat" {
  count    = var.use_nat_instance ? 1 : 0
  domain   = "vpc"
  instance = aws_instance.nat[0].id
  tags     = { Name = "${var.project_name}-nat-eip" }
}

# Managed NAT Gateway fallback (only created if use_nat_instance = false)
resource "aws_eip" "ngw" {
  count  = var.use_nat_instance ? 0 : 1
  domain = "vpc"
}

resource "aws_nat_gateway" "ngw" {
  count         = var.use_nat_instance ? 0 : 1
  allocation_id = aws_eip.ngw[0].id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project_name}-nat-gateway" }
}

# Private route table -> NAT instance OR NAT Gateway (never the IGW directly)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.use_nat_instance ? [1] : []
    content {
      cidr_block           = "0.0.0.0/0"
      network_interface_id = aws_instance.nat[0].primary_network_interface_id
    }
  }

  dynamic "route" {
    for_each = var.use_nat_instance ? [] : [1]
    content {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = aws_nat_gateway.ngw[0].id
    }
  }

  tags = { Name = "${var.project_name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ---------------------------------------------------------------------------
# Database route table: intentionally has ZERO routes to the Internet
# Gateway, the NAT instance, or the NAT Gateway. See notes.md Task 2.3 for
# the written justification. Free VPC Gateway Endpoints let this subnet
# still reach S3 (e.g. for RDS backups) with no NAT/internet path at all.
# ---------------------------------------------------------------------------
resource "aws_route_table" "database" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-database-rt" }
}

resource "aws_route_table_association" "database" {
  count          = 2
  subnet_id      = aws_subnet.database[count.index].id
  route_table_id = aws_route_table.database.id
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.database[*].id
  tags       = { Name = "${var.project_name}-db-subnet-group" }
}

resource "aws_elasticache_subnet_group" "main" {
  count      = var.enable_redis ? 1 : 0
  name       = "${var.project_name}-redis-subnet-group"
  subnet_ids = aws_subnet.database[*].id
}

# Free VPC Gateway Endpoint for S3 - no hourly charge, no data processing fee.
# Lets the database and private subnets reach S3 (backups, RDS snapshot
# export) without a NAT Gateway/instance at all.
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${var.aws_region}.s3"
  route_table_ids = [
    aws_route_table.private.id,
    aws_route_table.database.id,
  ]
  tags = { Name = "${var.project_name}-s3-endpoint" }
}
