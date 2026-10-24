output "journal_db_endpoint" {
  description = "Private PostgreSQL endpoint for the Journal API."
  value       = aws_db_instance.journal.address
}

output "journal_db_port" {
  description = "PostgreSQL port."
  value       = aws_db_instance.journal.port
}

output "journal_db_name" {
  description = "Initial database name."
  value       = aws_db_instance.journal.db_name
}

output "journal_db_master_secret_arn" {
  description = "Secrets Manager ARN containing the RDS-managed master credentials."
  value       = aws_db_instance.journal.master_user_secret[0].secret_arn
}

output "journal_api_public_ip" {
  description = "Static public IPv4 address assigned to the API Network Load Balancer."
  value       = aws_eip.journal_api_ingress.public_ip
}

output "journal_api_production_url" {
  description = "HTTPS endpoint for the API using sslip.io and the static load balancer address."
  value       = "https://${aws_eip.journal_api_ingress.public_ip}.sslip.io"
}

output "github_actions_build_role_arn" {
  description = "Set this as the AWS_BUILD_ROLE_ARN repository Actions variable."
  value       = aws_iam_role.github_build.arn
}

output "github_actions_deploy_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN repository Actions variable."
  value       = aws_iam_role.github_deploy.arn
}
