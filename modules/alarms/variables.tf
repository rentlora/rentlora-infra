variable "cluster_name" {
  description = "EKS cluster name — used in alarm names and as the ContainerInsights ClusterName dimension."
  type        = string
}

variable "alert_email" {
  description = "Email address that receives alarm notifications (SNS). Must be CONFIRMED via the link AWS emails after apply."
  type        = string
}
