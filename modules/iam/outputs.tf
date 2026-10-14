output "instance_profile_name" {
  description = "Name of the IAM instance profile to attach to the Kafka EC2 instance"
  value       = aws_iam_instance_profile.kafka_instance.name
}

output "role_arn" {
  description = "ARN of the Kafka EC2 instance IAM role"
  value       = aws_iam_role.kafka_instance.arn
}
