@description('Regional identifier.')
param regionName string

@description('Local Azure region.')
param location string

@description('Local private endpoint subnet ID.')
param endpointSubnetId string

@description('Primary vault ID, name, and URI.')
param primaryVault object

@description('Secondary vault ID, name, and URI.')
param secondaryVault object

@description('Primary Service Bus ID, name, and hostname.')
param primaryServiceBus object

@description('Secondary Service Bus ID, name, and hostname.')
param secondaryServiceBus object

@description('Local Function storage account ID.')
param storageId string

var definitions = [
  {
    name: regionName == 'primary' ? 'pe-kv-primary' : 'pe-kv-primary-remote'
    id: primaryVault.id
    groupId: 'vault'
    zoneId: ''
  }
  {
    name: regionName == 'secondary' ? 'pe-kv-secondary' : 'pe-kv-secondary-remote'
    id: secondaryVault.id
    groupId: 'vault'
    zoneId: ''
  }
  {
    name: regionName == 'primary' ? 'pe-sb-primary' : 'pe-sb-primary-remote'
    id: primaryServiceBus.id
    groupId: 'namespace'
    zoneId: ''
  }
  {
    name: regionName == 'secondary' ? 'pe-sb-secondary' : 'pe-sb-secondary-remote'
    id: secondaryServiceBus.id
    groupId: 'namespace'
    zoneId: ''
  }
  {
    name: 'pe-stmrkv-${regionName}-blob'
    id: storageId
    groupId: 'blob'
    zoneId: resourceId('Microsoft.Network/privateDnsZones', 'privatelink.blob.${environment().suffixes.storage}')
  }
  {
    name: 'pe-stmrkv-${regionName}-queue'
    id: storageId
    groupId: 'queue'
    zoneId: resourceId('Microsoft.Network/privateDnsZones', 'privatelink.queue.${environment().suffixes.storage}')
  }
  {
    name: 'pe-stmrkv-${regionName}-table'
    id: storageId
    groupId: 'table'
    zoneId: resourceId('Microsoft.Network/privateDnsZones', 'privatelink.table.${environment().suffixes.storage}')
  }
]

module endpoints './private-endpoint.bicep' = [for (definition, index) in definitions: {
  name: 'mrkv-${regionName}-pe-${index}'
  params: {
    name: definition.name
    location: location
    subnetId: endpointSubnetId
    targetId: definition.id
    groupId: definition.groupId
    dnsZoneId: definition.zoneId
  }
}]

resource vaultZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.vaultcore.azure.net'
}

resource busZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: 'privatelink.servicebus.windows.net'
}

resource vaultRecords 'Microsoft.Network/privateDnsZones/A@2020-06-01' = [for (name, index) in [primaryVault.name, secondaryVault.name]: {
  parent: vaultZone
  name: name
  properties: {
    ttl: 10
    aRecords: [
      {
        ipv4Address: endpoints[index].outputs.privateIp
      }
    ]
  }
}]

resource busRecords 'Microsoft.Network/privateDnsZones/A@2020-06-01' = [for (name, index) in [primaryServiceBus.name, secondaryServiceBus.name]: {
  parent: busZone
  name: name
  properties: {
    ttl: 10
    aRecords: [
      {
        ipv4Address: endpoints[index + 2].outputs.privateIp
      }
    ]
  }
}]
