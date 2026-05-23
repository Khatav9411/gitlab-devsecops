################################################################################
# Azure Cosmos DB (SQL/Core API) — free tier + UAMI + data-plane RBAC.
#
# Free tier gives 1000 RU/s + 25 GB free forever, per *subscription* (only one
# free-tier account allowed). If you already consume the free tier elsewhere,
# set var.cosmos_free_tier = false to provision a paid account instead.
################################################################################

variable "cosmos_free_tier" {
  type        = bool
  default     = true
  description = "Use the free tier (1000 RU/s + 25 GB free). One per subscription."
}

resource "azurerm_cosmosdb_account" "todoapp" {
  name                = "cosmos-${var.cluster_name}-${substr(md5(azurerm_resource_group.this.id), 0, 6)}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  offer_type          = "Standard"
  kind                = "GlobalDocumentDB"

  free_tier_enabled                 = var.cosmos_free_tier
  automatic_failover_enabled        = false
  public_network_access_enabled     = true # POC; production: false + private endpoint
  local_authentication_disabled     = true # force Entra ID — no master keys

  consistency_policy {
    consistency_level = "Session"
  }

  geo_location {
    location          = azurerm_resource_group.this.location
    failover_priority = 0
  }

  capabilities {
    name = "EnableServerless" # only billed for RU consumed; free tier still applies
  }

  tags = var.tags
}

resource "azurerm_cosmosdb_sql_database" "todoapp" {
  name                = "todoapp"
  resource_group_name = azurerm_cosmosdb_account.todoapp.resource_group_name
  account_name        = azurerm_cosmosdb_account.todoapp.name
}

resource "azurerm_cosmosdb_sql_container" "todos" {
  name                  = "todos"
  resource_group_name   = azurerm_cosmosdb_account.todoapp.resource_group_name
  account_name          = azurerm_cosmosdb_account.todoapp.name
  database_name         = azurerm_cosmosdb_sql_database.todoapp.name
  partition_key_paths   = ["/id"]
  partition_key_version = 2
}

################################################################################
# UAMI the todoapp API will assume via workload identity to read/write Cosmos
################################################################################

resource "azurerm_user_assigned_identity" "todoapi" {
  name                = "uami-todoapi"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "todoapi" {
  name                = "fic-todoapi"
  resource_group_name = azurerm_resource_group.this.name
  parent_id           = azurerm_user_assigned_identity.todoapi.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.this.oidc_issuer_url
  subject             = "system:serviceaccount:todoapp:todoapi"
}

# Cosmos DB built-in "Data Contributor" role at the database scope.
# Built-in role definition ID is well-known across all Cosmos accounts:
#   00000000-0000-0000-0000-000000000002 = Cosmos DB Built-in Data Contributor
resource "azurerm_cosmosdb_sql_role_assignment" "todoapi" {
  resource_group_name = azurerm_cosmosdb_account.todoapp.resource_group_name
  account_name        = azurerm_cosmosdb_account.todoapp.name
  role_definition_id  = "${azurerm_cosmosdb_account.todoapp.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002"
  principal_id        = azurerm_user_assigned_identity.todoapi.principal_id
  scope               = azurerm_cosmosdb_account.todoapp.id
}
