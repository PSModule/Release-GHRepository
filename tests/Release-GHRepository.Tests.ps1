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
    $helperPath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\Release-GHRepository.Helpers.psm1'
    $actionPath = Join-Path -Path $PSScriptRoot -ChildPath '..\action.yml'
    $actionDefinition = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $actionPath -Raw)
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
    $bundleSettingsYaml = @'
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

Describe 'Release-GHRepository caller compatibility' {
    BeforeEach {
        $environmentNames = @(
            'GITHUB_REPOSITORY'
            'GITHUB_EVENT_PATH'
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

        $callerDirectory = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path (Join-Path -Path $callerDirectory -ChildPath '.github') -ItemType Directory
        Push-Location -LiteralPath $callerDirectory

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
        Pop-Location
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

    It 'declares release.settings.yml as the only conventional settings default' {
        $actionDefinition.inputs.SettingsFilePath.default | Should -BeExactly '.github\release.settings.yml'
        $actionDefinition.runs.steps[0].env.PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath |
            Should -BeExactly '${{ inputs.SettingsFilePath }}'
    }

    It 'reads the declared default without an injected SettingsFilePath input' {
        Remove-Item -LiteralPath Env:\PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        @'
DefaultBump: minor
WhatIf: true
'@ | Set-Content -LiteralPath '.github\release.settings.yml'

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Reading settings file .*release\.settings\.yml'
        $output | Should -Match 'Default bump:\s+\[minor\]'
        $output | Should -Match 'Default bump source:\s+\[RepositorySetting\]'
        $output | Should -Match 'gh release create v2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'uses conventional-file policy when named inputs are omitted or blank' {
        Remove-Item -LiteralPath Env:\PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = ''
        $env:PSMODULE_AUTO_RELEASE_INPUT_AutoCleanup = ''
        $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix = ''
        $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat = ''
        @'
DefaultBump: minor
AutoCleanup: false
VersionPrefix: ''
DatePrereleaseFormat: ''
WhatIf: true
'@ | Set-Content -LiteralPath '.github\release.settings.yml'

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Reading settings file .*release\.settings\.yml'
        $output | Should -Match 'Default bump:\s+\[minor\]'
        $output | Should -Match 'Auto cleanup enabled:\s+\[False\]'
        $output | Should -Match 'Version prefix:\s+\[\]'
        $output | Should -Match 'Date-based prerelease format:\s+\[\]'
        $output | Should -Match 'gh release create 2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'inherits valid defaults when the conventional settings file is intentionally absent' {
        Remove-Item -LiteralPath Env:\PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Settings file not found at .*release\.settings\.yml'
        $output | Should -Match 'Default bump:\s+\[patch\]'
        $output | Should -Match 'Default bump source:\s+\[SharedDefault\]'
        $output | Should -Match 'gh release create v2\.0\.4 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'rejects legacy-only conventional settings instead of silently applying another policy' {
        Remove-Item -LiteralPath Env:\PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        @'
DefaultBump: major
WhatIf: false
'@ | Set-Content -LiteralPath '.github\auto-release.yml'

        { & $mainPath } |
            Should -Throw '*auto-release.yml*no longer supported*release.settings.yml*SettingsFilePath*'
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'rejects a legacy conventional file even when the new default file also exists' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath = '.github\release.settings.yml'
        'DefaultBump: major' | Set-Content -LiteralPath '.github\auto-release.yml'
        'DefaultBump: minor' | Set-Content -LiteralPath '.github\release.settings.yml'

        { & $mainPath } | Should -Throw '*auto-release.yml*no longer supported*release.settings.yml*'
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'rejects the removed conventional path even when explicitly supplied as <PathKind>' -ForEach @(
        @{ PathKind = 'relative'; PathValue = '.github\auto-release.yml' }
        @{ PathKind = 'normalized relative'; PathValue = '.github\..\.github\auto-release.yml' }
        @{ PathKind = 'absolute'; PathValue = $null }
    ) {
        $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath = $PathValue
        if ($PathKind -eq 'absolute') {
            $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath = Join-Path -Path $callerDirectory -ChildPath '.github\auto-release.yml'
        }
        @'
DefaultBump: major
WhatIf: false
'@ | Set-Content -LiteralPath '.github\auto-release.yml'

        { & $mainPath } | Should -Throw '*auto-release.yml*no longer supported*release.settings.yml*'
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'preserves an intentional custom settings path without adding discovery or fallback' {
        'DefaultBump: major' | Set-Content -LiteralPath '.github\auto-release.yml'
        'DefaultBump: major' | Set-Content -LiteralPath '.github\release.settings.yml'
        $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath = Join-Path -Path $callerDirectory -ChildPath 'custom.settings.yml'
        @'
DefaultBump: minor
WhatIf: false
'@ | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'true'

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Reading settings file .*custom\.settings\.yml'
        $output | Should -Match 'Default bump:\s+\[minor\]'
        $output | Should -Match 'gh release create v2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'does not ignore legacy settings when an explicitly selected custom file is missing' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath = 'missing.settings.yml'
        'DefaultBump: major' | Set-Content -LiteralPath '.github\auto-release.yml'

        { & $mainPath } | Should -Throw '*auto-release.yml*no longer supported*release.settings.yml*SettingsFilePath*'
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'applies an explicit standard-valued input before an owned bump' {
        Remove-Item -LiteralPath Env:\PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'
        $env:PSMODULE_AUTO_RELEASE_INPUT_AutoCleanup = 'false'
        @'
DefaultBump: major
AutoCleanup: true
WhatIf: true
'@ | Set-Content -LiteralPath '.github\release.settings.yml'
        $githubEvent.pull_request.labels = @(@{ name = 'release:minor' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Reading settings file .*release\.settings\.yml'
        $output | Should -Match 'Default bump:\s+\[patch\]'
        $output | Should -Match 'Default bump source:\s+\[ActionInput\]'
        $output | Should -Match 'Auto cleanup enabled:\s+\[False\]'
        $output | Should -Match 'Bump source:\s+\[release:minor\]'
        $output | Should -Match 'gh release create v2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'keeps conventional-file text settings when named inputs are blank' {
        Remove-Item -LiteralPath Env:\PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix = ''
        $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat = ''
        @'
DefaultBump: minor
VersionPrefix: release-
DatePrereleaseFormat: yyyyMMdd
WhatIf: true
'@ | Set-Content -LiteralPath '.github\release.settings.yml'

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Reading settings file .*release\.settings\.yml'
        $output | Should -Match 'Version prefix:\s+\[release-\]'
        $output | Should -Match 'Date-based prerelease format:\s+\[yyyyMMdd\]'
        $output | Should -Match 'gh release create release-2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'rejects invalid data in the new default file before contacting GitHub' -ForEach @(
        @{ Yaml = 'DefaultBump: date'; Message = '*Invalid DefaultBump*' }
        @{ Yaml = 'DefaultBump: null'; Message = '*DefaultBump*' }
        @{ Yaml = 'WhatIf: invalid'; Message = '*WhatIf*true or false*' }
        @{ Yaml = 'AutoPatching: false'; Message = '*AutoPatching*removed*' }
        @{ Yaml = '- patch'; Message = '*configuration must be a mapping*' }
        @{ Yaml = ''; Message = '*settings file*must be a mapping*' }
    ) {
        Remove-Item -LiteralPath Env:\PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $Yaml | Set-Content -LiteralPath '.github\release.settings.yml'
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'

        { & $mainPath } | Should -Throw $Message
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'uses bundled standards without repository settings or injected input defaults' {
        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Default bump:\s+\[patch\]'
        $output | Should -Match 'Auto cleanup enabled:\s+\[True\]'
        $output | Should -Match 'Use PR body as release notes:\s+\[True\]'
        $output | Should -Match 'gh release create v2\.0\.4 '
        $output.Contains($authoredBody) | Should -BeTrue
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'validates the action-owned standards file when it is <BundleState>' -ForEach @(
        @{ BundleState = 'valid'; Message = $null }
        @{ BundleState = 'missing'; Message = '*release.settings.yml*' }
        @{ BundleState = 'empty'; Message = '*Bundled release defaults*must be a mapping*' }
        @{ BundleState = 'scalar'; Message = '*Bundled release defaults*must be a mapping*' }
        @{ BundleState = 'unknown'; Message = '*Unsupported release setting*DefaultBunp*' }
        @{ BundleState = 'null value'; Message = '*WhatIf*true or false*' }
        @{ BundleState = 'invalid bump'; Message = '*Invalid DefaultBump*' }
        @{ BundleState = 'incomplete'; Message = '*standard defaults*missing*WhatIf*' }
    ) {
        $bundleDirectory = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $bundleSource = Join-Path -Path $bundleDirectory -ChildPath 'src'
        $null = New-Item -Path $bundleSource -ItemType Directory -Force
        Copy-Item -LiteralPath $mainPath, $helperPath -Destination $bundleSource
        Copy-Item -LiteralPath $actionPath -Destination (Join-Path -Path $bundleDirectory -ChildPath 'action.yml')
        $bundleData = ConvertFrom-Yaml -Yaml $bundleSettingsYaml
        switch ($BundleState) {
            'unknown' { $bundleData.DefaultBunp = 'minor' }
            'null value' { $bundleData.WhatIf = $null }
            'invalid bump' { $bundleData.DefaultBump = 'date' }
            'incomplete' { $bundleData.Remove('WhatIf') }
        }
        $bundleYaml = ConvertTo-Yaml -Data $bundleData
        if ($BundleState -eq 'empty') {
            $bundleYaml = ''
        } elseif ($BundleState -eq 'scalar') {
            $bundleYaml = 'minor'
        }
        if ($BundleState -ne 'missing') {
            $bundleYaml | Set-Content -LiteralPath (Join-Path -Path $bundleSource -ChildPath 'release.settings.yml')
        }
        $bundleMainPath = Join-Path -Path $bundleSource -ChildPath 'main.ps1'

        Push-Location -LiteralPath $TestDrive
        try {
            if ($Message) {
                $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'
                { & $bundleMainPath } | Should -Throw $Message
                Should -Invoke gh -Times 0 -Exactly
            } else {
                $output = (& $bundleMainPath) -join "`n"

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
        $actionDefinition.inputs.ContainsKey('ConfigurationFile') | Should -BeFalse
        $defaultSettingsPath = $actionDefinition.inputs.SettingsFilePath.default
        $defaultSettingsPath | Should -BeExactly '.github\release.settings.yml'
        $callerDirectory = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path (Join-Path -Path $callerDirectory -ChildPath '.github') -ItemType Directory
        if ($FilePresent) {
            'DefaultBump: minor' | Set-Content -LiteralPath (Join-Path -Path $callerDirectory -ChildPath $defaultSettingsPath)
        }
        Remove-Item -LiteralPath 'Env:\PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath'

        Push-Location -LiteralPath $callerDirectory
        try {
            $output = (& $mainPath) -join "`n"
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

        { & $mainPath } | Should -Throw '*SettingsFilePath must be a nonempty path.*'
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'uses a caller minor default for an unlabeled pull request' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'minor'

        $output = (& $mainPath) -join "`n"

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

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Default bump:\s+\[minor\]'
        $output | Should -Match 'Auto cleanup enabled:\s+\[False\]'
        $output | Should -Match 'Date-based prerelease format:\s+\[\]'
        $output | Should -Match 'gh release create 2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'keeps the repository bump when its named input is <InputState>' -ForEach @(
        @{ InputState = 'omitted' }
        @{ InputState = 'empty' }
    ) {
        if ($InputState -eq 'empty') {
            $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = ''
        }
        'DefaultBump: major' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Default bump:\s+\[major\]'
        $output | Should -Match 'Default bump source:\s+\[RepositorySetting\]'
        $output | Should -Match 'gh release create v3\.0\.0 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'keeps bundled policy when all release inputs are empty' {
        foreach ($settingName in $releaseSettingNames) {
            [Environment]::SetEnvironmentVariable("PSMODULE_AUTO_RELEASE_INPUT_$settingName", '')
        }
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'true'

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Default bump:\s+\[patch\]'
        $output | Should -Match 'Default bump source:\s+\[SharedDefault\]'
        $output | Should -Match 'gh release create v2\.0\.4 '
        Should -Invoke gh -Times 2 -Exactly
    }

    It 'lets an explicit owned major override a file minor default and preserves the complete record' {
        'DefaultBump: minor' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $githubEvent.pull_request.labels = @(@{ name = 'release:major' }, @{ name = 'dependencies' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $mainPath) -join "`n"

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

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Default bump applied:\s+\[True\]'
        $output | Should -Match 'Create a prerelease:\s+\[False\]'
        $output | Should -Match 'gh release create v2\.1\.0 '
    }

    It 'lets a named DefaultBump override repository policy' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'minor'
        'DefaultBump: major' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        $output = (& $mainPath) -join "`n"

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

        $output = (& $mainPath) -join "`n"

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

        { & $mainPath } | Should -Throw '*DefaultBump*'
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'keeps validation read-only when explicit WhatIf overrides a false repository setting' {
        'WhatIf: false' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath

        $output = (& $mainPath) -join "`n"

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

        $output = (& $mainPath) -join "`n"

        $output | Should -Match "Date-based prerelease format:\s+\['fixed'\]"
        $output | Should -Match 'gh release create v2\.0\.4-featurecaller\.fixed\.1 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'keeps a true file WhatIf policy when its named input is empty' {
        'WhatIf: true' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = ''

        $output = (& $mainPath) -join "`n"

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

        $output = (& $mainPath) -join "`n"

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

        $output = (& $mainPath) -join "`n"

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

        { & $mainPath } | Should -Throw $Message
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'validates a merged skipped pull request successfully without planning publication' {
        $githubEvent.pull_request.labels = @(@{ name = 'release:skip' })
        $githubEvent.pull_request.merged = $true
        $githubEvent.pull_request.state = 'closed'
        $githubEvent.action = 'closed'
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $mainPath) -join "`n"

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

        $output = (& $mainPath) -join "`n"

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

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Skipping release creation\.'
        $output | Should -Match 'WhatIf: gh release delete v2\.0\.4-featurecaller\.1'
        $output | Should -Not -Match 'gh release create|git tag|git push'
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'targets a prerelease at the exact pull-request head without executing publication commands' {
        $githubEvent.pull_request.labels = @(@{ name = 'release:prerelease' }, @{ name = 'release:minor' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'gh release create v2\.1\.0-featurecaller\.1 '
        $output | Should -Match "--target $headSha --prerelease"
        $output | Should -Match 'WhatIf: gh pr comment 42 '
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    Describe 'Publication concurrency settings' {
        BeforeAll {
            $workflowPath = Join-Path -Path $PSScriptRoot -ChildPath '..\.github\workflows\Release.yml'
            $releaseWorkflow = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $workflowPath -Raw)
        }

        It 'never cancels an in-progress publication run' {
            $releaseWorkflow.concurrency.'cancel-in-progress' | Should -BeFalse
        }

        It 'serializes merged pull requests by target branch and isolates open pull requests by number' {
            $releaseWorkflow.concurrency.group | Should -BeExactly (
                '${{ github.workflow }}-${{ github.event.pull_request.merged && github.event.pull_request.base.ref || ' +
                'github.event.pull_request.number || github.ref }}'
            )
        }
    }

    It 'rejects conflicting owned labels instead of falling back to the default' {
        $githubEvent.pull_request.labels = @(@{ name = 'release:patch' }, @{ name = 'release:major' })
        $githubEvent | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH

        { & $mainPath } | Should -Throw '*Conflicting release bump labels*'
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

        { & $mainPath } | Should -Throw $Message
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }
}
