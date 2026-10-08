# Azure Portal Deployment Guide - Private Key Vault Secret Replication

This walkthrough deploys the **secrets-only, private-endpoint and managed-identity/RBAC** solution in [`infra/main.bicep`](../infra/main.bicep). It preserves the main-branch Terraform's two-region topology and default resource names, but deliberately changes the runtime and networking to satisfy strict private data-plane access.

For the automated deployment path, use the separate [Bicep deployment README](../infra/README.md). The repository [main page](../README.md#private-polling-architecture) contains the Mermaid architecture diagram. Source URLs are listed under their relevant phases and collected in the complete appendix.

**Do not follow the legacy Terraform deployment steps for this variant.** `main.tf` and `replicatefunc/` are retained as the original, event-driven implementation. Deploy code from **`private-functions/`**, not `replicatefunc/` or the historical ZIP files.

## Why polling replaces Event Grid

Event Grid system topics cannot deliver through private endpoints. A managed identity or trusted-service firewall exception does not make that delivery private. This solution therefore has **no Event Grid topics, subscriptions, trusted-service bypass, or public data-plane fallback**.

The primary timer reads its local vault through Private Link, discovers the latest readable secret versions, and sends **version references, not secret values**, to the secondary Service Bus queue through a cross-region private endpoint. The secondary worker reads the source version privately, writes its local vault privately, and records operation/checkpoint state in its local private Blob account. Reverse replication uses the same pattern during a controlled failover.

All workload data-plane endpoints are private. Azure Resource Manager, Microsoft Entra authentication for operators/build agents, and platform management are not converted to private endpoints by this deployment. A requirement for zero public control-plane or build-system egress requires a separate approved network design.

**Source documentation**

- [Event Grid managed identities and private delivery limitation](https://learn.microsoft.com/en-us/azure/event-grid/managed-service-identity#private-endpoints)
- [Event Grid private endpoints: system-topic limitations](https://learn.microsoft.com/en-us/azure/event-grid/configure-private-endpoints)
- [Key Vault SecretClient SDK](https://learn.microsoft.com/en-us/python/api/azure-keyvault-secrets/azure.keyvault.secrets.secretclient)
- [ServiceBusClient SDK](https://learn.microsoft.com/en-us/python/api/azure-servicebus/azure.servicebus.servicebusclient)
- [Blob ContainerClient SDK](https://learn.microsoft.com/en-us/python/api/azure-storage-blob/azure.storage.blob.containerclient)
- [GitHub Mermaid diagrams used on the main page](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams)

## Resource inventory

| Resource | Primary | Secondary |
| --- | --- | --- |
| Region | South Central US | Sweden Central |
| Resource group | `rg-mrkv-primary` | `rg-mrkv-secondary` |
| VNet | `vnet-mrkv-primary`, `10.35.0.0/16` | `vnet-mrkv-secondary`, `10.36.0.0/16` |
| Function subnet | `snet-function-primary`, `10.35.1.0/24` | `snet-function-secondary`, `10.36.1.0/24` |
| Endpoint subnet | `snet-private-endpoints-primary`, `10.35.0.0/24` | `snet-private-endpoints-secondary`, `10.36.0.0/24` |
| Vault | `kv-mrkv-primary` | `kv-mrkv-secondary` |
| Storage | `samrkvprimaryfunc` | `samrkvsecondaryfunc` |
| Service Bus | `sb-mrkv-primary`, Premium, one messaging unit/partition | `sb-mrkv-secondary`, same SKU |
| Queue | `kv-events` | `kv-events` |
| Plan | `asp-mrkv-primary`, Linux EP1 | `asp-mrkv-secondary`, Linux EP1 |
| Function | `func-mrkv-primary`, Python 3.11 | `func-mrkv-secondary`, Python 3.11 |
| Blob containers | `packages`, `replication-state` | `packages`, `replication-state` |
| Polling producer default | Enabled | Disabled until controlled failover |
| Replication worker | Enabled | Enabled |

Each VNet has eight private endpoints: both vaults, both Service Bus namespaces, local Blob/Queue/Table storage, and its local Function App. There are **16 private endpoints and 12 private DNS zones** in total. There is no VNet peering, Azure Files share, storage key, SAS token, or Service Bus shared-access credential.

## Prerequisites and migration safety

1. Obtain subscription-level permission to create the resource groups and resources, plus permission to assign RBAC roles. Register `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.KeyVault`, `Microsoft.ServiceBus`, and `Microsoft.Web`.
2. Confirm **Elastic Premium EP1** and **Service Bus Premium** availability/quota in both regions. EP1 is not the App Service Premium V3 P1v3 SKU.
3. Use Azure CLI with Bicep support. For package building, use Python with pip, PowerShell, and a .NET SDK that can build `net8.0` projects. Build dependencies come from approved package feeds or mirrors; they are bundled before deployment.
4. Provide an administrative/build host with routing and DNS into each regional VNet. The Bicep files do not create a VPN, ExpressRoute circuit, jump host, or private DNS resolver. Azure Cloud Shell is not sufficient unless it has been explicitly VNet-integrated and configured for these private endpoints.
5. Ensure the **browser**, not just the CLI host, can resolve and reach the vault private endpoints before using the Portal's Secrets blade. Use each region's local deployment host for its storage account, or a separately designed hub/resolver topology. Do not link duplicate same-name private zones indiscriminately into a shared hub.
6. Set unique names in `infra/main.bicepparam`; the supplied names may already be taken. Change the region parameters to `eastus` and `centralus` for that scenario, after checking quota. CIDRs must not overlap existing connected networks.
7. Prefer a new deployment with distinct names. **Do not deploy over Terraform-managed resources without an explicit migration plan.** Bicep does not adopt Terraform state or remove old Event Grid subscriptions in incremental deployments. Old subscriptions and legacy workers must be disabled before cutover; pre-existing role assignments can also conflict with newly named Bicep role assignments.
8. Key Vault purge protection is enabled with 90-day soft-delete retention. It cannot be turned off after activation, and deleted vault names cannot immediately be reused.

```powershell
az login
az account set --subscription "<subscription-id>"
az bicep version
```

**Source documentation**

- [Bicep tooling installation](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install)
- [Azure resource naming rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules)
- [Functions Premium plan/quota considerations](https://learn.microsoft.com/en-us/azure/azure-functions/functions-premium-plan)
- [Key Vault soft-delete and purge protection](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview)

## Automated Bicep alternative

The [dedicated Bicep README](../infra/README.md) covers parameters, module responsibilities, build/what-if, subscription deployment, packaging, and release validation. Do not also recreate those template-managed resources manually.

The template creates infrastructure, RBAC, and containers, **not the package blob**. After automated infrastructure deployment, use **Phase 8** below for package upload/restart/synchronization and **Phase 9** for live checks. Initial startup can fail until package upload and RBAC propagation complete; do not enable public access as a workaround.

**Source documentation:** [Subscription deployments](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-subscription), [Bicep parameter files](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files), and [what-if](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if).

## Portal deployment walkthrough

The following phases provide click-through instructions and PowerShell/Azure CLI references. Substitute your chosen names consistently. The snippets use the defaults in the inventory.

### Phase 1 - Resource groups and VNets

1. **Home > Resource groups > Create**: create the primary and secondary groups in their respective regions.
2. **Create a resource > Virtual network**: create each VNet with the inventory CIDR.
3. On **IP addresses**, remove the default subnet and add the Function and private endpoint subnets.
4. Delegate each Function subnet to **Microsoft.Web/serverFarms**. Do **not** add service endpoints.
5. Set private endpoint subnet network policies to **Disabled**. Keep private endpoints out of the delegated Function subnet.

```powershell
foreach ($region in 'primary','secondary') {
  $location = if ($region -eq 'primary') { 'southcentralus' } else { 'swedencentral' }
  $prefix = if ($region -eq 'primary') { '10.35' } else { '10.36' }
  az group create -n "rg-mrkv-$region" -l $location
  az network vnet create -g "rg-mrkv-$region" -n "vnet-mrkv-$region" `
    -l $location --address-prefixes "$prefix.0.0/16"
  az network vnet subnet create -g "rg-mrkv-$region" --vnet-name "vnet-mrkv-$region" `
    -n "snet-function-$region" --address-prefixes "$prefix.1.0/24" `
    --delegations Microsoft.Web/serverFarms
  az network vnet subnet create -g "rg-mrkv-$region" --vnet-name "vnet-mrkv-$region" `
    -n "snet-private-endpoints-$region" --address-prefixes "$prefix.0.0/24" `
    --disable-private-endpoint-network-policies true
}
```

**Source documentation**

- [VNet/subnet/delegation schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/virtualnetworks)
- [Resource group schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.resources/2024-03-01/resourcegroups)
- [Private endpoint subnet and placement requirements](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview)

### Phase 2 - Private DNS

1. **Create a resource > Private DNS zone**: create these six zones in **each** resource group:
   `privatelink.vaultcore.azure.net`, `privatelink.servicebus.windows.net`,
   `privatelink.blob.core.windows.net`, `privatelink.queue.core.windows.net`,
   `privatelink.table.core.windows.net`, `privatelink.azurewebsites.net`.
2. For every zone, open **Virtual network links > Add** and link only its own regional VNet. Leave auto-registration **off**.
3. Identical zone names in different resource groups are intentional. Each VNet resolves vault and Service Bus names to the endpoints reachable from **that VNet**.

```powershell
$zones = @(
  'privatelink.vaultcore.azure.net', 'privatelink.servicebus.windows.net',
  'privatelink.blob.core.windows.net', 'privatelink.queue.core.windows.net',
  'privatelink.table.core.windows.net', 'privatelink.azurewebsites.net'
)
foreach ($region in 'primary','secondary') {
  for ($index = 0; $index -lt $zones.Count; $index++) {
    az network private-dns zone create -g "rg-mrkv-$region" -n $zones[$index]
    az network private-dns link vnet create -g "rg-mrkv-$region" `
      --zone-name $zones[$index] -n "link-$index-$region" `
      --virtual-network "vnet-mrkv-$region" --registration-enabled false
  }
}
```

**Source documentation**

- [Private endpoint DNS configuration and zone values](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)
- [Private DNS zone schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2020-06-01/privatednszones)
- [Private DNS VNet-link schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2020-06-01/privatednszones/virtualnetworklinks)
- [Private DNS A-record schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2020-06-01/privatednszones/a)

### Phase 3 - Vaults and private storage

1. **Create a resource > Key Vault**: create both Standard vaults. Select **Azure RBAC** authorization, enable **purge protection**, and use 90-day retention.
2. Set **Public network access = Disabled**. Do not enable trusted-service bypass or VM/template/disk-encryption access unless a separately reviewed workload needs it.
3. **Create a resource > Storage account**: create one Standard LRS, StorageV2 account in each region.
4. On **Advanced**, require HTTPS and TLS 1.2, disallow anonymous Blob access and storage account key access. On **Networking**, disable public network access.
5. Do not rely on Azure Policy to turn key access off later. These settings must be explicit.
6. Bicep creates the `packages` and `replication-state` Blob containers through ARM. For the manual route, create them from the private host after Phase 5 and operator RBAC are ready, using the commands below. No storage keys are needed. Do not delete or edit replication-state records as routine cleanup.

```powershell
foreach ($region in 'primary','secondary') {
  $location = if ($region -eq 'primary') { 'southcentralus' } else { 'swedencentral' }
  az keyvault create -g "rg-mrkv-$region" -n "kv-mrkv-$region" -l $location `
    --sku standard --enable-rbac-authorization true --enable-purge-protection true `
    --retention-days 90 --public-network-access Disabled --default-action Deny --bypass None
  az storage account create -g "rg-mrkv-$region" -n "samrkv${region}func" -l $location `
    --sku Standard_LRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 `
    --allow-shared-key-access false --allow-blob-public-access false `
    --public-network-access Disabled --default-action Deny --bypass None
}
```

The Bicep deployment creates the two containers through ARM. For a manual deployment, after Blob private endpoints and operator RBAC are ready, the private host can instead run:

```powershell
foreach ($container in 'packages','replication-state') {
  az storage container create --account-name samrkvprimaryfunc -n $container `
    --auth-mode login --public-access off
  az storage container create --account-name samrkvsecondaryfunc -n $container `
    --auth-mode login --public-access off
}
```

**Key Vault source documentation**

- [Network security and trusted-service bypass behavior](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security)
- [Soft delete/purge protection](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview)
- [Vault ARM/Bicep schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/2023-07-01/vaults)
- [Key Vault Secrets Officer/User roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security)
- [Key Vault SecretClient SDK](https://learn.microsoft.com/en-us/python/api/azure-keyvault-secrets/azure.keyvault.secrets.secretclient)

**Storage source documentation**

- [Prevent Shared Key authorization](https://learn.microsoft.com/en-us/azure/storage/common/shared-key-authorization-prevent)
- [Storage private endpoints](https://learn.microsoft.com/en-us/azure/storage/common/storage-private-endpoints)
- [Storage account schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2023-05-01/storageaccounts)
- [Blob service schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2023-05-01/storageaccounts/blobservices)
- [Container schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2023-05-01/storageaccounts/blobservices/containers)
- [Blob ContainerClient SDK](https://learn.microsoft.com/en-us/python/api/azure-storage-blob/azure.storage.blob.containerclient)

### Phase 4 - Service Bus

1. **Create a resource > Service Bus**: create both **Premium** namespaces with one messaging unit and one messaging partition.
2. Disable **local authentication**. On **Networking**, set public access to **Disabled** and **Allow trusted Microsoft services to bypass = Off**.
3. **Queues > Create**: create `kv-events`. Disable partitioning; enable duplicate detection with a 10-minute window. Set TTL to seven days, lock duration to one minute, maximum delivery count to ten, and dead-lettering on expiry.
4. RBAC still controls operations over private endpoints; network reachability alone is not permission.

```powershell
foreach ($region in 'primary','secondary') {
  $location = if ($region -eq 'primary') { 'southcentralus' } else { 'swedencentral' }
  az servicebus namespace create -g "rg-mrkv-$region" -n "sb-mrkv-$region" `
    -l $location --sku Premium --capacity 1 --premium-messaging-partitions 1 `
    --disable-local-auth true --public-network-access Disabled --minimum-tls-version 1.2
  az servicebus namespace network-rule-set update -g "rg-mrkv-$region" `
    --namespace-name "sb-mrkv-$region" --default-action Deny `
    --public-network-access Disabled --enable-trusted-service-access false
  az servicebus queue create -g "rg-mrkv-$region" --namespace-name "sb-mrkv-$region" `
    -n kv-events --enable-partitioning false --enable-duplicate-detection true `
    --duplicate-detection-history-time-window PT10M --default-message-time-to-live P7D `
    --lock-duration PT1M --max-delivery-count 10 --enable-dead-lettering-on-message-expiration true
}
```

**Source documentation**

- [Service Bus Private Link](https://learn.microsoft.com/en-us/azure/service-bus-messaging/private-link-service)
- [Duplicate detection](https://learn.microsoft.com/en-us/azure/service-bus-messaging/duplicate-detection)
- [Dead-letter queues](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dead-letter-queues)
- [Namespace schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.servicebus/2024-01-01/namespaces)
- [Queue schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.servicebus/2024-01-01/namespaces/queues)
- [Network-rule-set schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.servicebus/2024-01-01/namespaces/networkrulesets)
- [ServiceBusClient SDK](https://learn.microsoft.com/en-us/python/api/azure-servicebus/azure.servicebus.servicebusclient)

### Phase 5 - Vault, Service Bus, and storage private endpoints

For each endpoint: open the target resource's **Networking > Private endpoint connections > Add**, select the endpoint's regional resource group/VNet and **private endpoint subnet**, and select the target subresource.

| Target | Primary VNet endpoint | Secondary VNet endpoint | Subresource / DNS |
| --- | --- | --- | --- |
| Primary vault | `pe-kv-primary` | `pe-kv-primary-remote` | `vault`, manual A records |
| Secondary vault | `pe-kv-secondary-remote` | `pe-kv-secondary` | `vault`, manual A records |
| Primary Service Bus | `pe-sb-primary` | `pe-sb-primary-remote` | `namespace`, manual A records |
| Secondary Service Bus | `pe-sb-secondary-remote` | `pe-sb-secondary` | `namespace`, manual A records |
| Local storage Blob | `pe-stmrkv-primary-blob` | `pe-stmrkv-secondary-blob` | `blob`, local zone group |
| Local storage Queue | `pe-stmrkv-primary-queue` | `pe-stmrkv-secondary-queue` | `queue`, local zone group |
| Local storage Table | `pe-stmrkv-primary-table` | `pe-stmrkv-secondary-table` | `table`, local zone group |

For **vault and Service Bus** endpoints, select **DNS integration = No**. In the local vault/Service Bus zones, create an A record named after each target resource, pointing to that target's endpoint NIC IP in the **local VNet**, TTL 10. Do not automatically register both regions' IPs into the same zone.

For **Blob/Queue/Table** endpoints, use **DNS integration = Yes**, selecting the appropriate zone in the same resource group as the endpoint.

This PowerShell reference creates the local and remote endpoints and DNS records. Run after Phases 1-4. `Get-PrivateEndpointIp` reads the endpoint NIC rather than assuming `customDnsConfigs` is always populated.

```powershell
function Get-PrivateEndpointIp($group, $name) {
  $nic = az network private-endpoint show -g $group -n $name --query 'networkInterfaces[0].id' -o tsv
  if ($LASTEXITCODE -ne 0 -or -not $nic) { throw "Cannot find NIC for $name" }
  $ip = az network nic show --ids $nic --query 'ipConfigurations[0].privateIPAddress' -o tsv
  if ($LASTEXITCODE -ne 0 -or -not $ip) { throw "Cannot find private IP for $name" }
  return $ip
}

foreach ($region in 'primary','secondary') {
  $group = "rg-mrkv-$region"
  $location = if ($region -eq 'primary') { 'southcentralus' } else { 'swedencentral' }
  foreach ($target in 'primary','secondary') {
    $suffix = if ($region -eq $target) { '' } else { '-remote' }
    foreach ($kind in 'kv','sb') {
      $resourceName = "$kind-mrkv-$target"
      $endpointName = "pe-$kind-$target$suffix"
      $resourceId = if ($kind -eq 'kv') {
        az keyvault show -g "rg-mrkv-$target" -n $resourceName --query id -o tsv
      } else {
        az servicebus namespace show -g "rg-mrkv-$target" -n $resourceName --query id -o tsv
      }
      $subresource = if ($kind -eq 'kv') { 'vault' } else { 'namespace' }
      $zone = if ($kind -eq 'kv') { 'privatelink.vaultcore.azure.net' } else { 'privatelink.servicebus.windows.net' }
      az network private-endpoint create -g $group -n $endpointName -l $location `
        --vnet-name "vnet-mrkv-$region" --subnet "snet-private-endpoints-$region" `
        --private-connection-resource-id $resourceId --group-id $subresource --connection-name "psc-$endpointName"
      $ip = Get-PrivateEndpointIp $group $endpointName
      az network private-dns record-set a create -g $group -z $zone -n $resourceName --ttl 10
      az network private-dns record-set a add-record -g $group -z $zone -n $resourceName --ipv4-address $ip
    }
  }
  $storageId = az storage account show -g $group -n "samrkv${region}func" --query id -o tsv
  foreach ($service in 'blob','queue','table') {
    $endpointName = "pe-stmrkv-$region-$service"
    az network private-endpoint create -g $group -n $endpointName -l $location `
      --vnet-name "vnet-mrkv-$region" --subnet "snet-private-endpoints-$region" `
      --private-connection-resource-id $storageId --group-id $service --connection-name "psc-$endpointName"
    $zoneId = az network private-dns zone show -g $group -n "privatelink.$service.core.windows.net" --query id -o tsv
    az network private-endpoint dns-zone-group create -g $group --endpoint-name $endpointName `
      -n default --private-dns-zone $zoneId --zone-name $service
  }
}
```

**Source documentation**

- [Private endpoint overview](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview)
- [Private endpoint DNS configuration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)
- [Private endpoint schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/privateendpoints)
- [Private endpoint NIC/IP-address schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/networkinterfaces)
- [DNS zone-group schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/privateendpoints/privatednszonegroups)
- [Key Vault network security](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security)
- [Service Bus Private Link](https://learn.microsoft.com/en-us/azure/service-bus-messaging/private-link-service)
- [Storage private endpoints](https://learn.microsoft.com/en-us/azure/storage/common/storage-private-endpoints)

### Phase 6 - Private Function Apps without Azure Files

1. **Create a resource > Function App**, choose **Functions Premium**, Linux, Python 3.11, and EP1. Create `asp-mrkv-primary`/`asp-mrkv-secondary` and the respective Function Apps.
2. On **Storage**, select the local account, choose managed-identity host storage, and **clear Add an Azure Files connection**. Do not accept a storage-key or Azure Files connection string.
3. On **Networking**, disable public access and integrate with the regional delegated Function subnet. Turn on **Route All**.
4. Enable the **system-assigned managed identity**. Require HTTPS, TLS 1.2 for app/SCM, enable HTTP/2, disable FTPS, and disable SCM/FTP basic-auth publishing.
5. Add the settings in the table below. If the Portal wizard cannot create this configuration without keys, use `infra/modules/function.bicep` through **Deploy a custom template**, or use the subscription Bicep deployment. Do not create a key-based placeholder.
6. Create a Function private endpoint named `pe-func-primary`/`pe-func-secondary`, target subresource **sites**, in the local endpoint subnet. Integrate with the local `privatelink.azurewebsites.net` zone. Confirm **both app and SCM records** resolve privately.

| Setting | Value for primary; swap local/remote for secondary |
| --- | --- |
| `FUNCTIONS_EXTENSION_VERSION` | `~4` |
| `FUNCTIONS_WORKER_RUNTIME` | `python` |
| `AzureWebJobsFeatureFlags` | `EnableWorkerIndexing` |
| `AzureWebJobsStorage__accountName` | `samrkvprimaryfunc` |
| `AzureWebJobsStorage__credential` | `managedidentity` |
| `WEBSITE_RUN_FROM_PACKAGE` | `https://samrkvprimaryfunc.blob.core.windows.net/packages/functionapp.zip` |
| `WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID` | `SystemAssigned` |
| `LOCAL_KEY_VAULT_URI` | `https://kv-mrkv-primary.vault.azure.net/` |
| `REMOTE_KEY_VAULT_URI` | `https://kv-mrkv-secondary.vault.azure.net/` |
| `DESTINATION_SERVICE_BUS_NAMESPACE` | `sb-mrkv-secondary.servicebus.windows.net` |
| `ServiceBusConnection__fullyQualifiedNamespace` | `sb-mrkv-primary.servicebus.windows.net` |
| `ServiceBusConnection__credential` | `managedidentity` |
| `REPLICATION_STATE_STORAGE_URI` | `https://samrkvprimaryfunc.blob.core.windows.net` |
| `ReplicationPollSchedule` | `0 */1 * * * *` |
| `AzureWebJobs.poll_secrets.Disabled` | `false` for primary; `true` for secondary initially |

Do not set `AzureWebJobsStorage`, `WEBSITE_CONTENTSHARE`, or `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`. The Functions run from a private Blob package using their identities. [Azure Files does not support this identity-based host-content connection](https://learn.microsoft.com/en-us/azure/azure-functions/storage-considerations#create-an-app-without-azure-files). Removing Files can limit Elastic Premium scale-out; validate throughput before production.

CLI reference for strict app creation, after the preceding resources exist:

```powershell
foreach ($region in 'primary','secondary') {
  $remote = if ($region -eq 'primary') { 'secondary' } else { 'primary' }
  $location = if ($region -eq 'primary') { 'southcentralus' } else { 'swedencentral' }
  $functionSubnetId = az network vnet subnet show -g "rg-mrkv-$region" `
    --vnet-name "vnet-mrkv-$region" -n "snet-function-$region" --query id -o tsv
  $endpointSubnetId = az network vnet subnet show -g "rg-mrkv-$region" `
    --vnet-name "vnet-mrkv-$region" -n "snet-private-endpoints-$region" --query id -o tsv
  $polling = if ($region -eq 'primary') { 'true' } else { 'false' }
  az deployment group create -g "rg-mrkv-$region" --template-file .\infra\modules\function.bicep `
    --parameters regionName=$region location=$location functionName="func-mrkv-$region" `
      functionSubnetId=$functionSubnetId endpointSubnetId=$endpointSubnetId `
      localVaultUri="https://kv-mrkv-$region.vault.azure.net/" `
      remoteVaultUri="https://kv-mrkv-$remote.vault.azure.net/" `
      localServiceBusHost="sb-mrkv-$region.servicebus.windows.net" `
      remoteServiceBusHost="sb-mrkv-$remote.servicebus.windows.net" `
      storageName="samrkv${region}func" pollSchedule="0 */1 * * * *" `
      pollingEnabled=$polling packageBlobName=functionapp.zip
}
```

**Source documentation**

- [Functions Premium](https://learn.microsoft.com/en-us/azure/azure-functions/functions-premium-plan)
- [Functions networking/VNet integration](https://learn.microsoft.com/en-us/azure/azure-functions/functions-networking-options)
- [Managed-identity connections and host storage](https://learn.microsoft.com/en-us/azure/azure-functions/manage-connections?pivots=functions-auth-identity&tabs=host)
- [Apps without Azure Files](https://learn.microsoft.com/en-us/azure/azure-functions/storage-considerations#create-an-app-without-azure-files)
- [Function app settings](https://learn.microsoft.com/en-us/azure/azure-functions/functions-app-settings)
- [EP1 plan schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/serverfarms)
- [Function App/site schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/sites)
- [SCM/FTP basic publishing-credentials policy schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/sites/basicpublishingcredentialspolicies)

### Phase 7 - Resource-scoped RBAC

For each assignment: open the target **Access control (IAM) > Add role assignment**, select the role, then **Managed identity > Function App**, choose the appropriate identity, and assign.

| Target scope | Identity | Roles |
| --- | --- | --- |
| Local vault | Local Function | Key Vault Secrets Officer |
| Local vault | Remote Function | Key Vault Secrets User |
| Local `kv-events` queue | Local Function | Azure Service Bus Data Receiver |
| Local `kv-events` queue | Remote Function | Azure Service Bus Data Sender |
| Local storage account | Local Function | Storage Blob Data Owner; Storage Queue Data Contributor; Storage Table Data Contributor |

Blob Data Owner is the documented host-storage role, not subscription Owner. The host and operation-state containers must be protected because they affect code execution and loop prevention. There are no cross-region storage grants, certificate roles, Files roles, Event Grid identities, or shared-access credentials.

```powershell
$primaryPrincipal = az functionapp identity show -g rg-mrkv-primary -n func-mrkv-primary --query principalId -o tsv
$secondaryPrincipal = az functionapp identity show -g rg-mrkv-secondary -n func-mrkv-secondary --query principalId -o tsv
az deployment group create -g rg-mrkv-primary --template-file .\infra\modules\access.bicep `
  --parameters vaultName=kv-mrkv-primary serviceBusName=sb-mrkv-primary storageName=samrkvprimaryfunc `
    localPrincipalId=$primaryPrincipal remotePrincipalId=$secondaryPrincipal
az deployment group create -g rg-mrkv-secondary --template-file .\infra\modules\access.bicep `
  --parameters vaultName=kv-mrkv-secondary serviceBusName=sb-mrkv-secondary storageName=samrkvsecondaryfunc `
    localPrincipalId=$secondaryPrincipal remotePrincipalId=$primaryPrincipal
```

The package uploader additionally needs **Storage Blob Data Contributor** on the appropriate `packages` container. Operators who test secret replication need an appropriate vault data role, such as Secrets Officer for creating the test secret and Secrets User for reading the replica. Contributor/Owner control-plane access alone does not grant secret access. Allow time for RBAC propagation; do not switch to keys after a transient 403.

**Source documentation**

- [Assign roles through the Portal](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-portal)
- [Role assignment ARM/Bicep schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/2022-04-01/roleassignments)
- [Key Vault roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security)
- [Storage roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage)
- [Service Bus sender/receiver roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/integration)
- [Functions managed-identity host permissions](https://learn.microsoft.com/en-us/azure/azure-functions/manage-connections?pivots=functions-auth-identity&tabs=host)

### Phase 8 - Build and upload the private Function package

Run the build script from the repository root:

```powershell
.\private-functions\build-package.ps1 -OutputFile .\functionapp.zip
```

The script packages Linux/Python 3.11 wheels and compiles the Service Bus extension into `bin/`. It deliberately does not use runtime extension-bundle downloads, remote builds, Azure Files, SCM ZIP deployment, or storage keys. It restores dependencies from configured pip/NuGet feeds at **build time**, not from the production Function at startup. Ensure your organization approves these feeds or configures mirrors.

From the private deployment host for **each region**, upload with your Entra identity:

```powershell
# Run with private routing/DNS into the primary VNet.
az storage blob upload --account-name samrkvprimaryfunc --container-name packages `
  --name functionapp.zip --file .\functionapp.zip --auth-mode login --overwrite true

# Run with private routing/DNS into the secondary VNet.
az storage blob upload --account-name samrkvsecondaryfunc --container-name packages `
  --name functionapp.zip --file .\functionapp.zip --auth-mode login --overwrite true
```

After both uploads and RBAC propagation, restart and synchronize triggers through ARM:

```powershell
foreach ($region in 'primary','secondary') {
  az functionapp restart -g "rg-mrkv-$region" -n "func-mrkv-$region"
  $id = az functionapp show -g "rg-mrkv-$region" -n "func-mrkv-$region" --query id -o tsv
  az rest --method post --url "https://management.azure.com$id/syncfunctiontriggers?api-version=2024-04-01"
  az functionapp function list -g "rg-mrkv-$region" -n "func-mrkv-$region" --query '[].name'
}
```

Expect `poll_secrets` and `replicate_secret`. For future releases, prefer an immutable versioned package name, update `WEBSITE_RUN_FROM_PACKAGE`, then restart/synchronize again. Infrastructure deployment does not upload packages or synchronize code releases for you.

**Source documentation**

- [Managed-identity package download](https://learn.microsoft.com/en-us/azure/azure-functions/deployment-zip-push#fetch-a-package-from-azure-blob-storage-by-using-a-managed-identity)
- [Explicit binding extension installation](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-register#explicitly-install-extensions)
- [Azure Functions local development/Core Tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local)
- [Functions without Azure Files](https://learn.microsoft.com/en-us/azure/azure-functions/storage-considerations#create-an-app-without-azure-files)
- [Package/host app settings](https://learn.microsoft.com/en-us/azure/azure-functions/functions-app-settings)

### Phase 9 - Validate private networking, RBAC, and replication

1. From each regional private host, resolve **both vaults and both Service Bus namespaces**. They must resolve to the endpoints in that host's VNet, not the other region's unreachable addresses.
2. Resolve its local Blob, Queue, Table, Function, and SCM names. Confirm DNS zone-group records and approved private endpoint connections.
3. Verify public access is disabled on both vaults, both storage accounts, both Service Bus namespaces, and both Function Apps. Verify shared-key/local auth and trusted-service bypass are disabled.
4. From an **unconnected external host**, authenticated vault/Blob/Service Bus data access must fail. Do not temporarily open public access for this test.
5. Using the private host and authorized operator identity, create a non-sensitive test secret in the active primary vault. Wait longer than the one-minute schedule plus queue/processing delay, then inspect the replica.
6. Confirm version counts stabilize; a replica must not bounce repeatedly between regions. Test a local new-version update that inherits replica tags during a controlled failover.
7. Check queue and dead-letter counts. A successful ARM/Bicep deployment is not evidence that the runtime is healthy.

```powershell
Resolve-DnsName kv-mrkv-primary.vault.azure.net
Resolve-DnsName kv-mrkv-secondary.vault.azure.net
Resolve-DnsName sb-mrkv-primary.servicebus.windows.net
Resolve-DnsName sb-mrkv-secondary.servicebus.windows.net
Resolve-DnsName samrkvprimaryfunc.blob.core.windows.net
Resolve-DnsName samrkvprimaryfunc.queue.core.windows.net
Resolve-DnsName samrkvprimaryfunc.table.core.windows.net
Resolve-DnsName func-mrkv-primary.azurewebsites.net
Resolve-DnsName func-mrkv-primary.scm.azurewebsites.net

az keyvault secret set --vault-name kv-mrkv-primary --name test-secret --value private-replication-test
Start-Sleep -Seconds 120
az keyvault secret show --vault-name kv-mrkv-secondary --name test-secret --query value -o tsv
az servicebus queue show -g rg-mrkv-secondary --namespace-name sb-mrkv-secondary -n kv-events `
  --query 'countDetails'
```

Queue/dead-letter metrics are available through the namespace's management plane. Provision persistent private telemetry and alerting before production; this conversion does not create Application Insights, an Azure Monitor Private Link Scope, or alerts. Without Azure Files, do not rely on Portal file-system log streaming.

**Source documentation:** [Private endpoint DNS](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns), [Key Vault firewall behavior](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security), and [Service Bus dead-letter queues](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dead-letter-queues).

### Phase 10 - Failover and operational limits

**Use one active writer/polling producer during normal operation.** Secondary workers are always active, but secondary polling starts disabled. Before activating secondary polling, disable primary polling and fence application writes to the primary, including when it recovers. Restore normal direction only after reconciling the vaults.

Keep `activePollingRegion` in the Bicep parameter file aligned with the active region before subsequent deployments; otherwise redeployment restores the parameter file's producer selection. Changing the parameter alone does not fence application writes or perform an atomic failover.

```powershell
# Controlled failover: fence primary application writes first.
az functionapp config appsettings set -g rg-mrkv-primary -n func-mrkv-primary `
  --settings 'AzureWebJobs.poll_secrets.Disabled=true'
az functionapp config appsettings set -g rg-mrkv-secondary -n func-mrkv-secondary `
  --settings 'AzureWebJobs.poll_secrets.Disabled=false'
```

- **RPO:** polling interval plus queue/processing latency, not a guaranteed one-minute RPO. The initial poll backfills current readable secrets. Intermediate versions created between polls can be missed.
- **Consistency:** version references do not contain secret values. The source must remain readable until the worker fetches that version. Regional outages can cause retries/dead-lettering; this is asynchronous pre-positioning, not synchronous failover replication.
- **Retry/loop safety:** state is written before replica creation. A private state fingerprint identifies replicas even if the completion checkpoint fails. Inherited replica tags do not suppress changed secret values. Completed operations deduplicate normal retries; concurrent/crash-edge processing is still at-least-once, not exactly-once.
- **Ordering:** queued versions superseded in the source are skipped. Simultaneous writes across regions are not resolved automatically; do not enable competing writers.
- **State:** keep the `replication-state` container private and intact. No lifecycle deletion policy is attached to it. Deleting checkpoints or operation records can replay versions or defeat loop prevention; establish a deliberate retention/reconciliation procedure for large inventories.
- **Unsupported:** certificate-managed secrets, certificates, keys, deletions, and metadata-only updates on existing versions. Disabled, expired, or future-dated secrets are not readable/copyable and produce warnings; independent activation/expiry handling needs a separate runbook.
- **Tags:** reserve two tag slots for `mrkv-replication-operation` and `mrkv-replicated-from`. Do not forge or remove replica markers, or mutate source-version attributes while delivery is in progress.
- **DLQ:** investigate permissions, private DNS, source availability, validity dates, and immutable source-version attributes before replaying messages. Do not log secret values or paste message payloads containing customer data into external tools.
- **Cost/scale:** two EP1 plans and two Service Bus Premium namespaces incur standing costs. Polling scales with the number of current secrets and can encounter Key Vault throttling. Benchmark and adjust the schedule before production.

**Source documentation**

- [Key Vault reliability](https://learn.microsoft.com/en-us/azure/reliability/reliability-key-vault)
- [Backup/restore restrictions](https://learn.microsoft.com/en-us/azure/key-vault/general/backup)
- [Certificate model and exportability](https://learn.microsoft.com/en-us/azure/key-vault/certificates/about-certificates)
- [BYOK specification](https://learn.microsoft.com/en-us/azure/key-vault/keys/byok-specification)
- [Azure encryption at rest and key management](https://learn.microsoft.com/en-us/azure/security/fundamentals/encryption-atrest)
- Repository analysis: [Key Vault DR gap analysis](./keyvault-dr-gap-analysis.md)

## Cleanup

Deletion is a separate operator-approved action. Stop replication and retain any required state/secret recovery information before deleting groups. Purge protection prevents immediate permanent vault deletion and name reuse for the retention period. Do not assume Terraform destroys resources created only by Bicep, or vice versa.

**Source documentation:** [Key Vault soft-delete and purge protection](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview).

## Local validation and policy exceptions

From the repository root, build the template and run the private runtime tests with the private requirements installed in an isolated environment:

```powershell
az bicep build --file .\infra\main.bicep --outfile .\infra\main.json
az bicep build-params --file .\infra\main.bicepparam
python -m venv .venv-review
.\.venv-review\Scripts\Activate.ps1
python -m pip install -r .\private-functions\requirements.txt
python -m pip install checkov
Push-Location .\private-functions
python -m unittest discover -s tests -v
Pop-Location
checkov --file .\infra\main.json --config-file .\infra\checkov.yaml
```

Checkov runs locally with policy downloads disabled. `infra/checkov.yaml` lists explicit exceptions, not an assertion of production readiness:

| Policy | Reason for exception |
| --- | --- |
| `CKV_AZURE_36` | Trusted Microsoft service bypass is prohibited by this private-only design. |
| `CKV_AZURE_43` | The scanner does not resolve nested storage-name parameters. Length constraints are in Bicep; actual lowercase-alphanumeric names and uniqueness must pass ARM validation/what-if. |
| `CKV_AZURE_206` | Each Function uses independent regional LRS host/state storage, preserving Terraform's placement rather than adding automatic paired-region storage replication. |
| `CKV_AZURE_17`, `CKV_AZURE_213` | The app exposes timer and Service Bus triggers, not an HTTP workload needing incoming client certificates or an invented HTTP health-check route. |
| `CKV_AZURE_212`, `CKV_AZURE_225` | Single-instance, non-zonal EP1 sizing is retained. In-region instance/zone redundancy must be reviewed against region support, quota, budget, and RTO before production. |

Cross-module dependency graphs and live DNS, RBAC propagation, package startup, and service availability are not proven by static scans. Bicep build/package checks and unit tests do not replace Phase 9's live private-network tests. This variant is not a claim of zero public platform/control-plane dependencies or guaranteed RPO/RTO.

**Source documentation:** [Checkov ARM scanning](https://www.checkov.io/7.Scan%20Examples/Azure%20ARM%20templates.html), [Checkov CLI/configuration](https://www.checkov.io/2.Basics/CLI%20Command%20Reference.html), and [Bicep what-if](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if).

## Appendix - Source documentation

This complete catalog covers the Portal and Bicep guides. Conceptual pages explain platform behavior; version-pinned schemas document resource properties. Custom polling/checkpoint behavior is defined by [`private-functions/replication.py`](../private-functions/replication.py) and its tests, not guaranteed by these service documents. The appendix links to upstream source documents rather than reproducing them in full.

### Deployment and parameters

- Bicep tooling: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install>
- Subscription scope: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-subscription>
- Parameter files: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files>
- What-if: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if>
- Resource naming rules: <https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules>
- Resource group schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.resources/2024-03-01/resourcegroups>

### Private networking and DNS

- Private endpoint overview: <https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview>
- Private endpoint DNS: <https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns>
- VNet schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/virtualnetworks>
- Private endpoint schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/privateendpoints>
- DNS zone-group schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/privateendpoints/privatednszonegroups>
- Network interface schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/networkinterfaces>
- Private DNS zone schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2020-06-01/privatednszones>
- DNS VNet-link schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2020-06-01/privatednszones/virtualnetworklinks>
- DNS A-record schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2020-06-01/privatednszones/a>

### Key Vault and DR scope

- Network security: <https://learn.microsoft.com/en-us/azure/key-vault/general/network-security>
- Soft delete/purge protection: <https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview>
- Vault schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/2023-07-01/vaults>
- SecretClient SDK: <https://learn.microsoft.com/en-us/python/api/azure-keyvault-secrets/azure.keyvault.secrets.secretclient>
- Reliability: <https://learn.microsoft.com/en-us/azure/reliability/reliability-key-vault>
- Backup/restore: <https://learn.microsoft.com/en-us/azure/key-vault/general/backup>
- Certificate model: <https://learn.microsoft.com/en-us/azure/key-vault/certificates/about-certificates>
- BYOK: <https://learn.microsoft.com/en-us/azure/key-vault/keys/byok-specification>
- Encryption at rest/customer-managed keys: <https://learn.microsoft.com/en-us/azure/security/fundamentals/encryption-atrest>

### Storage

- Private endpoints: <https://learn.microsoft.com/en-us/azure/storage/common/storage-private-endpoints>
- Prevent Shared Key: <https://learn.microsoft.com/en-us/azure/storage/common/shared-key-authorization-prevent>
- Storage account schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2023-05-01/storageaccounts>
- Blob service schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2023-05-01/storageaccounts/blobservices>
- Container schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2023-05-01/storageaccounts/blobservices/containers>
- ContainerClient SDK: <https://learn.microsoft.com/en-us/python/api/azure-storage-blob/azure.storage.blob.containerclient>

### Service Bus

- Private Link: <https://learn.microsoft.com/en-us/azure/service-bus-messaging/private-link-service>
- Duplicate detection: <https://learn.microsoft.com/en-us/azure/service-bus-messaging/duplicate-detection>
- Dead-letter queues: <https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dead-letter-queues>
- Namespace schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.servicebus/2024-01-01/namespaces>
- Queue schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.servicebus/2024-01-01/namespaces/queues>
- Network-rule-set schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.servicebus/2024-01-01/namespaces/networkrulesets>
- ServiceBusClient SDK: <https://learn.microsoft.com/en-us/python/api/azure-servicebus/azure.servicebus.servicebusclient>

### Functions and package deployment

- Premium hosting: <https://learn.microsoft.com/en-us/azure/azure-functions/functions-premium-plan>
- Networking: <https://learn.microsoft.com/en-us/azure/azure-functions/functions-networking-options>
- Identity connections/host RBAC: <https://learn.microsoft.com/en-us/azure/azure-functions/manage-connections?pivots=functions-auth-identity&tabs=host>
- Without Azure Files: <https://learn.microsoft.com/en-us/azure/azure-functions/storage-considerations#create-an-app-without-azure-files>
- Explicit binding extensions: <https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-register#explicitly-install-extensions>
- Identity-authenticated package: <https://learn.microsoft.com/en-us/azure/azure-functions/deployment-zip-push#fetch-a-package-from-azure-blob-storage-by-using-a-managed-identity>
- App settings: <https://learn.microsoft.com/en-us/azure/azure-functions/functions-app-settings>
- Local development/Core Tools: <https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local>
- Plan schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/serverfarms>
- App/site schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/sites>
- Publishing-credentials schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/sites/basicpublishingcredentialspolicies>

### RBAC

- Role assignment schema: <https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/2022-04-01/roleassignments>
- Portal role assignments: <https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-portal>
- Key Vault roles: <https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security>
- Storage roles: <https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage>
- Service Bus roles: <https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/integration>

### Event Grid exclusions and documentation tooling

- Private delivery limitation: <https://learn.microsoft.com/en-us/azure/event-grid/managed-service-identity#private-endpoints>
- Topic/system-topic Private Link limits: <https://learn.microsoft.com/en-us/azure/event-grid/configure-private-endpoints>
- Checkov ARM scanning: <https://www.checkov.io/7.Scan%20Examples/Azure%20ARM%20templates.html>
- Checkov CLI/configuration: <https://www.checkov.io/2.Basics/CLI%20Command%20Reference.html>
- GitHub Mermaid diagrams: <https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams>
