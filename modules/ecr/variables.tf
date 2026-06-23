variable "github_org" {
  type    = string
  default = "rentlora"
}
variable "github_repo" {
  type    = string
  default = "rentlora" # the application repo (builds + pushes images)
}
variable "infra_repo" {
  type    = string
  default = "rentlora-infra" # the terraform/IaC repo
}
variable "cluster_name" { type = string }
