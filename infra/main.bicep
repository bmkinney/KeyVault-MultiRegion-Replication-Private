targetScope = 'subscription'

@description('Primary Azure region. Defaults match the original Terraform.')
param primaryLocation string = 'southcentralus'

@description('Secondary Azure region.')
param secondaryLocation string = 'swedencentral'

@description('Primary resource group name.')
param primaryResourceGroupName string = 'rg-mrkv-primary'

@description('Secondary resource group name.')
param secondaryResourceGroupName string = 'rg-mrkv-secondary'

@description('Primary Key Vault name; must be globally unique.')
@minLength(3)
@maxLength(24)
param primaryVaultName string = 'kv-mrkv-primary'

@description('Secondary Key Vault name; must be globally unique.')
@minLength(3)
@maxLength(24)
param secondaryVaultName string = 'kv-mrkv-secondary'

@description('Primary storage account name; globally unique, lowercase alphanumeric.')
@minLength(3)
@maxLength(24)
param primaryStorageName string = 'samrkvprimaryfunc'

@description('Secondary storage account name; globally unique, lowercase alphanumeric.')
@minLength(3)
@maxLength(24)
param secondaryStorageName string = 'samrkvsecondaryfunc'

@description('Primary Premium Service Bus namespace name; globally unique.')
@minLength(6)
@maxLength(50)
param primaryServiceBusName string = 'sb-mrkv-primary'

@description('Secondary Premium Service Bus namespace name; globally unique.')
@minLength(6)
@maxLength(50)
param secondaryServiceBusName string = 'sb-mrkv-secondary'

@description('Primary Function App name; globally unique.')
@minLength(2)
@maxLength(60)
param primaryFunctionName string = 'func-mrkv-primary'

@description('Secondary Function App name; globally unique.')
@minLength(2)
@maxLength(60)
param secondaryFunctionName string = 'func-mrkv-secondary'

@description('Primary VNet CIDR.')
param primaryVnetPrefix string = '10.35.0.0/16'

@description('Primary delegated Function subnet CIDR.')
param primaryFunctionSubnetPrefix string = '10.35.1.0/24'

@description('Primary private endpoint subnet CIDR.')
param primaryEndpointSubnetPrefix string = '10.35.0.0/24'

@description('Secondary VNet CIDR.')
param secondaryVnetPrefix string = '10.36.0.0/16'

@description('Secondary delegated Function subnet CIDR.')
param secondaryFunctionSubnetPrefix string = '10.36.1.0/24'

@description('Secondary private endpoint subnet CIDR.')
param secondaryEndpointSubnetPrefix string = '10.36.0.0/24'

@description('Six-field timer schedule. Latest versions are sampled, not every intermediate version.')
param pollSchedule string = '0 */1 * * * *'

@description('Single active polling region. Fence writes and disable the old producer before changing during failover.')
@allowed([
  'primary'
  'secondary'
])
param activePollingRegion string = 'primary'

@description('Prebuilt Linux/Python 3.11 package uploaded to the private packages container after infrastructure deployment.')
param packageBlobName string = 'functionapp.zip'

resource primaryGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: primaryResourceGroupName
  location: primaryLocation
}

resource secondaryGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: secondaryResourceGroupName
  location: secondaryLocation
}

module primary './modules/region.bicep' = {
  name: 'mrkv-primary-core'
  scope: primaryGroup
  params: {
    regionName: 'primary'
    location: primaryLocation
    vaultName: primaryVaultName
    storageName: primaryStorageName
    serviceBusName: primaryServiceBusName
    vnetPrefix: primaryVnetPrefix
    functionSubnetPrefix: primaryFunctionSubnetPrefix
    endpointSubnetPrefix: primaryEndpointSubnetPrefix
  }
}

module secondary './modules/region.bicep' = {
  name: 'mrkv-secondary-core'
  scope: secondaryGroup
  params: {
    regionName: 'secondary'
    location: secondaryLocation
    vaultName: secondaryVaultName
    storageName: secondaryStorageName
    serviceBusName: secondaryServiceBusName
    vnetPrefix: secondaryVnetPrefix
    functionSubnetPrefix: secondaryFunctionSubnetPrefix
    endpointSubnetPrefix: secondaryEndpointSubnetPrefix
  }
}

module primaryNetwork './modules/connectivity.bicep' = {
  name: 'mrkv-primary-connectivity'
  scope: primaryGroup
  params: {
    regionName: 'primary'
    location: primaryLocation
    endpointSubnetId: primary.outputs.endpointSubnetId
    primaryVault: primary.outputs.vault
    secondaryVault: secondary.outputs.vault
    primaryServiceBus: primary.outputs.serviceBus
    secondaryServiceBus: secondary.outputs.serviceBus
    storageId: primary.outputs.storageId
  }
}

module secondaryNetwork './modules/connectivity.bicep' = {
  name: 'mrkv-secondary-connectivity'
  scope: secondaryGroup
  params: {
    regionName: 'secondary'
    location: secondaryLocation
    endpointSubnetId: secondary.outputs.endpointSubnetId
    primaryVault: primary.outputs.vault
    secondaryVault: secondary.outputs.vault
    primaryServiceBus: primary.outputs.serviceBus
    secondaryServiceBus: secondary.outputs.serviceBus
    storageId: secondary.outputs.storageId
  }
}

module primaryApp './modules/function.bicep' = {
  name: 'mrkv-primary-function'
  scope: primaryGroup
  params: {
    regionName: 'primary'
    location: primaryLocation
    functionName: primaryFunctionName
    functionSubnetId: primary.outputs.functionSubnetId
    endpointSubnetId: primary.outputs.endpointSubnetId
    localVaultUri: primary.outputs.vault.uri
    remoteVaultUri: secondary.outputs.vault.uri
    localServiceBusHost: primary.outputs.serviceBus.host
    remoteServiceBusHost: secondary.outputs.serviceBus.host
    storageName: primaryStorageName
    pollSchedule: pollSchedule
    pollingEnabled: activePollingRegion == 'primary'
    packageBlobName: packageBlobName
  }
  dependsOn: [
    primaryNetwork
  ]
}

module secondaryApp './modules/function.bicep' = {
  name: 'mrkv-secondary-function'
  scope: secondaryGroup
  params: {
    regionName: 'secondary'
    location: secondaryLocation
    functionName: secondaryFunctionName
    functionSubnetId: secondary.outputs.functionSubnetId
    endpointSubnetId: secondary.outputs.endpointSubnetId
    localVaultUri: secondary.outputs.vault.uri
    remoteVaultUri: primary.outputs.vault.uri
    localServiceBusHost: secondary.outputs.serviceBus.host
    remoteServiceBusHost: primary.outputs.serviceBus.host
    storageName: secondaryStorageName
    pollSchedule: pollSchedule
    pollingEnabled: activePollingRegion == 'secondary'
    packageBlobName: packageBlobName
  }
  dependsOn: [
    secondaryNetwork
  ]
}

module primaryAccess './modules/access.bicep' = {
  name: 'mrkv-primary-access'
  scope: primaryGroup
  params: {
    vaultName: primaryVaultName
    serviceBusName: primaryServiceBusName
    storageName: primaryStorageName
    localPrincipalId: primaryApp.outputs.principalId
    remotePrincipalId: secondaryApp.outputs.principalId
  }
}

module secondaryAccess './modules/access.bicep' = {
  name: 'mrkv-secondary-access'
  scope: secondaryGroup
  params: {
    vaultName: secondaryVaultName
    serviceBusName: secondaryServiceBusName
    storageName: secondaryStorageName
    localPrincipalId: secondaryApp.outputs.principalId
    remotePrincipalId: primaryApp.outputs.principalId
  }
}

output primaryFunctionId string = primaryApp.outputs.functionId
output secondaryFunctionId string = secondaryApp.outputs.functionId
output primaryPackageUri string = primaryApp.outputs.packageUri
output secondaryPackageUri string = secondaryApp.outputs.packageUri
