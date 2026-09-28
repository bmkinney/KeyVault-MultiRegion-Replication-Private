terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  storage_use_azuread = true
}

# We need the tenant id for the key vault.
data "azurerm_client_config" "this" {}

resource "azurerm_resource_group" "primary" {
  name     = "rg-mrkv-primary"
  location = "southcentralus"
}

resource "azurerm_resource_group" "secondary" {
  name     = "rg-mrkv-secondary"
  location = "swedencentral"
}

resource "azurerm_virtual_network" "primary" {
  name                = "vnet-mrkv-primary"
  address_space       = ["10.35.0.0/16"]
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
}

resource "azurerm_virtual_network" "secondary" {
  name                = "vnet-mrkv-secondary"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  address_space       = ["10.36.0.0/16"]
}

locals {

  vnet_names = {
    primary   = azurerm_virtual_network.primary.name
    secondary = azurerm_virtual_network.secondary.name
  }

  vnet_rg_names = {
    primary   = azurerm_resource_group.primary.name
    secondary = azurerm_resource_group.secondary.name
  }
}

resource "azurerm_subnet" "snet_function_primary" {
  name                 = "snet-function-primary"
  resource_group_name  = azurerm_resource_group.primary.name
  virtual_network_name = azurerm_virtual_network.primary.name
  address_prefixes     = ["10.35.1.0/24"] // adjust if needed
  service_endpoints    = ["Microsoft.Storage"]
  delegation {
    name = "webapp-delegation"

    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action"
      ]
    }
  }
}

resource "azurerm_subnet" "snet_private_endpoints_primary" {
  name                 = "snet-private-endpoints-primary"
  resource_group_name  = azurerm_resource_group.primary.name
  virtual_network_name = azurerm_virtual_network.primary.name
  address_prefixes     = ["10.35.0.0/24"] // adjust if needed

  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_subnet" "snet_function_secondary" {
  name                 = "snet-function-secondary"
  resource_group_name  = azurerm_resource_group.secondary.name
  virtual_network_name = azurerm_virtual_network.secondary.name
  address_prefixes     = ["10.36.1.0/24"] # adjust to your CIDR
  service_endpoints    = ["Microsoft.Storage"]

  delegation {
    name = "webapp-delegation"

    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
    }
  }
}

resource "azurerm_subnet" "snet_private_endpoints_secondary" {
  name                 = "snet-private-endpoints-secondary"
  resource_group_name  = azurerm_resource_group.secondary.name
  virtual_network_name = azurerm_virtual_network.secondary.name
  address_prefixes     = ["10.36.0.0/24"]

  private_endpoint_network_policies = "Disabled"
}

# Private DNS Zones for Key Vault - split by region to avoid cross-VNet IP resolution without peering
resource "azurerm_private_dns_zone" "kv_primary" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.primary.name
}

resource "azurerm_private_dns_zone" "kv_secondary" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.secondary.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv_primary" {
  name                  = "link-kv-primary"
  resource_group_name   = azurerm_private_dns_zone.kv_primary.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.kv_primary.name
  virtual_network_id    = azurerm_virtual_network.primary.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "kv_secondary" {
  name                  = "link-kv-secondary"
  resource_group_name   = azurerm_private_dns_zone.kv_secondary.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.kv_secondary.name
  virtual_network_id    = azurerm_virtual_network.secondary.id
  registration_enabled  = false
}

# Private DNS Zones for Service Bus - separate zones linked to respective VNets (per MS recommendation)
resource "azurerm_private_dns_zone" "sb_primary" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.primary.name
}

resource "azurerm_private_dns_zone" "sb_secondary" {
  name                = "privatelink.servicebus.windows.net"
  resource_group_name = azurerm_resource_group.secondary.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "sb_primary" {
  name                  = "link-sb-primary"
  resource_group_name   = azurerm_private_dns_zone.sb_primary.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.sb_primary.name
  virtual_network_id    = azurerm_virtual_network.primary.id
  registration_enabled  = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "sb_secondary" {
  name                  = "link-sb-secondary"
  resource_group_name   = azurerm_private_dns_zone.sb_secondary.resource_group_name
  private_dns_zone_name = azurerm_private_dns_zone.sb_secondary.name
  virtual_network_id    = azurerm_virtual_network.secondary.id
  registration_enabled  = false
}

resource "azurerm_key_vault" "primary" {
  name                            = "kv-mrkv-primary-01"
  location                        = azurerm_resource_group.primary.location
  resource_group_name             = azurerm_resource_group.primary.name
  tenant_id                       = data.azurerm_client_config.this.tenant_id
  sku_name                        = "standard"
  purge_protection_enabled        = false
  enabled_for_deployment          = true
  enabled_for_disk_encryption     = true
  enabled_for_template_deployment = true
  rbac_authorization_enabled      = true
}

resource "azurerm_key_vault" "secondary" {
  name                            = "kv-mrkv-secondary-01"
  location                        = azurerm_resource_group.secondary.location
  resource_group_name             = azurerm_resource_group.secondary.name
  tenant_id                       = data.azurerm_client_config.this.tenant_id
  sku_name                        = "standard"
  purge_protection_enabled        = false
  enabled_for_deployment          = true
  enabled_for_disk_encryption     = true
  enabled_for_template_deployment = true
  rbac_authorization_enabled      = true
}

# Event Grid System Topics for Key Vault events
resource "azurerm_eventgrid_system_topic" "kv_primary" {
  name                = "evgt-kv-mrkv-primary"
  resource_group_name = azurerm_resource_group.primary.name
  location            = azurerm_resource_group.primary.location
  source_resource_id  = azurerm_key_vault.primary.id
  topic_type          = "Microsoft.KeyVault.vaults"

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_eventgrid_system_topic" "kv_secondary" {
  name                = "evgt-kv-mrkv-secondary"
  resource_group_name = azurerm_resource_group.secondary.name
  location            = azurerm_resource_group.secondary.location
  source_resource_id  = azurerm_key_vault.secondary.id
  topic_type          = "Microsoft.KeyVault.vaults"

  identity {
    type = "SystemAssigned"
  }
}

# Key Vault Private Endpoints - use discrete subnet resources
resource "azurerm_private_endpoint" "kv_primary" {
  name                = "pe-kv-primary"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_primary.id

  private_service_connection {
    name                           = "psc-kv-primary"
    private_connection_resource_id = azurerm_key_vault.primary.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.kv_primary
  ]
}

resource "azurerm_private_endpoint" "kv_primary_remote" {
  name                = "pe-kv-primary-remote"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_secondary.id

  private_service_connection {
    name                           = "psc-kv-primary-remote"
    private_connection_resource_id = azurerm_key_vault.primary.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }
  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.kv_primary
  ]
}

resource "azurerm_private_endpoint" "kv_secondary" {
  name                = "pe-kv-secondary"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_secondary.id

  private_service_connection {
    name                           = "psc-kv-secondary"
    private_connection_resource_id = azurerm_key_vault.secondary.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.kv_secondary
  ]
}

resource "azurerm_private_endpoint" "kv_secondary_remote" {
  name                = "pe-kv-secondary-remote"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_primary.id

  private_service_connection {
    name                           = "psc-kv-secondary-remote"
    private_connection_resource_id = azurerm_key_vault.secondary.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }
  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.kv_secondary
  ]
}

resource "azurerm_servicebus_namespace" "primary" {
  name                = "sb-mrkv-primary-01"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  sku                 = "Premium"
  capacity            = 1

  premium_messaging_partitions = 1 // Must be 1, 2, or 4 (change from current value)

  public_network_access_enabled = true
}

resource "azurerm_servicebus_namespace" "secondary" {
  name                = "sb-mrkv-secondary-01"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  sku                 = "Premium"
  capacity            = 1

  premium_messaging_partitions = 1 // Must be 1, 2, or 4 (change from current value)

  public_network_access_enabled = true

}

# Service Bus Queues for Key Vault events
resource "azurerm_servicebus_queue" "kv_events_primary" {
  name         = "kv-events"
  namespace_id = azurerm_servicebus_namespace.primary.id

  partitioning_enabled = false
}

resource "azurerm_servicebus_queue" "kv_events_secondary" {
  name         = "kv-events"
  namespace_id = azurerm_servicebus_namespace.secondary.id

  partitioning_enabled = false
}

# Service Bus Private Endpoints
resource "azurerm_private_endpoint" "sb_primary" {
  name                = "pe-sb-primary"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_primary.id

  private_service_connection {
    name                           = "psc-sb-primary"
    private_connection_resource_id = azurerm_servicebus_namespace.primary.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }

  private_dns_zone_group {
    name                 = "sb-dns-primary"
    private_dns_zone_ids = [azurerm_private_dns_zone.sb_primary.id]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.sb_primary
  ]
}

resource "azurerm_private_endpoint" "sb_secondary" {
  name                = "pe-sb-secondary"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_secondary.id

  private_service_connection {
    name                           = "psc-sb-secondary"
    private_connection_resource_id = azurerm_servicebus_namespace.secondary.id
    is_manual_connection           = false
    subresource_names              = ["namespace"]
  }

  private_dns_zone_group {
    name                 = "sb-dns-secondary"
    private_dns_zone_ids = [azurerm_private_dns_zone.sb_secondary.id]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.sb_secondary
  ]
}

# Event Grid Event Subscriptions - Route Key Vault events to Service Bus
resource "azurerm_eventgrid_system_topic_event_subscription" "kv_to_sb_primary" {
  name                = "kv-to-servicebus-primary"
  system_topic        = azurerm_eventgrid_system_topic.kv_primary.name
  resource_group_name = azurerm_resource_group.primary.name

  service_bus_queue_endpoint_id = azurerm_servicebus_queue.kv_events_primary.id

  delivery_identity {
    type = "SystemAssigned"
  }

  included_event_types = [
    "Microsoft.KeyVault.SecretNewVersionCreated",
    "Microsoft.KeyVault.SecretNearExpiry",
    "Microsoft.KeyVault.SecretExpired",
    "Microsoft.KeyVault.CertificateNewVersionCreated",
    "Microsoft.KeyVault.CertificateNearExpiry",
    "Microsoft.KeyVault.CertificateExpired"
  ]

  depends_on = [
    azurerm_role_assignment.evgt_primary_sb_primary_sender,
    azurerm_role_assignment.evgt_primary_kv_reader
  ]
}

resource "azurerm_eventgrid_system_topic_event_subscription" "kv_to_sb_secondary" {
  name                = "kv-to-servicebus-secondary"
  system_topic        = azurerm_eventgrid_system_topic.kv_secondary.name
  resource_group_name = azurerm_resource_group.secondary.name

  service_bus_queue_endpoint_id = azurerm_servicebus_queue.kv_events_secondary.id

  delivery_identity {
    type = "SystemAssigned"
  }

  included_event_types = [
    "Microsoft.KeyVault.SecretNewVersionCreated",
    "Microsoft.KeyVault.SecretNearExpiry",
    "Microsoft.KeyVault.SecretExpired",
    "Microsoft.KeyVault.CertificateNewVersionCreated",
    "Microsoft.KeyVault.CertificateNearExpiry",
    "Microsoft.KeyVault.CertificateExpired"
  ]

  depends_on = [
    azurerm_role_assignment.evgt_secondary_sb_secondary_sender,
    azurerm_role_assignment.evgt_secondary_kv_reader
  ]
}

# Primary VNet zone records - only IPs reachable from primary VNet
resource "azurerm_private_dns_a_record" "kv_primary_in_primary_zone" {
  name                = azurerm_key_vault.primary.name
  zone_name           = azurerm_private_dns_zone.kv_primary.name
  resource_group_name = azurerm_private_dns_zone.kv_primary.resource_group_name
  ttl                 = 10
  records = [
    azurerm_private_endpoint.kv_primary.private_service_connection[0].private_ip_address,
  ]

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.kv_primary,
    azurerm_private_endpoint.kv_primary,
  ]
}

resource "azurerm_private_dns_a_record" "kv_secondary_in_primary_zone" {
  name                = azurerm_key_vault.secondary.name
  zone_name           = azurerm_private_dns_zone.kv_primary.name
  resource_group_name = azurerm_private_dns_zone.kv_primary.resource_group_name
  ttl                 = 10
  records = [
    azurerm_private_endpoint.kv_secondary_remote.private_service_connection[0].private_ip_address,
  ]

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.kv_primary,
    azurerm_private_endpoint.kv_secondary_remote,
  ]
}

# Secondary VNet zone records - only IPs reachable from secondary VNet
resource "azurerm_private_dns_a_record" "kv_primary_in_secondary_zone" {
  name                = azurerm_key_vault.primary.name
  zone_name           = azurerm_private_dns_zone.kv_secondary.name
  resource_group_name = azurerm_private_dns_zone.kv_secondary.resource_group_name
  ttl                 = 10
  records = [
    azurerm_private_endpoint.kv_primary_remote.private_service_connection[0].private_ip_address,
  ]

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.kv_secondary,
    azurerm_private_endpoint.kv_primary_remote,
  ]
}

resource "azurerm_private_dns_a_record" "kv_secondary_in_secondary_zone" {
  name                = azurerm_key_vault.secondary.name
  zone_name           = azurerm_private_dns_zone.kv_secondary.name
  resource_group_name = azurerm_private_dns_zone.kv_secondary.resource_group_name
  ttl                 = 10
  records = [
    azurerm_private_endpoint.kv_secondary.private_service_connection[0].private_ip_address,
  ]

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.kv_secondary,
    azurerm_private_endpoint.kv_secondary,
  ]
}


resource "azurerm_storage_account" "primary_func" {
  name                          = "samrkvprimaryfunc01"
  resource_group_name           = azurerm_resource_group.primary.name
  location                      = azurerm_resource_group.primary.location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  public_network_access_enabled = true
  # NOTE: shared_access_key_enabled is enforced to false by Azure Policy
  # File shares are created using ARM API (az storage share-rm) which doesn't require shared key access
}

resource "azurerm_private_endpoint" "storage_primary_blob" {
  name                = "pe-stmrkv-primary-blob"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_primary.id

  private_service_connection {
    name                           = "psc-stmrkv-primary-blob"
    private_connection_resource_id = azurerm_storage_account.primary_func.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "storage-blob-dns-primary"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_blob_primary.id]
  }
}

resource "azurerm_private_endpoint" "storage_primary_file" {
  name                = "pe-stmrkv-primary-file"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_primary.id

  private_service_connection {
    name                           = "psc-stmrkv-primary-file"
    private_connection_resource_id = azurerm_storage_account.primary_func.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "storage-file-dns-primary"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_file_primary.id]
  }
}

resource "azurerm_private_dns_zone" "storage_blob_primary" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.primary.name
}

resource "azurerm_private_dns_zone" "storage_file_primary" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.primary.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_blob_primary" {
  name                  = "vnet-link-storage-blob-primary"
  resource_group_name   = azurerm_resource_group.primary.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_blob_primary.name
  virtual_network_id    = azurerm_virtual_network.primary.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_file_primary" {
  name                  = "vnet-link-storage-file-primary"
  resource_group_name   = azurerm_resource_group.primary.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_file_primary.name
  virtual_network_id    = azurerm_virtual_network.primary.id
}

resource "azurerm_service_plan" "primary" {
  name                = "asp-mrkv-primary"
  location            = azurerm_resource_group.primary.location
  resource_group_name = azurerm_resource_group.primary.name
  os_type             = "Linux"
  sku_name            = "EP1"
}

resource "azurerm_linux_function_app" "primary" {
  name                          = "func-mrkv-primary-01"
  location                      = azurerm_resource_group.primary.location
  resource_group_name           = azurerm_resource_group.primary.name
  service_plan_id               = azurerm_service_plan.primary.id
  storage_account_name          = azurerm_storage_account.primary_func.name
  storage_uses_managed_identity = true
  public_network_access_enabled = true # Required for zip deploy via SCM/Kudu endpoint

  app_settings = {
    PRIMARY_KEY_VAULT_URI                         = azurerm_key_vault.primary.vault_uri
    SECONDARY_KEY_VAULT_URI                       = azurerm_key_vault.secondary.vault_uri
    PRIMARY_KEY_VAULT_NAME                        = azurerm_key_vault.primary.name
    SECONDARY_KEY_VAULT_NAME                      = azurerm_key_vault.secondary.name
    ServiceBusConnection__fullyQualifiedNamespace = "${azurerm_servicebus_namespace.primary.name}.servicebus.windows.net"
    ServiceBusConnection__credential              = "managedidentity"
    FUNCTIONS_WORKER_RUNTIME                      = "python"
    WEBSITE_RUN_FROM_PACKAGE                      = "1"
    AzureWebJobsStorage__accountName              = azurerm_storage_account.primary_func.name
    AzureWebJobsStorage__credential               = "ManagedIdentity"
  }

  site_config {
    vnet_route_all_enabled = true

    application_stack {
      python_version = "3.11"
    }
  }

  virtual_network_subnet_id    = azurerm_subnet.snet_function_primary.id
  content_share_force_disabled = true # Disable auto-creation; create manually after RBAC roles are assigned

  identity {
    type = "SystemAssigned"
  }

  depends_on = [
    azurerm_private_endpoint.storage_primary_blob,
    azurerm_private_endpoint.storage_primary_file,
    azurerm_private_dns_zone_virtual_network_link.storage_blob_primary,
    azurerm_private_dns_zone_virtual_network_link.storage_file_primary,
  ]
}

# RBAC role assignments for Function App's Managed Identity
resource "azurerm_role_assignment" "func_primary_blob" {
  scope                = azurerm_storage_account.primary_func.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id
}

resource "azurerm_role_assignment" "func_primary_file" {
  scope                = azurerm_storage_account.primary_func.id
  role_definition_name = "Storage File Data SMB Share Contributor"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id
}

resource "azurerm_role_assignment" "func_primary_queue" {
  scope                = azurerm_storage_account.primary_func.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id
}

# Create the file share using ARM API (works without shared key access)
# azurerm_storage_share resource cannot be used because Azure Policy blocks shared_access_key_enabled
resource "null_resource" "func_primary_share" {
  provisioner "local-exec" {
    command = "az storage share-rm create --storage-account ${azurerm_storage_account.primary_func.name} --name func-mrkv-primary-share --quota 100 --resource-group rg-mrkv-primary"
  }

  depends_on = [
    azurerm_role_assignment.func_primary_blob,
    azurerm_role_assignment.func_primary_file,
  ]
}

# Note: The 'site' directory in the file share should be created by the Function App at runtime
# or manually using: az storage directory create --share-name func-mrkv-primary-share --name site --account-name samrkvprimaryfunc01 --auth-mode login --enable-file-backup-request-intent


resource "azurerm_storage_account" "secondary_func" {
  name                          = "samrkvsecondaryfunc01"
  resource_group_name           = azurerm_resource_group.secondary.name
  location                      = azurerm_resource_group.secondary.location
  account_tier                  = "Standard"
  account_replication_type      = "LRS"
  public_network_access_enabled = true
  # NOTE: shared_access_key_enabled is enforced to false by Azure Policy
  # File shares are created using ARM API (az storage share-rm) which doesn't require shared key access
}

resource "azurerm_private_endpoint" "storage_secondary_blob" {
  name                = "pe-stmrkv-secondary-blob"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_secondary.id

  private_service_connection {
    name                           = "psc-stmrkv-secondary-blob"
    private_connection_resource_id = azurerm_storage_account.secondary_func.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "storage-blob-dns-secondary"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_blob_secondary.id]
  }
}

resource "azurerm_private_endpoint" "storage_secondary_file" {
  name                = "pe-stmrkv-secondary-file"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  subnet_id           = azurerm_subnet.snet_private_endpoints_secondary.id

  private_service_connection {
    name                           = "psc-stmrkv-secondary-file"
    private_connection_resource_id = azurerm_storage_account.secondary_func.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "storage-file-dns-secondary"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage_file_secondary.id]
  }
}

resource "azurerm_private_dns_zone" "storage_blob_secondary" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.secondary.name
}

resource "azurerm_private_dns_zone" "storage_file_secondary" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.secondary.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_blob_secondary" {
  name                  = "vnet-link-storage-blob-secondary"
  resource_group_name   = azurerm_resource_group.secondary.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_blob_secondary.name
  virtual_network_id    = azurerm_virtual_network.secondary.id
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_file_secondary" {
  name                  = "vnet-link-storage-file-secondary"
  resource_group_name   = azurerm_resource_group.secondary.name
  private_dns_zone_name = azurerm_private_dns_zone.storage_file_secondary.name
  virtual_network_id    = azurerm_virtual_network.secondary.id
}

# ============================================================================
# SECONDARY REGION - Service Plan, Function App, Storage RBAC, File Share
# ============================================================================

resource "azurerm_service_plan" "secondary" {
  name                = "asp-mrkv-secondary"
  location            = azurerm_resource_group.secondary.location
  resource_group_name = azurerm_resource_group.secondary.name
  os_type             = "Linux"
  sku_name            = "EP1"
}

resource "azurerm_linux_function_app" "secondary" {
  name                          = "func-mrkv-secondary-01"
  location                      = azurerm_resource_group.secondary.location
  resource_group_name           = azurerm_resource_group.secondary.name
  service_plan_id               = azurerm_service_plan.secondary.id
  storage_account_name          = azurerm_storage_account.secondary_func.name
  storage_uses_managed_identity = true
  public_network_access_enabled = true # Required for zip deploy via SCM/Kudu endpoint

  app_settings = {
    PRIMARY_KEY_VAULT_URI                         = azurerm_key_vault.primary.vault_uri
    SECONDARY_KEY_VAULT_URI                       = azurerm_key_vault.secondary.vault_uri
    PRIMARY_KEY_VAULT_NAME                        = azurerm_key_vault.primary.name
    SECONDARY_KEY_VAULT_NAME                      = azurerm_key_vault.secondary.name
    ServiceBusConnection__fullyQualifiedNamespace = "${azurerm_servicebus_namespace.secondary.name}.servicebus.windows.net"
    ServiceBusConnection__credential              = "managedidentity"
    FUNCTIONS_WORKER_RUNTIME                      = "python"
    WEBSITE_RUN_FROM_PACKAGE                      = "1"
    AzureWebJobsStorage__accountName              = azurerm_storage_account.secondary_func.name
    AzureWebJobsStorage__credential               = "ManagedIdentity"
  }

  site_config {
    vnet_route_all_enabled = true

    application_stack {
      python_version = "3.11"
    }
  }

  virtual_network_subnet_id    = azurerm_subnet.snet_function_secondary.id
  content_share_force_disabled = true # Disable auto-creation; create manually after RBAC roles are assigned

  identity {
    type = "SystemAssigned"
  }

  depends_on = [
    azurerm_private_endpoint.storage_secondary_blob,
    azurerm_private_endpoint.storage_secondary_file,
    azurerm_private_dns_zone_virtual_network_link.storage_blob_secondary,
    azurerm_private_dns_zone_virtual_network_link.storage_file_secondary,
  ]
}

# RBAC role assignments for Secondary Function App's Managed Identity - Storage
resource "azurerm_role_assignment" "func_secondary_blob" {
  scope                = azurerm_storage_account.secondary_func.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id
}

resource "azurerm_role_assignment" "func_secondary_file" {
  scope                = azurerm_storage_account.secondary_func.id
  role_definition_name = "Storage File Data SMB Share Contributor"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id
}

resource "azurerm_role_assignment" "func_secondary_queue" {
  scope                = azurerm_storage_account.secondary_func.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id
}

# Create the file share for secondary using ARM API (works without shared key access)
resource "null_resource" "func_secondary_share" {
  provisioner "local-exec" {
    command = "az storage share-rm create --storage-account ${azurerm_storage_account.secondary_func.name} --name func-mrkv-secondary-share --quota 100 --resource-group rg-mrkv-secondary"
  }

  depends_on = [
    azurerm_role_assignment.func_secondary_blob,
    azurerm_role_assignment.func_secondary_file,
  ]
}

# ============================================================================
# MANAGED IDENTITY ROLE ASSIGNMENTS
# ============================================================================

# Primary Function App - Key Vault Access
resource "azurerm_role_assignment" "func_primary_kv_primary_secret_officer" {
  scope                = azurerm_key_vault.primary.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.primary]
}

resource "azurerm_role_assignment" "func_primary_kv_secondary_secret_officer" {
  scope                = azurerm_key_vault.secondary.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.primary]
}

resource "azurerm_role_assignment" "func_primary_kv_primary_cert_officer" {
  scope                = azurerm_key_vault.primary.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.primary]
}

resource "azurerm_role_assignment" "func_primary_kv_secondary_cert_officer" {
  scope                = azurerm_key_vault.secondary.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.primary]
}

# Primary Function App - Service Bus Access
resource "azurerm_role_assignment" "func_primary_sb_primary_sender" {
  scope                = azurerm_servicebus_namespace.primary.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.primary]
}

resource "azurerm_role_assignment" "func_primary_sb_primary_receiver" {
  scope                = azurerm_servicebus_namespace.primary.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.primary]
}

resource "azurerm_role_assignment" "func_primary_sb_secondary_sender" {
  scope                = azurerm_servicebus_namespace.secondary.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.primary]
}

resource "azurerm_role_assignment" "func_primary_sb_secondary_receiver" {
  scope                = azurerm_servicebus_namespace.secondary.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_linux_function_app.primary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.primary]
}

# Secondary Function App - Key Vault Access
resource "azurerm_role_assignment" "func_secondary_kv_primary_secret_officer" {
  scope                = azurerm_key_vault.primary.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.secondary]
}

resource "azurerm_role_assignment" "func_secondary_kv_secondary_secret_officer" {
  scope                = azurerm_key_vault.secondary.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.secondary]
}

resource "azurerm_role_assignment" "func_secondary_kv_primary_cert_officer" {
  scope                = azurerm_key_vault.primary.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.secondary]
}

resource "azurerm_role_assignment" "func_secondary_kv_secondary_cert_officer" {
  scope                = azurerm_key_vault.secondary.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.secondary]
}

# Secondary Function App - Service Bus Access
resource "azurerm_role_assignment" "func_secondary_sb_primary_sender" {
  scope                = azurerm_servicebus_namespace.primary.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.secondary]
}

resource "azurerm_role_assignment" "func_secondary_sb_primary_receiver" {
  scope                = azurerm_servicebus_namespace.primary.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.secondary]
}

resource "azurerm_role_assignment" "func_secondary_sb_secondary_sender" {
  scope                = azurerm_servicebus_namespace.secondary.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.secondary]
}

resource "azurerm_role_assignment" "func_secondary_sb_secondary_receiver" {
  scope                = azurerm_servicebus_namespace.secondary.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_linux_function_app.secondary.identity[0].principal_id

  depends_on = [azurerm_linux_function_app.secondary]
}

resource "azurerm_role_assignment" "evgt_primary_sb_primary_sender" {
  scope                = azurerm_servicebus_namespace.primary.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_eventgrid_system_topic.kv_primary.identity[0].principal_id

  depends_on = [azurerm_eventgrid_system_topic.kv_primary]
}

# Event Grid needs Key Vault reader access to monitor for events
resource "azurerm_role_assignment" "evgt_primary_kv_reader" {
  scope                = azurerm_key_vault.primary.id
  role_definition_name = "Key Vault Reader"
  principal_id         = azurerm_eventgrid_system_topic.kv_primary.identity[0].principal_id

  depends_on = [azurerm_eventgrid_system_topic.kv_primary]
}

resource "azurerm_role_assignment" "evgt_secondary_sb_secondary_sender" {
  scope                = azurerm_servicebus_namespace.secondary.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_eventgrid_system_topic.kv_secondary.identity[0].principal_id

  depends_on = [azurerm_eventgrid_system_topic.kv_secondary]
}

# Event Grid needs Key Vault reader access to monitor for events
resource "azurerm_role_assignment" "evgt_secondary_kv_reader" {
  scope                = azurerm_key_vault.secondary.id
  role_definition_name = "Key Vault Reader"
  principal_id         = azurerm_eventgrid_system_topic.kv_secondary.identity[0].principal_id

  depends_on = [azurerm_eventgrid_system_topic.kv_secondary]
}