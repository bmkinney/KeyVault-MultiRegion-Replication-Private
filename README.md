
# Private, Asynchronous Multi‑Region Secret and Certificate Replication for Azure Key Vault

## Introduction

This Terraform deployment implements a **private, asynchronous, multi‑region secret and certificate replication architecture for Azure Key Vault**. The pattern enables organizations to maintain business continuity before a Microsoft‑declared regional outage. It ensures that a secondary region (Sweden Central) always contains an up‑to‑date replica of secrets and certificates stored in the primary region (South Central US).

The solution provides:

- Continuous, event‑driven secret and certificate replication infrastructure
- Private endpoint and private DNS paths for Key Vault, Storage blob/file, and local Service Bus access
- Region‑agnostic flexibility with cross‑geography replication
- Cross-region private endpoint connectivity for both Key Vaults
- Bi-directional replication capability (South Central US ↔ Sweden Central)

## Prerequisites

- Azure subscription with appropriate permissions
- Terraform >= 1.0
- Azure CLI or appropriate credentials configured
- Terraform AzureRM provider ~> 4.0
- Quota for App Service Plan EP1 in both regions

>[!IMPORTANT]
>Quota for App Service Plan EP1 is set to 0 by default. Request a quota increase for EP1 in both South Central US and Sweden Central regions before deploying. Use support cases with Microsoft and request escalation. The process may take several days, so plan accordingly.
![Screen capture showing the current EP1 quota set to zero across Azure regions](./images/EP1-quota.png)

This deployment uses RBAC-based authentication for Function App access to storage accounts. Function Apps use System-Assigned Managed Identities with the following roles:

- **Storage Blob Data Contributor** for blob storage operations
- **Storage File Data SMB Share Contributor** for file share operations
- **Storage Queue Data Contributor** for runtime queue operations

Storage accounts are configured with RBAC authentication only. File shares are created via ARM API (`az storage share-rm create`) and do not require shared key access.

## Deployment Architecture

![Diagram showing multi-region key vault replication with private endpoints connecting primary and secondary regions](./images/keyvault-multiregion.svg)

The workload is Multi-Region Key Vault Replication (MRKV). Regions are identified as Primary and Secondary, consisting of:

### Resource groups

- **Primary**: `rg-mrkv-primary` (South Central US)
- **Secondary**: `rg-mrkv-secondary` (Sweden Central)

### Network infrastructure

#### Primary region (South Central US)

- VNet: `vnet-mrkv-primary` (10.35.0.0/16)
  - `snet-function-primary` (10.35.1.0/24) — Function App subnet with Microsoft.Storage service endpoint
  - `snet-private-endpoints-primary` (10.35.0.0/24) — Private endpoint subnet

#### Secondary region (Sweden Central)

- VNet: `vnet-mrkv-secondary` (10.36.0.0/16)
  - `snet-function-secondary` (10.36.1.0/24) — Function App subnet with Microsoft.Storage service endpoint
  - `snet-private-endpoints-secondary` (10.36.0.0/24) — Private endpoint subnet

### Private DNS zones

Both regions use separate private DNS zones for each domain:

- `privatelink.vaultcore.azure.net`
- `privatelink.servicebus.windows.net`
- `privatelink.blob.core.windows.net`
- `privatelink.file.core.windows.net`

Key Vault DNS uses manual A records so each VNet resolves vault names to the private endpoint IPs reachable from that region. Service Bus and Storage private endpoints use private DNS zone groups for registration.

### Key vaults

Both regions use Standard SKU vaults with RBAC authorization enabled:

- **Primary**: `kv-mrkv-primary-01` (South Central US)
- **Secondary**: `kv-mrkv-secondary-01` (Sweden Central)

Both have private endpoints in both regions and purge protection disabled.

> [!WARNING]
> The current Terraform keeps Key Vault purge protection disabled for faster iteration. Azure best practice for production is to enable purge protection and validate your recovery process before go-live.

### Private endpoints (cross-region connectivity)

The deployment creates 10 private endpoints across both regions:

| Region | Resource | Private Endpoint |
| -------- | ---------- | ------------------ |
| Primary | Key Vault primary | `pe-kv-primary` |
| Primary | Key Vault secondary (cross-region) | `pe-kv-secondary-remote` |
| Primary | Service Bus | `pe-sb-primary` |
| Primary | Storage (blob) | `pe-stmrkv-primary-blob` |
| Primary | Storage (file) | `pe-stmrkv-primary-file` |
| Secondary | Key Vault secondary | `pe-kv-secondary` |
| Secondary | Key Vault primary (cross-region) | `pe-kv-primary-remote` |
| Secondary | Service Bus | `pe-sb-secondary` |
| Secondary | Storage (blob) | `pe-stmrkv-secondary-blob` |
| Secondary | Storage (file) | `pe-stmrkv-secondary-file` |

> [!NOTE]
> Manual A records are used only for Key Vault DNS. Service Bus and Storage private endpoints register through private DNS zone groups. The design avoids VNet peering for DNS resolution, but public endpoints still remain enabled on several services for deployment and runtime compatibility.

### Service Bus namespaces

Both regions use Premium SKU with one messaging partition:

- **Primary**: `sb-mrkv-primary-01` with public network access enabled
- **Secondary**: `sb-mrkv-secondary-01` with public network access enabled

Each has a private endpoint in its local region.

### Event Grid and Service Bus queues

Event Grid System Topics capture Key Vault events:

- **Primary**: `evgt-kv-mrkv-primary` (South Central US)
- **Secondary**: `evgt-kv-mrkv-secondary` (Sweden Central)

Each routes events to a queue named `kv-events` with partitioning disabled. Event subscriptions route events from system topics to Service Bus queues, triggering the Functions.

### Azure Functions

Both Function Apps use Linux with Python 3.11 and Elastic Premium (EP1) plans with managed identities:

- **Primary**: `func-mrkv-primary-01` with storage `samrkvprimaryfunc01`
- **Secondary**: `func-mrkv-secondary-01` with storage `samrkvsecondaryfunc01`

Both are VNet integrated and use managed identity authentication for all services. All traffic routes through their VNets with `vnet_route_all_enabled` set.

Core app settings:

- Service Bus connection using managed identity
- Storage configured with managed identity
- Key Vault URIs for both regions
- Run From Package enabled

### Managed identities and access control

All Functions use System-Assigned Managed Identities automatically created with the Function App. Each identity receives RBAC role assignments across Key Vaults, Service Bus, and storage accounts.

The primary Function has:

- Writer access to the primary Key Vault (`Key Vault Secrets Officer` and `Key Vault Certificates Officer`)
- Writer access to the secondary Key Vault (for replication, same roles)
- Read/write access to storage in its local region
- Sender/receiver permissions on both Service Bus namespaces

The secondary Function is configured symmetrically and also has `Key Vault Secrets Officer` and `Key Vault Certificates Officer` on both vaults plus sender/receiver permissions on both Service Bus namespaces.

> [!NOTE]
> The current Function app settings bind each Function to its local Service Bus namespace. Cross-namespace Service Bus RBAC is provisioned in Terraform, but the current app configuration uses the local `ServiceBusConnection__fullyQualifiedNamespace` value in each region.
> [!NOTE]
> This deployment uses only managed identity authentication. No shared keys or connection strings are stored as credentials.

## Messaging and Event Triggering

### Event flow architecture

The solution implements an event-driven pattern that prefers private endpoints for the application data path while leaving some public endpoints enabled for deployment and compatibility:

```text
┌─────────────────────────────────────────────────────────────┐
│ PRIMARY REGION (South Central US)                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Secret/Certificate Created/Updated in Key Vault            │
│  │                                                          │
│  ├──→ Event Grid System Topic (internal)                    │
│  │                                                          │
│  └──→ Event Subscription                                    │
│       │                                                     │
│       └──→ Service Bus Queue: kv-events                     │
│            │                                                │
│            ├──→ Function App triggered                      │
│            │    ├─ Read secret/cert from primary vault      │
│            │    └─ Write to secondary vault                 │
│            │                                                │
│            └──→ Secondary region via private endpoint       │
│                                                             │
└─────────────────────────────────────────────────────────────┘
         │
         │ (Private connectivity)
         │
         ↓
┌─────────────────────────────────────────────────────────────┐
│ SECONDARY REGION (Sweden Central)                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Secret/certificate written to Key Vault (replicated)       │
│                                                             │
│  (Optional) Replicate back to primary on update             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Event types and triggers

The Event Grid System Topics capture and route the following Key Vault events:

| Event Type | Trigger | Replication Action |
| --- | --- | --- |
| **SecretNewVersionCreated** | New secret version created or secret updated | Replicate to secondary vault immediately |
| **SecretNearExpiry** | Secret expiring within 30 days | Logged by the Function; no alerting or rotation workflow is provisioned |
| **SecretExpired** | Secret has expired | Logged by the Function; no automated recovery workflow is provisioned |
| **CertificateNewVersionCreated** | New certificate version created, imported, or renewed | Export from source vault and import into the other vault immediately |
| **CertificateNearExpiry** | Certificate expiring within 30 days | Logged by the Function; no alerting or renewal workflow is provisioned |
| **CertificateExpired** | Certificate has expired | Logged by the Function; no automated recovery workflow is provisioned |

Each event flows through the Event Subscription to the Service Bus queue, where the Function App processes it as a trigger.

### Service Bus queue processing

**Queue Name**: `kv-events`

**Configuration**:

- **Partitioning**: Disabled
- **Access**: Private endpoints are provisioned, but namespace public network access remains enabled in Terraform
- **Trigger**: Azure Functions Service Bus Trigger

**Message Flow**:

1. Event Grid receives Key Vault event
2. Event Subscription routes to Service Bus queue
3. Queue message delivered via private connection
4. Service Bus Trigger activates Function App
5. Function processes message and replicates the secret or certificate

### Replication workflow

**Primary Function Replication** (`func-mrkv-primary-01`):

1. **Trigger**: Service Bus message from `kv-events` queue in primary namespace
2. **Read**: Retrieve secret or certificate from `kv-mrkv-primary-01` using private endpoint
3. **Identify**: Determine if new version or expiry event
4. **Replicate**: Write secret or import certificate to `kv-mrkv-secondary-01` using private endpoint
5. **Log**: Record replication status in Function App logs
6. **Acknowledge**: Remove message from Service Bus queue

**Secondary Function Replication** (`func-mrkv-secondary-01`):

1. **Trigger**: Service Bus message from `kv-events` queue in secondary namespace (when deployed)
2. **Read**: Retrieve secret or certificate from `kv-mrkv-secondary-01`
3. **Replicate**: Write back to `kv-mrkv-primary-01` for fail-back scenario
4. **Acknowledge**: Process message completion

### Fail-back and bi-directional replication

The secondary region's Function App enables fail-back replication:

- **Scenario**: Primary region is degraded or offline
- **Action**: Updates to secondary Key Vault replicate back to primary
- **Benefit**: Maintains secret and certificate synchronization if primary recovers
- **Implementation**: Identical Service Bus queue and Function setup in secondary region

### Certificate replication

Certificates are replicated through the same event flow as secrets:

1. **Trigger**: `CertificateNewVersionCreated` event for the new version
2. **Check exportability**: Read the certificate policy; if the private key is not exportable, log a warning and complete the message without replicating
3. **Export**: Read the certificate's backing secret version, which contains the PFX (`application/x-pkcs12`) or PEM (`application/x-pem-file`) including the private key
4. **Import**: Call `import_certificate` on the other vault with the source policy, enabled state, and tags

The backing secret of a certificate also appears as a secret (`managed = true`). The Function skips managed secrets on the secret path so certificates are only replicated through the certificate path.

### Loop prevention

Every replicated version is tagged with `mrkv-replicated-from=<source vault name>`. When the destination vault emits its own new-version event, the Function reads the version, finds the tag, and skips it. Without this guard, each write would bounce between regions indefinitely.

The tag is only set on replicas. Versions created directly in either vault (by users or applications) do not carry it and are replicated normally.

### Certificate replication limitations

- **Non-exportable keys**: Certificates created with `exportable = false` cannot be replicated. The Function logs a warning and skips them.
- **Name collisions**: Import fails if the destination vault already has a plain secret with the certificate's name. The message is retried and then dead-lettered.
- **Issuers and contacts**: Certificate issuer configurations (for example, DigiCert or GlobalSign) and certificate contacts are not replicated. Configure them in each vault.
- **Auto-renewal**: The source policy, including lifetime actions, is imported with the certificate. Auto-renew can therefore run independently in each vault, and each renewal is replicated to the other vault.

### Dead-letter queue handling

Service Bus dead-letter queues handle failed replication:

- **Trigger**: Function unable to process message after max retries
- **Location**: `kv-events/$DeadLetterQueue` in each namespace
- **Monitoring**: Monitor dead-letter queue for replication errors; Terraform does not create alerts or dashboards for this automatically
- **Manual Retry**: Process dead-lettered messages once root cause is resolved

## Deployment Instructions

### Initialize Terraform

```powershell
terraform init
```

### Review deployment plan

```powershell
terraform plan -out=tfplan
```

### Apply configuration

```powershell
terraform apply tfplan
```

### Verify deployment

```powershell
terraform show
```

### Deploy Function code

The infrastructure creates the hosting resources, identity, RBAC, networking, and bindings. This final step is required because the Python package is not deployed by Terraform. The function code is in `replicatefunc/`, and the Service Bus trigger is defined in `replicatefunc/function.json`.

### Deploy Function code (Azure CLI) in PowerShell

Run from the repo root.

**Package the function app**:

```powershell
Compress-Archive -Path host.json,requirements.txt,replicatefunc -DestinationPath functionapp.zip -Force
```

**Deploy to primary region**:

```powershell
az functionapp deployment source config-zip `
  --resource-group rg-mrkv-primary `
  --name func-mrkv-primary-01 `
  --src functionapp.zip `
  --build-remote true

az functionapp restart `
  --resource-group rg-mrkv-primary `
  --name func-mrkv-primary-01
```

**Verify deployment**:

```powershell
az functionapp function list --resource-group rg-mrkv-primary --name func-mrkv-primary-01 --query "[].name"
```

If zip deployment fails with a 503 error, temporarily enable `public_network_access_enabled = true` for the deployment, then re-apply your security configuration afterward.

### Deploy Function code to secondary region

Deploy the same function code to the secondary region:

**Deploy to secondary region**:

```powershell
az functionapp deployment source config-zip `
  --resource-group rg-mrkv-secondary `
  --name func-mrkv-secondary-01 `
  --src functionapp.zip `
  --build-remote true

az functionapp restart `
  --resource-group rg-mrkv-secondary `
  --name func-mrkv-secondary-01
```

**Verify deployment**:

```powershell
az functionapp function list --resource-group rg-mrkv-secondary --name func-mrkv-secondary-01 --query "[].name"
```

Both functions are now deployed and ready to handle cross-region replication.

Terraform already creates the Event Grid System Topics, Event Grid subscriptions, and Service Bus queues. After code deployment, validate that these resources exist and that the Function package is processing messages.

### Verify file share creation

The Terraform uses `az storage share-rm create` through `null_resource` to create the Function file shares. Verify that both shares exist:

```powershell
az storage share-rm show `
  --storage-account samrkvprimaryfunc01 `
  --resource-group rg-mrkv-primary `
  --name func-mrkv-primary-share `
  --output table

az storage share-rm show `
  --storage-account samrkvsecondaryfunc01 `
  --resource-group rg-mrkv-secondary `
  --name func-mrkv-secondary-share `
  --output table
```

## MRKV Workload Verification

### Verify end-to-end replication [bash]

#### Primary to secondary

Update the secret in primary and verify it propagates to secondary:

```bash
# Update primary secret
az keyvault secret set \
  --vault-name kv-mrkv-primary-01 \
  --name test-p2s \
  --value "updated-value-$(date +%s)"

# Wait for replication
sleep 10

# Verify update in secondary
az keyvault secret show \
  --vault-name kv-mrkv-secondary-01 \
  --name test-p2s \
  --query "value" \
  --output tsv
```

#### Secondary to primary

Update the secret in secondary and verify it propagates back to primary:

```bash
# Update secondary secret
az keyvault secret set \
  --vault-name kv-mrkv-secondary-01 \
  --name test-s2p \
  --value "updated-value-$(date +%s)"

# Wait for replication
sleep 10

# Verify update in primary
az keyvault secret show \
  --vault-name kv-mrkv-primary-01 \
  --name test-s2p \
  --query "value" \
  --output tsv
```

#### Certificate primary to secondary

Create a self-signed certificate in primary and verify it propagates to secondary. The default policy produces an exportable PKCS12 certificate:

```bash
# Create certificate in primary
az keyvault certificate create \
  --vault-name kv-mrkv-primary-01 \
  --name test-cert-p2s \
  --policy "$(az keyvault certificate get-default-policy)"

# Certificate replication was observed to take 2-3 minutes; rerun the checks below if the copy is not there yet
sleep 180

# Thumbprints should match; the secondary copy carries the replication tag
az keyvault certificate show \
  --vault-name kv-mrkv-primary-01 \
  --name test-cert-p2s \
  --query "x509ThumbprintHex" \
  --output tsv

az keyvault certificate show \
  --vault-name kv-mrkv-secondary-01 \
  --name test-cert-p2s \
  --query "{thumbprint:x509ThumbprintHex, replicatedFrom:tags.\"mrkv-replicated-from\"}" \
  --output json

# Loop guard: each vault should have a single version
az keyvault certificate list-versions --vault-name kv-mrkv-primary-01 --name test-cert-p2s --query "length(@)"
az keyvault certificate list-versions --vault-name kv-mrkv-secondary-01 --name test-cert-p2s --query "length(@)"
```

#### Certificate secondary to primary

```bash
az keyvault certificate create \
  --vault-name kv-mrkv-secondary-01 \
  --name test-cert-s2p \
  --policy "$(az keyvault certificate get-default-policy)"

sleep 180

az keyvault certificate show \
  --vault-name kv-mrkv-primary-01 \
  --name test-cert-s2p \
  --query "{thumbprint:x509ThumbprintHex, replicatedFrom:tags.\"mrkv-replicated-from\"}" \
  --output json
```

## Troubleshooting and Validation

### Verify Function App configuration [bash]

These settings were needed during deployment so the Functions could start correctly after code deployment and authenticate without secrets.

#### Primary Function App

```bash
az functionapp config appsettings list \
  --resource-group rg-mrkv-primary \
  --name func-mrkv-primary-01 \
  --query "[?name=='PRIMARY_KEY_VAULT_URI' || name=='SECONDARY_KEY_VAULT_URI' || name=='PRIMARY_KEY_VAULT_NAME' || name=='SECONDARY_KEY_VAULT_NAME' || name=='ServiceBusConnection__fullyQualifiedNamespace' || name=='ServiceBusConnection__credential' || name=='AzureWebJobsStorage__accountName' || name=='AzureWebJobsStorage__credential' || name=='FUNCTIONS_WORKER_RUNTIME' || name=='WEBSITE_RUN_FROM_PACKAGE'].{name:name,value:value}" \
  --output table

az functionapp show \
  --resource-group rg-mrkv-primary \
  --name func-mrkv-primary-01 \
  --query "{subnet:virtualNetworkSubnetId,state:state,hostNames:enabledHostNames}" \
  --output json
```

#### Secondary Function App

```bash
az functionapp config appsettings list \
  --resource-group rg-mrkv-secondary \
  --name func-mrkv-secondary-01 \
  --query "[?name=='PRIMARY_KEY_VAULT_URI' || name=='SECONDARY_KEY_VAULT_URI' || name=='PRIMARY_KEY_VAULT_NAME' || name=='SECONDARY_KEY_VAULT_NAME' || name=='ServiceBusConnection__fullyQualifiedNamespace' || name=='ServiceBusConnection__credential' || name=='AzureWebJobsStorage__accountName' || name=='AzureWebJobsStorage__credential' || name=='FUNCTIONS_WORKER_RUNTIME' || name=='WEBSITE_RUN_FROM_PACKAGE'].{name:name,value:value}" \
  --output table

az functionapp show \
  --resource-group rg-mrkv-secondary \
  --name func-mrkv-secondary-01 \
  --query "{subnet:virtualNetworkSubnetId,state:state,hostNames:enabledHostNames}" \
  --output json
```

### Verify Function App public network access [bash]

This setting was needed during deployment because zip deploy uses the Function App SCM endpoint.

#### Primary Function App network access

```bash
az functionapp show \
  --resource-group rg-mrkv-primary \
  --name func-mrkv-primary-01 \
  --query "{publicNetworkAccess:publicNetworkAccess, httpsOnly:httpsOnly}" \
  --output table
```

#### Secondary Function App network access

```bash
az functionapp show \
  --resource-group rg-mrkv-secondary \
  --name func-mrkv-secondary-01 \
  --query "{publicNetworkAccess:publicNetworkAccess, httpsOnly:httpsOnly}" \
  --output table
```

### Verify storage RBAC configuration [bash]

This setting was needed during deployment because shared key access is disabled by policy and the Functions must use RBAC instead.

> [!NOTE]
> If RBAC verification returns no rows, wait 2 to 10 minutes for propagation and retry. Also confirm your signed-in identity has permission to read role assignments at the target scope (for example, Reader plus role-assignment read permissions).
> The commands below use `az rest` against the ARM roleAssignments endpoint. This avoids Azure CLI argument/version differences and the intermittent `az role assignment list` `Bad Request` behavior.
> The example queries below focus on the blob and file roles required for the Function storage path. Terraform also assigns `Storage Queue Data Contributor` to both Function identities.
> Expected role IDs in the output: `ba92f5b4-2d11-453d-a403-e96b0029c9fe` = Storage Blob Data Contributor, `0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb` = Storage File Data SMB Share Contributor.

#### Primary storage account RBAC

```bash
PRIMARY_FUNC_PRINCIPAL_ID=$(az functionapp identity show \
  --resource-group rg-mrkv-primary \
  --name func-mrkv-primary-01 \
  --query principalId -o tsv | tr -d '\r')

PRIMARY_STORAGE_ID=$(az storage account show \
  --resource-group rg-mrkv-primary \
  --name samrkvprimaryfunc01 \
  --query id -o tsv | tr -d '\r')

PRIMARY_ROLE_ASSIGNMENTS_URL="https://management.azure.com${PRIMARY_STORAGE_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"

az rest \
  --method get \
  --url "$PRIMARY_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$PRIMARY_FUNC_PRINCIPAL_ID' && (contains(properties.roleDefinitionId, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') || contains(properties.roleDefinitionId, '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'))].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table
```

#### Secondary storage account RBAC

```bash
SECONDARY_FUNC_PRINCIPAL_ID=$(az functionapp identity show \
  --resource-group rg-mrkv-secondary \
  --name func-mrkv-secondary-01 \
  --query principalId -o tsv | tr -d '\r')

SECONDARY_STORAGE_ID=$(az storage account show \
  --resource-group rg-mrkv-secondary \
  --name samrkvsecondaryfunc01 \
  --query id -o tsv | tr -d '\r')

SECONDARY_ROLE_ASSIGNMENTS_URL="https://management.azure.com${SECONDARY_STORAGE_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"

az rest \
  --method get \
  --url "$SECONDARY_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$SECONDARY_FUNC_PRINCIPAL_ID' && (contains(properties.roleDefinitionId, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe') || contains(properties.roleDefinitionId, '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'))].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table
```

### Verify storage account public network access [bash]

This setting remains enabled in the current Terraform because it avoids deployment and platform issues while private endpoints still provide the intended private data path.

#### Primary storage account network access

```bash
az storage account show \
  --resource-group rg-mrkv-primary \
  --name samrkvprimaryfunc01 \
  --query "{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, allowSharedKeyAccess:allowSharedKeyAccess}" \
  --output table
```

#### Secondary storage account network access

```bash
az storage account show \
  --resource-group rg-mrkv-secondary \
  --name samrkvsecondaryfunc01 \
  --query "{publicNetworkAccess:publicNetworkAccess, defaultAction:networkRuleSet.defaultAction, allowSharedKeyAccess:allowSharedKeyAccess}" \
  --output table
```

### Verify Key Vault RBAC assignments [bash]

These assignments were needed during deployment so the Functions could read and write secrets and certificates across both regions once the code was deployed.

> [!NOTE]
> Expected role IDs in the output: `b86a8fe4-44ce-4948-aee5-eccb2c155cd7` = Key Vault Secrets Officer, `a4417e6f-fecd-4de8-b567-7b0420556985` = Key Vault Certificates Officer.

#### Primary Function identity against both vaults

```bash
PRIMARY_FUNC_PRINCIPAL_ID=$(az functionapp identity show \
  --resource-group rg-mrkv-primary \
  --name func-mrkv-primary-01 \
  --query principalId -o tsv | tr -d '\r')

PRIMARY_VAULT_ID=$(az keyvault show \
  --resource-group rg-mrkv-primary \
  --name kv-mrkv-primary-01 \
  --query id -o tsv | tr -d '\r')

SECONDARY_VAULT_ID=$(az keyvault show \
  --resource-group rg-mrkv-secondary \
  --name kv-mrkv-secondary-01 \
  --query id -o tsv | tr -d '\r')

PRIMARY_VAULT_ROLE_ASSIGNMENTS_URL="https://management.azure.com${PRIMARY_VAULT_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
SECONDARY_VAULT_ROLE_ASSIGNMENTS_URL="https://management.azure.com${SECONDARY_VAULT_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"

az rest \
  --method get \
  --url "$PRIMARY_VAULT_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$PRIMARY_FUNC_PRINCIPAL_ID'].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table

az rest \
  --method get \
  --url "$SECONDARY_VAULT_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$PRIMARY_FUNC_PRINCIPAL_ID'].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table
```

#### Secondary Function identity against both vaults

```bash
SECONDARY_FUNC_PRINCIPAL_ID=$(az functionapp identity show \
  --resource-group rg-mrkv-secondary \
  --name func-mrkv-secondary-01 \
  --query principalId -o tsv | tr -d '\r')

PRIMARY_VAULT_ID=$(az keyvault show \
  --resource-group rg-mrkv-primary \
  --name kv-mrkv-primary-01 \
  --query id -o tsv | tr -d '\r')

SECONDARY_VAULT_ID=$(az keyvault show \
  --resource-group rg-mrkv-secondary \
  --name kv-mrkv-secondary-01 \
  --query id -o tsv | tr -d '\r')

PRIMARY_VAULT_ROLE_ASSIGNMENTS_URL="https://management.azure.com${PRIMARY_VAULT_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
SECONDARY_VAULT_ROLE_ASSIGNMENTS_URL="https://management.azure.com${SECONDARY_VAULT_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"

az rest \
  --method get \
  --url "$PRIMARY_VAULT_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$SECONDARY_FUNC_PRINCIPAL_ID'].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table

az rest \
  --method get \
  --url "$SECONDARY_VAULT_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$SECONDARY_FUNC_PRINCIPAL_ID'].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table
```

### Verify Key Vault private access path [bash]

This is the network dependency that mattered during deployment and runtime. The Functions rely on private endpoints and private DNS to reach both vaults over private IPs.

#### Primary region private endpoints

```bash
az network private-endpoint list \
  --resource-group rg-mrkv-primary \
  --query "[?contains(name, 'pe-kv')].{name:name,service:privateLinkServiceConnections[0].privateLinkServiceId,ip:customDnsConfigs[0].ipAddresses[0]}" \
  --output table
```

#### Secondary region private endpoints

```bash
az network private-endpoint list \
  --resource-group rg-mrkv-secondary \
  --query "[?contains(name, 'pe-kv')].{name:name,service:privateLinkServiceConnections[0].privateLinkServiceId,ip:customDnsConfigs[0].ipAddresses[0]}" \
  --output table
```

#### Key Vault private DNS A records

```bash
az network private-dns record-set a list \
  --resource-group rg-mrkv-primary \
  --zone-name privatelink.vaultcore.azure.net \
  --query "[].{name:name,ips:arecords[].ipv4Address}" \
  --output table

az network private-dns record-set a list \
  --resource-group rg-mrkv-secondary \
  --zone-name privatelink.vaultcore.azure.net \
  --query "[].{name:name,ips:arecords[].ipv4Address}" \
  --output table
```

### Verify Service Bus public network access [bash]

This setting remains enabled in the current Terraform. The deployment uses private endpoints for the VNet path, while keeping the namespace reachable for platform operations and avoiding setup issues.

#### Primary Service Bus namespace network access

```bash
az servicebus namespace show \
  --resource-group rg-mrkv-primary \
  --name sb-mrkv-primary-01 \
  --query "{publicNetworkAccess:publicNetworkAccess, sku:sku.name, capacity:sku.capacity, premiumPartitions:premiumMessagingPartitions}" \
  --output table
```

#### Secondary Service Bus namespace network access

```bash
az servicebus namespace show \
  --resource-group rg-mrkv-secondary \
  --name sb-mrkv-secondary-01 \
  --query "{publicNetworkAccess:publicNetworkAccess, sku:sku.name, capacity:sku.capacity, premiumPartitions:premiumMessagingPartitions}" \
  --output table
```

### Verify Service Bus RBAC assignments [bash]

These assignments were needed during deployment so the Functions could receive and complete queue-triggered messages in both regions.

#### Primary Function identity against both namespaces

```bash
PRIMARY_FUNC_PRINCIPAL_ID=$(az functionapp identity show \
  --resource-group rg-mrkv-primary \
  --name func-mrkv-primary-01 \
  --query principalId -o tsv | tr -d '\r')

PRIMARY_SB_ID=$(az servicebus namespace show \
  --resource-group rg-mrkv-primary \
  --name sb-mrkv-primary-01 \
  --query id -o tsv | tr -d '\r')

SECONDARY_SB_ID=$(az servicebus namespace show \
  --resource-group rg-mrkv-secondary \
  --name sb-mrkv-secondary-01 \
  --query id -o tsv | tr -d '\r')

PRIMARY_SB_ROLE_ASSIGNMENTS_URL="https://management.azure.com${PRIMARY_SB_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
SECONDARY_SB_ROLE_ASSIGNMENTS_URL="https://management.azure.com${SECONDARY_SB_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"

az rest \
  --method get \
  --url "$PRIMARY_SB_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$PRIMARY_FUNC_PRINCIPAL_ID'].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table

az rest \
  --method get \
  --url "$SECONDARY_SB_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$PRIMARY_FUNC_PRINCIPAL_ID'].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table
```

#### Secondary Function identity against both namespaces

```bash
SECONDARY_FUNC_PRINCIPAL_ID=$(az functionapp identity show \
  --resource-group rg-mrkv-secondary \
  --name func-mrkv-secondary-01 \
  --query principalId -o tsv | tr -d '\r')

PRIMARY_SB_ID=$(az servicebus namespace show \
  --resource-group rg-mrkv-primary \
  --name sb-mrkv-primary-01 \
  --query id -o tsv | tr -d '\r')

SECONDARY_SB_ID=$(az servicebus namespace show \
  --resource-group rg-mrkv-secondary \
  --name sb-mrkv-secondary-01 \
  --query id -o tsv | tr -d '\r')

PRIMARY_SB_ROLE_ASSIGNMENTS_URL="https://management.azure.com${PRIMARY_SB_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"
SECONDARY_SB_ROLE_ASSIGNMENTS_URL="https://management.azure.com${SECONDARY_SB_ID}/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01"

az rest \
  --method get \
  --url "$PRIMARY_SB_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$SECONDARY_FUNC_PRINCIPAL_ID'].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table

az rest \
  --method get \
  --url "$SECONDARY_SB_ROLE_ASSIGNMENTS_URL" \
  --query "value[?properties.principalId=='$SECONDARY_FUNC_PRINCIPAL_ID'].{principalId:properties.principalId,roleDefinitionId:properties.roleDefinitionId,scope:properties.scope}" \
  --output table
```

## Post-Deployment Configuration

After deploying the infrastructure, verify the settings that the deployment depends on.

### Why these settings matter

The deployment uses private endpoints for data-plane access, but several platform settings must still be present for provisioning, code deployment, or runtime startup:

1. **Function App configuration** is required so each Function can start with the correct Key Vault URIs, authenticate to Service Bus with managed identity, and use AzureWebJobsStorage without storage keys.
2. **Function App public network access** is intentionally enabled in this Terraform because zip deployment uses the SCM/Kudu endpoint. Without it, `az functionapp deployment source config-zip` can fail.
3. **Storage RBAC configuration** is required because shared key access is blocked by policy. The Function runtime and the manual file-share creation flow both depend on Microsoft Entra ID and RBAC.
4. **Storage account public network access** remains enabled in this deployment to avoid platform and provisioning issues during deployment. Data-plane access for the app still uses private endpoints and private DNS.
5. **Key Vault RBAC assignments** are required because both Functions must read from one vault and write to the other during replication. Secret replication uses `Key Vault Secrets Officer`; certificate import uses `Key Vault Certificates Officer`.
6. **Key Vault network path** matters because the app is designed to reach both vaults over private endpoints from each region. This is what preserves private east-west traffic during replication.
7. **Service Bus public network access** remains enabled in this deployment. The Function binds through managed identity, while private endpoints provide the private path from the VNets. Keeping public network access enabled also avoids breaking Service Bus namespace operations during setup.
8. **Function code deployment** is still a required post-deployment step. The infrastructure creates the hosting environment, but replication does not start until the Python package is deployed with remote build enabled.

### Hardening notes

The current Terraform favors easier deployment over full network lockdown. Before production, validate these tradeoffs and harden where appropriate:

1. **Enable Key Vault purge protection** and validate your recovery process.
2. **Review public network access** on Function Apps, Service Bus namespaces, storage accounts, and Key Vaults after confirming your private path and deployment workflow.
3. **Add Storage queue private endpoints and DNS** before disabling storage public network access. The current Terraform creates private endpoints for blob and file, but not queue.
4. **Reduce symmetric RBAC** if you want a stricter primary/secondary separation. The current Terraform grants both Functions write access to both vaults and sender/receiver rights on both namespaces.

## Testing

Use these commands to verify replication is working in both directions. Run them from WSL or a bash shell.

### Testing Prerequisites

The Key Vaults use RBAC-only authorization. Grant your CLI identity the `Key Vault Secrets Officer` and `Key Vault Certificates Officer` roles on both vaults before testing:

```bash
# Get your current user's object ID
USER_OBJECT_ID=$(az ad signed-in-user show --query id --output tsv)

PRIMARY_VAULT_ID=$(az keyvault show --name kv-mrkv-primary-01 --resource-group rg-mrkv-primary --query id --output tsv)
SECONDARY_VAULT_ID=$(az keyvault show --name kv-mrkv-secondary-01 --resource-group rg-mrkv-secondary --query id --output tsv)

for ROLE in "Key Vault Secrets Officer" "Key Vault Certificates Officer"; do
  az role assignment create --role "$ROLE" --assignee "$USER_OBJECT_ID" --scope "$PRIMARY_VAULT_ID"
  az role assignment create --role "$ROLE" --assignee "$USER_OBJECT_ID" --scope "$SECONDARY_VAULT_ID"
done
```

> [!NOTE]
> Role assignments can take 1–2 minutes to propagate. If you receive a 403 Forbidden error, wait and retry.
> [!NOTE]
> **Loop prevention**: Replicated versions are tagged `mrkv-replicated-from`, and the Function skips tagged versions, so each update produces one replica rather than bouncing between regions. See [Loop prevention](#loop-prevention).
> [!NOTE]
> `SecretNearExpiry`, `SecretExpired`, `CertificateNearExpiry`, and `CertificateExpired` events are routed to Service Bus by Terraform, but the current Function code only logs those events. No alerting, notification, or automated rotation workflow is included in this repo.

### Check Service Bus queue status

Monitor the Service Bus queues to ensure messages are being processed:

```bash
# Primary Service Bus queue
az servicebus queue show \
  --namespace-name sb-mrkv-primary-01 \
  --resource-group rg-mrkv-primary \
  --name kv-events \
  --query "{active:countDetails.activeMessageCount, deadLetter:countDetails.deadLetterMessageCount}"

# Secondary Service Bus queue
az servicebus queue show \
  --namespace-name sb-mrkv-secondary-01 \
  --resource-group rg-mrkv-secondary \
  --name kv-events \
  --query "{active:countDetails.activeMessageCount, deadLetter:countDetails.deadLetterMessageCount}"
```

If `active` is 0, messages are being processed successfully. If > 0, check Function App logs with `az webapp log tail` for processing errors.

### Check dead-letter queue

If replication is not working, check the dead-letter queue for failed messages:

```bash
# Primary dead-letter queue
az servicebus queue show \
  --namespace-name sb-mrkv-primary-01 \
  --resource-group rg-mrkv-primary \
  --name "kv-events/$DeadLetterQueue"

# Secondary dead-letter queue
az servicebus queue show \
  --namespace-name sb-mrkv-secondary-01 \
  --resource-group rg-mrkv-secondary \
  --name "kv-events/$DeadLetterQueue"
```

Dead-lettered messages indicate replication failures that require investigation.

## Operational workflow

### Normal operation (forward replication)

1. Secret or certificate created/updated in primary Key Vault (`kv-mrkv-primary-01`)
2. Event Grid System Topic emits event
3. Event routed to Service Bus queue (`sb-mrkv-primary-01`)
4. Function (`func-mrkv-primary-01`) triggered by queue message
5. Function reads the secret, or the certificate and its backing secret, from primary vault via private endpoint
6. Function writes the secret or imports the certificate into secondary vault (`kv-mrkv-secondary-01`) via private endpoint, tagged `mrkv-replicated-from`

### Fail-back operation (reverse replication)

1. Secret or certificate created/updated in secondary Key Vault (`kv-mrkv-secondary-01`)
2. Event Grid System Topic emits event (`evgt-kv-mrkv-secondary`)
3. Event routed to Service Bus queue (`sb-mrkv-secondary-01`)
4. Function (`func-mrkv-secondary-01`) triggered
5. Function replicates to primary vault via cross-region private endpoint

### Regional degradation scenarios

#### South Central US Degradation

- Sweden Central remains current as long as primary region can emit events
- Applications can fail over to secondary vault
- Cross-region private endpoints enable continued access

#### Sweden Central Degradation

- Primary region continues normal operations
- Replication may be delayed but will resume when secondary recovers
- Dead-letter queues capture failed replication attempts

#### Full Regional Outage

- If primary region experiences complete outage, Sweden Central vault remains available
- Applications can be redirected to use secondary vault
- Upon recovery, fail-back replication syncs Sweden → South Central US

## Resource Naming Conventions

This deployment follows a consistent naming pattern:

| Resource Type | Primary Name | Secondary Name |
| -------------- | -------------- | ---------------- |
| Resource Group | `rg-mrkv-primary` | `rg-mrkv-secondary` |
| Virtual Network | `vnet-mrkv-primary` | `vnet-mrkv-secondary` |
| Key Vault | `kv-mrkv-primary-01` | `kv-mrkv-secondary-01` |
| Service Bus | `sb-mrkv-primary-01` | `sb-mrkv-secondary-01` |
| Event Grid System Topic | `evgt-kv-mrkv-primary` | `evgt-kv-mrkv-secondary` |
| Function App | `func-mrkv-primary-01` | `func-mrkv-secondary-01` |
| Storage Account | `samrkvprimaryfunc01` | `samrkvsecondaryfunc01` |
| App Service Plan | `asp-mrkv-primary` | `asp-mrkv-secondary` |

## Monitoring and health

### Key metrics to track

- **Replication Lag**: Time between secret or certificate update and replication completion
- **Function Execution**: Success/failure rates, duration, exceptions
- **Service Bus**: Queue depth, dead-letter queue messages
- **Key Vault**: Request latency, throttling events, availability
- **Private Endpoints**: Connection status, DNS resolution times

### Recommended monitoring tools

- Azure Monitor for metrics and logs
- Application Insights for Function telemetry (optional; not provisioned by this Terraform configuration)
- Log Analytics for centralized log queries
- Azure Service Health for regional status

## Security and compliance

### Security features

- **Private connectivity for core data paths**: Private endpoints are provisioned for Key Vault, Service Bus, and storage blob/file services
- **Network isolation where configured**: Key Vault DNS uses manual A records and Service Bus/Storage use private DNS zone groups, while some public endpoints remain enabled in the current Terraform
- **Identity-Based Access**: Managed Identities with RBAC
- **Traffic Routing**: All Function traffic routed through VNet (`vnet_route_all_enabled`)

### Access control

- **Function Managed Identities** require:
  - `Key Vault Secrets Officer` RBAC roles for secret operations
  - `Key Vault Certificates Officer` RBAC roles for certificate import
  - Storage Blob Data Contributor role on storage accounts
  - Storage File Data SMB Share Contributor role on storage accounts
  - Storage Queue Data Contributor role on storage accounts
  - Service Bus Data Sender/Receiver roles for queue operations
- **Storage accounts** use:
  - RBAC authentication for Function App runtime operations
  - Shared key access disabled by policy
  - File shares created via ARM API (`az storage share-rm create`)
- **Private endpoints** enforce:
  - Network-level isolation for Key Vault and for storage blob/file access paths
  - DNS resolution through private zones

### Compliance considerations

- Cross-geography replication (US ↔ EU) may require compliance review
- Data residency requirements should be evaluated
- Purge protection currently disabled (enable for production)

## Cost optimization

### Billable resources

The constraints of this architecture require certain resource types that have associated costs. Key cost drivers include:

- **Function Apps**: EP1 Elastic Premium plan ($172/month each)
- **Service Bus**: Premium namespace ($680/month each)
- **Key Vaults**: Standard tier (pay per operation, 10,000 operations/month free)
- **Private Endpoints**: $7.30/month per endpoint
- **Storage Accounts**: Standard LRS
- **VNet**: No charge, but consider peering costs if needed

>[!NOTE]
>Costs based on Pay as You Go pricing as of June 2024. Actual costs may vary based on usage and region.

## Troubleshooting

### Common issues

#### Private Endpoint DNS Resolution

- Verify Key Vault private DNS zones are region-scoped (`kv_primary` linked to primary VNet, `kv_secondary` linked to secondary VNet)
- Check A records in each `privatelink.vaultcore.azure.net` zone
- Test DNS resolution from the Function App environment

#### Function Unable to Access Key Vault

- Confirm Managed Identity has `Key Vault Secrets Officer` role assignment
- For certificates, confirm Managed Identity also has `Key Vault Certificates Officer` on both vaults
- Verify Function is VNet integrated
- Check NSG rules on subnets
- Validate Private Endpoint connections

#### Storage Account 403 Errors

#### During Terraform deployment

- Set `storage_use_azuread = true` in provider configuration
- Verify storage accounts are RBAC-only (shared key access disabled by policy)
- Confirm the Function subnet has Microsoft.Storage service endpoint

#### During Function App runtime

- Verify Function Managed Identity has Storage Blob Data Contributor role
- Verify Function Managed Identity has Storage File Data SMB Share Contributor role
- Check that storage private endpoints are healthy and DNS resolves correctly
- Ensure RBAC roles are properly assigned for both Function managed identities

#### Replication Not Working

- Verify Event Grid subscription is configured
- Check Service Bus queue for messages
- Review Function logs via `az webapp log tail` or `az webapp log download`
- Validate cross-region private endpoints are healthy

#### Certificate Not Replicating

- Check Function logs for `private key is not exportable`; non-exportable certificates are skipped by design
- Check for a plain secret in the destination vault with the same name as the certificate; import fails on the name conflict
- Confirm the Event Grid subscriptions include the `Microsoft.KeyVault.Certificate*` event types
- If the destination copy exists but no new version appears, check whether the source version already carries the `mrkv-replicated-from` tag

## Terraform state management

The deployment uses local Terraform state by default. For team environments, use remote state:

```hcl
backend "azurerm" {
  resource_group_name  = "rg-terraform-state"
  storage_account_name = "sttfstate"
  container_name       = "tfstate"
  key                  = "keyvault-multiregion.tfstate"
  use_azuread_auth     = true
}
```

## Cleanup

To destroy all resources, run:

```bash
terraform destroy -auto-approve
```

> [!WARNING]
> This command permanently deletes all resources including Key Vaults. Back up secrets and certificates before proceeding.

## Summary

This Terraform deployment provides a production-ready foundation for:

- **Cross-region secret and certificate replication** with private connectivity
- **Business continuity** during regional degradation
- **Zero Trust networking** with Private Endpoints and VNet integration
- **Bi-directional replication** supporting fail-forward and fail-back
- **Flexible architecture** adaptable to other region pairs

The infrastructure is ready for Function code deployment and Event Grid configuration to enable automated secret and certificate replication.
