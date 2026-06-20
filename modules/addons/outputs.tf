output "karpenter_node_role_arn" { value = aws_iam_role.karpenter_node.arn }
output "karpenter_node_instance_profile" { value = aws_iam_instance_profile.karpenter_node.name }
output "karpenter_interruption_queue" { value = aws_sqs_queue.karpenter_interruption.name }
