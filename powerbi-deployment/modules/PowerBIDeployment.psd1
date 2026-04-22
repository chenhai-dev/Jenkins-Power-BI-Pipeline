@{
    RootModule        = 'PowerBIDeployment.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a7f3c9e1-4b2d-4e8a-9f1c-8d3e7a2b5c4f'
    Author            = 'DevOps Team'
    CompanyName       = 'Enterprise'
    Copyright         = '(c) Enterprise. All rights reserved.'
    Description       = 'Enterprise Power BI deployment module for CI/CD pipelines. Supports .pbix and .rdl paginated reports on Premium capacity.'
    PowerShellVersion = '7.2'
    RequiredModules   = @(
        @{ ModuleName = 'MicrosoftPowerBIMgmt'; ModuleVersion = '1.2.1111' }
    )
    FunctionsToExport = @(
        'Write-DeploymentLog'
        'Connect-PowerBIWithServicePrincipal'
        'Disconnect-PowerBISession'
        'Get-OrCreateWorkspace'
        'Test-PremiumCapacity'
        'Publish-PowerBIReport'
        'Publish-PaginatedReport'
        'Update-ReportDatasourceCredentials'
        'Update-ReportDataset'
        'Test-ReportDeployment'
    )
    PrivateData = @{
        PSData = @{
            Tags         = @('PowerBI', 'DevOps', 'CICD', 'Deployment', 'Paginated')
            ProjectUri   = 'https://internal.example.com/devops/powerbi-deployment'
            ReleaseNotes = 'Initial release'
        }
    }
}
