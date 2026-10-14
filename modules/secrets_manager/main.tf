locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

resource "random_password" "demo_password" {
  length           = 32
  special          = true
  override_special = "!@#%^*-_=+"
}

resource "aws_secretsmanager_secret" "phase3" {
  name                    = "${local.name_prefix}/phase3/kafka-demo"
  description             = "Phase 3 demo secret for secure application configuration."
  recovery_window_in_days = 0

  tags = {
    Name = "${local.name_prefix}-phase3-secret"
  }
}

resource "aws_secretsmanager_secret_version" "phase3" {
  secret_id = aws_secretsmanager_secret.phase3.id

  secret_string = jsonencode({
    username = var.secret_username
    password = random_password.demo_password.result
    purpose  = "phase3-demo"
  })
}
