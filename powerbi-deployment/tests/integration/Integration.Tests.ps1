<#
.SYNOPSIS
    Integration tests - run against a real Power BI Service + Dev workspace.
.DESCRIPTION
    Requires:
      - PBI_TEST_TENANT_ID, PBI_TEST_CLIENT_ID, PBI_TEST_CLIENT_SECRET env vars
      - PBI_TEST_WORKSPACE_ID pointing to a throwaway dev workspace on Premium
      - A sample .pbix and .rdl in ./tests/fixtures

    These tests mutate the workspace. Do NOT run against Prod.

    Execution:
        Invoke-Pester -Path ./tests/integration -Tag Integration
#>

#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..' '..' 'modules' 'PowerBIDeployment.psd1'
    Import-Module $ModulePath -Force

    # Skip entire file if required env vars not set
    $required = @('PBI_TEST_TENANT_ID', 'PBI_TEST_CLIENT_ID', 'PBI_TEST_CLIENT_SECRET', 'PBI_TEST_WORKSPACE_ID')
    foreach ($var in $required) {
        if (-not [Environment]::GetEnvironmentVariable($var)) {
            Set-ItResult -Skipped -Because "Required env var $var not set"
            return
        }
    }

    $script:tenantId    = $env:PBI_TEST_TENANT_ID
    $script:clientId    = $env:PBI_TEST_CLIENT_ID
    $script:workspaceId = $env:PBI_TEST_WORKSPACE_ID
    $script:clientSecret = ConvertTo-SecureString $env:PBI_TEST_CLIENT_SECRET -AsPlainText -Force

    $script:fixturePath = Join-Path $PSScriptRoot '..' 'fixtures'
    $script:samplePbix  = Join-Path $script:fixturePath 'sample.pbix'
    $script:sampleRdl   = Join-Path $script:fixturePath 'sample.rdl'

    # Connect once for all tests
    Connect-PowerBIWithServicePrincipal `
        -TenantId $script:tenantId `
        -ClientId $script:clientId `
        -ClientSecret $script:clientSecret | Out-Null
}

AfterAll {
    Disconnect-PowerBISession
}

Describe 'Integration: Authentication' -Tag Integration {
    It 'Successfully authenticates to Power BI Service with SP' {
        $ctx = Get-PowerBIAccessToken
        $ctx | Should -Not -BeNullOrEmpty
    }
}

Describe 'Integration: Workspace' -Tag Integration {
    It 'Retrieves the test workspace' {
        $ws = Get-PowerBIWorkspace -Id $script:workspaceId -Scope Organization
        $ws | Should -Not -BeNullOrEmpty
        $ws.State | Should -Be 'Active'
    }

    It 'Verifies workspace is on Premium capacity' {
        { Test-PremiumCapacity -WorkspaceId $script:workspaceId } | Should -Not -Throw
    }
}

Describe 'Integration: .pbix publish' -Tag Integration {
    BeforeAll {
        if (-not (Test-Path $script:samplePbix)) {
            Set-ItResult -Skipped -Because 'Sample .pbix fixture missing'
        }
    }

    It 'Publishes sample.pbix' {
        $name = "IntegrationTest-PBIX-$([guid]::NewGuid().ToString().Substring(0,8))"
        $script:publishedPbix = Publish-PowerBIReport `
            -FilePath $script:samplePbix `
            -WorkspaceId $script:workspaceId `
            -ReportName $name `
            -ConflictAction 'CreateOrOverwrite'

        $script:publishedPbix.Id | Should -Not -BeNullOrEmpty
        $script:publishedPbix.Name | Should -Be $name
    }

    It 'Retrieves the published report via API' {
        $test = Test-ReportDeployment `
            -ReportId $script:publishedPbix.Id `
            -WorkspaceId $script:workspaceId
        $test | Should -Be $true
    }

    AfterAll {
        # Cleanup
        if ($script:publishedPbix) {
            try {
                Invoke-PowerBIRestMethod `
                    -Url "groups/$script:workspaceId/reports/$($script:publishedPbix.Id)" `
                    -Method Delete | Out-Null
            } catch { }
        }
    }
}

Describe 'Integration: .rdl publish' -Tag Integration {
    BeforeAll {
        if (-not (Test-Path $script:sampleRdl)) {
            Set-ItResult -Skipped -Because 'Sample .rdl fixture missing'
        }
    }

    It 'Publishes sample.rdl paginated report' {
        $name = "IntegrationTest-RDL-$([guid]::NewGuid().ToString().Substring(0,8))"
        $script:publishedRdl = Publish-PowerBIReport `
            -FilePath $script:sampleRdl `
            -WorkspaceId $script:workspaceId `
            -ReportName $name `
            -ConflictAction 'CreateOrOverwrite'

        $script:publishedRdl.Id | Should -Not -BeNullOrEmpty
    }

    It 'Published report has reportType=PaginatedReport' {
        $r = (Invoke-PowerBIRestMethod `
            -Url "groups/$script:workspaceId/reports/$($script:publishedRdl.Id)" `
            -Method Get) | ConvertFrom-Json
        $r.reportType | Should -Be 'PaginatedReport'
    }

    AfterAll {
        if ($script:publishedRdl) {
            try {
                Invoke-PowerBIRestMethod `
                    -Url "groups/$script:workspaceId/reports/$($script:publishedRdl.Id)" `
                    -Method Delete | Out-Null
            } catch { }
        }
    }
}

Describe 'Integration: Idempotency' -Tag Integration {
    It 'Publishing the same .pbix twice produces the same report ID' {
        if (-not (Test-Path $script:samplePbix)) {
            Set-ItResult -Skipped -Because 'Sample .pbix fixture missing'
            return
        }

        $name = "IdempotencyTest-$([guid]::NewGuid().ToString().Substring(0,8))"

        $first = Publish-PowerBIReport `
            -FilePath $script:samplePbix `
            -WorkspaceId $script:workspaceId `
            -ReportName $name `
            -ConflictAction 'CreateOrOverwrite'

        $second = Publish-PowerBIReport `
            -FilePath $script:samplePbix `
            -WorkspaceId $script:workspaceId `
            -ReportName $name `
            -ConflictAction 'CreateOrOverwrite'

        # Report ID should be preserved on overwrite
        $second.Id | Should -Be $first.Id

        # Cleanup
        Invoke-PowerBIRestMethod `
            -Url "groups/$script:workspaceId/reports/$($first.Id)" `
            -Method Delete | Out-Null
    }
}

Describe 'Integration: Error handling' -Tag Integration {
    It 'Throws when file does not exist' {
        { Publish-PowerBIReport -FilePath './nonexistent.pbix' -WorkspaceId $script:workspaceId } |
            Should -Throw
    }

    It 'Throws when workspace does not exist' {
        if (-not (Test-Path $script:samplePbix)) { return }
        $fake = [guid]::NewGuid().ToString()
        { Publish-PowerBIReport `
            -FilePath $script:samplePbix `
            -WorkspaceId $fake `
            -ReportName "ShouldFail" `
            -ConflictAction 'Abort' } | Should -Throw
    }
}
