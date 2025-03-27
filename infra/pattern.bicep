metadata description = 'Pattern template for deploying a web application using Azure Container Apps backed by Azure Cosmos DB.'

import { secretType, environmentVarType } from 'br/public:avm/res/app/container-app:0.14.1'

@description('The primary location for all resources. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('The tags to apply to the resources. Defaults to an empty object.')
param tags object = {}

@description('The principal ID of the deployment identity used to deploy the resources. Defaults to the identity of the deployment principal.')
param deploymentPrincipalId string = deployer().objectId

@description('The configuration of the resources to be deployed.')
param configuration configurationType?

@description('The configuration settings for the resources to be deployed.')
type configurationType = {
  @description('The configuration for the web application.')
  web: {
    @description('The name of the web application.')
    name: string?
    @description('The tags to apply to the web application.')
    tags: object?
    @description('The exposed port for the web application.')
    port: int?
    @description('The container configuration for the web application.')
    container: {
      @description('The name of the container instance.')
      name: string?
      @description('The container image to use.')
      image: string?
      @description('The container resource configuration for the web application.')
      resources: {
        @description('The CPU resource for the container.')
        cpu: int?
        @description('The memory resource for the container.')
        memory: string?
      }?
    }?
    settings: environmentVarType[]?
    secrets: secretType[]?
    environment: {
      name: string?
      zoneRedundant: bool?
    }?
    registry: {
      name: string?
      sku: ('Basic' | 'Standard' | 'Premium')?
    }?
    analytics: {
      name: string?
    }?
    replicas: {
      min: int?
      max: int?
    }?
  }?
  @description('The configuration for the data store.')
  data: {
    name: string?
    tags: object?
    locations: {
      failoverPriority: int
      locationName: string
      isZoneRedundant: bool?
    }[]?
    type: ('nosql' | 'mongodb-ru' | 'mongodb-vcore' | 'table')?
    database: {
      name: string?
    }?
    container: {
      name: string?
      partitionKeyPath: string?
    }?
    collection: {
      name: string?
      indexes: object[]?
      shardKey: string?
    }?
    table: {
      name: string?
    }?
    cluster: {
      adminLogin: string?
      adminPassword: string?
      sku: string?
      nodeCount: int?
      highAvailabilityMode: bool?
      storage: int?
    }?
  }?
  @description('The configuration for the user-assigned managed identity.')
  identity: {
    name: string?
  }?
  @description('The configuration for the key vault.')
  vault: {
    name: string?
    purgeProtection: bool?
    softDeleteRetentionInDays: int?
  }?
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
    name: configuration.?vault.?name ?? 'kv-${resourceGroup().location}-${uniqueString(resourceGroup().id)}'
    location: location
    tags: tags
    enablePurgeProtection: configuration.?vault.?purgeProtection ?? true
    enableRbacAuthorization: true
    publicNetworkAccess: 'Enabled'
    softDeleteRetentionInDays: configuration.?vault.?softDeleteRetentionInDays ?? 7
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
                configuration.?data.?cluster.?adminLogin ?? 'app'
              ),
              '<password>',
              configuration.?data.?cluster.?adminPassword ?? 'P@ssw.rd'
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
    nodeCount: configuration.?data.?cluster.?nodeCount ?? 2
    sku: configuration.?data.?cluster.?sku ?? 'M30'
    highAvailabilityMode: configuration.?data.?cluster.?highAvailabilityMode ?? true
    storage: configuration.?data.?cluster.?storage ?? 128
    administratorLogin: configuration.?data.?cluster.?adminLogin ?? 'app'
    administratorLoginPassword: configuration.?data.?cluster.?adminPassword ?? 'P@ssw.rd'
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
    locations: configuration.?data.?locations ?? [
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
                indexes: configuration.?data.?collection.?indexes ?? [
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
                  category: configuration.?data.?collection.?shardKey ?? 'Hash'
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
    acrSku: configuration.?web.?registry.?sku ?? 'Standard'
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
    zoneRedundant: configuration.?web.?environment.?zoneRedundant ?? true
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
    ingressTransport: 'auto'
    stickySessionsAffinity: 'sticky'
    scaleSettings: {
      minReplicas: configuration.?web.?replicas.?min ?? 2
      maxReplicas: configuration.?web.?replicas.?max ?? 3
    }
    corsPolicy: {
      allowCredentials: true
      allowedOrigins: [
        '*'
      ]
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
        image: configuration.?web.?container.?image ?? 'nginx:latest'
        name: configuration.?web.?container.?name ?? 'app'
        resources: {
          cpu: configuration.?web.?container.?resources.?cpu ?? '0.25'
          memory: configuration.?web.?container.?resources.?memory ?? '.5Gi'
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
  nosql: configuration.?data.?type == 'nosql' ? cosmosAccount.outputs.endpoint : ''
  'mongodb-ru': configuration.?data.?type == 'mongodb-ru' ? cosmosAccount.outputs.endpoint : ''
  'mongodb-vcore': ''
  table: configuration.?data.?type == 'table' ? cosmosAccount.outputs.endpoint : ''
}[configuration.?data.?type ?? 'nosql']
