metadata description = 'Pattern template for deploying a web application using Azure Container Apps backed by Azure Cosmos DB.'

import { secretType, environmentVarType } from 'br/public:avm/res/app/container-app:0.14.1'

@description('The primary location for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('The tags to apply to the resources. Defaults to an empty object.')
param tags object = {}

@minLength(5)
@maxLength(19)
@description('The name of the suffix that is used as part of naming resource convention. Only alphanumeric characters and hyphens are allowed.')
param nameSuffix string

@description('The principal ID of the deployment identity used to deploy the resources. Defaults to the identity of the deployment principal.')
param deploymentPrincipalId string = deployer().objectId

@description('The unique identifier for the service. Defaults to "app".')
param webServiceName string = 'app'

@description('The target port for the service. Defaults to 80.')
param webTargetPort int = 80

@description('The container image for the service. Defaults to "nginx:latest".')
param webContainerImage string = 'nginx:latest'

@allowed([
  'nosql'
  'mongodb-ru'
  'mongodb-vcore'
  'table'
])
@description('The type of database to use. Defaults to "nosql".')
param databaseType string = 'nosql'

@description('The name of the database. Defaults to "demo".')
param databaseName string = 'demo'

@description('The name of the container. Defaults to "example".')
param databaseContainerName string = 'example'

@description('The partition key path for the container. Defaults to "/id".')
param databasePartitionKeyPath string = '/id'

@description('The list of environment variables for the service. Defaults to an empty array.')
param webEnvironmentVariables environmentVarType[] = []

@description('The administrator login for the database. Defaults to "app".')
param mongoAdminLogin string = 'app'

@secure()
@description('The administrator password for the database. Defaults to a random GUID.')
param mongoAdminPassword string = newGuid()

module managedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'user-assigned-managed-identity'
  params: {
    name: 'id${nameSuffix}'
    location: location
    tags: tags
  }
}

module keyVault 'br/public:avm/res/key-vault/vault:0.12.1' = if (databaseType == 'mongodb-ru' || databaseType == 'mongodb-vcore') {
  name: 'key-vault'
  params: {
    name: 'kv${nameSuffix}'
    location: location
    tags: tags
    enablePurgeProtection: false
    enableRbacAuthorization: true
    publicNetworkAccess: 'Enabled'
    softDeleteRetentionInDays: 7
    roleAssignments: [
      {
        principalId: managedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User
      }
      {
        principalId: deploymentPrincipalId
        principalType: 'User'
        roleDefinitionIdOrName: 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' // Key Vault Secrets Officer
      }
    ]
    secrets: databaseType == 'mongodb-vcore'
      ? [
          {
            name: 'azure-cosmos-db-connection-string'
            value: replace(
              replace(cosmosMongoCluster.outputs.connectionStringKey, '<user>', mongoAdminLogin),
              '<password>',
              mongoAdminPassword
            )
          }
        ]
      : []
  }
}

module cosmosMongoCluster 'br/public:avm/res/document-db/mongo-cluster:0.1.1' = if (databaseType == 'mongodb-vcore') {
  name: 'cosmos-db-mongodb-vcore-account'
  params: {
    name: 'cosmnv${nameSuffix}'
    location: location
    tags: tags
    nodeCount: 1
    sku: 'M10'
    highAvailabilityMode: false
    storage: 32
    administratorLogin: mongoAdminLogin
    administratorLoginPassword: mongoAdminPassword
    networkAcls: {
      allowAllIPs: true
      allowAzureIPs: true
    }
  }
}

module cosmosAccount 'br/public:avm/res/document-db/database-account:0.11.3' = if (databaseType == 'table' || databaseType == 'nosql' || databaseType == 'mongodb-ru') {
  name: 'cosmos-db-account'
  params: {
    name: {
      nosql: 'cosno${nameSuffix}'
      'mongodb-ru': 'cosmon${nameSuffix}'
      table: 'costab${nameSuffix}'
    }[databaseType]
    location: location
    locations: [
      {
        failoverPriority: 0
        locationName: location
        isZoneRedundant: false
      }
    ]
    tags: tags
    disableKeyBasedMetadataWriteAccess: true
    disableLocalAuth: {
      nosql: true
      'mongodb-ru': false
      table: true
    }[databaseType]
    networkRestrictions: {
      publicNetworkAccess: 'Enabled'
      ipRules: []
      virtualNetworkRules: []
    }
    capabilitiesToAdd: union(
      [
        'EnableServerless'
      ],
      databaseType == 'table'
        ? [
            'EnableTable'
          ]
        : []
    )
    sqlRoleDefinitions: union(
      databaseType == 'nosql'
        ? [
            {
              name: 'nosql-data-plane-contributor'
              dataAction: [
                'Microsoft.DocumentDB/databaseAccounts/readMetadata' // Read account metadata
                'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/*' // Manage databases
                'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*' // Manage containers
                'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*' // Manage items
              ]
            }
          ]
        : [],
      databaseType == 'table'
        ? [
            {
              name: 'table-data-plane-contributor'
              dataAction: [
                'Microsoft.DocumentDB/databaseAccounts/readMetadata' // Read account metadata
                'Microsoft.DocumentDB/databaseAccounts/tables/*' // Manage tables
                'Microsoft.DocumentDB/databaseAccounts/tables/containers/*' // Manage containers  
                'Microsoft.DocumentDB/databaseAccounts/tables/containers/entities/*' // Manage entities          
              ]
            }
          ]
        : []
    )
    sqlRoleAssignmentsPrincipalIds: [
      deploymentPrincipalId
      managedIdentity.outputs.principalId
    ]
    secretsExportConfiguration: databaseType == 'mongodb-ru'
      ? {
          primaryWriteConnectionStringSecretName: 'azure-cosmos-db-connection-string'
          keyVaultResourceId: keyVault.outputs.resourceId
        }
      : null
    sqlDatabases: databaseType == 'nosql'
      ? [
          {
            name: databaseName
            containers: [
              {
                name: databaseContainerName
                paths: [
                  databasePartitionKeyPath
                ]
              }
            ]
          }
        ]
      : []
    tables: databaseType == 'table'
      ? [
          {
            name: databaseContainerName
          }
        ]
      : []
    mongodbDatabases: databaseType == 'mongodb-ru'
      ? [
          {
            name: databaseName
            collections: [
              {
                name: databaseContainerName
                indexes: [
                  {
                    key: {
                      keys: [
                        '_id'
                      ]
                    }
                  }
                  {
                    key: {
                      keys: [
                        '$**'
                      ]
                    }
                  }
                  {
                    key: {
                      keys: [
                        '_ts'
                      ]
                    }
                    options: {
                      expireAfterSeconds: 2629746
                    }
                  }
                ]
                shardKey: {
                  category: 'Hash'
                }
              }
            ]
          }
        ]
      : []
  }
}

module containerRegistry 'br/public:avm/res/container-registry/registry:0.9.1' = {
  name: 'container-registry'
  params: {
    name: 'cnreg${toLower(replace(nameSuffix, '-', ''))}'
    location: location
    tags: tags
    acrAdminUserEnabled: false
    anonymousPullEnabled: false
    publicNetworkAccess: 'Enabled'
    acrSku: 'Standard'
    roleAssignments: [
      {
        principalId: deploymentPrincipalId
        roleDefinitionIdOrName: '8311e382-0749-4cb8-b61a-304f252e45ec' // AcrPush
      }
      {
        principalId: managedIdentity.outputs.principalId
        roleDefinitionIdOrName: '8311e382-0749-4cb8-b61a-304f252e45ec' // AcrPull
      }
    ]
  }
}

module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.11.1' = {
  name: 'log-analytics-workspace'
  params: {
    name: 'log${nameSuffix}'
    location: location
    tags: tags
  }
}

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.10.1' = {
  name: 'container-apps-env'
  params: {
    name: 'cae${nameSuffix}'
    location: location
    tags: tags
    logAnalyticsWorkspaceResourceId: logAnalyticsWorkspace.outputs.resourceId
    publicNetworkAccess: 'Enabled'
    zoneRedundant: false
  }
}

module containerAppsApp 'br/public:avm/res/app/container-app:0.14.1' = {
  name: 'container-apps-app'
  params: {
    name: 'ca${nameSuffix}'
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, { 'azd-service-name': webServiceName })
    ingressTargetPort: webTargetPort
    ingressExternal: true
    scaleSettings: {
      maxReplicas: 1
      minReplicas: 1
    }
    managedIdentities: {
      userAssignedResourceIds: [
        managedIdentity.outputs.resourceId
      ]
    }
    registries: [
      {
        server: containerRegistry.outputs.loginServer
        identity: managedIdentity.outputs.resourceId
      }
    ]
    secrets: union(
      (databaseType == 'nosql' || databaseType == 'table')
        ? [
            {
              name: 'user-assigned-managed-identity-client-id'
              value: managedIdentity.outputs.clientId
            }
          ]
        : [],
      [
        {
          nosql: databaseType == 'nosql'
            ? {
                name: 'azure-cosmos-db-endpoint'
                value: cosmosAccount.outputs.endpoint
              }
            : null
          'mongodb-ru': databaseType == 'mongodb-ru'
            ? {
                name: 'azure-cosmos-db-connection-string'
                keyVaultUrl: '${keyVault.outputs.uri}secrets/azure-cosmos-db-connection-string'
                identity: managedIdentity.outputs.resourceId
              }
            : null
          'mongodb-vcore': databaseType == 'mongodb-vcore'
            ? {
                name: 'azure-cosmos-db-connection-string'
                keyVaultUrl: '${keyVault.outputs.uri}secrets/azure-cosmos-db-connection-string'
                identity: managedIdentity.outputs.resourceId
              }
            : null
          table: databaseType == 'table'
            ? {
                name: 'azure-cosmos-db-endpoint'
                value: cosmosAccount.outputs.endpoint
              }
            : null
        }[databaseType]
      ]
    )
    containers: [
      {
        image: webContainerImage
        name: webServiceName
        resources: {
          cpu: '0.25'
          memory: '.5Gi'
        }
        env: union(
          (databaseType == 'nosql' || databaseType == 'table')
            ? [
                {
                  name: 'AZURE_CLIENT_ID'
                  secretRef: 'user-assigned-managed-identity-client-id'
                }
              ]
            : [],
          (databaseType == 'nosql' || databaseType == 'table')
            ? [
                {
                  name: 'CONFIGURATION__ENDPOINT'
                  secretRef: 'azure-cosmos-db-endpoint'
                }
              ]
            : [],
          (databaseType == 'mongodb-ru' || databaseType == 'mongodb-vcore')
            ? [
                {
                  name: 'CONFIGURATION__CONNECTIONSTRING'
                  secretRef: 'azure-cosmos-db-connection-string'
                }
              ]
            : [],
          (databaseType == 'nosql' || databaseType == 'mongodb-ru' || databaseType == 'mongodb-vcore')
            ? [
                {
                  name: 'CONFIGURATION__DATABASENAME'
                  value: databaseName
                }
              ]
            : [],
          databaseType == 'nosql'
            ? [
                {
                  name: 'CONFIGURATION__CONTAINERNAME'
                  value: databaseContainerName
                }
              ]
            : [],
          (databaseType == 'mongodb-ru' || databaseType == 'mongodb-vcore')
            ? [
                {
                  name: 'CONFIGURATION__COLLECTIONNAME'
                  value: databaseContainerName
                }
              ]
            : [],
          databaseType == 'table'
            ? [
                {
                  name: 'CONFIGURATION__TABLENAME'
                  value: databaseContainerName
                }
              ]
            : [],
          webEnvironmentVariables
        )
      }
    ]
  }
}

output containerRegistryLoginServer string = containerRegistry.outputs.loginServer
output databaseAccountEndpoint string = {
  nosql: databaseType == 'nosql' ? cosmosAccount.outputs.endpoint : null
  'mongodb-ru': null
  'mongodb-vcore': null
  table: databaseType == 'table' ? cosmosAccount.outputs.endpoint : null
}[databaseType]
