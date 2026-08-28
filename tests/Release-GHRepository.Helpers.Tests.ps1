[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables are assigned in BeforeAll and used inside It blocks.'
)]
[CmdletBinding()]
param()

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../src/Release-GHRepository.Helpers.psm1'
    Import-Module -Name $modulePath -Force
}

Describe 'Get-ReleaseLabelDefinition' {
    BeforeAll {
        $definitions = @(Get-ReleaseLabelDefinition)
    }

    It 'returns exactly the five canonical labels' {
        $definitions.Name | Should -Be @(
            'release:patch'
            'release:minor'
            'release:major'
            'release:pre-release'
            'release:skip'
        )
    }

    It 'returns a unique name for every definition' {
        @($definitions.Name | Sort-Object -Unique).Count | Should -Be $definitions.Count
    }

    It 'returns valid repository metadata for <Name>' -ForEach @(
        @{ Name = 'release:patch' }
        @{ Name = 'release:minor' }
        @{ Name = 'release:major' }
        @{ Name = 'release:pre-release' }
        @{ Name = 'release:skip' }
    ) {
        $definition = $definitions | Where-Object Name -CEQ $Name

        $definition.Color | Should -Match '^[0-9a-f]{6}$'
        $definition.Description | Should -Not -BeNullOrEmpty
        $definition.Description.Length | Should -BeLessOrEqual 100
    }
}

Describe 'Resolve-ReleaseDecision' {
    It 'resolves <Name>' -ForEach @(
        @{
            Name       = 'a patch release'
            Labels     = @('release:patch')
            Bump       = 'Patch'
            Prerelease = $false
            Skip       = $false
        }
        @{
            Name       = 'a minor release'
            Labels     = @('release:minor')
            Bump       = 'Minor'
            Prerelease = $false
            Skip       = $false
        }
        @{
            Name       = 'a major release'
            Labels     = @('release:major')
            Bump       = 'Major'
            Prerelease = $false
            Skip       = $false
        }
        @{
            Name       = 'a patch prerelease'
            Labels     = @('release:patch', 'release:pre-release')
            Bump       = 'Patch'
            Prerelease = $true
            Skip       = $false
        }
        @{
            Name       = 'a minor prerelease'
            Labels     = @('release:minor', 'release:pre-release')
            Bump       = 'Minor'
            Prerelease = $true
            Skip       = $false
        }
        @{
            Name       = 'a major prerelease'
            Labels     = @('release:major', 'release:pre-release')
            Bump       = 'Major'
            Prerelease = $true
            Skip       = $false
        }
        @{
            Name       = 'a skipped release'
            Labels     = @('release:skip')
            Bump       = 'None'
            Prerelease = $false
            Skip       = $true
        }
        @{
            Name       = 'a bump alongside unrelated labels'
            Labels     = @('dependencies', 'release:patch', 'release:unknown')
            Bump       = 'Patch'
            Prerelease = $false
            Skip       = $false
        }
        @{
            Name       = 'a skip alongside unrelated labels'
            Labels     = @('documentation', 'release:skip', 'release:unknown')
            Bump       = 'None'
            Prerelease = $false
            Skip       = $true
        }
    ) {
        $result = Resolve-ReleaseDecision -Labels $Labels

        $result.Bump | Should -BeExactly $Bump
        $result.Prerelease | Should -Be $Prerelease
        $result.Skip | Should -Be $Skip
    }

    It 'rejects <Name>' -ForEach @(
        @{
            Name    = 'an empty label set'
            Labels  = @()
            Message = '*Release decision is missing*'
        }
        @{
            Name    = 'a null label set'
            Labels  = $null
            Message = '*Release decision is missing*'
        }
        @{
            Name    = 'legacy bare labels'
            Labels  = @('Major', 'Minor', 'Patch', 'Prerelease', 'NoRelease')
            Message = '*Release decision is missing*'
        }
        @{
            Name    = 'lowercase bare labels'
            Labels  = @('major', 'minor', 'patch', 'prerelease')
            Message = '*Release decision is missing*'
        }
        @{
            Name    = 'noncanonical casing'
            Labels  = @('Release:Patch')
            Message = '*Release decision is missing*'
        }
        @{
            Name    = 'an unknown release label'
            Labels  = @('release:unknown')
            Message = '*Release decision is missing*'
        }
        @{
            Name    = 'prerelease without a bump'
            Labels  = @('release:pre-release')
            Message = '*release:pre-release requires exactly one release bump label*'
        }
        @{
            Name    = 'patch and minor bumps'
            Labels  = @('release:patch', 'release:minor')
            Message = '*Conflicting release bump labels*'
        }
        @{
            Name    = 'minor and major bumps'
            Labels  = @('release:minor', 'release:major')
            Message = '*Conflicting release bump labels*'
        }
        @{
            Name    = 'all bump labels'
            Labels  = @('release:patch', 'release:minor', 'release:major')
            Message = '*Conflicting release bump labels*'
        }
        @{
            Name    = 'skip and patch'
            Labels  = @('release:skip', 'release:patch')
            Message = '*release:skip must not be combined*'
        }
        @{
            Name    = 'skip and prerelease'
            Labels  = @('release:skip', 'release:pre-release')
            Message = '*release:skip must not be combined*'
        }
    ) {
        { Resolve-ReleaseDecision -Labels $Labels } | Should -Throw $Message
    }

    It 'accepts exactly the seven valid subsets of owned release labels' {
        $ownedLabels = @(
            'release:patch'
            'release:minor'
            'release:major'
            'release:pre-release'
            'release:skip'
        )
        $validSubsets = @(
            'release:patch'
            'release:minor'
            'release:major'
            'release:patch,release:pre-release'
            'release:minor,release:pre-release'
            'release:major,release:pre-release'
            'release:skip'
        )

        for ($mask = 0; $mask -lt (1 -shl $ownedLabels.Count); $mask++) {
            $labels = @(
                for ($index = 0; $index -lt $ownedLabels.Count; $index++) {
                    if (($mask -band (1 -shl $index)) -ne 0) {
                        $ownedLabels[$index]
                    }
                }
            )
            $subset = ($labels | Sort-Object) -join ','

            if ($validSubsets -ccontains $subset) {
                { Resolve-ReleaseDecision -Labels $labels } |
                    Should -Not -Throw -Because "[$subset] is a valid release decision"
            } else {
                { Resolve-ReleaseDecision -Labels $labels } |
                    Should -Throw -Because "[$subset] is not a valid release decision"
            }
        }
    }
}
