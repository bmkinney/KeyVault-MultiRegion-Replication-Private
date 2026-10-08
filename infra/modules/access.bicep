@description('Local vault name.')
param vaultName string

@description('Local Service Bus namespace name.')
param serviceBusName string

@description('Local storage account name.')
param storageName string

@description('Local Function system-assigned identity object ID.')
param localPrincipalId string

@description('Remote Function system-assigned identity object ID.')
param remotePrincipalId string

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
}

resource namespace 'Microsoft.ServiceBus/namespaces@2024-01-01' existing = {
  name: serviceBusName
}

resource queue 'Microsoft.ServiceBus/namespaces/queues@2024-01-01' existing = {
  parent: namespace
  name: 'kv-events'
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageName
}

var secretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
var secretsUser = '4633458b-17de-408a-b874-0445c86b69e6'
var busReceiver = '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
var busSender = '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
var storageRoles = [
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
]

resource localVaultAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, localPrincipalId, secretsOfficer)
  properties: {
    principalId: localPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficer)
  }
}

resource remoteVaultAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(vault.id, remotePrincipalId, secretsUser)
  properties: {
    principalId: remotePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsUser)
  }
}

resource receiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: queue
  name: guid(queue.id, localPrincipalId, busReceiver)
  properties: {
    principalId: localPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', busReceiver)
  }
}

resource sender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: queue
  name: guid(queue.id, remotePrincipalId, busSender)
  properties: {
    principalId: remotePrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', busSender)
  }
}

resource storageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for role in storageRoles: {
  scope: storage
  name: guid(storage.id, localPrincipalId, role)
  properties: {
    principalId: localPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', role)
  }
}]
