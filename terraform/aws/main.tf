# Terraform = "infrastructure as code". Instead of clicking around the AWS console,
# you describe what you want here and run `terraform apply`. `terraform destroy`
# deletes all of it again, so you only pay while you're practising.
#
# What gets created:
#   1. A small Linux server (EC2) that runs the site with Docker Compose
#   2. A firewall (security group): website open to everyone, Grafana/Prometheus only to you
#   3. A permission role so the server can write logs and you can log in without SSH keys
#   4. A CloudWatch log group where every request and error is stored
#   5. Alarms that email you when the site errors or the server fails
#   6. A monthly budget that emails you before AWS spending gets out of hand

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
  region = var.region
  default_tags {
    tags = {
      Project = "sre-quotes"
    }
  }
}

# ---------------------------------------------------------------------------
# Lookups (things that already exist in your account)
# ---------------------------------------------------------------------------

# Latest Amazon Linux 2023 image, published by AWS
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Every AWS account has a "default VPC" (network) in each region
data "aws_vpc" "default" {
  default = true
}

resource "random_password" "grafana" {
  length  = 20
  special = false
}

# ---------------------------------------------------------------------------
# 1. Logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = "/sre-quotes/app"
  retention_in_days = 7 # keep a week of logs; older logs are deleted (saves money)
}

# ---------------------------------------------------------------------------
# 2. Firewall
# ---------------------------------------------------------------------------
resource "aws_security_group" "web" {
  name_prefix = "sre-quotes-"
  description = "Quotes site: web open to all, monitoring only to the owner"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "Website (HTTP) for everyone"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Grafana - only your IP"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "Prometheus - only your IP"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    description = "Server may reach the internet (downloads, AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# 3. Permissions for the server
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ec2" {
  name_prefix = "sre-quotes-ec2-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Lets you open a terminal on the server from the AWS console (Session Manager) — no SSH keys or open port 22
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets Docker send container logs to our log group (and nothing else — least privilege)
resource "aws_iam_role_policy" "logs" {
  name = "write-app-logs"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = ["${aws_cloudwatch_log_group.app.arn}:*"]
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name_prefix = "sre-quotes-"
  role        = aws_iam_role.ec2.name
}

# ---------------------------------------------------------------------------
# 4. The server
# ---------------------------------------------------------------------------
resource "aws_instance" "web" {
  ami                         = nonsensitive(data.aws_ssm_parameter.al2023.value)
  instance_type               = var.instance_type
  iam_instance_profile        = aws_iam_instance_profile.ec2.name
  vpc_security_group_ids      = [aws_security_group.web.id]
  associate_public_ip_address = true

  # Script that runs once on first boot: installs Docker, downloads your repo, starts the site
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    repo_url         = var.repo_url
    branch           = var.branch
    region           = var.region
    log_group        = aws_cloudwatch_log_group.app.name
    grafana_password = random_password.grafana.result
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required" # IMDSv2 — a security best practice
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "sre-quotes-web"
  }
}

# ---------------------------------------------------------------------------
# 5. Alerts (email)
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "sre-quotes-alerts"
}

# AWS emails you a confirmation link — you MUST click it to receive alerts
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Turns log lines with "status" >= 500 into a number CloudWatch can alarm on
resource "aws_cloudwatch_log_metric_filter" "errors_5xx" {
  name           = "quotes-http-5xx"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.status >= 500 }"

  metric_transformation {
    name          = "Http5xxCount"
    namespace     = "SREQuotes"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "errors_5xx" {
  alarm_name          = "sre-quotes-high-5xx"
  alarm_description   = "5 or more server errors in 1 minute. Runbook: docs/runbooks/high-error-rate.md"
  namespace           = "SREQuotes"
  metric_name         = "Http5xxCount"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "server_unhealthy" {
  alarm_name          = "sre-quotes-server-status-check"
  alarm_description   = "The EC2 server is failing AWS health checks"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = aws_instance.web.id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# ---------------------------------------------------------------------------
# 6. Money guard — emails you if the WHOLE account's spend (excluding credits) grows
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "sre-quotes-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_types {
    include_credit = false # credits would otherwise hide real spending
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
