# CloudWatch alarms + SNS notifications — the AWS-native equivalent of Grafana's
# alert notifications. Alarms watch the Container Insights cluster-level metrics
# (now that the cloudwatch-observability addon publishes them) and notify the SNS
# topic on ALARM and again on OK (recovery). The email subscription must be
# CONFIRMED by clicking the link AWS sends after the first apply.

resource "aws_sns_topic" "alerts" {
  name = "${var.cluster_name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Each entry becomes one CloudWatch alarm on a ContainerInsights metric scoped to
# the whole cluster (dimension ClusterName). period is 5 min (300s).
locals {
  alarms = {
    node-cpu-high = {
      metric    = "node_cpu_utilization"
      stat      = "Average"
      threshold = 80
      periods   = 2
      op        = "GreaterThanThreshold"
      desc      = "Average node CPU > 80% for 10 minutes"
    }
    node-memory-high = {
      metric    = "node_memory_utilization"
      stat      = "Average"
      threshold = 80
      periods   = 2
      op        = "GreaterThanThreshold"
      desc      = "Average node memory > 80% for 10 minutes"
    }
    node-disk-high = {
      metric    = "node_filesystem_utilization"
      stat      = "Average"
      threshold = 85
      periods   = 2
      op        = "GreaterThanThreshold"
      desc      = "Node filesystem > 85% for 10 minutes"
    }
    failed-nodes = {
      metric    = "cluster_failed_node_count"
      stat      = "Maximum"
      threshold = 1
      periods   = 1
      op        = "GreaterThanOrEqualToThreshold"
      desc      = "One or more cluster nodes are in a failed state"
    }
    pod-restarts-high = {
      metric    = "pod_number_of_container_restarts"
      stat      = "Maximum"
      threshold = 5
      periods   = 1
      op        = "GreaterThanThreshold"
      desc      = "Container restarts spiking — possible CrashLoop"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "ci" {
  for_each = local.alarms

  alarm_name          = "${var.cluster_name}-${each.key}"
  alarm_description   = each.value.desc
  namespace           = "ContainerInsights"
  metric_name         = each.value.metric
  dimensions          = { ClusterName = var.cluster_name }
  statistic           = each.value.stat
  period              = 300
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = each.value.op
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
