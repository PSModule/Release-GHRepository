[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables are assigned in Pester setup and used by tests and mocks.'
)]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module -Name GitHub, powershell-yaml, PSSemVer
    $mainPath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\main.ps1'
    $bootstrapPath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\Initialize-ReleaseConfiguration.ps1'
    $helperPath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\Release-GHRepository.Helpers.psm1'
    $actionPath = Join-Path -Path $PSScriptRoot -ChildPath '..\action.yml'
    $actionDefinition = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $actionPath -Raw)
    $readBootstrapOutputs = {
        param([string] $Path)

        $outputs = @{}
        $reader = [IO.File]::OpenText($Path)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ($line -match '\A([^=]+)=(.*)\z') {
                    $outputs[$Matches[1]] = $Matches[2]
                } elseif ($line -match '\A([^<]+)<<(.+)\z') {
                    $name = $Matches[1]
                    $delimiter = $Matches[2]
                    $lines = [Collections.Generic.List[string]]::new()
                    while ($null -ne ($line = $reader.ReadLine()) -and $line -cne $delimiter) {
                        $lines.Add($line)
                    }
                    if ($null -eq $line) {
                        throw 'The bootstrap output is missing its closing delimiter.'
                    }
                    $outputs[$name] = $lines -join "`n"
                } else {
                    throw 'The bootstrap wrote an invalid runner output command.'
                }
            }
        } finally {
            $reader.Dispose()
        }
        $outputs
    }
    $runRelease = {
        param(
            [string] $ControllerPath = $mainPath,
            [string] $ConfigurationPath = $bootstrapPath
        )

        $null = & $ConfigurationPath
        $outputs = & $readBootstrapOutputs -Path $env:GITHUB_OUTPUT
        $releaseSettings = ConvertFrom-Json -InputObject $outputs.ReleaseSettings
        Push-Location -LiteralPath $outputs.WorkingDirectory
        try {
            & $ControllerPath -Settings $releaseSettings
        } finally {
            Pop-Location
        }
    }
    $releaseSettingNames = @(
        'AutoCleanup'
        'DefaultBump'
        'CreateMajorTag'
        'CreateMinorTag'
        'DatePrereleaseFormat'
        'IncrementalPrerelease'
        'UsePRTitleAsReleaseName'
        'UsePRBodyAsReleaseNotes'
        'UsePRTitleAsNotesHeading'
        'VersionPrefix'
        'WhatIf'
    )
    $fixtureStandardsYaml = @'
AutoCleanup: false
DefaultBump: minor
CreateMajorTag: true
CreateMinorTag: true
DatePrereleaseFormat: ''
IncrementalPrerelease: true
UsePRTitleAsReleaseName: false
UsePRBodyAsReleaseNotes: true
UsePRTitleAsNotesHeading: true
VersionPrefix: v
WhatIf: false
'@
    $headSha = '0123456789012345678901234567890123456789'
    $squashCommitSha = 'fedcba9876543210fedcba9876543210fedcba98'
    $authoredBody = @'
This release preserves the source-bound adoption record.

## Adopting this release

1. Select the reviewed release.
2. Keep the caller's explicit settings.

<!-- ANNOUNCEMENT STOP -->
<details>
<summary>Technical details</summary>

The complete record remains part of the release notes.

</details>

Resolved release decision: release:major, stable.
'@
}

Describe 'Release-GHRepository configuration bootstrap' {
    BeforeEach {
        $bootstrapEnvironmentNames = @('GITHUB_WORKSPACE', 'GITHUB_OUTPUT') + @(
            $actionDefinition.inputs.Keys | ForEach-Object { "PSMODULE_AUTO_RELEASE_INPUT_$_" }
        )
        $bootstrapSavedEnvironment = @{}
        foreach ($environmentName in $bootstrapEnvironmentNames) {
            $bootstrapSavedEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName)
            [Environment]::SetEnvironmentVariable($environmentName, $null)
        }
        $workspace = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $workspace -ItemType Directory
        $env:GITHUB_WORKSPACE = $workspace
        $env:GITHUB_OUTPUT = Join-Path -Path $workspace -ChildPath 'outputs.txt'
        $selectedFile = Join-Path -Path $workspace -ChildPath 'settings [literal path].yml'
        $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath = $selectedFile
        Mock Install-PSResource { throw 'Bootstrap tests use the installed parsing modules.' }
    }

    AfterEach {
        foreach ($environmentName in $bootstrapEnvironmentNames) {
            [Environment]::SetEnvironmentVariable($environmentName, $bootstrapSavedEnvironment[$environmentName])
        }
    }

    It 'resolves all startup standards from the workspace before dependency startup' {
        $settings = & $bootstrapPath

        $settings.Debug | Should -BeFalse
        $settings.Verbose | Should -BeFalse
        $settings.Prerelease | Should -BeFalse
        $settings.Version | Should -BeExactly ''
        $settings.WorkingDirectory | Should -BeExactly $workspace
        $settings.DefaultBump | Should -BeExactly 'patch'
        $settings.DefaultBumpSource | Should -BeExactly 'SharedDefault'
        $outputs = & $readBootstrapOutputs -Path $env:GITHUB_OUTPUT
        $outputs.Count | Should -Be 6
        $outputs.Debug | Should -BeExactly 'false'
        $outputs.Verbose | Should -BeExactly 'false'
        $outputs.Prerelease | Should -BeExactly 'false'
        $outputs.Version | Should -BeExactly ''
        $outputs.WorkingDirectory | Should -BeExactly $workspace
        $releaseSettings = ConvertFrom-Json -InputObject $outputs.ReleaseSettings
        $releaseSettings.DefaultBump | Should -BeExactly 'patch'
        $releaseSettings.VersionPrefix | Should -BeExactly 'v'
        $releaseSettings.PSObject.Properties.Name | Should -Not -Contain 'Prerelease'
        Should -Invoke Install-PSResource -Times 0 -Exactly
    }

    It 'uses all five startup settings from a literal selected file' {
        $executionDirectory = Join-Path -Path $workspace -ChildPath 'execution [directory]'
        $null = New-Item -Path $executionDirectory -ItemType Directory
        @'
Debug: true
Verbose: true
Prerelease: true
Version: '[0.43.0, 1.0.0)'
WorkingDirectory: 'execution [directory]'
DefaultBump: major
'@ | Set-Content -LiteralPath $selectedFile

        $settings = & $bootstrapPath

        $settings.Debug | Should -BeTrue
        $settings.Verbose | Should -BeTrue
        $settings.Prerelease | Should -BeTrue
        $settings.Version | Should -BeExactly '[0.43.0, 1.0.0)'
        $settings.WorkingDirectory | Should -BeExactly $executionDirectory
        $settings.DefaultBump | Should -BeExactly 'major'
        $settings.DefaultBumpSource | Should -BeExactly 'RepositorySetting'
        $outputs = & $readBootstrapOutputs -Path $env:GITHUB_OUTPUT
        $outputs.Debug | Should -BeExactly 'true'
        $outputs.Verbose | Should -BeExactly 'true'
        $outputs.Prerelease | Should -BeExactly 'true'
        $outputs.Version | Should -BeExactly '[0.43.0, 1.0.0)'
        $outputs.WorkingDirectory | Should -BeExactly $executionDirectory
        $releaseSettings = ConvertFrom-Json -InputObject $outputs.ReleaseSettings
        $releaseSettings.DefaultBump | Should -BeExactly 'major'
        $releaseSettings.DefaultBumpSource | Should -BeExactly 'RepositorySetting'
    }

    It 'selects a relative file from <InitialDirectory> without rediscovery after file WorkingDirectory' -ForEach @(
        @{ InitialDirectory = 'github.workspace'; ExplicitDirectory = $false }
        @{ InitialDirectory = 'an explicit WorkingDirectory'; ExplicitDirectory = $true }
    ) {
        $initialDirectory = $workspace
        if ($ExplicitDirectory) {
            $initialDirectory = Join-Path -Path $workspace -ChildPath 'initial [directory]'
            $null = New-Item -Path $initialDirectory -ItemType Directory
            $env:PSMODULE_AUTO_RELEASE_INPUT_WorkingDirectory = 'initial [directory]'
        }
        $executionDirectory = Join-Path -Path $workspace -ChildPath 'execution [directory]'
        $null = New-Item -Path $executionDirectory -ItemType Directory
        $relativeFile = 'settings [selected].yml'
        @'
WorkingDirectory: 'execution [directory]'
DefaultBump: minor
'@ | Set-Content -LiteralPath (Join-Path -Path $initialDirectory -ChildPath $relativeFile)
        'DefaultBump: invalid' | Set-Content -LiteralPath (Join-Path -Path $executionDirectory -ChildPath $relativeFile)
        $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath = $relativeFile

        Push-Location -LiteralPath $TestDrive
        try {
            $settings = & $bootstrapPath
        } finally {
            Pop-Location
        }

        $settings.DefaultBump | Should -BeExactly 'minor'
        $settings.DefaultBumpSource | Should -BeExactly 'RepositorySetting'
        if ($ExplicitDirectory) {
            $settings.WorkingDirectory | Should -BeExactly $initialDirectory
        } else {
            $settings.WorkingDirectory | Should -BeExactly $executionDirectory
        }
    }

    It 'keeps all startup file values when named inputs are <InputState>' -ForEach @(
        @{ InputState = 'omitted'; InputValue = $null }
        @{ InputState = 'empty'; InputValue = '' }
    ) {
        @'
Debug: true
Verbose: true
Prerelease: true
Version: '[0.43.1]'
WorkingDirectory: '.'
'@ | Set-Content -LiteralPath $selectedFile
        foreach ($name in @('Debug', 'Verbose', 'Prerelease', 'Version', 'WorkingDirectory')) {
            [Environment]::SetEnvironmentVariable("PSMODULE_AUTO_RELEASE_INPUT_$name", $InputValue)
        }

        $settings = & $bootstrapPath

        $settings.Debug | Should -BeTrue
        $settings.Verbose | Should -BeTrue
        $settings.Prerelease | Should -BeTrue
        $settings.Version | Should -BeExactly '[0.43.1]'
        $settings.WorkingDirectory | Should -BeExactly $workspace
    }

    It 'applies named false and standard-valued startup overrides' {
        $executionDirectory = Join-Path -Path $workspace -ChildPath 'execution'
        $null = New-Item -Path $executionDirectory -ItemType Directory
        @'
Debug: true
Verbose: true
Prerelease: true
Version: '[0.43.0, 1.0.0)'
WorkingDirectory: execution
'@ | Set-Content -LiteralPath $selectedFile
        $env:PSMODULE_AUTO_RELEASE_INPUT_Debug = 'false'
        $env:PSMODULE_AUTO_RELEASE_INPUT_Verbose = 'FALSE'
        $env:PSMODULE_AUTO_RELEASE_INPUT_Prerelease = 'false'
        $env:PSMODULE_AUTO_RELEASE_INPUT_Version = '[0.43.1]'
        $env:PSMODULE_AUTO_RELEASE_INPUT_WorkingDirectory = $workspace

        $settings = & $bootstrapPath

        $settings.Debug | Should -BeFalse
        $settings.Verbose | Should -BeFalse
        $settings.Prerelease | Should -BeFalse
        $settings.Version | Should -BeExactly '[0.43.1]'
        $settings.WorkingDirectory | Should -BeExactly $workspace
    }

    It 'accepts empty file Version text as latest dependency selection' {
        "Version: ''" | Set-Content -LiteralPath $selectedFile

        $settings = & $bootstrapPath

        $settings.Version | Should -BeExactly ''
    }

    It 'rejects an invalid file <Name> even when a valid named override would mask it' -ForEach @(
        @{ Name = 'Debug'; InvalidValue = 'yes'; InputValue = 'false'; Message = '*Debug*true or false*' }
        @{ Name = 'Verbose'; InvalidValue = 'null'; InputValue = 'false'; Message = '*Verbose*true or false*' }
        @{ Name = 'Prerelease'; InvalidValue = '1'; InputValue = 'true'; Message = '*Prerelease*true or false*' }
        @{ Name = 'Version'; InvalidValue = 'inherit'; InputValue = '[0.43.1]'; Message = '*Version*version*' }
        @{ Name = 'WorkingDirectory'; InvalidValue = 'missing'; InputValue = '.'; Message = '*WorkingDirectory*directory*' }
    ) {
        "$Name`: $InvalidValue" | Set-Content -LiteralPath $selectedFile
        [Environment]::SetEnvironmentVariable("PSMODULE_AUTO_RELEASE_INPUT_$Name", $InputValue)

        { & $bootstrapPath } | Should -Throw $Message
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'rejects invalid selected paths rather than treating them as absent files' -ForEach @(
        @{ PathCase = 'empty'; Value = ''; Message = '*SettingsFilePath*nonempty path*' }
        @{ PathCase = 'whitespace'; Value = ' '; Message = '*SettingsFilePath*nonempty path*' }
        @{ PathCase = 'directory'; Value = '.'; Message = '*SettingsFilePath*file*' }
        @{ PathCase = 'provider'; Value = 'Env:\PATH'; Message = '*SettingsFilePath*path*' }
    ) {
        [Environment]::SetEnvironmentVariable('PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath', $Value)

        { & $bootstrapPath } | Should -Throw $Message
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'rejects invalid named startup <SettingName> before writing the handoff' -ForEach @(
        @{ SettingName = 'Debug'; InputValue = ' yes '; Message = '*Debug*true or false*' }
        @{ SettingName = 'Verbose'; InputValue = ' '; Message = '*Verbose*true or false*' }
        @{ SettingName = 'Prerelease'; InputValue = '1'; Message = '*Prerelease*true or false*' }
        @{ SettingName = 'Version'; InputValue = 'latest'; Message = '*Version*version*' }
        @{ SettingName = 'Version'; InputValue = '[2.0.0, 1.0.0)'; Message = '*Version*version*' }
        @{ SettingName = 'WorkingDirectory'; InputValue = 'missing'; Message = '*WorkingDirectory*directory*' }
    ) {
        @'
Debug: false
Verbose: false
Prerelease: false
Version: '[0.43.1]'
WorkingDirectory: '.'
'@ | Set-Content -LiteralPath $selectedFile
        [Environment]::SetEnvironmentVariable("PSMODULE_AUTO_RELEASE_INPUT_$SettingName", $InputValue)

        { & $bootstrapPath } | Should -Throw $Message
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'rejects SettingsFilePath as a settings-file key' {
        'SettingsFilePath: another.yml' | Set-Content -LiteralPath $selectedFile

        { & $bootstrapPath } | Should -Throw '*Unsupported release setting*SettingsFilePath*'
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }
}

Describe 'Release-GHRepository caller compatibility' {
    BeforeEach {
        $environmentNames = @(
            'GITHUB_REPOSITORY'
            'GITHUB_EVENT_PATH'
            'GITHUB_WORKSPACE'
            'GITHUB_OUTPUT'
            'PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile'
            'PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath'
            'PSMODULE_AUTO_RELEASE_INPUT_AutoCleanup'
            'PSMODULE_AUTO_RELEASE_INPUT_DefaultBump'
            'PSMODULE_AUTO_RELEASE_INPUT_CreateMajorTag'
            'PSMODULE_AUTO_RELEASE_INPUT_CreateMinorTag'
            'PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat'
            'PSMODULE_AUTO_RELEASE_INPUT_IncrementalPrerelease'
            'PSMODULE_AUTO_RELEASE_INPUT_UsePRTitleAsReleaseName'
            'PSMODULE_AUTO_RELEASE_INPUT_UsePRBodyAsReleaseNotes'
            'PSMODULE_AUTO_RELEASE_INPUT_UsePRTitleAsNotesHeading'
            'PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix'
            'PSMODULE_AUTO_RELEASE_INPUT_WhatIf'
            'PSMODULE_AUTO_RELEASE_INPUT_Debug'
            'PSMODULE_AUTO_RELEASE_INPUT_Verbose'
            'PSMODULE_AUTO_RELEASE_INPUT_WorkingDirectory'
            'PSMODULE_AUTO_RELEASE_INPUT_Version'
            'PSMODULE_AUTO_RELEASE_INPUT_Prerelease'
        )
        $savedEnvironment = @{}
        foreach ($name in $environmentNames) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            if (Test-Path -LiteralPath "Env:\$name") {
                Remove-Item -LiteralPath "Env:\$name"
            }
        }

        $env:GITHUB_REPOSITORY = 'example/repository'
        $env:GITHUB_EVENT_PATH = Join-Path -Path $TestDrive -ChildPath 'event.json'
        $env:GITHUB_WORKSPACE = $TestDrive
        $env:GITHUB_OUTPUT = Join-Path -Path $TestDrive -ChildPath ('outputs-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        $settingsFileName = 'settings [custom path] {0}.yml' -f [guid]::NewGuid().ToString('N')
        $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath = Join-Path -Path $TestDrive -ChildPath $settingsFileName
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'true'
        $githubEvent = @{
            action       = 'opened'
            pull_request = @{
                number = 42
                title  = 'The complete authored record is preserved'
                body   = $authoredBody
                merged = $false
                state  = 'open'
                base   = @{ ref = 'main' }
                head   = @{ ref = 'feature/caller'; sha = $headSha }
                labels = @()
            }
        }
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $releaseRecordsJson = '[{"tagName":"v2.0.3","isLatest":true,"isPrerelease":false}]'
        $simulateLabelWrites = $false
        Mock Install-PSResource {}
        Mock Write-GitHubNotice {}
        Mock git { throw 'A caller compatibility test must never invoke git.' }
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'repo' -and $args[1] -eq 'view') {
                '{"defaultBranchRef":{"name":"main"}}'
            } elseif ($args[0] -eq 'release' -and $args[1] -eq 'list') {
                $releaseRecordsJson
            } elseif ($simulateLabelWrites -and $args[0] -eq 'label' -and $args[1] -eq 'create') {
                return
            } else {
                throw "A caller compatibility test must never mutate GitHub: gh $($args -join ' ')"
            }
        }
    }

    AfterEach {
        foreach ($name in $environmentNames) {
            if ($null -eq $savedEnvironment[$name]) {
                if (Test-Path -LiteralPath "Env:\$name") {
                    Remove-Item -LiteralPath "Env:\$name"
                }
            } else {
                [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
            }
        }
    }

    It 'uses action standards without repository settings or injected input defaults' {
        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Default bump:\s+\[patch\]'
        $output | Should -Match 'Auto cleanup enabled:\s+\[True\]'
        $output | Should -Match 'Use PR body as release notes:\s+\[True\]'
        $output | Should -Match 'gh release create v2\.0\.4 '
        $output.Contains($authoredBody) | Should -BeTrue
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'validates metadata-owned standards when they are <StandardsState>' -ForEach @(
        @{ StandardsState = 'valid'; Message = $null }
        @{ StandardsState = 'missing'; Message = '*action release standards*YAML mapping*' }
        @{ StandardsState = 'empty'; Message = '*action release standards*YAML mapping*' }
        @{ StandardsState = 'scalar'; Message = '*action release standards*mapping*' }
        @{ StandardsState = 'unknown'; Message = '*Unsupported release setting*DefaultBunp*' }
        @{ StandardsState = 'null value'; Message = '*WhatIf*true or false*' }
        @{ StandardsState = 'invalid bump'; Message = '*Invalid DefaultBump*' }
        @{ StandardsState = 'incomplete'; Message = '*standard defaults*missing*WhatIf*' }
        @{ StandardsState = 'invalid startup boolean'; Message = '*Debug*true or false*' }
        @{ StandardsState = 'invalid startup version'; Message = '*Version*version*' }
        @{ StandardsState = 'invalid directory standard'; Message = '*WorkingDirectory*directory*' }
        @{ StandardsState = 'nonmapping definition'; Message = '*Invalid metadata*Debug*' }
        @{ StandardsState = 'missing default'; Message = '*Invalid metadata*Debug*' }
        @{ StandardsState = 'unknown type'; Message = '*Invalid metadata type*Debug*' }
        @{ StandardsState = 'unknown phase'; Message = '*Invalid metadata phase*Debug*' }
        @{ StandardsState = 'extra definition field'; Message = '*Invalid metadata*Debug*' }
    ) {
        $fixtureDirectory = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $fixtureSource = Join-Path -Path $fixtureDirectory -ChildPath 'src'
        $null = New-Item -Path $fixtureSource -ItemType Directory -Force
        Copy-Item -LiteralPath $mainPath, $helperPath, $bootstrapPath -Destination $fixtureSource
        $fixtureMetadata = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $actionPath -Raw)
        $standardData = ConvertFrom-Yaml -Yaml $fixtureMetadata.runs.steps[0].env.PSMODULE_AUTO_RELEASE_SETTING_METADATA
        $fixtureStandards = ConvertFrom-Yaml -Yaml $fixtureStandardsYaml
        foreach ($name in $fixtureStandards.Keys) {
            $standardData[$name].Default = $fixtureStandards[$name]
        }
        switch ($StandardsState) {
            'unknown' { $standardData.DefaultBunp = @{ Type = 'Bump'; Default = 'minor'; Phase = 'Release' } }
            'null value' { $standardData.WhatIf.Default = $null }
            'invalid bump' { $standardData.DefaultBump.Default = 'date' }
            'incomplete' { $standardData.Remove('WhatIf') }
            'invalid startup boolean' { $standardData.Debug.Default = 'yes' }
            'invalid startup version' { $standardData.Version.Default = 'not-a-version' }
            'invalid directory standard' { $standardData.WorkingDirectory.Default = 'missing' }
            'nonmapping definition' { $standardData.Debug = $true }
            'missing default' { $standardData.Debug.Remove('Default') }
            'unknown type' { $standardData.Debug.Type = 'Flag' }
            'unknown phase' { $standardData.Debug.Phase = 'Dependency' }
            'extra definition field' { $standardData.Debug.Unexpected = $true }
        }
        $standardYaml = ConvertTo-Yaml -Data $standardData
        if ($StandardsState -eq 'empty') {
            $standardYaml = ''
        } elseif ($StandardsState -eq 'scalar') {
            $standardYaml = 'minor'
        }
        $fixtureMetadata.runs.steps[0].env.PSMODULE_AUTO_RELEASE_SETTING_METADATA = $standardYaml
        if ($StandardsState -eq 'missing') {
            $fixtureMetadata.runs.steps[0].env.Remove('PSMODULE_AUTO_RELEASE_SETTING_METADATA')
        }
        ConvertTo-Yaml -Data $fixtureMetadata |
            Set-Content -LiteralPath (Join-Path -Path $fixtureDirectory -ChildPath 'action.yml')
        $fixtureMainPath = Join-Path -Path $fixtureSource -ChildPath 'main.ps1'
        $fixtureBootstrapPath = Join-Path -Path $fixtureSource -ChildPath 'Initialize-ReleaseConfiguration.ps1'

        Push-Location -LiteralPath $TestDrive
        try {
            if ($Message) {
                $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'
                $env:PSMODULE_AUTO_RELEASE_INPUT_Debug = 'false'
                $env:PSMODULE_AUTO_RELEASE_INPUT_Version = '[0.43.1]'
                $env:PSMODULE_AUTO_RELEASE_INPUT_WorkingDirectory = $TestDrive
                { & $runRelease -ControllerPath $fixtureMainPath -ConfigurationPath $fixtureBootstrapPath } |
                    Should -Throw $Message
                Should -Invoke gh -Times 0 -Exactly
            } else {
                $output = (& $runRelease -ControllerPath $fixtureMainPath -ConfigurationPath $fixtureBootstrapPath) -join "`n"

                $output | Should -Match 'Default bump:\s+\[minor\]'
                $output | Should -Match 'Default bump source:\s+\[SharedDefault\]'
                $output | Should -Match 'Auto cleanup enabled:\s+\[False\]'
                $output | Should -Match 'gh release create v2\.1\.0 '
                Should -Invoke gh -Times 2 -Exactly
            }
        } finally {
            Pop-Location
        }
        Should -Invoke git -Times 0 -Exactly
    }

    It 'uses the declared SettingsFilePath default when the file is <FileState>' -ForEach @(
        @{
            FileState       = 'present'
            FilePresent     = $true
            ExpectedBump    = 'minor'
            ExpectedSource  = 'RepositorySetting'
            ExpectedVersion = 'v2.1.0'
        }
        @{
            FileState       = 'absent'
            FilePresent     = $false
            ExpectedBump    = 'patch'
            ExpectedSource  = 'SharedDefault'
            ExpectedVersion = 'v2.0.4'
        }
    ) {
        $defaultSettingsPath = '.github\auto-release.yml'
        $callerDirectory = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path (Join-Path -Path $callerDirectory -ChildPath '.github') -ItemType Directory
        if ($FilePresent) {
            'DefaultBump: minor' | Set-Content -LiteralPath (Join-Path -Path $callerDirectory -ChildPath $defaultSettingsPath)
        }
        Remove-Item -LiteralPath 'Env:\PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath'
        $env:GITHUB_WORKSPACE = $callerDirectory

        Push-Location -LiteralPath $callerDirectory
        try {
            $output = (& $runRelease) -join "`n"
        } finally {
            Pop-Location
        }

        $output | Should -Match "Default bump:\s+\[$ExpectedBump\]"
        $output | Should -Match "Default bump source:\s+\[$ExpectedSource\]"
        $output | Should -Match "gh release create $([regex]::Escape($ExpectedVersion)) "
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'rejects a <PathDescription> SettingsFilePath before contacting GitHub' -ForEach @(
        @{ PathDescription = 'blank'; PathValue = '' }
        @{ PathDescription = 'whitespace-only'; PathValue = ' ' }
    ) {
        [Environment]::SetEnvironmentVariable('PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath', $PathValue)

        { & $runRelease } | Should -Throw '*SettingsFilePath must be a nonempty path.*'
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'uses a caller minor default for an unlabeled pull request' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'minor'

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Default bump:\s+\[minor\]'
        $output | Should -Match 'gh release create v2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
    }

    It 'keeps repository policy when the runner supplies empty release inputs' {
        foreach ($settingName in $releaseSettingNames) {
            [Environment]::SetEnvironmentVariable("PSMODULE_AUTO_RELEASE_INPUT_$settingName", '')
        }
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'true'
        @'
DefaultBump: minor
AutoCleanup: false
DatePrereleaseFormat: ''
VersionPrefix: ''
'@ | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Default bump:\s+\[minor\]'
        $output | Should -Match 'Auto cleanup enabled:\s+\[False\]'
        $output | Should -Match 'Date-based prerelease format:\s+\[\]'
        $output | Should -Match 'gh release create 2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'distinguishes existing file policy from a named bump that is <InputState>' -ForEach @(
        @{
            InputState      = 'omitted'
            InputValue      = $null
            ExpectedBump    = 'major'
            ExpectedSource  = 'RepositorySetting'
            ExpectedVersion = 'v3.0.0'
        }
        @{
            InputState      = 'empty'
            InputValue      = ''
            ExpectedBump    = 'major'
            ExpectedSource  = 'RepositorySetting'
            ExpectedVersion = 'v3.0.0'
        }
        @{
            InputState      = 'equal to the standard'
            InputValue      = 'patch'
            ExpectedBump    = 'patch'
            ExpectedSource  = 'ActionInput'
            ExpectedVersion = 'v2.0.4'
        }
    ) {
        if ($null -ne $InputValue) {
            $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = $InputValue
        }
        'DefaultBump: major' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        $output = (& $runRelease) -join "`n"

        $output | Should -Match "Default bump:\s+\[$ExpectedBump\]"
        $output | Should -Match "Default bump source:\s+\[$ExpectedSource\]"
        $output | Should -Match "gh release create $([regex]::Escape($ExpectedVersion)) "
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'keeps action standards when all release inputs are empty' {
        foreach ($settingName in $releaseSettingNames) {
            [Environment]::SetEnvironmentVariable("PSMODULE_AUTO_RELEASE_INPUT_$settingName", '')
        }
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'true'

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Default bump:\s+\[patch\]'
        $output | Should -Match 'Default bump source:\s+\[SharedDefault\]'
        $output | Should -Match 'gh release create v2\.0\.4 '
        Should -Invoke gh -Times 2 -Exactly
    }

    It 'lets release:major override a file minor default and preserves the complete record' {
        'DefaultBump: minor' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $githubEvent.pull_request.labels = @(@{ name = 'release:major' }, @{ name = 'dependencies' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Default bump applied:\s+\[False\]'
        $output | Should -Match 'gh release create v3\.0\.0 '
        $output.Contains($authoredBody) | Should -BeTrue
        $output | Should -Match '# The complete authored record is preserved \(#42\)'
        Should -Invoke gh -Times 2 -Exactly
    }

    It 'ignores dependency, retired, and bare labels when using the caller default' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'minor'
        $githubEvent.pull_request.labels = @(
            @{ name = 'major' }
            @{ name = 'dependencies' }
            @{ name = 'release:pre-release' }
        )
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Default bump applied:\s+\[True\]'
        $output | Should -Match 'Create a prerelease:\s+\[False\]'
        $output | Should -Match 'gh release create v2\.1\.0 '
    }

    It 'lets a named DefaultBump override repository policy' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'minor'
        'DefaultBump: major' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Default bump:\s+\[minor\]'
        $output | Should -Match 'Default bump source:\s+\[ActionInput\]'
        $output | Should -Match 'Bump source:\s+\[ActionInput\]'
        $output | Should -Match 'gh release create v2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
    }

    It 'applies named patch and false while an empty text input keeps file policy' {
        @'
DefaultBump: major
AutoCleanup: true
VersionPrefix: v
'@ | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'
        $env:PSMODULE_AUTO_RELEASE_INPUT_AutoCleanup = 'false'
        $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix = ''

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Default bump:\s+\[patch\]'
        $output | Should -Match 'Default bump source:\s+\[ActionInput\]'
        $output | Should -Match 'Auto cleanup enabled:\s+\[False\]'
        $output | Should -Match 'Version prefix:\s+\[v\]'
        $output | Should -Match 'gh release create v2\.0\.4 '
        Should -Invoke gh -Times 2 -Exactly
    }

    It 'does not mask an invalid file value with a valid explicit caller override' {
        'DefaultBump: invalid' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'

        { & $runRelease } | Should -Throw '*DefaultBump*'
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'keeps validation read-only when explicit WhatIf overrides a false repository setting' {
        'WhatIf: false' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'What if mode:\s+\[True\]'
        $output | Should -Match 'WhatIf: gh label create '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'keeps the configured prerelease date format when its input is empty' {
        @'
DatePrereleaseFormat: "'fixed'"
'@ | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat = ''
        $githubEvent.pull_request.labels = @(@{ name = 'release:prerelease' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $output | Should -Match "Date-based prerelease format:\s+\['fixed'\]"
        $output | Should -Match 'gh release create v2\.0\.4-featurecaller\.fixed\.1 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'keeps a true file WhatIf policy when its named input is empty' {
        'WhatIf: true' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = ''

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'What if mode:\s+\[True\]'
        $output | Should -Match 'WhatIf: gh label create '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'treats literal inherit as ordinary prefix text rather than an omission marker' {
        'VersionPrefix: repo-' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix = 'inherit'
        $githubEvent.pull_request.labels = @(@{ name = 'release:skip' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Version prefix:\s+\[inherit\]'
        $output | Should -Match 'Skipping release creation\.'
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'accepts explicit false for WhatIf as a real override with only simulated label writes' {
        'WhatIf: true' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'false'
        $simulateLabelWrites = $true
        $githubEvent.pull_request.labels = @(@{ name = 'release:skip' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'What if mode:\s+\[False\]'
        $output | Should -Match 'Skipping release creation\.'
        Should -Invoke gh -Times 5 -Exactly -ParameterFilter { $args[0] -eq 'label' -and $args[1] -eq 'create' }
        Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'release' -and $args[1] -eq 'create' }
        Should -Invoke git -Times 0 -Exactly
    }

    It 'rejects invalid named inputs before contacting GitHub' -ForEach @(
        @{ InputName = 'DefaultBump'; Value = 'date'; Message = '*DefaultBump*' }
        @{ InputName = 'DefaultBump'; Value = 'inherit'; Message = '*DefaultBump*' }
        @{ InputName = 'DefaultBump'; Value = ' '; Message = '*DefaultBump*' }
        @{ InputName = 'WhatIf'; Value = 'invalid'; Message = '*WhatIf*true or false*' }
        @{ InputName = 'WhatIf'; Value = 'inherit'; Message = '*WhatIf*true or false*' }
        @{ InputName = 'WhatIf'; Value = ' '; Message = '*WhatIf*true or false*' }
    ) {
        [Environment]::SetEnvironmentVariable("PSMODULE_AUTO_RELEASE_INPUT_$InputName", $Value)

        { & $runRelease } | Should -Throw $Message
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'validates a merged skipped pull request successfully without planning publication' {
        $githubEvent.pull_request.labels = @(@{ name = 'release:skip' })
        $githubEvent.pull_request.merged = $true
        $githubEvent.pull_request.state = 'closed'
        $githubEvent.action = 'closed'
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Skip release:\s+\[True\]'
        $output | Should -Match 'Skipping release creation\.'
        $output | Should -Not -Match 'gh release create|git push|git tag'
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke Write-GitHubNotice -Times 0 -Exactly
    }

    It 'validates a skipped branch even when it has no ASCII prerelease identifier' {
        $githubEvent.pull_request.head.ref = ([char] 0x2603).ToString()
        $githubEvent.pull_request.labels = @(@{ name = 'release:skip' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Skip release:\s+\[True\]'
        $output | Should -Match 'no prerelease identifier'
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'validates a closed skip without parsing a malformed latest version while retaining cleanup' {
        $releaseRecordsJson = @'
[{"tagName":"not-a-semver","isLatest":true,"isPrerelease":false},{"tagName":"v2.0.4-featurecaller.1","isLatest":false,"isPrerelease":true}]
'@
        $githubEvent.pull_request.labels = @(@{ name = 'release:skip' })
        $githubEvent.pull_request.merged = $true
        $githubEvent.pull_request.state = 'closed'
        $githubEvent.action = 'closed'
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'Skipping release creation\.'
        $output | Should -Match 'WhatIf: gh release delete v2\.0\.4-featurecaller\.1'
        $output | Should -Not -Match 'gh release create|git tag|git push'
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'keeps the bootstrap policy when files and raw inputs change after resolution' {
        @'
DefaultBump: major
WhatIf: true
'@ | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $null = & $bootstrapPath
        $outputs = & $readBootstrapOutputs -Path $env:GITHUB_OUTPUT
        $releaseSettings = ConvertFrom-Json -InputObject $outputs.ReleaseSettings
        'Version: invalid' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'minor'
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'false'

        $output = (& $mainPath -Settings $releaseSettings) -join "`n"

        $output | Should -Match 'Default bump:\s+\[major\]'
        $output | Should -Match 'Default bump source:\s+\[RepositorySetting\]'
        $output | Should -Match 'What if mode:\s+\[True\]'
        $output | Should -Match 'gh release create v3\.0\.0 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'keeps dependency Prerelease separate from repository prerelease mode' {
        @'
Prerelease: true
Version: '[0.43.0, 1.0.0)'
'@ | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        $output = (& $runRelease) -join "`n"

        $outputs = & $readBootstrapOutputs -Path $env:GITHUB_OUTPUT
        $outputs.Prerelease | Should -BeExactly 'true'
        $outputs.Version | Should -BeExactly '[0.43.0, 1.0.0)'
        $output | Should -Match 'Create a prerelease:\s+\[False\]'
        $output | Should -Match 'gh release create v2\.0\.4 '
        $output | Should -Not -Match '--prerelease'
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'plans cleanup only at the effective prefix boundary for <PrefixCase>' -ForEach @(
        @{
            PrefixCase     = 'the own branch after version-like text'
            Prefix         = 'release-1.2.3-'
            TagName        = 'release-1.2.3-2.0.4-feature.1'
            DeleteExpected = $true
        }
        @{
            PrefixCase     = 'another branch after identifier-like text'
            Prefix         = 'release-1.2.3-feature.extra-'
            TagName        = 'release-1.2.3-feature.extra-2.0.4-other.1'
            DeleteExpected = $false
        }
    ) {
        "VersionPrefix: '$Prefix'" | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $releaseRecordsJson = ConvertTo-Json -InputObject @(
            @{ tagName = 'v2.0.3'; isLatest = $true; isPrerelease = $false }
            @{ tagName = $TagName; isLatest = $false; isPrerelease = $true }
        )
        $githubEvent.pull_request.head.ref = 'feature'
        $githubEvent.pull_request.labels = @(@{ name = 'release:skip' })
        $githubEvent.pull_request.state = 'closed'
        $githubEvent.action = 'closed'
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $deleteCommand = "WhatIf: gh release delete $TagName --cleanup-tag --yes"
        $output.Contains($deleteCommand) | Should -Be $DeleteExpected
        $output | Should -Not -Match 'gh release create|git tag|git push'
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'targets a prerelease at the exact pull-request head without executing publication commands' {
        $githubEvent.pull_request.labels = @(@{ name = 'release:prerelease' }, @{ name = 'release:minor' })
        $githubEvent.pull_request.merge_commit_sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $runRelease) -join "`n"

        $output | Should -Match 'gh release create v2\.1\.0-featurecaller\.1 '
        $output | Should -Match "--target $headSha --prerelease"
        $output | Should -Match 'WhatIf: gh pr comment 42 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    Context 'Stable publication from a merged pull request' {
        BeforeEach {
            $githubEvent.action = 'closed'
            $githubEvent.pull_request.merged = $true
            $githubEvent.pull_request.state = 'closed'
            $githubEvent.pull_request.merge_commit_sha = $squashCommitSha
            $githubEvent.pull_request.labels = @(@{ name = 'release:major' })
            $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH
            $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'false'
            $simulateLabelWrites = $true
            Mock git { $global:LASTEXITCODE = 0 }
            Mock gh { $global:LASTEXITCODE = 0 } -ParameterFilter {
                $args[0] -eq 'release' -and $args[1] -eq 'create'
            }
        }

        It 'points the version tag and both enabled aliases at the squash commit' {
            $null = & $runRelease

            Should -Invoke git -Times 3 -Exactly
            Should -Invoke git -Times 1 -Exactly -ParameterFilter {
                ($args -join ' ') -ceq "fetch --no-tags origin $squashCommitSha"
            }
            Should -Invoke git -Times 1 -Exactly -ParameterFilter {
                ($args -join ' ') -ceq "push --no-follow-tags origin ${squashCommitSha}:refs/tags/v3.0.0"
            }
            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -eq 'release' -and $args[1] -eq 'create' -and $args[2] -eq 'v3.0.0' -and
                $args -contains '--verify-tag' -and $args[-1] -ceq $squashCommitSha -and
                $args -notcontains '--prerelease'
            }
            Should -Invoke git -Times 1 -Exactly -ParameterFilter {
                ($args -join ' ') -ceq "push --no-follow-tags origin +${squashCommitSha}:refs/tags/v3 +${squashCommitSha}:refs/tags/v3.0"
            }
        }

        It 'does not update disabled aliases' {
            $env:PSMODULE_AUTO_RELEASE_INPUT_CreateMajorTag = 'false'
            $env:PSMODULE_AUTO_RELEASE_INPUT_CreateMinorTag = 'false'

            $null = & $runRelease

            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'push' }
            Should -Invoke git -Times 1 -Exactly -ParameterFilter {
                ($args -join ' ') -ceq "push --no-follow-tags origin ${squashCommitSha}:refs/tags/v3.0.0"
            }
        }

        It 'does not publish or move aliases if Git rejects the version tag' {
            Mock git { $global:LASTEXITCODE = 1 } -ParameterFilter {
                $args[0] -eq 'push' -and $args -contains "${squashCommitSha}:refs/tags/v3.0.0"
            }

            { & $runRelease } | Should -Throw '*version tag*v3.0.0*'

            Should -Invoke gh -Times 0 -Exactly -ParameterFilter {
                $args[0] -eq 'release' -and $args[1] -eq 'create'
            }
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $args[0] -eq 'push' }
        }

        It 'rejects a <SourceCase> merge SHA before writing labels or tags' -ForEach @(
            @{ SourceCase = 'missing'; MergeSha = $null }
            @{ SourceCase = 'branch name instead of a'; MergeSha = 'main' }
        ) {
            $githubEvent.pull_request.merge_commit_sha = $MergeSha
            $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

            { & $runRelease } | Should -Throw '*merge commit SHA*'

            Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'label' -or $args[0] -eq 'release' }
            Should -Invoke git -Times 0 -Exactly
        }

        It 'does not write labels or tags if it cannot fetch the squash commit' {
            Mock git { $global:LASTEXITCODE = 1 } -ParameterFilter { $args[0] -eq 'fetch' }

            { & $runRelease } | Should -Throw '*Failed to fetch the merge commit*'

            Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'label' -or $args[0] -eq 'release' }
            Should -Invoke git -Times 0 -Exactly -ParameterFilter { $args[0] -eq 'push' }
        }

        It 'does not publish a stable release on <Case>' -ForEach @(
            @{ Case = 'a label change after merge'; Action = 'labeled'; Base = 'main' }
            @{ Case = 'a merge into a different branch'; Action = 'closed'; Base = 'Main' }
        ) {
            $githubEvent.action = $Action
            $githubEvent.pull_request.base.ref = $Base
            $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

            $null = & $runRelease

            Should -Invoke gh -Times 0 -Exactly -ParameterFilter {
                $args[0] -eq 'release' -and $args[1] -eq 'create'
            }
            Should -Invoke git -Times 0 -Exactly
        }
    }

    It 'does not write labels or tags when the event has no pull request' {
        '{}' | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'false'
        $simulateLabelWrites = $true
        Mock Write-GitHubWarning {}

        $null = & $runRelease

        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
        Should -Invoke Write-GitHubWarning -Times 1 -Exactly
    }

    It 'rejects conflicting release labels instead of falling back to the default' {
        $githubEvent.pull_request.labels = @(@{ name = 'release:patch' }, @{ name = 'release:major' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        { & $runRelease } | Should -Throw '*Conflicting release bump labels*'
        Should -Invoke gh -Times 1 -Exactly
    }

    It 'rejects invalid effective file settings before calling GitHub' -ForEach @(
        @{ Yaml = 'DefaultBump: null'; Message = '*DefaultBump*' }
        @{ Yaml = 'DefaultBump: date'; Message = '*Invalid DefaultBump*' }
        @{ Yaml = 'WhatIf: invalid'; Message = '*WhatIf*true or false*' }
        @{ Yaml = "DatePrereleaseFormat: '%'"; Message = '*DatePrereleaseFormat*format*' }
        @{ Yaml = 'AutoPatching: false'; Message = '*AutoPatching*removed*' }
        @{ Yaml = 'DefaultBunp: minor'; Message = '*Unsupported release setting*' }
        @{ Yaml = '- patch'; Message = '*configuration must be a mapping*' }
        @{ Yaml = ''; Message = '*settings file*must be a mapping*' }
    ) {
        $Yaml | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        { & $runRelease } | Should -Throw $Message
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }
}
