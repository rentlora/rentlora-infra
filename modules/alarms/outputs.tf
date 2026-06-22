output "sns_topic_arn" {
  description = "SNS topic that alarm notifications publish to."
  value       = aws_sns_topic.alerts.arn
}
