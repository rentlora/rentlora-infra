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
