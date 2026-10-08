@description('Private endpoint name.')
param name string

@description('Private endpoint region, matching its VNet.')
param location string

@description('Private endpoint subnet resource ID.')
param subnetId string

@description('Target resource ID.')
param targetId string

@description('Private Link subresource group.')
param groupId string

@description('Optional zone ID for automatic registration. Empty for split-horizon manual records.')
param dnsZoneId string = ''

resource endpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: name
  location: location
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'psc-${name}'
        properties: {
          privateLinkServiceId: targetId
          groupIds: [groupId]
        }
      }
    ]
  }
}

resource zoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = if (!empty(dnsZoneId)) {
  parent: endpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: groupId
        properties: {
          privateDnsZoneId: dnsZoneId
        }
      }
    ]
  }
}

// A nested deployment resolves the Azure-assigned NIC after endpoint creation.
module address './private-endpoint-address.bicep' = {
  name: '${name}-address'
  params: {
    networkInterfaceId: endpoint.properties.networkInterfaces[0].id!
  }
}

output privateIp string = address.outputs.privateIp
