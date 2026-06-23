variable "env" { type = string }
variable "db_subnet_group_name" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}
variable "deletion_protection" {
  type    = bool
  default = false
}
variable "skip_final_snapshot" {
  type    = bool
  default = true
}
variable "backup_retention_period" {
  type        = number
  default     = 7
  description = "Days of automated RDS backups (point-in-time recovery). 0 disables."
}
variable "multi_az" {
  type        = bool
  default     = false
  description = "Run a synchronous standby in another AZ for automatic failover (prod)."
}
