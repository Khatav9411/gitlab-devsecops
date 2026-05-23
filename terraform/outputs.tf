output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "kube_config_command" {
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.this.name} --name ${azurerm_kubernetes_cluster.this.name}"
  description = "Run this to populate ~/.kube/config"
}

output "oidc_issuer_url" {
  value = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "eso_uami_client_id" {
  value       = azurerm_user_assigned_identity.eso.client_id
  description = "Annotate the ESO service account with this client-id for workload identity"
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}
