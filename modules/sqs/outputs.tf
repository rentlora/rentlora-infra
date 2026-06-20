output "property_sync_queue_url" { value = aws_sqs_queue.property_sync.url }
output "property_sync_queue_arn" { value = aws_sqs_queue.property_sync.arn }
output "property_sync_dlq_arn" { value = aws_sqs_queue.property_sync_dlq.arn }
output "booking_events_queue_url" { value = aws_sqs_queue.booking_events.url }
output "booking_events_queue_arn" { value = aws_sqs_queue.booking_events.arn }
output "booking_events_dlq_arn" { value = aws_sqs_queue.booking_events_dlq.arn }
