################################################################################
# Azure Key Vault + UAMI + federated identity for External Secrets Operator
################################################################################

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                       = "kv-${var.cluster_name}-${substr(md5(azurerm_resource_group.this.id), 0, 6)}"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false # POC; production: true
  soft_delete_retention_days = 7

  tags = var.tags
}

# Let the human running terraform (you) also write secrets to the vault
resource "azurerm_role_assignment" "kv_admin_self" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Sample secret — real values would be added out-of-band by ops
resource "azurerm_key_vault_secret" "demo" {
  name         = "myapp-demo-secret"
  value        = "hello-from-keyvault"
  key_vault_id = azurerm_key_vault.this.id

  depends_on = [azurerm_role_assignment.kv_admin_self]
}

################################################################################
# UAMI that ESO will assume via workload identity
################################################################################

resource "azurerm_user_assigned_identity" "eso" {
  name                = "uami-eso"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# UAMI gets read-only access to KV secrets
resource "azurerm_role_assignment" "eso_kv_reader" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.eso.principal_id
}

# Federate the UAMI with the ESO service account on the AKS cluster.
# The ESO helm install will create a SA named `external-secrets` in ns `external-secrets`.
resource "azurerm_federated_identity_credential" "eso" {
  name                = "fic-eso"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.eso.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:external-secrets:external-secrets"
}
