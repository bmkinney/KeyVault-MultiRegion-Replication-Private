@description('Regional identifier.')
param regionName string

@description('Azure region.')
param location string

@description('Globally unique Function App name.')
param functionName string

@description('Delegated VNet integration subnet ID.')
param functionSubnetId string

@description('Private endpoint subnet ID.')
param endpointSubnetId string

@description('Local vault URI, polled and written by this app.')
param localVaultUri string

@description('Remote vault URI, read by the replication worker.')
param remoteVaultUri string

@description('Local Service Bus namespace hostname, used by the worker.')
param localServiceBusHost string

@description('Remote Service Bus namespace hostname, used by the polling producer.')
param remoteServiceBusHost string

@description('Local private storage account name.')
param storageName string

@description('Six-field polling schedule.')
param pollSchedule string

@description('Whether the polling producer is active. The Service Bus worker remains enabled.')
param pollingEnabled bool

@description('Prebuilt package blob name, without SAS credentials.')
param packageBlobName string

var packageUri = 'https://${storageName}.blob.${environment().suffixes.storage}/packages/${packageBlobName}'

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-mrkv-${regionName}'
  location: location
  kind: 'linux'
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource app 'Microsoft.Web/sites@2024-04-01' = {
  name: functionName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    virtualNetworkSubnetId: functionSubnetId
    publicNetworkAccess: 'Disabled'
    httpsOnly: true
    vnetRouteAllEnabled: true
    siteConfig: {
      linuxFxVersion: 'Python|3.11'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      http20Enabled: true
      functionsRuntimeScaleMonitoringEnabled: true
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'AzureWebJobsFeatureFlags', value: 'EnableWorkerIndexing' }
        { name: 'AzureWebJobsStorage__accountName', value: storageName }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: packageUri }
        { name: 'WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID', value: 'SystemAssigned' }
        { name: 'LOCAL_KEY_VAULT_URI', value: localVaultUri }
        { name: 'REMOTE_KEY_VAULT_URI', value: remoteVaultUri }
        { name: 'DESTINATION_SERVICE_BUS_NAMESPACE', value: remoteServiceBusHost }
        { name: 'ServiceBusConnection__fullyQualifiedNamespace', value: localServiceBusHost }
        { name: 'ServiceBusConnection__credential', value: 'managedidentity' }
        { name: 'REPLICATION_STATE_STORAGE_URI', value: 'https://${storageName}.blob.${environment().suffixes.storage}' }
        { name: 'ReplicationPollSchedule', value: pollSchedule }
        { name: 'AzureWebJobs.poll_secrets.Disabled', value: string(!pollingEnabled) }
      ]
    }
  }
}

resource ftpPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: app
  name: 'scm'
  properties: {
    allow: false
  }
}

module endpoint './private-endpoint.bicep' = {
  name: 'mrkv-${regionName}-function-pe'
  params: {
    name: 'pe-func-${regionName}'
    location: location
    subnetId: endpointSubnetId
    targetId: app.id
    groupId: 'sites'
    dnsZoneId: resourceId('Microsoft.Network/privateDnsZones', 'privatelink.azurewebsites.net')
  }
}

output principalId string = app.identity.principalId
output functionId string = app.id
output packageUri string = packageUri
