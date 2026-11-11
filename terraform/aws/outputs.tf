output "website_url" {
  description = "Your live website"
  value       = "http://${aws_instance.web.public_ip}"
}

output "grafana_url" {
  description = "Grafana (only reachable from your IP). User: admin"
  value       = "http://${aws_instance.web.public_ip}:3000"
}

output "prometheus_url" {
  description = "Prometheus (only reachable from your IP)"
  value       = "http://${aws_instance.web.public_ip}:9090"
}

output "grafana_password" {
  description = "Show it with: terraform output -raw grafana_password"
  value       = random_password.grafana.result
  sensitive   = true
}

output "region" {
  value = var.region
}

output "instance_id" {
  value = aws_instance.web.id
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "cloudwatch_logs_link" {
  description = "Open this to read the logs in the AWS console"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#logsV2:log-groups/log-group/$252Fsre-quotes$252Fapp"
}

output "open_terminal_on_server" {
  description = "Run this to get a shell on the server (needs the Session Manager plugin)"
  value       = "aws ssm start-session --target ${aws_instance.web.id} --region ${var.region}"
}
