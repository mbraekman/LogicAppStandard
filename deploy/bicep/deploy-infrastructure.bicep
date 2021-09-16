
// Define input parameters
@allowed([
  'westeurope'
  'northeurope'
])
param location string
param environment string
param resourcePrefix string
param logicAppServiceName string
param releaseName string
param releaseUrl string
param releaseRequestedFor string
param releaseTriggerType string

// Define variables
var trimmedResourcePrefix = replace(replace(resourcePrefix, '-', ''), '_', '')
var appPlanName = '${resourcePrefix}-plan'
var workflowName = 'orc-event-handler-stateless'
var appInsightsName = '${resourcePrefix}-platform-insights'
var storageAccountName = '${trimmedResourcePrefix}storage'
var keyVaultName = '${resourcePrefix}-key-vault'
var serviceBusName = '${resourcePrefix}-service-bus'
var logAnalyticsWorkspaceName = '${resourcePrefix}-monitoring'

var tags = {
  environment: environment
  createdBy: releaseUrl
  releaseName: releaseName
  triggeredBy: releaseRequestedFor
  triggerType: releaseTriggerType
}

// Define resources
// Create Application Insights
resource appInsights 'Microsoft.Insights/components@2020-02-02-preview' = {
  name: appInsightsName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// Create Log Analytics Workspace
resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2021-06-01' = {
  name: logAnalyticsWorkspaceName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
  }
}

// Create Storage Account
resource storageAccount 'Microsoft.Storage/storageAccounts@2021-02-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
}

// Create containers in Storage Account
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2021-02-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    restorePolicy: {
      enabled: false
    }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2021-02-01' = {
  name: 'deploy'
  parent: blobService
  properties: {
    publicAccess: 'Blob'
  }
}

// Create KeyVault
resource keyVault 'Microsoft.KeyVault/vaults@2019-09-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: [
      
    ]
  }
}

// Add secrets in KeyVault
resource secret 'Microsoft.KeyVault/vaults/secrets@2019-09-01' = {
  parent: keyVault
  name: 'dummySecret'
  tags: tags
  properties: {
    attributes: {
       enabled: true
    }
    contentType: 'text/plain'
    value: 'abc'
  }
}

// Create ServiceBus
resource serviceBus 'Microsoft.ServiceBus/namespaces@2021-01-01-preview' = {
  name: serviceBusName
  location: location
  tags: tags
  identity: {
     type: 'SystemAssigned'
  }
  properties: {
    zoneRedundant: false
  }
}

// Create ServiceBus Queues
resource queue 'Microsoft.ServiceBus/namespaces/queues@2021-01-01-preview' = {
  parent: serviceBus
  name: 'firstQueue'
  properties: {
    deadLetteringOnMessageExpiration: true
  }
}

// Create Service Plan
resource myAppPlan 'Microsoft.Web/serverfarms@2020-12-01' = {
  name: appPlanName
  location: location
  tags: tags
  sku: {
    name: 'B1'
  }
  // When created via the Azure Portal, you will get a WorkflowStandard-tier app service plan -> no dev pricing for now
  // sku: {
    //   name: 'WS1'
    //   tier: 'WorkflowStandard'
  // }
}

// Create Logic App Standard
resource appService 'Microsoft.Web/sites@2020-12-01' = {
  name: logicAppServiceName
  location: location
  tags: tags
  kind: 'workflowapp,functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: myAppPlan.id
    httpsOnly: true
    enabled: true
    siteConfig: {
      appSettings: [
        {
          name: 'APP_KIND'
          value: 'workflowApp'
        }
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: appInsights.properties.InstrumentationKey
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__id'
          value: 'Microsoft.Azure.Functions.ExtensionBundle.Workflows'
        }
        {
          name: 'AzureFunctionsJobHost__extensionBundle__version'
          value: '[1.*, 2.0.0)'
        }
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${listKeys(storageAccount.id, storageAccount.apiVersion).keys[1].value}'
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~3'
        }
        {
          name: 'FUNCTIONS_V2_COMPATIBILITY_MODE'
          value: 'true'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'node'
        }
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~12'
        }
        {
          name: 'Workflows.${workflowName}.FlowState'
          value: 'Enabled'
        }
        {
          name: 'Workflows.${workflowName}.OperationOptions'
          value: 'WithStatelessRunHistory'
        }
      ]
    }
  }
}

// Add Access to KeyVault - KeyVault Secret User Access rights
resource accessToKeyVaultFromAppService 'Microsoft.KeyVault/vaults/accessPolicies@2021-04-01-preview' = {
  name: 'add'
  parent: keyVault
  properties: {
     accessPolicies: [
       {
         objectId: appService.identity.principalId
         tenantId: subscription().tenantId
         permissions: {
           secrets: [
             'get'
             'list'
           ]
         }
       }
     ]
  }
}

// Create Blob Storage API Connection
resource logAnalyticsConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: '${logicAppServiceName}-con-log-analytics'
  location: location
  tags: tags
  kind: 'V2'
  properties: {
    api: {
      id: '${subscription().id}/providers/Microsoft.Web/locations/${location}/managedApis/azureloganalyticsdatacollector'
    }
    parameterValues: {
      username: logAnalyticsWorkspace.properties.customerId
      password: listKeys(logAnalyticsWorkspace.id, logAnalyticsWorkspace.apiVersion).primarySharedKey
    }
  }
}
