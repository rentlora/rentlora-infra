variable "name" {
  description = "Prefix for the backup vault/plan/role (e.g. the cluster name)."
  type        = string
}

variable "selection_tag_value" {
  description = "Resources tagged backup-plan=<this> are included in the plan."
  type        = string
  default     = "rentlora-daily"
}

variable "delete_after_days" {
  description = "Days to retain each recovery point."
  type        = number
  default     = 35
}
