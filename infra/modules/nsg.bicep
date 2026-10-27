// Network security group built from a typed list of rules.
// The rule type is defined in types.bicep, so main.bicep and this module agree on the shape at compile time.

import { nsgRule } from '../types.bicep'

@description('NSG name')
param name string

@description('Azure region')
param location string

@description('Tags applied to the NSG')
param tags object

@description('Inbound rules. Priorities must be unique (100-4096).')
param rules nsgRule[]

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    securityRules: [
      for rule in rules: {
        name: rule.name
        properties: {
          priority: rule.priority
          direction: 'Inbound'
          access: rule.access
          protocol: rule.protocol
          sourceAddressPrefix: rule.sourceAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: rule.destinationAddressPrefix
          destinationPortRange: rule.destinationPortRange
        }
      }
    ]
  }
}

output id string = nsg.id
output name string = nsg.name
