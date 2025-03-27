metadata description = 'Pattern template for deploying a web application using Azure Container Apps backed by Azure Cosmos DB.'

import { secretType, environmentVarType } from 'br/public:avm/res/app/container-app:0.14.1'

@description('The primary location for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('The tags to apply to the resources. Defaults to an empty object.')
param tags object = {}

@description('The principal ID of the deployment identity used to deploy the resources. Defaults to the identity of the deployment principal.')
param deploymentPrincipalId string = deployer().objectId

@description('The configuration of the resources to be deployed.')
param configuration rootConfigurationType = {
  web: {
    name: 'ca-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    tags: {}
    environment: {
      name: 'cae-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    }
    registry: {
      name: 'cnreg${resourceGroup().location}${uniqueString(resourceGroup().id)}'
    }
    analytics: {
      name: 'law-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    }
    port: 80
    containerImage: 'nginx:latest'
    settings: []
    secrets: []
  }
  data: {
    name: 'cosmo-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    tags: {}
    type: 'nosql'
    database: {
      name: 'demo'
    }
    container: {
      name: 'example'
      partitionKeyPath: '/id'
    }
    collection: {
      name: 'example'
    }
    table: {
      name: 'example'
    }
    mongo: {
      adminLogin: 'app'
      adminPassword: newGuid()
    }
  }
  identity: {
    name: 'id-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
  }
  vault: {
    name: 'kv-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
  }
}

type rootConfigurationType = {
  web: webConfigurationType?
  data: databaseConfigurationType?
  identity: managedIdentityConfigurationType?
  vault: keyVaultConfigurationType?
}

type webConfigurationType = {
  name: string?
  tags: object?
  port: int?
  containerImage: string?
  settings: environmentVarType[]?
  secrets: secretType[]?
  environment: environmentConfigurationType?
  registry: registryConfigurationType?
  analytics: analyticsConfigurationType?
}

type databaseConfigurationType = {
  name: string?
  tags: object?
  type: ('nosql' | 'mongodb-ru' | 'mongodb-vcore' | 'table')?
  database: databaseDatabaseConfigurationType?
  container: databaseContainerConfigurationType?
  collection: databaseCollectionConfigurationType?
  table: databaseTableConfigurationType?
  mongo: databaseMongoConfigurationType?
}

type registryConfigurationType = {
  name: string?
}

type analyticsConfigurationType = {
  name: string?
}

type environmentConfigurationType = {
  name: string?
}

type databaseDatabaseConfigurationType = {
  name: string?
}

type databaseContainerConfigurationType = {
  name: string?
  partitionKeyPath: string?
}

type databaseCollectionConfigurationType = {
  name: string?
}

type databaseTableConfigurationType = {
  name: string?
}

type databaseMongoConfigurationType = {
  adminLogin: string?
  adminPassword: string?
}

type managedIdentityConfigurationType = {
  name: string?
}

type keyVaultConfigurationType = {
  name: string?
}

module managedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.0' = {
  name: 'user-assigned-managed-identity'
  params: {
    name: configuration.?identity.name ?? 'id-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    location: location
    tags: tags
  }
}

module keyVault 'br/public:avm/res/key-vault/vault:0.12.1' = if (configuration.?data.?type == 'mongodb-ru' || configuration.?data.?type == 'mongodb-vcore') {
  name: 'key-vault'
  params: {
    name: configuration.?vault.name ?? 'kv-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
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
    secrets: configuration.?data.type == 'mongodb-vcore'
      ? [
          {
            name: 'azure-cosmos-db-connection-string'
            value: replace(
              replace(
                cosmosMongoCluster.outputs.connectionStringKey,
                '<user>',
                configuration.?data.?mongo.?adminLogin ?? 'app'
              ),
              '<password>',
              configuration.?data.?mongo.?adminPassword ?? 'P@ssw.rd'
            )
          }
        ]
      : []
  }
}

module cosmosMongoCluster 'br/public:avm/res/document-db/mongo-cluster:0.1.1' = if (configuration.?data.?type == 'mongodb-vcore') {
  name: 'cosmos-db-mongodb-vcore-account'
  params: {
    name: configuration.?data.?name ?? 'cosmo-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    location: location
    tags: union(tags, configuration.?data.?tags ?? {})
    nodeCount: 1
    sku: 'M10'
    highAvailabilityMode: false
    storage: 32
    administratorLogin: configuration.?data.?mongo.?adminLogin ?? 'app'
    administratorLoginPassword: configuration.?data.?mongo.?adminPassword ?? 'P@ssw.rd'
    networkAcls: {
      allowAllIPs: true
      allowAzureIPs: true
    }
  }
}

module cosmosAccount 'br/public:avm/res/document-db/database-account:0.11.3' = if (configuration.?data.?type == 'table' || configuration.?data.?type == 'nosql' || configuration.?data.?type == 'mongodb-ru') {
  name: 'cosmos-db-account'
  params: {
    name: configuration.?data.?name ?? 'cosmo-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    location: location
    locations: [
      {
        failoverPriority: 0
        locationName: location
        isZoneRedundant: false
      }
    ]
    tags: union(tags, configuration.?data.?tags ?? {})
    disableKeyBasedMetadataWriteAccess: true
    disableLocalAuth: {
      nosql: true
      'mongodb-ru': false
      table: true
    }[configuration.?data.?type ?? 'nosql']
    networkRestrictions: {
      publicNetworkAccess: 'Enabled'
      ipRules: []
      virtualNetworkRules: []
    }
    capabilitiesToAdd: union(
      [
        'EnableServerless'
      ],
      configuration.?data.?type == 'table'
        ? [
            'EnableTable'
          ]
        : []
    )
    sqlRoleDefinitions: union(
      configuration.?data.?type == 'nosql'
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
      configuration.?data.?type == 'table'
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
    secretsExportConfiguration: configuration.?data.?type == 'mongodb-ru'
      ? {
          primaryWriteConnectionStringSecretName: 'azure-cosmos-db-connection-string'
          keyVaultResourceId: keyVault.outputs.resourceId
        }
      : null
    sqlDatabases: configuration.?data.?type == 'nosql'
      ? [
          {
            name: configuration.?data.?database.?name ?? 'demo'
            containers: [
              {
                name: configuration.?data.?container.?name ?? 'example'
                paths: [
                  configuration.?data.?container.?partitionKeyPath ?? '/id'
                ]
              }
            ]
          }
        ]
      : []
    tables: configuration.?data.?type == 'table'
      ? [
          {
            name: configuration.?data.?table.?name ?? 'example'
          }
        ]
      : []
    mongodbDatabases: configuration.?data.?type == 'mongodb-ru'
      ? [
          {
            name: configuration.?data.?database.?name ?? 'demo'
            collections: [
              {
                name: configuration.?data.?collection.?name ?? 'example'
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
    name: configuration.?web.?registry.?name ?? 'cnreg${resourceGroup().location}${uniqueString(resourceGroup().id)}'
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
    name: configuration.?web.?analytics.?name ?? 'law-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    location: location
    tags: tags
  }
}

module containerAppsEnvironment 'br/public:avm/res/app/managed-environment:0.10.1' = {
  name: 'container-apps-env'
  params: {
    name: configuration.?web.?environment.?name ?? 'cae-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
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
    name: configuration.?web.?name ?? 'ca-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    environmentResourceId: containerAppsEnvironment.outputs.resourceId
    location: location
    tags: union(tags, configuration.?web.?tags ?? {})
    ingressTargetPort: configuration.?web.?port ?? 80
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
      (configuration.?data.?type == 'nosql' || configuration.?data.?type == 'table')
        ? [
            {
              name: 'user-assigned-managed-identity-client-id'
              value: managedIdentity.outputs.clientId
            }
          ]
        : [],
      [
        {
          nosql: configuration.?data.?type == 'nosql'
            ? {
                name: 'azure-cosmos-db-endpoint'
                value: cosmosAccount.outputs.endpoint
              }
            : null
          'mongodb-ru': configuration.?data.?type == 'mongodb-ru'
            ? {
                name: 'azure-cosmos-db-connection-string'
                keyVaultUrl: '${keyVault.outputs.uri}secrets/azure-cosmos-db-connection-string'
                identity: managedIdentity.outputs.resourceId
              }
            : null
          'mongodb-vcore': configuration.?data.?type == 'mongodb-vcore'
            ? {
                name: 'azure-cosmos-db-connection-string'
                keyVaultUrl: '${keyVault.outputs.uri}secrets/azure-cosmos-db-connection-string'
                identity: managedIdentity.outputs.resourceId
              }
            : null
          table: configuration.?data.?type == 'table'
            ? {
                name: 'azure-cosmos-db-endpoint'
                value: cosmosAccount.outputs.endpoint
              }
            : null
        }[configuration.?data.?type ?? 'nosql']
      ],
      configuration.?web.?secrets ?? []
    )
    containers: [
      {
        image: configuration.?web.?containerImage ?? 'nginx:latest'
        name: 'app'
        resources: {
          cpu: '0.25'
          memory: '.5Gi'
        }
        env: union(
          (configuration.?data.?type == 'nosql' || configuration.?data.?type == 'table')
            ? [
                {
                  name: 'AZURE_CLIENT_ID'
                  secretRef: 'user-assigned-managed-identity-client-id'
                }
              ]
            : [],
          (configuration.?data.?type == 'nosql' || configuration.?data.?type == 'table')
            ? [
                {
                  name: 'CONFIGURATION__ENDPOINT'
                  secretRef: 'azure-cosmos-db-endpoint'
                }
              ]
            : [],
          (configuration.?data.?type == 'mongodb-ru' || configuration.?data.?type == 'mongodb-vcore')
            ? [
                {
                  name: 'CONFIGURATION__CONNECTIONSTRING'
                  secretRef: 'azure-cosmos-db-connection-string'
                }
              ]
            : [],
          (configuration.?data.?type == 'nosql' || configuration.?data.?type == 'mongodb-ru' || configuration.?data.?type == 'mongodb-vcore')
            ? [
                {
                  name: 'CONFIGURATION__DATABASENAME'
                  value: configuration.?data.?database.?name ?? 'demo'
                }
              ]
            : [],
          configuration.?data.?type == 'nosql'
            ? [
                {
                  name: 'CONFIGURATION__CONTAINERNAME'
                  value: configuration.?data.?container.?name ?? 'example'
                }
              ]
            : [],
          (configuration.?data.?type == 'mongodb-ru' || configuration.?data.?type == 'mongodb-vcore')
            ? [
                {
                  name: 'CONFIGURATION__COLLECTIONNAME'
                  value: configuration.?data.?collection.?name ?? 'example'
                }
              ]
            : [],
          configuration.?data.?type == 'table'
            ? [
                {
                  name: 'CONFIGURATION__TABLENAME'
                  value: configuration.?data.?table.?name ?? 'example'
                }
              ]
            : [],
          configuration.?web.?settings ?? []
        )
      }
    ]
  }
}

output containerRegistryLoginServer string = containerRegistry.outputs.loginServer
output databaseAccountEndpoint string = {
  nosql: cosmosAccount.outputs.endpoint
  'mongodb-ru': cosmosAccount.outputs.endpoint
  'mongodb-vcore': ''
  table: cosmosAccount.outputs.endpoint
}[configuration.?data.?type ?? 'nosql']
