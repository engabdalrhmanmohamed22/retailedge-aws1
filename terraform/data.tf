# ---------------------------------------------------------------------------
# Task 4.1 - RDS MySQL
#
# FREE-TIER ADAPTATION per explicit request: multi_az = false (Single-AZ).
# RDS Multi-AZ is never Free-Tier eligible - it silently runs (and bills) a
# second synchronous-standby instance. Single-AZ db.t3.micro + 20GB storage
# fits the 750 hrs/month + 20GB Free Tier allowance. storage_encrypted and
# 7-day automated backups are both still enabled - those cost nothing extra
# and there is no reason to drop them just because we're on Single-AZ.
# ---------------------------------------------------------------------------
resource "random_password" "db_password" {
  length  = 20
  special = false
}

resource "aws_secretsmanager_secret" "db_password" {
  name = "${var.project_name}-db-password"
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db_password.result
}

resource "aws_db_instance" "main" {
  identifier             = "${var.project_name}-mysql"
  engine                 = "mysql"
  engine_version         = var.db_engine_version
  instance_class         = var.db_instance_class          # db.t3.micro - Free Tier eligible
  allocated_storage      = var.db_allocated_storage        # 20 GB - Free Tier cap
  storage_type           = "gp3"
  storage_encrypted      = true
  multi_az               = var.db_multi_az                 # false - Single-AZ per request
  db_name                = var.db_name
  username               = var.db_username
  password               = random_password.db_password.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  backup_retention_period = var.db_backup_retention_days # 7
  backup_window           = "03:00-04:00"                # low-traffic UTC window
  maintenance_window      = "sun:04:30-sun:05:30"
  deletion_protection     = true
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.project_name}-final-snapshot"

  tags = { Name = "${var.project_name}-rds" }
}

# ---------------------------------------------------------------------------
# S3-based backup pipeline (as requested: "نعمل backup على s3")
#
# RDS's native 7-day automated backups already protect against point-in-time
# recovery inside the RDS service itself, at no extra cost (covered by the
# Free Tier's 20GB backup storage allowance as long as it stays <= your
# allocated storage). To also land a portable copy in S3 - useful for
# long-term retention past 7 days, or recovery even if the RDS instance
# itself is deleted - a small scheduled Lambda runs `mysqldump` against the
# instance and uploads the compressed dump to this bucket. S3 storage for a
# small logical dump comfortably fits inside the 5GB Free Tier allowance.
# ---------------------------------------------------------------------------
resource "random_id" "backup_bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "backups" {
  bucket = "${var.backup_bucket_name}-${random_id.backup_bucket_suffix.hex}"
  tags   = { Name = "${var.project_name}-backups" }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Keep the bucket itself small (and free): expire dumps after 30 days,
# push anything older to Infrequent Access first.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    id     = "expire-old-dumps"
    status = "Enabled"
    filter { prefix = "db-dumps/" }
    transition {
      days          = 7
      storage_class = "STANDARD_IA"
    }
    expiration {
      days = 30
    }
  }
}

resource "aws_iam_role" "backup_lambda_role" {
  name = "${var.project_name}-backup-lambda-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "backup_lambda_policy" {
  name = "${var.project_name}-backup-lambda-policy"
  role = aws_iam_role.backup_lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.backups.arn}/db-dumps/*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.db_password.arn
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents",
          "ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
    ]
  })
}

# Lambda deployment package is built and referenced from the CI/CD pipeline
# (see .github/workflows/deploy.yml) - this Terraform module expects a
# pre-built zip at ../lambda/db_backup.zip.
resource "aws_lambda_function" "db_backup" {
  function_name = "${var.project_name}-db-backup"
  role          = aws_iam_role.backup_lambda_role.arn
  runtime       = "python3.12"
  handler       = "db_backup.handler"
  filename      = "${path.module}/../lambda/db_backup.zip"
  timeout       = 60

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.app_sg.id]
  }

  environment {
    variables = {
      DB_HOST     = aws_db_instance.main.address
      DB_NAME     = var.db_name
      DB_USER     = var.db_username
      SECRET_ARN  = aws_secretsmanager_secret.db_password.arn
      BUCKET_NAME = aws_s3_bucket.backups.bucket
    }
  }
}

resource "aws_cloudwatch_event_rule" "nightly_backup" {
  name                = "${var.project_name}-nightly-backup"
  schedule_expression = "cron(0 3 * * ? *)" # 03:00 UTC daily
}

resource "aws_cloudwatch_event_target" "nightly_backup" {
  rule      = aws_cloudwatch_event_rule.nightly_backup.name
  arn       = aws_lambda_function.db_backup.arn
  target_id = "db-backup-lambda"
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.db_backup.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.nightly_backup.arn
}

# ---------------------------------------------------------------------------
# Task 4.1 (cont.) - ElastiCache Redis
#
# COST NOTE: unlike everything else in this stack, Redis has NO Free Tier
# allowance at any node size - a single cache.t3.micro node runs roughly
# $11-13/month from the moment it's created. redis_num_nodes defaults to 1
# (not the 2-node cluster in the original diagram) to minimize this one
# unavoidable cost. Set enable_redis = false to remove it completely if you
# want a strictly $0 stack (the app can fall back to querying RDS directly).
# ---------------------------------------------------------------------------
resource "aws_elasticache_replication_group" "main" {
  count                      = var.enable_redis ? 1 : 0
  replication_group_id       = "${var.project_name}-redis"
  description                = "Session cache + query cache for the app tier"
  node_type                  = var.redis_node_type
  num_cache_clusters         = var.redis_num_nodes
  engine                     = "redis"
  engine_version             = "7.1"
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.main[0].name
  security_group_ids         = [aws_security_group.redis_sg[0].id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  automatic_failover_enabled = var.redis_num_nodes > 1

  tags = { Name = "${var.project_name}-redis" }
}
