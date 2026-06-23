variable "alert_email" {
  description = "Email that receives budget + cost-anomaly notifications."
  type        = string
}

variable "monthly_limit" {
  description = "Monthly cost budget in USD."
  type        = string
  default     = "50"
}

variable "anomaly_threshold" {
  description = "Minimum anomaly impact (USD) that triggers an alert."
  type        = string
  default     = "10"
}
