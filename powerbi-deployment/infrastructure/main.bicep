// =============================================================================
// Power BI Deployment - Supporting Infrastructure (Bicep)
// =============================================================================
// Provisions Key Vault, Log Analytics workspace, and storage account used by
// the deployment pipeline. Run once per environment.
//
// Usage:
//   az deployment group create \
//     --resource-group rg-analytics-prod \
//     --template-file infrastructure/main.bicep \
//     --parameters environment=prod pipelineSpObjectId=<objId>
// =============================================================================

targetScope = 'resourceGroup'

@description('Environment name: dev, test, or prod')
@allowed(['dev', 'test', 'prod'])
param environment string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Object ID of the pipeline service principal (needs KV read access)')
param pipelineSpObjectId string

@description('Object ID of the DevOps team group (needs full KV access)')
param devopsGroupObjectId string

@description('Tenant ID for Key Vault')
param tenantId string = subscription().tenantId

@description('Retention days for diagnostic logs')
@minValue(30)
@maxValue(730)
param logRetentionDays int = environment == 'prod' ? 365 : 90

var baseName = 'powerbi-${environment}'
var tags = {
  Environment: environment
  Application: 'PowerBI-Deployment'
  ManagedBy: 'Bicep'
  CostCenter: 'DataPlatform'
}

// ---------------------------------------------------------------------------
// Log Analytics workspace - central log sink for pipeline logs & audit
// ---------------------------------------------------------------------------
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: 'log-${baseName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: logRetentionDays
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    workspaceCapping: {
      dailyQuotaGb: environment == 'prod' ? 10 : 2
    }
  }
}

// ---------------------------------------------------------------------------
// Key Vault
// ---------------------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${baseName}'
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: environment == 'prod' ? 'premium' : 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: environment == 'prod' ? true : null
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// Built-in role definition IDs
var roleKeyVaultSecretsUser      = '4633458b-17de-408a-b874-0445c86b69e6'
var roleKeyVaultAdministrator    = '00482a5a-887f-4fb3-b363-3b7fe8e74483'

resource kvSecretsUserForPipeline 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, pipelineSpObjectId, roleKeyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultSecretsUser)
    principalId: pipelineSpObjectId
    principalType: 'ServicePrincipal'
  }
}

resource kvAdminForDevOps 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, devopsGroupObjectId, roleKeyVaultAdministrator)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleKeyVaultAdministrator)
    principalId: devopsGroupObjectId
    principalType: 'Group'
  }
}

// ---------------------------------------------------------------------------
// Storage account for deployment artifacts backup & .rdl history
// ---------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'st${replace(baseName,'-','')}'
  location: location
  tags: tags
  sku: {
    name: environment == 'prod' ? 'Standard_GRS' : 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices, Logging, Metrics'
    }
    encryption: {
      services: {
        blob: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    isVersioningEnabled: true
    changeFeed: {
      enabled: true
      retentionInDays: 90
    }
  }
}

resource artifactContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'powerbi-artifacts'
  properties: {
    publicAccess: 'None'
    metadata: {
      purpose: 'Retain deployed report versions for DR & rollback'
    }
  }
}

resource backupContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'powerbi-backups'
  properties: {
    publicAccess: 'None'
    metadata: {
      purpose: 'Nightly export of live Power BI reports'
    }
  }
}

// Lifecycle rule: move artifacts to cool after 30d, delete after 365d
resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'ArtifactRetention'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['powerbi-artifacts/']
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 30
                }
                delete: {
                  daysAfterModificationGreaterThan: environment == 'prod' ? 365 : 90
                }
              }
            }
          }
        }
        {
          name: 'BackupRetention'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['powerbi-backups/']
            }
            actions: {
              baseBlob: {
                tierToCool: {
                  daysAfterModificationGreaterThan: 7
                }
                tierToArchive: {
                  daysAfterModificationGreaterThan: 90
                }
                delete: {
                  daysAfterModificationGreaterThan: environment == 'prod' ? 2555 : 365   // 7y prod
                }
              }
            }
          }
        }
      ]
    }
  }
}

// Grant pipeline SP access to storage
var roleStorageBlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
resource storageRoleForPipeline 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, pipelineSpObjectId, roleStorageBlobDataContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleStorageBlobDataContributor)
    principalId: pipelineSpObjectId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Diagnostic settings - send everything to Log Analytics
// ---------------------------------------------------------------------------
resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${keyVault.name}'
  scope: keyVault
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource storageDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${storage.name}'
  scope: blobService
  properties: {
    workspaceId: logAnalytics.id
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Action group for alerts
// ---------------------------------------------------------------------------
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${baseName}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take('pbi${environment}', 12)
    enabled: true
    emailReceivers: [
      {
        name: 'dataplatform'
        emailAddress: 'dataplatform-oncall@example.com'
        useCommonAlertSchema: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Alert: Key Vault access from unexpected IP
// ---------------------------------------------------------------------------
resource alertKvUnauthorizedAccess 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-kv-unauthorized-${environment}'
  location: location
  tags: tags
  properties: {
    displayName: 'Key Vault unauthorized access (${environment})'
    description: 'Fires when Key Vault secret operations fail authorization'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    scopes: [logAnalytics.id]
    criteria: {
      allOf: [
        {
          query: 'AzureDiagnostics | where ResourceType == "VAULTS" | where ResultType == "Unauthorized" or httpStatusCode_d >= 403 | summarize count() by CallerIPAddress, identity_claim_appid_g'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsCustomerId string = logAnalytics.properties.customerId
output storageAccountName string = storage.name
output artifactContainerName string = artifactContainer.name
output backupContainerName string = backupContainer.name
output actionGroupId string = actionGroup.id
