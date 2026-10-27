// Shared user-defined types. A parameter file that doesn't match these shapes fails at build time,
// before anything reaches Azure (cheapest place to catch a mistake).

@export()
@description('One inbound NSG rule')
type nsgRule = {
  @minLength(1)
  @maxLength(80)
  name: string

  @minValue(100)
  @maxValue(4096)
  priority: int

  access: 'Allow' | 'Deny'

  protocol: 'Tcp' | 'Udp' | 'Icmp' | '*'

  @description('CIDR or service tag, for example 10.40.1.0/24 or VirtualNetwork')
  sourceAddressPrefix: string

  destinationAddressPrefix: string

  @description('Single port, range (1000-2000), or *')
  destinationPortRange: string
}

@export()
@description('One subnet and the NSG rules that protect it')
type subnetConfig = {
  @minLength(1)
  @maxLength(80)
  name: string

  @description('Subnet CIDR. Must fall inside the VNet address space and not overlap another subnet.')
  addressPrefix: string

  nsgRules: nsgRule[]
}
