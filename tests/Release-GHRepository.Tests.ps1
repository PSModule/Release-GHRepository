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
        $env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile = Join-Path -Path $TestDrive -ChildPath 'settings.yml'
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

        Mock Install-PSResource {}
        Mock Write-GitHubNotice {}
        Mock git { throw 'A caller compatibility test must never invoke git.' }
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'repo' -and $args[1] -eq 'view') {
                '{"defaultBranchRef":{"name":"main"}}'
            } elseif ($args[0] -eq 'release' -and $args[1] -eq 'list') {
                '[{"tagName":"v2.0.3","isLatest":true,"isPrerelease":false}]'
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

    It 'uses action.yml defaults without relying on the composite wrapper to inject them' {
        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Default bump:\s+\[patch\]'
        $output | Should -Match 'Auto cleanup enabled:\s+\[True\]'
        $output | Should -Match 'Use PR body as release notes:\s+\[True\]'
        $output | Should -Match 'gh release create v2\.0\.4 '
        $output.Contains($authoredBody) | Should -BeTrue
        Should -Invoke gh -Times 2 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }

    It 'uses a caller minor default for an unlabeled pull request' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'minor'

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Default bump:\s+\[minor\]'
        $output | Should -Match 'gh release create v2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
    }

    It 'uses file overrides, including empty text and false, with the real YAML parser' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'major'
        $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat = 'yyyyMMddHHmm'
        @'
DefaultBump: minor
AutoCleanup: false
DatePrereleaseFormat: ''
VersionPrefix: ''
'@ | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile

        $output = (& $mainPath) -join "`n"

        $output | Should -Match 'Default bump:\s+\[minor\]'
        $output | Should -Match 'Auto cleanup enabled:\s+\[False\]'
        $output | Should -Match 'Date-based prerelease format:\s+\[\]'
        $output | Should -Match 'gh release create 2\.1\.0 '
        Should -Invoke gh -Times 2 -Exactly
    }

    It 'lets an explicit owned major override a file minor default and preserves the complete record' {
        'DefaultBump: minor' | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile
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
        @{ Yaml = 'AutoPatching: false'; Message = '*AutoPatching*removed*' }
        @{ Yaml = 'DefaultBunp: minor'; Message = '*Unsupported release setting*' }
        @{ Yaml = '- patch'; Message = '*configuration must be a mapping*' }
        @{ Yaml = ''; Message = '*configuration*must be a mapping*' }
    ) {
        $Yaml | Set-Content -LiteralPath $env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile

        { & $mainPath } | Should -Throw $Message
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke git -Times 0 -Exactly
    }
}
