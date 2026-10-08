@description('Network interface ID assigned by Azure to an already-provisioned private endpoint.')
param networkInterfaceId string

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' existing = {
  name: last(split(networkInterfaceId, '/'))
}

output privateIp string = nic.properties.ipConfigurations[0].properties.privateIPAddress!
