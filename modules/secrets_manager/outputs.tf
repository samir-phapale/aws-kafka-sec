output "secret_arn" {
  description = "ARN of the Phase 3 Secrets Manager secret."
  value       = aws_secretsmanager_secret.phase3.arn
}

output "secret_name" {
  description = "Name of the Phase 3 Secrets Manager secret."
  value       = aws_secretsmanager_secret.phase3.name
}
