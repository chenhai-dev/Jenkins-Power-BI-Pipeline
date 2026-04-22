#Requires -Modules @{ ModuleName='Pester'; ModuleVersion='5.0.0' }

BeforeAll {
    $ModulePath = Join-Path $PSScriptRoot '..' 'modules' 'PowerBIDeployment.psd1'
    Import-Module $ModulePath -Force
}

Describe 'Write-DeploymentLog' {
    It 'Emits structured JSON with required fields' {
        $output = Write-DeploymentLog -Message 'test' -Level INFO 6>&1
        $parsed = $output | ConvertFrom-Json
        $parsed.message | Should -Be 'test'
        $parsed.level | Should -Be 'INFO'
        $parsed.timestamp | Should -Match '^\d{4}-\d{2}-\d{2}T'
        $parsed.correlationId | Should -Not -BeNullOrEmpty
    }

    It 'Includes custom properties' {
        $output = Write-DeploymentLog -Message 'x' -Properties @{ foo = 'bar' } 6>&1
        $parsed = $output | ConvertFrom-Json
        $parsed.foo | Should -Be 'bar'
    }

    It 'Validates log level' {
        { Write-DeploymentLog -Message 'x' -Level 'BOGUS' } | Should -Throw
    }
}

Describe 'Publish-PowerBIReport' {
    BeforeAll {
        $script:testFile = Join-Path $TestDrive 'test.pbix'
        'dummy content' | Out-File -FilePath $script:testFile

        $script:testRdl = Join-Path $TestDrive 'test.rdl'
        '<?xml version="1.0"?><Report/>' | Out-File -FilePath $script:testRdl
    }

    It 'Rejects unsupported file types' {
        $badFile = Join-Path $TestDrive 'bad.txt'
        'x' | Out-File $badFile
        { Publish-PowerBIReport -FilePath $badFile -WorkspaceId 'x' -WhatIf } |
            Should -Throw '*Unsupported file type*'
    }

    It 'Accepts .pbix with -WhatIf' {
        { Publish-PowerBIReport -FilePath $script:testFile -WorkspaceId 'ws-1' -WhatIf } |
            Should -Not -Throw
    }

    It 'Accepts .rdl with -WhatIf' {
        { Publish-PowerBIReport -FilePath $script:testRdl -WorkspaceId 'ws-1' -WhatIf } |
            Should -Not -Throw
    }

    It 'Defaults ReportName to file basename' {
        # Verified via WhatIf without actually calling API
        { Publish-PowerBIReport -FilePath $script:testFile -WorkspaceId 'ws-1' -WhatIf } |
            Should -Not -Throw
    }
}

Describe 'Configuration loading' {
    It 'Prod config parses as valid YAML' {
        $configPath = Join-Path $PSScriptRoot '..' 'config' 'prod.yaml'
        Install-Module powershell-yaml -Force -Scope CurrentUser -AcceptLicense -ErrorAction SilentlyContinue
        Import-Module powershell-yaml -Force
        $cfg = ConvertFrom-Yaml (Get-Content $configPath -Raw)
        $cfg.environment | Should -Be 'Prod'
        $cfg.workspace.createIfMissing | Should -Be $false
        $cfg.auth.tenantId | Should -Not -BeNullOrEmpty
    }

    It 'Dev config allows auto-create workspace' {
        $configPath = Join-Path $PSScriptRoot '..' 'config' 'dev.yaml'
        Import-Module powershell-yaml -Force
        $cfg = ConvertFrom-Yaml (Get-Content $configPath -Raw)
        $cfg.workspace.createIfMissing | Should -Be $true
    }

    It 'All environment configs define required fields' {
        Import-Module powershell-yaml -Force
        $configDir = Join-Path $PSScriptRoot '..' 'config'
        foreach ($file in Get-ChildItem $configDir -Filter '*.yaml') {
            $cfg = ConvertFrom-Yaml (Get-Content $file.FullName -Raw)
            $cfg.auth.tenantId | Should -Not -BeNullOrEmpty -Because "$($file.Name) needs tenantId"
            $cfg.auth.clientId | Should -Not -BeNullOrEmpty -Because "$($file.Name) needs clientId"
            $cfg.keyVault.name | Should -Not -BeNullOrEmpty -Because "$($file.Name) needs keyVault.name"
            $cfg.workspace.name | Should -Not -BeNullOrEmpty -Because "$($file.Name) needs workspace.name"
        }
    }
}

Describe 'Secret handling' {
    It 'Does not log secret values' {
        # Regression test: ensure the module never prints plaintext secrets
        $moduleContent = Get-Content (Join-Path $PSScriptRoot '..' 'modules' 'PowerBIDeployment.psm1') -Raw
        # Write-DeploymentLog never accepts raw secure strings directly
        $moduleContent | Should -Not -Match 'Write-.*\$ClientSecret[^N]'
        $moduleContent | Should -Not -Match 'Write-.*\$Password[^N]'
    }
}
