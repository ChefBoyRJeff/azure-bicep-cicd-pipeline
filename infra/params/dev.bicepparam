// dev environment. Committed on purpose: holds no secrets, only the network design.
using '../main.bicep'

param environmentName = 'dev'
param addressSpace = '10.40.0.0/16'

param subnets = [
  {
    name: 'snet-app'
    addressPrefix: '10.40.1.0/24'
    nsgRules: [
      {
        name: 'Allow-HTTPS-From-VNet'
        priority: 100
        access: 'Allow'
        protocol: 'Tcp'
        sourceAddressPrefix: 'VirtualNetwork'
        destinationAddressPrefix: '10.40.1.0/24'
        destinationPortRange: '443'
      }
      {
        name: 'Deny-VNet-Inbound'
        priority: 4000
        access: 'Deny'
        protocol: '*'
        sourceAddressPrefix: 'VirtualNetwork'
        destinationAddressPrefix: '*'
        destinationPortRange: '*'
      }
    ]
  }
  {
    name: 'snet-data'
    addressPrefix: '10.40.1.0/24'    // was 10.40.2.0/24: copy-paste error (M4b, deliberate)
    nsgRules: [
      {
        name: 'Allow-SQL-From-App'
        priority: 100
        access: 'Allow'
        protocol: 'Tcp'
        sourceAddressPrefix: '10.40.1.0/24'
        destinationAddressPrefix: '10.40.2.0/24'
        destinationPortRange: '1433'
      }
      {
        name: 'Deny-VNet-Inbound'
        priority: 4000
        access: 'Deny'
        protocol: '*'
        sourceAddressPrefix: 'VirtualNetwork'
        destinationAddressPrefix: '*'
        destinationPortRange: '*'
      }
    ]
  }
]
