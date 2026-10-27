// Project 3 (azure-bicep-cicd-pipeline): the workload the pipeline deploys.
// Resource-group scope on purpose: the pipeline identities hold roles on one resource group each,
// never on the subscription.
// Every resource here is free: VNet, subnets, NSGs, route table.

import { subnetConfig } from 'types.bicep'

@description('Environment name. Selects the resource names; must match the resource group (rg-cicd-<env>).')
@allowed([
  'dev'
  'prod'
])
param environmentName string

@description('Azure region. Defaults to the resource group region.')
param location string = resourceGroup().location

@description('VNet address space. dev 10.40.0.0/16, prod 10.41.0.0/16 (no overlap with other portfolio labs).')
param addressSpace string

@description('Subnets and their NSG rules')
param subnets subnetConfig[]

@description('Address range dropped by the route table')
param blockedPrefix string = '10.99.0.0/16'

@description('Standard tags')
param tags object = {
  project: 'azure-bicep-cicd-pipeline'
  environment: environmentName
  owner: 'jeff'
  costCenter: 'CC-1001'
  managedBy: 'github-actions'
}

module network 'modules/vnet.bicep' = {
  name: 'network-${environmentName}'
  params: {
    environmentName: environmentName
    location: location
    tags: tags
    addressSpace: addressSpace
    subnets: subnets
    blockedPrefix: blockedPrefix
  }
}

output vnetName string = network.outputs.vnetName
output subnetNames array = network.outputs.subnetNames
