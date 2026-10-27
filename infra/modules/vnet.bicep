// Virtual network with one NSG per subnet and a shared route table.

import { subnetConfig } from '../types.bicep'

@description('Environment name, used in resource names')
param environmentName string

@description('Azure region')
param location string

@description('Tags applied to every resource')
param tags object

@description('VNet address space (CIDR)')
param addressSpace string

@description('Subnets to create')
@minLength(1)
param subnets subnetConfig[]

@description('Address range with no route (traffic to it is dropped). Simulates a blocked network.')
param blockedPrefix string

// One NSG per subnet, so each tier has its own rules.
module subnetNsgs 'nsg.bicep' = [
  for subnet in subnets: {
    name: 'nsg-${environmentName}-${subnet.name}'
    params: {
      name: 'nsg-${environmentName}-${subnet.name}'
      location: location
      tags: tags
      rules: subnet.nsgRules
    }
  }
]

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: 'rt-${environmentName}-workload'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        // nextHopType None drops the traffic: a free way to show a user-defined route taking effect.
        name: 'Drop-Blocked-Range'
        properties: {
          addressPrefix: blockedPrefix
          nextHopType: 'None'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${environmentName}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        addressSpace
      ]
    }
    subnets: [
      for (subnet, i) in subnets: {
        name: subnet.name
        properties: {
          addressPrefix: subnet.addressPrefix
          networkSecurityGroup: {
            id: subnetNsgs[i].outputs.id
          }
          routeTable: {
            id: routeTable.id
          }
        }
      }
    ]
  }
}

output vnetName string = vnet.name
output subnetNames array = [for subnet in subnets: subnet.name]
