# ─── property-sync (standard) ───────────────────────────────────────────────

resource "aws_sqs_queue" "property_sync_dlq" {
  name                      = "rentlora-${var.env}-property-sync-dlq"
  message_retention_seconds = 1209600 # 14 days
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "property_sync" {
  name                       = "rentlora-${var.env}-property-sync"
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.property_sync_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "property_sync_dlq" {
  queue_url = aws_sqs_queue.property_sync_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.property_sync.arn]
  })
}

# ─── booking-events (FIFO) ──────────────────────────────────────────────────

resource "aws_sqs_queue" "booking_events_dlq" {
  name                      = "rentlora-${var.env}-booking-events-dlq.fifo"
  fifo_queue                = true
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "booking_events" {
  name                        = "rentlora-${var.env}-booking-events.fifo"
  fifo_queue                  = true
  content_based_deduplication = true
  visibility_timeout_seconds  = 60
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.booking_events_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "booking_events_dlq" {
  queue_url = aws_sqs_queue.booking_events_dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.booking_events.arn]
  })
}
