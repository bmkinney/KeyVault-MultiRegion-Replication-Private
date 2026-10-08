# Bicep Deployment README - Private Key Vault Secret Replication

Deploy the private-endpoint-only, managed-identity/RBAC implementation with [`main.bicep`](./main.bicep). This is the automated counterpart of the [Azure Portal deployment guide](../docs/azure-portal-deployment-guide.md). The repository [main README](../README.md#private-polling-architecture) contains the Mermaid architecture diagram.

The original `main.tf` and `replicatefunc/` are retained as a separate legacy reference. **Use `private-functions/` for this deployment.** Do not deploy the legacy Function package or assume this template adopts Terraform state.

Every service section includes its relevant source documentation. The appendix provides the complete source index for both deployment guides, including the API-version-pinned ARM/Bicep schemas used by the modules. The links reference upstream documentation; this appendix does not reproduce whole upstream documents.

## 1. Architecture and scope

The active region's timer discovers **latest readable secret versions** through its local Key Vault private endpoint. It sends version references, not values, to the opposite region's private Service Bus queue. The destination worker fetches the source version through a cross-region vault private endpoint and writes its local vault. Its private Blob account stores the package, Functions host data, checkpoints, and replication operation records.

Each VNet has private endpoints for both vaults, both Service Bus namespaces, local Blob/Queue/Table storage, and its Function App: **eight per region, 16 total**. Each resource group has six private DNS zones: **12 total**. PaaS services are not deployed inside the VNet; their private endpoint NICs are.

Event Grid cannot deliver through private endpoints, so the template has no Event Grid topics/subscriptions or trusted-service exception. There are no Azure Files shares, account keys, Service Bus local-auth credentials, or SAS package URLs. All workload data-plane services disable public access. ARM, operator authentication, platform management, and approved build-feed connectivity are separate from this private data-plane boundary.

The primary producer starts enabled and the secondary producer starts disabled. Both workers remain enabled. The loop/checkpoint logic is this repository's implementation, not a native Key Vault replication guarantee.

**Source documentation**

- [Event Grid managed identities and private delivery limitation](https://learn.microsoft.com/en-us/azure/event-grid/managed-service-identity#private-endpoints)
- [Event Grid private endpoints: system-topic limitations](https://learn.microsoft.com/en-us/azure/event-grid/configure-private-endpoints)
- [Azure private endpoint overview](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-overview)
- [Key Vault SecretClient SDK](https://learn.microsoft.com/en-us/python/api/azure-keyvault-secrets/azure.keyvault.secrets.secretclient)
- [ServiceBusClient SDK](https://learn.microsoft.com/en-us/python/api/azure-servicebus/azure.servicebus.servicebusclient)
- [Blob ContainerClient SDK](https://learn.microsoft.com/en-us/python/api/azure-storage-blob/azure.storage.blob.containerclient)
- [GitHub Mermaid diagrams](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams)

## 2. Prerequisites and migration safety

Use an Azure subscription with permission to deploy resources and assign roles. Register `Microsoft.Network`, `Microsoft.Storage`, `Microsoft.KeyVault`, `Microsoft.ServiceBus`, and `Microsoft.Web`. Confirm Linux Elastic Premium **EP1** and Service Bus Premium quota/availability in both chosen regions.

Install Azure CLI/Bicep for infrastructure deployment. Package building uses Python/pip, PowerShell, and a .NET SDK capable of building `net8.0`. Configure approved pip/NuGet feeds or mirrors. No runtime extension-bundle download or remote build is used.

Provide private deployment hosts with routing and DNS into the regional VNets. The template does not create a VPN, ExpressRoute circuit, jump host, or private DNS resolver. Ordinary Cloud Shell cannot reach the data endpoints without a separately configured private connection.

Prefer distinct resource groups and globally unique names for a new deployment. **Do not deploy over Terraform-managed resources without a reviewed migration plan.** Incremental Bicep deployments do not remove old Event Grid subscriptions or transfer Terraform state. Existing assignments can conflict with the new deterministic assignment names. Keep legacy workers/subscriptions disabled during cutover.

Key Vault purge protection is irreversible once enabled; the template uses 90-day retention. Two EP1 plans, two Premium Service Bus namespaces, and the private endpoints incur standing costs. Do not treat successful compilation as approval to deploy.

**Source documentation**

- [Install Bicep tooling](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install)
- [Subscription-scope deployments](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-subscription)
- [Azure resource naming rules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules)
- [Functions Premium plan](https://learn.microsoft.com/en-us/azure/azure-functions/functions-premium-plan)
- [Key Vault soft-delete and purge protection](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview)

## 3. Files, parameters, and deployment sequence

| File | Responsibility |
| --- | --- |
| `main.bicep` | Subscription orchestrator; creates two resource groups and coordinates regional modules |
| `main.bicepparam` | Example values; change global names, regions, CIDRs, package name, and active producer before deployment |
| `modules/region.bicep` | VNets/subnets, DNS zones/links, vault, storage/containers, Service Bus/queue |
| `modules/connectivity.bicep` | Local and cross-region data endpoints plus split-horizon vault/Service Bus A records |
| `modules/private-endpoint.bicep` | Private endpoint and optional DNS zone group |
| `modules/private-endpoint-address.bicep` | Resolves the Azure-created NIC IP after endpoint provisioning |
| `modules/function.bicep` | Linux EP1 app, private app endpoint, managed identity, and keyless app settings |
| `modules/access.bicep` | Resource/queue-scoped role assignments for the two app identities |
| `checkov.yaml` | Documented static-policy exceptions; not an assertion of production readiness |
| `../private-functions/` | Timer producer, Service Bus consumer, tests, and prebuilt package builder |

The default regions are `southcentralus` and `swedencentral`, matching Terraform. For East US/Central US, set `primaryLocation = 'eastus'` and `secondaryLocation = 'centralus'`, then verify service quota/availability. Region pairing is not required by the custom polling path.

Other settings to review:

| Parameter | Meaning |
| --- | --- |
| `primaryResourceGroupName`, `secondaryResourceGroupName` | Separate deployment groups |
| `primaryVaultName`, `secondaryVaultName` | Globally unique vault names |
| `primaryStorageName`, `secondaryStorageName` | Globally unique, lowercase-alphanumeric storage names |
| `primaryServiceBusName`, `secondaryServiceBusName` | Globally unique Premium namespaces |
| `primaryFunctionName`, `secondaryFunctionName` | Globally unique Function names |
| VNet/Function/endpoint CIDR parameters | Non-overlapping ranges consistent with your connected networks |
| `pollSchedule` | Six-field timer expression; default `0 */1 * * * *` |
| `activePollingRegion` | `primary` by default; change only after fencing the old writer |
| `packageBlobName` | Prebuilt package object in the `packages` container; prefer immutable release names |

Only explicitly overridden parameters need entries in `main.bicepparam`; other parameters retain their template defaults. Verify actual naming constraints and uniqueness through ARM validation/what-if, not just length decorators.

Deployment order is: core resources and DNS, data private endpoints, apps/identities, scoped RBAC, package upload, restart/trigger synchronization, and live private-network checks. The template creates containers but does not upload the package. Initial host startup may fail until package upload and RBAC propagation finish.

**Source documentation**

- [Bicep parameter files](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files)
- [Subscription deployment scopes and cross-resource-group modules](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-subscription)
- [Resource group schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.resources/2024-03-01/resourcegroups)
- [Resource naming constraints](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules)

## 4. Networking, private endpoints, and DNS

Each region has a delegated Function integration subnet and a separate private endpoint subnet. No service endpoints or VNet peering are created. Every private endpoint is located in the same region as its VNet; its target vault or Service Bus namespace may be in the other region.

Both VNets resolve both vaults and namespaces to **their own reachable endpoint NICs**. Separate, identically named vault/Service Bus DNS zones live in the two resource groups. Manual A records have TTL 10; do not automatically register both regions' endpoint IPs into one zone.

Local Blob/Queue/Table endpoints and Function app/SCM endpoints use zone groups. The six zones in each group are:

```text
privatelink.vaultcore.azure.net
privatelink.servicebus.windows.net
privatelink.blob.core.windows.net
privatelink.queue.core.windows.net
privatelink.table.core.windows.net
privatelink.azurewebsites.net
```

Each zone links only to its local VNet. Design routing/conditional forwarding separately for shared administrative hosts. Linking duplicate same-name zones into a hub without a resolver design can produce the wrong addresses or failed resolution.

**Source documentation**

- [Private endpoint DNS configuration and zone values](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)
- [VNet/subnet/delegation schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/virtualnetworks)
- [Private endpoint schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/privateendpoints)
- [Private endpoint DNS zone-group schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/privateendpoints/privatednszonegroups)
- [Private endpoint NIC schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2024-05-01/networkinterfaces)
- [Private DNS zone schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2020-06-01/privatednszones)
- [Private DNS VNet-link schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2020-06-01/privatednszones/virtualnetworklinks)
- [Private DNS A-record schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.network/2020-06-01/privatednszones/a)

## 5. Key Vault

The two Standard vaults use Azure RBAC, soft delete, 90-day retention, and purge protection. Public network access is disabled, the firewall defaults to deny, and bypass is explicitly **None**. Public-access disabling alone is not a reason to leave trusted-service bypass enabled.

The local app receives **Key Vault Secrets Officer** to poll/write its own vault. The remote app receives **Key Vault Secrets User** to read source versions. No certificate/key roles, deployment/disk-encryption bypass flags, or access policies are added.

The producer samples current readable secret versions; this is not a complete version-history mirror. Managed certificate secrets are skipped. Disabled, expired, and future-dated secrets are not copied; existing-version metadata changes and deletions are outside scope.

**Source documentation**

- [Key Vault network security](https://learn.microsoft.com/en-us/azure/key-vault/general/network-security)
- [Key Vault soft-delete and purge protection](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview)
- [Vault ARM/Bicep schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.keyvault/2023-07-01/vaults)
- [Key Vault built-in RBAC roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/security)
- [SecretClient version-read/list/write API](https://learn.microsoft.com/en-us/python/api/azure-keyvault-secrets/azure.keyvault.secrets.secretclient)

## 6. Storage and replication state

Each app uses its own Standard LRS StorageV2 account. Public access, anonymous Blob access, shared-key access, and trusted-service bypass are disabled; HTTPS/TLS 1.2 are required. Blob, Queue, and Table each have local private endpoints.

`packages` contains the immutable prebuilt application ZIP. `replication-state` contains observation checkpoints and operation/completion records. Secret values are not put in queue messages or state records; state fingerprints are kept private and are not exposed as vault tags. Protect state: unauthorized changes can defeat replay and loop prevention.

The local app receives host-storage roles on its own account. No cross-region storage access, Azure Files connection, storage key, or SAS URL is needed. LRS preserves the original regional host/state placement; it is not automatic geo-replication or an in-region HA guarantee.

**Source documentation**

- [Storage private endpoints](https://learn.microsoft.com/en-us/azure/storage/common/storage-private-endpoints)
- [Prevent Shared Key authorization](https://learn.microsoft.com/en-us/azure/storage/common/shared-key-authorization-prevent)
- [Storage account schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2023-05-01/storageaccounts)
- [Blob service schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2023-05-01/storageaccounts/blobservices)
- [Blob container schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.storage/2023-05-01/storageaccounts/blobservices/containers)
- [Storage RBAC roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/storage)
- [Blob ContainerClient API](https://learn.microsoft.com/en-us/python/api/azure-storage-blob/azure.storage.blob.containerclient)

## 7. Service Bus

Both namespaces use Premium with one messaging unit/partition. Public access, local authentication, service-endpoint allowances, and trusted-service bypass are disabled. Each queue receives a private endpoint path from both VNets.

`kv-events` disables partitioning, enables a 10-minute duplicate-detection window, uses seven-day TTL/one-minute locks, allows ten delivery attempts, and dead-letters expired messages. Producer message IDs are deterministic operation identifiers; duplicate detection is not an exactly-once guarantee.

The local app receives **Data Receiver** on its local queue. The opposite app receives **Data Sender** on that queue. The host renews processing locks during execution; failures are surfaced for retry/dead-letter handling.

**Source documentation**

- [Service Bus Private Link](https://learn.microsoft.com/en-us/azure/service-bus-messaging/private-link-service)
- [Duplicate detection](https://learn.microsoft.com/en-us/azure/service-bus-messaging/duplicate-detection)
- [Dead-letter queues](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dead-letter-queues)
- [Namespace schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.servicebus/2024-01-01/namespaces)
- [Queue schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.servicebus/2024-01-01/namespaces/queues)
- [Network-rule-set schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.servicebus/2024-01-01/namespaces/networkrulesets)
- [Service Bus RBAC roles](https://learn.microsoft.com/en-us/azure/role-based-access-control/built-in-roles/integration)
- [ServiceBusClient API](https://learn.microsoft.com/en-us/python/api/azure-servicebus/azure.servicebus.servicebusclient)

## 8. Functions, managed identity, and RBAC

The apps use Linux EP1/Python 3.11, system-assigned identities, outbound VNet integration/Route All, HTTPS/TLS 1.2, and HTTP/2. Public app access, FTPS, and SCM/FTP basic-auth publishing are disabled. Local app/SCM private DNS records come from the Function private endpoint's zone group.

`AzureWebJobsStorage__accountName` and `AzureWebJobsStorage__credential=managedidentity` configure keyless host storage. `WEBSITE_RUN_FROM_PACKAGE` is the private Blob URL; `WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID=SystemAssigned` authenticates package access.

The template deliberately omits `AzureWebJobsStorage`, `WEBSITE_CONTENTSHARE`, and `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`. Removing Azure Files is required for this keyless variant and may limit Elastic Premium scale-out. Benchmark before production.

| Target | Local app | Opposite app |
| --- | --- | --- |
| Local vault | Key Vault Secrets Officer | Key Vault Secrets User |
| Local queue | Service Bus Data Receiver | Service Bus Data Sender |
| Local storage | Blob Data Owner; Queue Data Contributor; Table Data Contributor | None |

The deployment identity needs control-plane deployment/role-assignment permissions. The package uploader additionally needs Blob Data Contributor on `packages`; operators need appropriate secret data roles for testing. Subscription Contributor/Owner alone does not grant secret data access.

**Source documentation**

- [Functions networking](https://learn.microsoft.com/en-us/azure/azure-functions/functions-networking-options)
- [Managed-identity connections and host RBAC](https://learn.microsoft.com/en-us/azure/azure-functions/manage-connections?pivots=functions-auth-identity&tabs=host)
- [Functions without Azure Files](https://learn.microsoft.com/en-us/azure/azure-functions/storage-considerations#create-an-app-without-azure-files)
- [Functions app settings](https://learn.microsoft.com/en-us/azure/azure-functions/functions-app-settings)
- [EP1 plan schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/serverfarms)
- [Function App/site schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/sites)
- [Basic publishing-credentials policy schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.web/2024-04-01/sites/basicpublishingcredentialspolicies)
- [Role assignment schema](https://learn.microsoft.com/en-us/azure/templates/microsoft.authorization/2022-04-01/roleassignments)
- [Assign roles in the Portal](https://learn.microsoft.com/en-us/azure/role-based-access-control/role-assignments-portal)

## 9. Build, preview, and deploy infrastructure

Run from the **repository root**, not this `infra` directory. Customize `infra/main.bicepparam` first.

```powershell
az login
az account set --subscription "<subscription-id>"

az bicep build --file .\infra\main.bicep
az bicep build-params --file .\infra\main.bicepparam

az deployment sub what-if --location southcentralus `
  --name mrkv-private-preview --parameters .\infra\main.bicepparam
```

Review changes, policies, quota, naming conflicts, migration risk, and cost. Only after approval:

```powershell
az deployment sub create --location southcentralus `
  --name mrkv-private --parameters .\infra\main.bicepparam
```

The command is **subscription-scoped**, because it creates two groups. Its `--location` is the deployment-record location, not an override for resource region parameters. Do not mix manual Portal and template management of the same deployment without understanding existing assignments/resources.

**Source documentation**

- [Deploy to subscription](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-subscription)
- [Bicep what-if](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-what-if)
- [Bicep parameter files](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/parameter-files)

## 10. Package, upload, restart, and synchronize

From the repository root:

```powershell
.\private-functions\build-package.ps1 -OutputFile .\functionapp.zip
```

The builder includes Linux/Python 3.11 dependencies and compiled Service Bus extension metadata in `bin/`. `host.json` does not request extension bundles at runtime. Dependencies are restored only during the build from approved feeds. Do not substitute the legacy ZIP or a source-only archive, and do not use remote builds or key-based SCM ZIP deployment.

After granting uploader RBAC and private host access, upload to each region from a host with that region's routing/DNS:

```powershell
az storage blob upload --account-name samrkvprimaryfunc --container-name packages `
  --name functionapp.zip --file .\functionapp.zip --auth-mode login --overwrite true
az storage blob upload --account-name samrkvsecondaryfunc --container-name packages `
  --name functionapp.zip --file .\functionapp.zip --auth-mode login --overwrite true
```

Wait for identity-role propagation, then restart and synchronize through ARM:

```powershell
foreach ($region in 'primary','secondary') {
  az functionapp restart -g "rg-mrkv-$region" -n "func-mrkv-$region"
  $id = az functionapp show -g "rg-mrkv-$region" -n "func-mrkv-$region" --query id -o tsv
  az rest --method post --url "https://management.azure.com$id/syncfunctiontriggers?api-version=2024-04-01"
  az functionapp function list -g "rg-mrkv-$region" -n "func-mrkv-$region" --query '[].name'
}
```

These examples use default names; substitute parameter overrides consistently. Expect `poll_secrets` and `replicate_secret`. For subsequent releases, prefer an immutable Blob name and update `packageBlobName`/the package setting before restart/synchronization.

**Source documentation**

- [Managed-identity access to an external Function package](https://learn.microsoft.com/en-us/azure/azure-functions/deployment-zip-push#fetch-a-package-from-azure-blob-storage-by-using-a-managed-identity)
- [Explicit binding extension installation](https://learn.microsoft.com/en-us/azure/azure-functions/functions-bindings-register#explicitly-install-extensions)
- [Azure Functions local development/Core Tools](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local)
- [Function app settings](https://learn.microsoft.com/en-us/azure/azure-functions/functions-app-settings)

## 11. Local and live validation

With private runtime requirements installed in an isolated environment:

```powershell
python -m venv .venv-review
.\.venv-review\Scripts\Activate.ps1
python -m pip install -r .\private-functions\requirements.txt
python -m pip install checkov
Push-Location .\private-functions
python -m unittest discover -s tests -v
Pop-Location
checkov --file .\infra\main.json --config-file .\infra\checkov.yaml
```

The preceding Bicep build produces `infra/main.json`. Checkov runs locally without policy downloads. Its configuration deliberately excludes trusted-service bypass, unresolved nested name expressions, and documented LRS/single-instance/non-HTTP policy tradeoffs. See the [Portal guide's exception table](../docs/azure-portal-deployment-guide.md#local-validation-and-policy-exceptions); this is not a blanket security certification.

For live checks, follow [Portal Phase 9](../docs/azure-portal-deployment-guide.md#phase-9---validate-private-networking-rbac-and-replication). From each VNet, verify both vault/namespace names and local storage/app/SCM names resolve to reachable private IPs. Authenticated data access from an unconnected external host must fail. Create a non-sensitive primary test secret, verify the secondary value, and confirm version counts stabilize.

Inspect queue/dead-letter metrics and errors without logging secret values. The template does not create private Application Insights/AMPLS or alerts; establish persistent private telemetry before production. Compilation and unit tests do not prove live identity propagation, private DNS, package startup, availability, or RPO.

**Source documentation**

- [Private DNS configuration](https://learn.microsoft.com/en-us/azure/private-link/private-endpoint-dns)
- [Service Bus dead-letter queue handling](https://learn.microsoft.com/en-us/azure/service-bus-messaging/service-bus-dead-letter-queues)
- [Checkov ARM scanning](https://www.checkov.io/7.Scan%20Examples/Azure%20ARM%20templates.html)
- [Checkov CLI configuration and check selection](https://www.checkov.io/2.Basics/CLI%20Command%20Reference.html)

## 12. Failover, limits, and recovery

Fence primary application writes before switching polling. Disable the old producer before enabling the other, and keep `activePollingRegion` aligned with the operational choice before future deployments.

```powershell
az functionapp config appsettings set -g rg-mrkv-primary -n func-mrkv-primary `
  --settings 'AzureWebJobs.poll_secrets.Disabled=true'
az functionapp config appsettings set -g rg-mrkv-secondary -n func-mrkv-secondary `
  --settings 'AzureWebJobs.poll_secrets.Disabled=false'
```

This is not an atomic application failover. Reconcile values and fence writers again before failback. RPO is the polling interval **plus** queue/processing latency; intermediate versions may be missed. Source availability is required while queued references are fetched. Retry processing is at-least-once; competing writers are not conflict-resolved.

Do not delete state as routine cleanup. Restore/reconcile operation state deliberately after loss, and investigate DLQ errors before replay. Disabled/expired secrets, certificate-managed secrets, certificates, keys, metadata-only changes, and deletions need separate handling. Customer-managed keys and non-exportable certificates require their own DR decisions; this template does not provision them.

Deleting resource groups is a separate approved operator action. Purge-protected vaults cannot be immediately purged/reused. Bicep and Terraform do not automatically clean up each other's exclusive resources.

**Source documentation**

- [Key Vault reliability](https://learn.microsoft.com/en-us/azure/reliability/reliability-key-vault)
- [Key Vault backup/restore restrictions](https://learn.microsoft.com/en-us/azure/key-vault/general/backup)
- [Key Vault certificate model/exportability](https://learn.microsoft.com/en-us/azure/key-vault/certificates/about-certificates)
- [Key Vault BYOK specification](https://learn.microsoft.com/en-us/azure/key-vault/keys/byok-specification)
- [Azure encryption at rest and key management](https://learn.microsoft.com/en-us/azure/security/fundamentals/encryption-atrest)
- [Soft-delete/purge protection](https://learn.microsoft.com/en-us/azure/key-vault/general/soft-delete-overview)
- Repository analysis: [Key Vault DR gap analysis](../docs/keyvault-dr-gap-analysis.md)

## Appendix - Source documentation

This complete catalog covers the Bicep and Portal guides. Conceptual pages explain platform behavior; version-pinned schemas document resource properties. Custom polling/checkpoint behavior is defined by [`private-functions/replication.py`](../private-functions/replication.py) and its tests, not guaranteed by these service documents.

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
