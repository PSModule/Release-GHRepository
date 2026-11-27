[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'The Pester cases share the bootstrap and workflow fixtures.'
)]
[CmdletBinding()]
param()

BeforeAll {
    Import-Module -Name powershell-yaml -RequiredVersion 0.4.12
    $bootstrap = Join-Path -Path $PSScriptRoot -ChildPath '..\src\Initialize-ReleaseConfiguration.ps1'
}

Describe 'Resolving release settings from the candidate' {
    BeforeEach {
        $workspace = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $workflowDirectory = Join-Path -Path $workspace -ChildPath '.github\workflows'
        $null = New-Item -Path $workflowDirectory -ItemType Directory -Force
        $workflowPath = Join-Path -Path $workflowDirectory -ChildPath 'Release.yml'
        $settingsPath = Join-Path -Path $workspace -ChildPath '.github\alternate.yml'
        $workflow = @'
name: Release
on:
  pull_request:
    branches: [main]
    types: [closed]
jobs:
  Release:
    runs-on: ubuntu-latest
    steps:
      - uses: ./
        with:
          SettingsFilePath: .github/alternate.yml
'@
        $workflow | Set-Content -LiteralPath $workflowPath
        $parameters = @{
            WorkspacePath   = $workspace
            OutputPath      = ''
            PublisherBranch = 'main'
        }
    }

    It 'uses the candidate settings file specified by the publisher' {
        'DefaultBump: major' | Set-Content -LiteralPath $settingsPath

        $settings = & $bootstrap @parameters

        $settings.DefaultBump | Should -BeExactly 'major'
        $settings.DefaultBumpSource | Should -BeExactly 'RepositorySetting'
        $settings.Mode | Should -BeExactly 'calculate'
    }

    It 'uses the actual publisher override when it differs from the selected file' {
        "$workflow`n          DefaultBump: minor" | Set-Content -LiteralPath $workflowPath
        'DefaultBump: major' | Set-Content -LiteralPath $settingsPath

        $settings = & $bootstrap @parameters

        $settings.DefaultBump | Should -BeExactly 'minor'
        $settings.DefaultBumpSource | Should -BeExactly 'ActionInput'
    }

    It 'rejects a missing explicitly selected policy file instead of substituting a default' {
        "$workflow`n          DefaultBump: minor" | Set-Content -LiteralPath $workflowPath

        { & $bootstrap @parameters } | Should -Throw '*publisher*settings file*not found*'
    }

    It 'rejects invalid candidate settings even when a publisher override is valid' {
        "$workflow`n          DefaultBump: minor" | Set-Content -LiteralPath $workflowPath
        'DefaultBump: invalid' | Set-Content -LiteralPath $settingsPath

        { & $bootstrap @parameters } | Should -Throw '*Invalid DefaultBump*'
    }

    It 'rejects a repository setting that would put the publisher in Calculate mode' {
        'Mode: calculate' | Set-Content -LiteralPath $settingsPath

        { & $bootstrap @parameters } | Should -Throw '*publisher*publish*'
    }

    It 'rejects a publisher invocation that would only Calculate' {
        "$workflow`n          Mode: calculate" | Set-Content -LiteralPath $workflowPath
        'DefaultBump: major' | Set-Content -LiteralPath $settingsPath

        { & $bootstrap @parameters } | Should -Throw '*publisher*publish*'
    }

    It 'rejects a policy path outside the candidate checkout' {
        $outside = Join-Path -Path $TestDrive -ChildPath 'runner-settings.yml'
        'DefaultBump: major' | Set-Content -LiteralPath $outside
        $workflow.Replace('.github/alternate.yml', '../runner-settings.yml') | Set-Content -LiteralPath $workflowPath

        { & $bootstrap @parameters } | Should -Throw '*SettingsFilePath*inside the candidate checkout*'
    }
}
