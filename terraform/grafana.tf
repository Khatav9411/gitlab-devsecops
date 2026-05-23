################################################################################
# UAMI + federated identity for Grafana to query Azure Monitor / Log Analytics
################################################################################

resource "azurerm_user_assigned_identity" "grafana" {
  name                = "uami-grafana"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# Required for the Azure Monitor data source: read metrics + activity log
resource "azurerm_role_assignment" "grafana_monitoring_reader" {
  scope                = azurerm_resource_group.this.id
  role_definition_name = "Monitoring Reader"
  principal_id         = azurerm_user_assigned_identity.grafana.principal_id
}

# Required to query the Log Analytics Workspace (Container Insights data)
resource "azurerm_role_assignment" "grafana_law_reader" {
  scope                = azurerm_log_analytics_workspace.this.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_user_assigned_identity.grafana.principal_id
}

# Federate the UAMI with the Grafana service account
resource "azurerm_federated_identity_credential" "grafana" {
  name                = "fic-grafana"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.grafana.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:grafana:grafana"
}
