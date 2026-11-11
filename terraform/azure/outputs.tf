output "website_url" {
  description = "Your live website"
  value       = "http://${azurerm_public_ip.web.fqdn}"
}

output "grafana_url" {
  description = "Grafana (only from your IP). User: admin"
  value       = "http://${azurerm_public_ip.web.fqdn}:3000"
}

output "prometheus_url" {
  description = "Prometheus (only from your IP)"
  value       = "http://${azurerm_public_ip.web.fqdn}:9090"
}

output "grafana_password" {
  description = "Show it with: terraform output -raw grafana_password"
  value       = random_password.grafana.result
  sensitive   = true
}

output "ssh_command" {
  description = "Open a terminal on the server"
  value       = "ssh azureuser@${azurerm_public_ip.web.ip_address}"
}

output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.web.name
}

output "logs_link" {
  description = "Open this to search the logs in the Azure portal"
  value       = "https://portal.azure.com/#resource${azurerm_log_analytics_workspace.logs.id}/logs"
}
