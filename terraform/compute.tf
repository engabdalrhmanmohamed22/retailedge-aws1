# ---------------------------------------------------------------------------
# Task 3.1 - Launch Template + Auto Scaling Group
#
# FREE-TIER ADAPTATION: instance_type defaults to m7i-flex.large (var.instance_type).
# CORRECTED: on accounts created on/after July 15, 2025, m7i-flex.large IS marked
# "Free tier eligible" in the console - it just draws down the $100-$200 credit
# balance (6-month Free Plan) faster than t3.micro would (~20 days vs ~200+ days
# at asg_min_size=2). Fine for this project's ~1 week runtime; see variables.tf
# for the full breakdown and the fallback to t3.micro if run for longer.
#
# asg_min_size/asg_max_size stay at 2/10 to match the Task 1.1 spec exactly
# for grading. If you want to actually apply this (not just `terraform plan`)
# without burning through the 750-hour budget, set environment = "demo",
# which drops min/desired to 1 via the locals block below.
# ---------------------------------------------------------------------------
locals {
  effective_min     = var.environment == "demo" ? var.demo_min_size : var.asg_min_size
  effective_desired = var.environment == "demo" ? var.demo_min_size : var.asg_desired_capacity
}

resource "aws_launch_template" "app_lt" {
  name_prefix   = "${var.project_name}-lt-"
  image_id      = coalesce(var.golden_ami_id, data.aws_ami.amazon_linux.id)
  instance_type = var.instance_type
  key_name      = var.key_name # null = no key pair; use SSM Session Manager instead (IAM role below)

  # ---------------------------------------------------------------------
  # Minimal user_data so the instance actually answers the ALB target
  # group's health check (port 8080, path /health) instead of booting a
  # bare AMI with nothing listening - without this, ELB health checks
  # never pass and instance_refresh in the CI/CD pipeline hangs forever
  # waiting for MinHealthyPercentage. This is placeholder content, not
  # the real PHP app - swap for a proper deploy mechanism (Golden AMI or
  # container pull) before production use.
  # ---------------------------------------------------------------------
  user_data = base64encode(<<-EOF
    #!/bin/bash
    dnf install -y httpd || yum install -y httpd
    sed -i 's/Listen 80/Listen 8080/' /etc/httpd/conf/httpd.conf
    echo "OK" > /var/www/html/health
    echo "<h1>RetailEdge - placeholder page</h1>" > /var/www/html/index.html
    systemctl enable httpd
    systemctl restart httpd
    EOF
  )

  vpc_security_group_ids = [aws_security_group.app_sg.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.app_profile.name
  }

  metadata_options {
    http_tokens   = "required" # IMDSv2 only
    http_endpoint = "enabled"
  }

  monitoring {
    enabled = true
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-app"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role" "app_role" {
  name = "${var.project_name}-app-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app_profile" {
  name = "${var.project_name}-app-profile"
  role = aws_iam_role.app_role.name
}

resource "aws_autoscaling_group" "app_asg" {
  name                = "${var.project_name}-asg"
  vpc_zone_identifier = aws_subnet.private[*].id
  target_group_arns   = [aws_lb_target_group.app_tg.arn]

  min_size         = local.effective_min
  max_size         = var.asg_max_size
  desired_capacity = local.effective_desired

  health_check_type         = "ELB"
  health_check_grace_period = 90

  launch_template {
    id      = aws_launch_template.app_lt.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 90
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project_name}-app"
    propagate_at_launch = true
  }
}

# ---------------------------------------------------------------------------
# Task 3.2 - Target Tracking scaling policy, target 60% average CPU
# ---------------------------------------------------------------------------
resource "aws_autoscaling_policy" "cpu_target_tracking" {
  name                   = "${var.project_name}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.asg_target_cpu # 60
  }
}

# ---------------------------------------------------------------------------
# Task 3.4 (Bonus) - Scheduled Scaling: bump to 6 every Friday 8PM UTC
# ahead of the weekend traffic ramp.
# ---------------------------------------------------------------------------
resource "aws_autoscaling_schedule" "friday_ramp" {
  scheduled_action_name  = "${var.project_name}-friday-8pm-ramp"
  autoscaling_group_name = aws_autoscaling_group.app_asg.name
  recurrence             = "0 20 * * FRI" # 20:00 UTC every Friday
  min_size               = var.asg_min_size
  max_size               = var.asg_max_size
  desired_capacity       = 6
}

# ---------------------------------------------------------------------------
# Application Load Balancer
# NOTE ON COST: 750 ALB hours + 15 LCUs/month are Free-Tier-eligible for the
# first 12 months on eligible (legacy) accounts, shared with any Classic/NLB
# in the account. Newer credit-based accounts may not carry this allowance -
# check Billing > Free Tier in your own console before leaving this running.
# ---------------------------------------------------------------------------
resource "aws_lb" "app_alb" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "app_tg" {
  name     = "${var.project_name}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
  }
}

# HTTPS:443 listener - only created once you set a real acm_certificate_arn.
resource "aws_lb_listener" "https" {
  count             = var.acm_certificate_arn != null ? 1 : 0
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# HTTP:80 fallback - active by default (acm_certificate_arn = null) so the
# stack runs and can be smoke-tested immediately via the ALB's own DNS name,
# with no domain/cert required. Once acm_certificate_arn is set, switch the
# ALB security group (alb_sg) to only allow 443 and drop this listener for
# a production launch.
resource "aws_lb_listener" "http" {
  count             = var.acm_certificate_arn == null ? 1 : 0
  load_balancer_arn = aws_lb.app_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}
