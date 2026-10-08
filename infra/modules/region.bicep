@description('Regional identifier used in local resource names.')
@allowed([
  'primary'
  'secondary'
])
param regionName string

@description('Azure region.')
param location string

@description('Globally unique Key Vault name.')
param vaultName string

@description('Globally unique storage account name.')
param storageName string

@description('Globally unique Service Bus namespace name.')
param serviceBusName string

@description('VNet CIDR.')
param vnetPrefix string

@description('Delegated Function subnet CIDR.')
param functionSubnetPrefix string

@description('Private endpoint subnet CIDR.')
param endpointSubnetPrefix string

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-mrkv-${regionName}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetPrefix]
    }
    subnets: [
      {
        name: 'snet-function-${regionName}'
        properties: {
          addressPrefix: functionSubnetPrefix
          delegations: [
            {
              name: 'webapp-delegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
      {
        name: 'snet-private-endpoints-${regionName}'
        properties: {
          addressPrefix: endpointSubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

var zoneNames = [
  'privatelink.vaultcore.azure.net'
  'privatelink.servicebus.windows.net'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.queue.${environment().suffixes.storage}'
  'privatelink.table.${environment().suffixes.storage}'
  'privatelink.azurewebsites.net'
]

resource zones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for name in zoneNames: {
  name: name
  location: 'global'
}]

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (name, index) in zoneNames: {
  name: '${zones[index].name}/link-${index}-${regionName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}]

resource vaultResource 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    accessPolicies: []
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    publicNetworkAccess: 'Disabled'
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    defaultToOAuthAuthentication: true
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource containers 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = [for name in ['packages', 'replication-state']: {
  parent: blobs
  name: name
  properties: {
    publicAccess: 'None'
  }
}]

resource namespace 'Microsoft.ServiceBus/namespaces@2024-01-01' = {
  name: serviceBusName
  location: location
  sku: {
    name: 'Premium'
    tier: 'Premium'
    capacity: 1
  }
  properties: {
    premiumMessagingPartitions: 1
    publicNetworkAccess: 'Disabled'
    disableLocalAuth: true
    minimumTlsVersion: '1.2'
  }
}

resource rules 'Microsoft.ServiceBus/namespaces/networkRuleSets@2024-01-01' = {
  parent: namespace
  name: 'default'
  properties: {
    publicNetworkAccess: 'Disabled'
    defaultAction: 'Deny'
    trustedServiceAccessEnabled: false
    ipRules: []
    virtualNetworkRules: []
  }
}

resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' = {
  parent: namespace
  name: 'kv-events'
  properties: {
    enablePartitioning: false
    requiresDuplicateDetection: true
    duplicateDetectionHistoryTimeWindow: 'PT10M'
    lockDuration: 'PT1M'
    maxDeliveryCount: 10
    defaultMessageTimeToLive: 'P7D'
    deadLetteringOnMessageExpiration: true
  }
}

output functionSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-function-${regionName}')
output endpointSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.name, 'snet-private-endpoints-${regionName}')
output storageId string = storage.id
output vault object = {
  id: vaultResource.id
  name: vaultResource.name
  uri: vaultResource.properties.vaultUri
}
output serviceBus object = {
  id: namespace.id
  name: namespace.name
  host: '${namespace.name}.servicebus.windows.net'
}
