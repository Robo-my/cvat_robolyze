# Daily on/off schedule for a single-instance CVAT deployment on EC2.
#
# Creates:
#   - two EventBridge Scheduler schedules (start / stop) in a local time zone
#   - an IAM role that can only start/stop this one instance
#   - an SQS dead-letter queue + alarm for failed start/stop calls
#   - an SNS topic (email) for alerts and daily "running"/"stopped" notices
#   - a CloudWatch alarm on instance status checks
#   - a DLM policy that snapshots the instance's EBS volumes daily while it is off
#
# Usage:
#   cd deploy/aws
#   terraform init
#   terraform apply -var 'instance_id=i-xxxxxxxx' -var 'alert_email=you@example.com'

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40"
    }
  }
}

variable "region" {
  type    = string
  default = "ap-southeast-5"
}

variable "instance_id" {
  type        = string
  description = "ID of the EC2 instance running CVAT."
}

variable "alert_email" {
  type        = string
  description = "Email address for alerts (the subscription must be confirmed from the inbox)."
}

variable "timezone" {
  type    = string
  default = "Asia/Kolkata"
}

variable "start_cron" {
  type        = string
  description = "When to start the instance, in var.timezone. 06:20 so CVAT is ready by 06:30."
  default     = "cron(20 6 * * ? *)"
}

variable "stop_cron" {
  type        = string
  description = "When to stop the instance, in var.timezone."
  default     = "cron(0 21 * * ? *)"
}

variable "snapshot_time_utc" {
  type        = string
  description = "Daily EBS snapshot time in UTC (DLM only accepts UTC). 15:45 UTC = 21:15 IST, after the stop."
  default     = "15:45"
}

variable "snapshot_retain_count" {
  type    = number
  default = 7
}

variable "notify_state_changes" {
  type        = bool
  description = "Email on every running/stopped transition. A missing morning email means the start failed."
  default     = true
}

variable "name_prefix" {
  type    = string
  default = "cvat"
}

provider "aws" {
  region = var.region
}

data "aws_instance" "cvat" {
  instance_id = var.instance_id
}

# --- Alerts -----------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid       = "AllowEventBridgeAndCloudWatch"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

# --- Scheduler --------------------------------------------------------------

resource "aws_sqs_queue" "scheduler_dlq" {
  name                      = "${var.name_prefix}-scheduler-dlq"
  message_retention_seconds = 1209600
}

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["ec2:StartInstances", "ec2:StopInstances"]
    resources = [data.aws_instance.cvat.arn]
  }

  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.scheduler_dlq.arn]
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name_prefix}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "start-stop-cvat-instance"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

locals {
  schedules = {
    start = {
      expression = var.start_cron
      target_arn = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    }
    stop = {
      expression = var.stop_cron
      target_arn = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    }
  }
}

resource "aws_scheduler_schedule" "cvat" {
  for_each = local.schedules

  name                         = "${var.name_prefix}-${each.key}"
  schedule_expression          = each.value.expression
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = each.value.target_arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ InstanceIds = [var.instance_id] })

    # Retries cover transient errors such as InsufficientInstanceCapacity on start.
    retry_policy {
      maximum_event_age_in_seconds = 1800
      maximum_retry_attempts       = 10
    }

    dead_letter_config {
      arn = aws_sqs_queue.scheduler_dlq.arn
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "scheduler_failures" {
  alarm_name          = "${var.name_prefix}-scheduler-failed"
  alarm_description   = "A scheduled start/stop of the CVAT instance failed after all retries. Check the ${aws_sqs_queue.scheduler_dlq.name} queue."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.scheduler_dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

# The instance is stopped every night, so missing data must not alarm.
resource "aws_cloudwatch_metric_alarm" "status_check" {
  alarm_name          = "${var.name_prefix}-status-check-failed"
  alarm_description   = "CVAT instance is running but failing EC2 status checks."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = var.instance_id }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_event_rule" "state_change" {
  count       = var.notify_state_changes ? 1 : 0
  name        = "${var.name_prefix}-state-change"
  description = "CVAT instance became running or stopped."
  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
    detail = {
      "instance-id" = [var.instance_id]
      state         = ["running", "stopped"]
    }
  })
}

resource "aws_cloudwatch_event_target" "state_change" {
  count = var.notify_state_changes ? 1 : 0
  rule  = aws_cloudwatch_event_rule.state_change[0].name
  arn   = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      state = "$.detail.state"
      time  = "$.time"
    }
    input_template = "\"CVAT instance ${var.instance_id} is now <state> (at <time> UTC).\""
  }
}

# --- Daily EBS snapshots ----------------------------------------------------

resource "aws_ec2_tag" "backup" {
  resource_id = var.instance_id
  key         = "${var.name_prefix}-backup"
  value       = "daily"
}

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.name_prefix}-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "snapshots" {
  description        = "Daily snapshots of the CVAT instance volumes"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["INSTANCE"]
    target_tags    = { (aws_ec2_tag.backup.key) = aws_ec2_tag.backup.value }

    schedule {
      name      = "daily"
      copy_tags = true

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = [var.snapshot_time_utc]
      }

      retain_rule {
        count = var.snapshot_retain_count
      }
    }
  }
}

output "schedules" {
  value = { for k, s in aws_scheduler_schedule.cvat : k => "${s.schedule_expression} (${s.schedule_expression_timezone})" }
}

output "alerts_topic_arn" {
  value = aws_sns_topic.alerts.arn
}
