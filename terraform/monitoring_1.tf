# ---------------------------------------------------------------------------
# Task 5.2 - CloudWatch Alarms
#
# This turns the alarms table in go_live_checklist.md into real
# infrastructure. All four alarms publish to a single SNS topic
# (retailedge-alerts), fanned out to whatever subscriptions you add below -
# matching the doc's own design ("severity controlled at the subscription
# level, not a different alarm per channel").
#
# NOTE ON SCOPE: the checklist table also mentions a "diagnostic Lambda" for
# the latency alarm and an "auto-rollback" action for the error-rate alarm.
# The rollback mechanism is already implemented (see .github/workflows/
# deploy.yml's "Rollback on failure" step, triggered by GitHub Actions, not
# by this alarm directly). A separate diagnostic-snapshot Lambda is not
# built here - it would be a 5th Lambda function beyond what any task in the
# README asks for. If you want it, say so and it's a quick add.
# ---------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
}

# Add real subscriptions here once you have a Slack webhook / PagerDuty
# integration / on-call email - e.g.:
#
# resource "aws_sns_topic_subscription" "email" {
#   topic_arn = aws_sns_topic.alerts.arn
#   protocol  = "email"
#   endpoint  = "your-team@example.com"
# }
#
# Left empty by default so `terraform apply` doesn't require you to own a
# real Slack/PagerDuty integration just to stand the stack up.

# ============================================================================
# Alarm 1 - High Latency: ALB P95 latency > 800ms for 5 minutes
# ============================================================================
resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "${var.project_name}-high-latency"
  alarm_description   = "ALB P95 target response time > 800ms for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0.8 # seconds - TargetResponseTime is reported in seconds
  treat_missing_data  = "notBreaching"

  metric_name        = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 300 # 5 minutes
  extended_statistic  = "p95"

  dimensions = {
    LoadBalancer = aws_lb.app_alb.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ============================================================================
# Alarm 2 - High Error Rate: ALB 5xx rate > 1%
#
# There is no native "5xx rate" metric - it's computed as
# (5xx count / total request count) * 100 via a metric math expression.
# ============================================================================
resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${var.project_name}-high-error-rate"
  alarm_description   = "ALB 5xx error rate > 1% over 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1 # percent
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "(errors / IF(requests == 0, 1, requests)) * 100"
    label       = "5xx Error Rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      metric_name = "HTTPCode_ELB_5XX_Count"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.app_alb.arn_suffix
      }
    }
  }

  metric_query {
    id = "requests"
    metric {
      metric_name = "RequestCount"
      namespace   = "AWS/ApplicationELB"
      period      = 300
      stat        = "Sum"
      dimensions = {
        LoadBalancer = aws_lb.app_alb.arn_suffix
      }
    }
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ============================================================================
# Alarm 3 - DB CPU Spike: RDS CPUUtilization > 80%
# Manual-response alarm on Single-AZ - no automated remediation target,
# just the SNS publish (see notes.md / migration_plan.md for why).
# ============================================================================
resource "aws_cloudwatch_metric_alarm" "db_cpu_spike" {
  alarm_name          = "${var.project_name}-db-cpu-spike"
  alarm_description   = "RDS CPUUtilization > 80% - manual response on Single-AZ"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 80
  treat_missing_data  = "notBreaching"

  metric_name = "CPUUtilization"
  namespace   = "AWS/RDS"
  period      = 300
  statistic   = "Average"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.main.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ============================================================================
# Alarm 4 - Low Cache Hit Rate: ElastiCache hit rate < 70% (warning only)
#
# Same math-expression pattern as the error-rate alarm: CloudWatch doesn't
# publish a ready-made "hit rate" metric for Redis, only CacheHits and
# CacheMisses per node - hit rate = hits / (hits + misses) * 100.
# ============================================================================
resource "aws_cloudwatch_metric_alarm" "low_cache_hit_rate" {
  count               = var.enable_redis ? 1 : 0
  alarm_name          = "${var.project_name}-low-cache-hit-rate"
  alarm_description   = "ElastiCache hit rate < 70% - warning severity, review TTL/key strategy"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = 70 # percent
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "hit_rate"
    expression  = "(hits / IF((hits + misses) == 0, 1, (hits + misses))) * 100"
    label       = "Cache Hit Rate (%)"
    return_data = true
  }

  metric_query {
    id = "hits"
    metric {
      metric_name = "CacheHits"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions = {
        CacheClusterId = tolist(aws_elasticache_replication_group.main[0].member_clusters)[0]
      }
    }
  }

  metric_query {
    id = "misses"
    metric {
      metric_name = "CacheMisses"
      namespace   = "AWS/ElastiCache"
      period      = 300
      stat        = "Sum"
      dimensions = {
        CacheClusterId = tolist(aws_elasticache_replication_group.main[0].member_clusters)[0]
      }
    }
  }

  # This alarm is "warning severity, not paging" per go_live_checklist.md -
  # still routes to the same SNS topic; you'd filter severity at the
  # subscription/Slack-vs-PagerDuty level, not by skipping alarm_actions here.
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
