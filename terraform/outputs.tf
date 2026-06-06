output "container_app_fqdn" {
  description = "Public FQDN of the Container App. MCP endpoint: https://<fqdn>/mcp"
  value       = "https://${azurerm_container_app.ca.ingress[0].fqdn}"
}

output "container_app_health_url" {
  description = "Unauthenticated health probe URL (for smoke tests and manual verification)."
  value       = "https://${azurerm_container_app.ca.ingress[0].fqdn}/health"
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace resource ID (for additional diagnostic settings or Kusto queries)."
  value       = azurerm_log_analytics_workspace.law.id
}

output "uami_client_id" {
  description = "Client ID of the user-assigned managed identity. Set as AZURE_CLIENT_ID in the container (already wired by Terraform) and needed for app registrations that trust this identity."
  value       = azurerm_user_assigned_identity.uami.client_id
}

output "uami_principal_id" {
  description = "Object ID (principal ID) of the UAMI. Passed to scripts/manual-uami-rbac.sh to create the Reader role assignment."
  value       = azurerm_user_assigned_identity.uami.principal_id
}

output "resource_group_name" {
  description = "Name of the resource group that contains all Terraform-managed resources."
  value       = azurerm_resource_group.rg.name
}

output "resource_group_id" {
  description = "Resource ID of the resource group (used by scripts/manual-uami-rbac.sh for the role assignment scope)."
  value       = azurerm_resource_group.rg.id
}
