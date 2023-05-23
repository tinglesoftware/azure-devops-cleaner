@description('Location for all resources.')
param location string = resourceGroup().location

@description('Name of all resources.')
param name string = 'azdo-cleaner'

@description('Registry of the docker image. E.g. "contoso.azurecr.io". Leave empty unless you have a private registry mirroring the official image.')
param dockerImageRegistry string = 'ghcr.io'

@description('Registry and repository of the docker image. Ideally, you do not need to edit this value.')
param dockerImageRepository string = 'tinglesoftware/azure-devops-cleaner'

@description('Tag of the docker image.')
param dockerImageTag string = '#{GITVERSION_NUGETVERSIONV2}#'

@secure()
@description('Notifications password.')
param notificationsPassword string

@description('URL of the project. For example "https://dev.azure.com/fabrikam/DefaultCollection"')
param azureDevOpsProjectUrl string

@secure()
@description('Token for accessing the project.')
param azureDevOpsProjectToken string

@allowed([
  'InMemory'
  'ServiceBus'
  'QueueStorage'
])
@description('Merge strategy to use when setting auto complete on created pull requests.')
param eventBusTransport string = 'ServiceBus'

@description('Resource identifier of the ServiceBus namespace to use. If none is provided, a new one is created.')
param serviceBusNamespaceId string = ''

@description('Resource identifier of the storage account to use. If none is provided, a new one is created.')
param storageAccountId string = ''

@description('Resource identifier of the ContainerApp Environment to deploy to. If none is provided, a new one is created.')
param appEnvironmentId string = ''

@minValue(0)
@maxValue(2)
@description('The minimum number of replicas')
param minReplicas int = 0

@minValue(1)
@maxValue(5)
@description('The maximum number of replicas')
param maxReplicas int = 1

var hasDockerImageRegistry = (dockerImageRegistry != null && !empty(dockerImageRegistry))
var isAcrServer = hasDockerImageRegistry && endsWith(dockerImageRegistry, environment().suffixes.acrLoginServer)
var hasProvidedServiceBusNamespace = (serviceBusNamespaceId != null && !empty(serviceBusNamespaceId))
var hasProvidedStorageAccount = (storageAccountId != null && !empty(storageAccountId))
var hasProvidedAppEnvironment = (appEnvironmentId != null && !empty(appEnvironmentId))
// avoid conflicts across multiple deployments for resources that generate FQDN based on the name
var collisionSuffix = uniqueString(resourceGroup().id) // e.g. zecnx476et7xm (13 characters)

/* Managed Identity */
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
}

/* Service Bus namespace */
resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2021-11-01' = if (eventBusTransport == 'ServiceBus' && !hasProvidedServiceBusNamespace) {
  name: '${name}-${collisionSuffix}'
  location: location
  properties: {
    disableLocalAuth: false
    zoneRedundant: false
  }
  sku: {
    name: 'Basic'
  }
}
resource providedServiceBusNamespace 'Microsoft.ServiceBus/namespaces@2021-11-01' existing = if (eventBusTransport == 'ServiceBus' && hasProvidedServiceBusNamespace) {
  // Inspired by https://github.com/Azure/bicep/issues/1722#issuecomment-952118402
  // Example: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Fabrikam/providers/Microsoft.ServiceBus/namespaces/fabrikam
  // 0 -> '', 1 -> 'subscriptions', 2 -> '00000000-0000-0000-0000-000000000000', 3 -> 'resourceGroups'
  // 4 -> 'Fabrikam', 5 -> 'providers', 6 -> 'Microsoft.ServiceBus' 7 -> 'namespaces'
  // 8 -> 'fabrikam'
  name: split(serviceBusNamespaceId, '/')[8]
  scope: resourceGroup(split(serviceBusNamespaceId, '/')[2], split(serviceBusNamespaceId, '/')[4])
}

/* Storage Account */
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' = if (eventBusTransport == 'QueueStorage' && !hasProvidedStorageAccount) {
  name: '${name}-${collisionSuffix}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: true // CDN does not work without this
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}
resource providedStorageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' existing = if (eventBusTransport == 'QueueStorage' && hasProvidedStorageAccount) {
  // Inspired by https://github.com/Azure/bicep/issues/1722#issuecomment-952118402
  // Example: /subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/Fabrikam/providers/Microsoft.Storage/storageAccounts/fabrikam
  // 0 -> '', 1 -> 'subscriptions', 2 -> '00000000-0000-0000-0000-000000000000', 3 -> 'resourceGroups'
  // 4 -> 'Fabrikam', 5 -> 'providers', 6 -> 'Microsoft.Storage' 7 -> 'storageAccounts'
  // 8 -> 'fabrikam'
  name: split(storageAccountId, '/')[8]
  scope: resourceGroup(split(storageAccountId, '/')[2], split(storageAccountId, '/')[4])
}

/* Container App Environment */
resource appEnvironment 'Microsoft.App/managedEnvironments@2022-10-01' = if (!hasProvidedAppEnvironment) {
  name: name
  location: location
  properties: {}
}

/* Application Insights */
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: name
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

/* Container App */
resource app 'Microsoft.App/containerApps@2022-10-01' = {
  name: name
  location: location
  properties: {
    managedEnvironmentId: hasProvidedAppEnvironment ? appEnvironmentId : appEnvironment.id
    configuration: {
      ingress: {
        external: true
        targetPort: 80
        traffic: [
          {
            latestRevision: true
            weight: 100
          }
        ]
      }
      registries: isAcrServer ? [
        {
          identity: managedIdentity.id
          server: dockerImageRegistry
        }
      ] : []
      secrets: [
        { name: 'connection-strings-application-insights', value: appInsights.properties.ConnectionString }
        { name: 'notifications-password', value: notificationsPassword }
        { name: 'project-and-token-0', value: '${azureDevOpsProjectUrl};${azureDevOpsProjectToken}' }
      ]
    }
    template: {
      containers: [
        {
          image: '${'${hasDockerImageRegistry ? '${dockerImageRegistry}/' : ''}'}${dockerImageRepository}:${dockerImageTag}'
          name: 'azdo-cleaner'
          env: [
            { name: 'AZURE_CLIENT_ID', value: managedIdentity.properties.clientId } // Specifies the User-Assigned Managed Identity to use. Without this, the app attempt to use the system assigned one.
            { name: 'ASPNETCORE_FORWARDEDHEADERS_ENABLED', value: 'true' }

            { name: 'ApplicationInsights__ConnectionString', secretRef: 'connection-strings-application-insights' }
            { name: 'Authentication__ServiceHooks__Credentials__vsts', secretRef: 'notifications-password' }

            { name: 'Handler__Projects__0', secretRef: 'project-and-token-0' }
            { name: 'Handler__AzureWebsites', value: 'false' }

            { name: 'EventBus__SelectedTransport', value: eventBusTransport }
            {
              name: 'EventBus__Transports__azure-service-bus__FullyQualifiedNamespace'
              // manipulating https://{your-namespace}.servicebus.windows.net:443/
              value: eventBusTransport == 'ServiceBus' ? split(split(hasProvidedServiceBusNamespace ? providedServiceBusNamespace.properties.serviceBusEndpoint : serviceBusNamespace.properties.serviceBusEndpoint, '/')[2], ':')[0] : ''
            }
            {
              name: 'EventBus__Transports__azure-queue-storage__ServiceUrl'
              value: eventBusTransport == 'QueueStorage' ? (hasProvidedStorageAccount ? providedStorageAccount.properties.primaryEndpoints.queue : storageAccount.properties.primaryEndpoints.queue) : ''
            }
          ]
          resources: {// these are the least resources we can provision
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          probes: [
            { type: 'Liveness', httpGet: { port: 80, path: '/liveness' } }
            { type: 'Readiness', httpGet: { port: 80, path: '/health' } }
          ]
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {/*ttk bug*/ }
    }
  }
}

/* Role Assignments */
resource serviceBusDataOwnerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (eventBusTransport == 'ServiceBus') {
  name: guid(managedIdentity.id, 'AzureServiceBusDataOwner')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '090c5cfd-751d-490a-894a-3ce6f1109419')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource storageQueueDataContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (eventBusTransport == 'QueueStorage') {
  name: guid(managedIdentity.id, 'StorageQueueDataContributor')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output id string = app.id
output fqdn string = app.properties.configuration.ingress.fqdn
output notificationUrl string = 'https://${app.properties.configuration.ingress.fqdn}/webhooks/azure'
