[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'The Pester cases share the workflow reader and fixture.'
)]
[CmdletBinding()]
param()

BeforeAll {
    Import-Module -Name powershell-yaml -RequiredVersion 0.4.12
    $reader = Join-Path -Path $PSScriptRoot -ChildPath '..\src\Get-ReleaseWorkflowInputs.ps1'
    $workflowFixture = @'
name: Release
on:
  pull_request:
    branches: [main]
    types: [closed]
jobs:
  Release:
    if: ${{ github.event.pull_request.head.repo.full_name == github.repository }}
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@example
      - uses: ./
<INPUTS>
'@
    $read = {
        param(
            [string] $Inputs,
            [string] $Target = 'main',
            [string] $Workflow = $workflowFixture
        )
        $path = Join-Path -Path $TestDrive -ChildPath 'Release.yml'
        $Workflow.Replace('<INPUTS>', $Inputs) | Set-Content -LiteralPath $path
        & $reader -Path $path -TargetBranch $Target -SettingNames @('Mode', 'DefaultBump', 'WhatIf', 'Version')
    }
}

Describe 'Reading the invoked release settings' {
    It 'reads literal publisher overrides in the same form as action inputs' {
        $inputs = & $read @'
        with:
          DefaultBump: minor
          SettingsFilePath: .github/branch-release.yml
          WhatIf: false
          Version: '[0.43.1]'
'@

        $inputs.DefaultBump | Should -BeExactly 'minor'
        $inputs.SettingsFilePath | Should -BeExactly '.github/branch-release.yml'
        $inputs.WhatIf | Should -BeExactly 'false'
        $inputs.Version | Should -BeExactly '[0.43.1]'
    }

    It 'leaves settings to the usual resolver when the publisher omits with' {
        $inputs = & $read ''

        $inputs | Should -BeOfType ([System.Collections.IDictionary])
        $inputs.Count | Should -Be 0
    }

    It 'keeps an explicit Publish mode so it can override the file' {
        $inputs = & $read "        with:`n          Mode: publish`n          DefaultBump: patch"

        $inputs.Mode | Should -BeExactly 'publish'
        $inputs.DefaultBump | Should -BeExactly 'patch'
    }

    It 'rejects a target that the publisher does not handle' {
        { & $read '' 'release-v2' } | Should -Throw '*does not handle*release-v2*'
    }

    It 'rejects a branch exclusion even when an earlier filter names the target' {
        $workflow = $workflowFixture.Replace('[main]', "[main, '!main']")

        { & $read '' -Workflow $workflow } | Should -Throw '*unsupported*branch*filter*'
    }

    It 'rejects a publisher that only runs on PR events before merge' {
        $workflow = $workflowFixture.Replace('types: [closed]', 'types: [opened]')

        { & $read '' -Workflow $workflow } | Should -Throw '*closed*'
    }

    It 'rejects a publisher that runs on a path filter' {
        $workflow = $workflowFixture.Replace('types: [closed]', "types: [closed]`n    paths: ['src/**']")

        { & $read '' -Workflow $workflow } | Should -Throw '*unsupported*filter*'
    }

    It 'rejects a different conditional publisher route' {
        $workflow = $workflowFixture.Replace('github.event.pull_request.head.repo.full_name == github.repository', 'false')

        { & $read '' -Workflow $workflow } | Should -Throw '*conditional*publisher*'
    }

    It 'rejects a publisher that checks out a different ref' {
        $checkout = "      - uses: actions/checkout@example`n        with:`n          ref: refs/heads/maintenance"
        $workflow = $workflowFixture.Replace('      - uses: actions/checkout@example', $checkout)

        { & $read '' -Workflow $workflow } | Should -Throw '*publisher checkout*ref*'
    }

    It 'rejects settings routed to a different repository' {
        $checkout = "      - uses: actions/checkout@example`n        with:`n          repository: example/other"
        $workflow = $workflowFixture.Replace('      - uses: actions/checkout@example', $checkout)

        { & $read '' -Workflow $workflow } | Should -Throw '*publisher checkout*repository*'
    }

    It 'rejects an unsupported input even if it is named Keys' {
        $inputs = "        with:`n          Keys: DefaultBump`n          DefaultBump: minor"

        { & $read $inputs } | Should -Throw '*unsupported*Keys*'
    }

    It 'rejects <Case> instead of falling back to defaults' -ForEach @(
        @{ Case = 'a dynamic bump'; Key = 'DefaultBump'; Value = '${{ vars.RELEASE_BUMP }}'; ErrorText = '*literal*DefaultBump*' }
        @{ Case = 'an unknown setting'; Key = 'DefaultBunp'; Value = 'major'; ErrorText = '*unsupported*DefaultBunp*' }
        @{ Case = 'a null override'; Key = 'Version'; Value = 'null'; ErrorText = '*literal*Version*' }
    ) {
        $inputBlock = "        with:`n          ${Key}: $Value"

        { & $read $inputBlock } | Should -Throw $ErrorText
    }
}
