#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.0.0'; MaximumVersion = '6.*' }
#Requires -Modules PSSemVer

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables are used by Pester test blocks.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidGlobalVars', '', Justification = 'Native command mocks share fixture state across script scopes and restore it after tests.'
)]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module -Name PSSemVer
    $script:mainPath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\main.ps1'
    $script:previousExitCode = $global:LASTEXITCODE
    $script:previousTestState = $global:ReleaseCleanupTestState
    $global:ReleaseCleanupTestState = @{}
    $script:previousEnvironment = @{}
    $script:inputDefaults = @{
        GITHUB_EVENT_PATH                                    = Join-Path -Path $TestDrive -ChildPath 'event.json'
        PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile        = Join-Path -Path $TestDrive -ChildPath 'missing.yml'
        PSMODULE_AUTO_RELEASE_INPUT_AutoCleanup              = 'true'
        PSMODULE_AUTO_RELEASE_INPUT_AutoPatching             = 'true'
        PSMODULE_AUTO_RELEASE_INPUT_CreateMajorTag           = 'true'
        PSMODULE_AUTO_RELEASE_INPUT_CreateMinorTag           = 'true'
        PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat     = ''
        PSMODULE_AUTO_RELEASE_INPUT_IgnoreLabels             = 'NoRelease'
        PSMODULE_AUTO_RELEASE_INPUT_IncrementalPrerelease    = 'true'
        PSMODULE_AUTO_RELEASE_INPUT_MajorLabels              = 'major, breaking'
        PSMODULE_AUTO_RELEASE_INPUT_MinorLabels              = 'minor, feature'
        PSMODULE_AUTO_RELEASE_INPUT_PatchLabels              = 'patch, fix'
        PSMODULE_AUTO_RELEASE_INPUT_UsePRBodyAsReleaseNotes  = 'true'
        PSMODULE_AUTO_RELEASE_INPUT_UsePRTitleAsReleaseName  = 'false'
        PSMODULE_AUTO_RELEASE_INPUT_UsePRTitleAsNotesHeading = 'true'
        PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix            = 'v'
        PSMODULE_AUTO_RELEASE_INPUT_WhatIf                   = 'false'
    }
    foreach ($name in $script:inputDefaults.Keys) {
        $script:previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }

    function Invoke-TestLogGroup {
        <#
            .SYNOPSIS
            Run an action log group in its shared script context.

            .DESCRIPTION
            Preserve the action's shared variables without depending on the GitHub logging runtime.
            This adapter does not validate the external logging integration.

            .EXAMPLE
            Invoke-TestLogGroup -Name 'Example' -ScriptBlock { $value = 1 }
            Make the group's value available to the calling script.
        #>
        [Alias('LogGroup')]
        [CmdletBinding()]
        param(
            # The log group name.
            [Parameter(Mandatory, Position = 0)]
            [string] $Name,

            # The action code to execute.
            [Parameter(Mandatory, Position = 1)]
            [scriptblock] $ScriptBlock
        )

        Write-Verbose -Message "Running test log group [$Name]."
        $initialVariables = @(Get-Variable -Scope Local | Select-Object -ExpandProperty Name)
        . $ScriptBlock
        foreach ($variable in Get-Variable -Scope Local) {
            if ($variable.Name -notin $initialVariables -and $variable.Name -notin @('initialVariables', 'variable')) {
                Set-Variable -Name $variable.Name -Value $variable.Value -Scope 1
            }
        }
    }

    function Write-GitHubNotice {
        <#
            .SYNOPSIS
            Accept a simulated action notice.

            .DESCRIPTION
            Avoid depending on the GitHub logging runtime in local tests.

            .EXAMPLE
            Write-GitHubNotice -Title 'Release created' -Message 'v1.2.4'
            Accept the action's notice without writing to GitHub.
        #>
        [CmdletBinding()]
        param(
            # The notice title.
            [Parameter()]
            [string] $Title,

            # The notice message.
            [Parameter()]
            [string] $Message
        )

        Write-Verbose -Message "$Title`: $Message"
    }
}

Describe 'Branch prerelease cleanup' {
    BeforeEach {
        foreach ($name in $script:inputDefaults.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:inputDefaults[$name])
        }
        $script:event = @{
            action       = 'closed'
            pull_request = @{
                merged = $false
                state  = 'closed'
                head   = @{ ref = 'feature/test' }
                base   = @{ ref = 'main' }
                labels = @()
                number = 42
                title  = 'Test release'
                body   = 'Test release notes'
            }
        }
        $global:ReleaseCleanupTestState.Releases = @(
            [pscustomobject]@{ tagName = 'v1.2.3'; isPrerelease = $false; isLatest = $true }
            [pscustomobject]@{ tagName = 'v0.1.0'; isPrerelease = $false; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.0.0-featuretest'; isPrerelease = $false; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4-featuretest'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4-featuretest.1'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4-featuretest.20261102.2'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4-featuretestextra.1'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4-otherfeaturetest.1'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4-other.1+featuretest'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4-other.1'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'notversion-featuretest.1'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4.5-featuretest.1'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4-featuretest.3'; isLatest = $false }
            [pscustomobject]@{ tagName = 'v1.2.4-featuretest.4'; isPrerelease = $null; isLatest = $false }
        )
        $script:deletedTags = [System.Collections.Generic.List[string]]::new()
        $global:ReleaseCleanupTestState.DeletedTags = $script:deletedTags
        $global:LASTEXITCODE = 0

        # Destructive GitHub and git boundaries are simulated; no real releases or tags are changed.
        Mock -CommandName Install-PSResource {}
        Mock -CommandName Import-Module {}
        Mock -CommandName git {}
        Mock -CommandName gh {
            if ($args[0] -eq 'repo' -and $args[1] -eq 'view') {
                return '{"defaultBranchRef":{"name":"main"}}'
            }
            if ($args[0] -eq 'release' -and $args[1] -eq 'list') {
                return ConvertTo-Json -InputObject $global:ReleaseCleanupTestState.Releases
            }
            if ($args[0] -eq 'release' -and $args[1] -eq 'delete') {
                $global:ReleaseCleanupTestState.DeletedTags.Add($args[2])
                return
            }
            if ($args[0] -eq 'release' -and $args[1] -eq 'create') {
                return 'https://example.invalid/releases/test'
            }
            if ($args[0] -eq 'pr' -and $args[1] -eq 'comment') {
                return
            }
            throw "Unexpected gh command: $($args -join ' ')"
        }
    }

    AfterEach {
        foreach ($name in $script:previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:previousEnvironment[$name])
        }
        $global:LASTEXITCODE = $script:previousExitCode
    }

    It 'Does not delete any release for the empty identifier from branch "<BranchName>" (merged: <Merged>)' -ForEach @(
        @{ BranchName = ''; Merged = $false }
        @{ BranchName = '_'; Merged = $false }
        @{ BranchName = '-'; Merged = $false }
        @{ BranchName = '---___'; Merged = $false }
        @{ BranchName = ''; Merged = $true }
        @{ BranchName = '_'; Merged = $true }
        @{ BranchName = '-'; Merged = $true }
        @{ BranchName = '---___'; Merged = $true }
    ) {
        $script:event.pull_request.head.ref = $BranchName
        $script:event.pull_request.merged = $Merged
        $script:event | ConvertTo-Json -Depth 5 | Set-Content -Path $env:GITHUB_EVENT_PATH

        & $script:mainPath | Out-Null

        $script:deletedTags.Count | Should -Be 0
    }

    It 'Deletes only exact branch prereleases for short or common branch "<BranchName>"' -ForEach @(
        @{ BranchName = 'v1'; ExpectedTag = 'v1.2.4-v1.1' }
        @{ BranchName = '1'; ExpectedTag = 'v1.2.4-1.1' }
        @{ BranchName = '0'; ExpectedTag = 'v1.2.4-0.1' }
    ) {
        $script:event.pull_request.head.ref = $BranchName
        $global:ReleaseCleanupTestState.Releases += @(
            [pscustomobject]@{ tagName = $ExpectedTag; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = "v1.2.4-${BranchName}extra.1"; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = "v1.2.4-other${BranchName}.1"; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = "v1.0.0-${BranchName}"; isPrerelease = $false; isLatest = $false }
        )
        $script:event | ConvertTo-Json -Depth 5 | Set-Content -Path $env:GITHUB_EVENT_PATH

        & $script:mainPath | Out-Null

        $script:deletedTags.Count | Should -Be 1
        $script:deletedTags[0] | Should -BeExactly $ExpectedTag
    }

    It 'Cleans up plain, incremental, and date-based branch prereleases (merged: <Merged>)' -ForEach @(
        @{ Merged = $false }
        @{ Merged = $true }
    ) {
        $script:event.pull_request.merged = $Merged
        $script:event | ConvertTo-Json -Depth 5 | Set-Content -Path $env:GITHUB_EVENT_PATH

        & $script:mainPath | Out-Null

        $script:deletedTags.Count | Should -Be 3
        $script:deletedTags[0] | Should -BeExactly 'v1.2.4-featuretest'
        $script:deletedTags[1] | Should -BeExactly 'v1.2.4-featuretest.1'
        $script:deletedTags[2] | Should -BeExactly 'v1.2.4-featuretest.20261102.2'
        if ($Merged) {
            Should -Invoke -CommandName gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq 'release' -and $args[1] -eq 'create' -and $args[2] -eq 'v1.2.4'
            }
        }
    }

    It 'Honors AutoCleanup being disabled' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_AutoCleanup = 'false'
        $script:event | ConvertTo-Json -Depth 5 | Set-Content -Path $env:GITHUB_EVENT_PATH

        & $script:mainPath | Out-Null

        $script:deletedTags.Count | Should -Be 0
    }

    It 'Does not clean up while the pull request is open' {
        $script:event.action = 'synchronize'
        $script:event.pull_request.state = 'open'
        $script:event | ConvertTo-Json -Depth 5 | Set-Content -Path $env:GITHUB_EVENT_PATH

        & $script:mainPath | Out-Null

        $script:deletedTags.Count | Should -Be 0
    }

    It 'Honors a custom literal version prefix' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix = 'release.v'
        $global:ReleaseCleanupTestState.Releases += @(
            [pscustomobject]@{ tagName = 'release.v1.2.4-featuretest.1'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = 'releaseXv1.2.4-featuretest.1'; isPrerelease = $true; isLatest = $false }
        )
        $script:event | ConvertTo-Json -Depth 5 | Set-Content -Path $env:GITHUB_EVENT_PATH

        & $script:mainPath | Out-Null

        $script:deletedTags.Count | Should -Be 1
        $script:deletedTags[0] | Should -BeExactly 'release.v1.2.4-featuretest.1'
    }

    It 'Supports tags without a version prefix' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix = ''
        $global:ReleaseCleanupTestState.Releases += @(
            [pscustomobject]@{ tagName = '1.2.4-featuretest.1'; isPrerelease = $true; isLatest = $false }
            [pscustomobject]@{ tagName = '1.2.3'; isPrerelease = $false; isLatest = $false }
        )
        $script:event | ConvertTo-Json -Depth 5 | Set-Content -Path $env:GITHUB_EVENT_PATH

        & $script:mainPath | Out-Null

        $script:deletedTags.Count | Should -Be 1
        $script:deletedTags[0] | Should -BeExactly '1.2.4-featuretest.1'
    }

    It 'Previews only intended deletions in WhatIf mode for branch "<BranchName>"' -ForEach @(
        @{ BranchName = '_'; ExpectedTags = @() }
        @{ BranchName = '1'; ExpectedTags = @('v1.2.4-1.1') }
        @{
            BranchName   = 'feature/test'
            ExpectedTags = @('v1.2.4-featuretest', 'v1.2.4-featuretest.1', 'v1.2.4-featuretest.20261102.2')
        }
    ) {
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'true'
        $script:event.pull_request.head.ref = $BranchName
        $global:ReleaseCleanupTestState.Releases += [pscustomobject]@{
            tagName = 'v1.2.4-1.1'; isPrerelease = $true; isLatest = $false
        }
        $script:event | ConvertTo-Json -Depth 5 | Set-Content -Path $env:GITHUB_EVENT_PATH

        $output = & $script:mainPath

        $previews = @($output | Where-Object { $_ -like 'WhatIf: gh release delete *' })
        $previews.Count | Should -Be $ExpectedTags.Count
        for ($index = 0; $index -lt $ExpectedTags.Count; $index++) {
            $previews[$index] | Should -BeExactly "WhatIf: gh release delete $($ExpectedTags[$index]) --cleanup-tag --yes"
        }
        $script:deletedTags.Count | Should -Be 0
        Should -Invoke -CommandName git -Times 0 -Exactly
    }
}

AfterAll {
    $global:ReleaseCleanupTestState = $script:previousTestState
}
