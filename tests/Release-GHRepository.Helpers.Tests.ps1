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
            'release:prerelease'
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
        @{ Name = 'release:prerelease' }
        @{ Name = 'release:skip' }
    ) {
        $definition = $definitions | Where-Object Name -CEQ $Name

        $definition.Color | Should -Match '^[0-9a-f]{6}$'
        $definition.Description | Should -Not -BeNullOrEmpty
        $definition.Description.Length | Should -BeLessOrEqual 100
    }
}

Describe 'ConvertTo-ReleaseBump' {
    It 'converts <DefaultBump> to <Expected>' -ForEach @(
        @{ DefaultBump = 'patch'; Expected = 'Patch' }
        @{ DefaultBump = 'minor'; Expected = 'Minor' }
        @{ DefaultBump = 'major'; Expected = 'Major' }
    ) {
        ConvertTo-ReleaseBump -DefaultBump $DefaultBump | Should -BeExactly $Expected
    }

    It 'uses patch when DefaultBump is omitted' {
        ConvertTo-ReleaseBump | Should -BeExactly 'Patch'
    }

    It 'rejects invalid DefaultBump [<DefaultBump>]' -ForEach @(
        @{ DefaultBump = '' }
        @{ DefaultBump = 'Patch' }
        @{ DefaultBump = 'prerelease' }
        @{ DefaultBump = 'none' }
        @{ DefaultBump = $null }
    ) {
        { ConvertTo-ReleaseBump -DefaultBump $DefaultBump } |
            Should -Throw '*Invalid DefaultBump*patch, minor, major*'
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
            Labels     = @('release:patch', 'release:prerelease')
            Bump       = 'Patch'
            Prerelease = $true
            Skip       = $false
        }
        @{
            Name       = 'a minor prerelease'
            Labels     = @('release:minor', 'release:prerelease')
            Bump       = 'Minor'
            Prerelease = $true
            Skip       = $false
        }
        @{
            Name       = 'a major prerelease'
            Labels     = @('release:major', 'release:prerelease')
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
        $result.DefaultBumpApplied | Should -BeFalse
    }

    It 'rejects <Name>' -ForEach @(
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
            Labels  = @('release:skip', 'release:prerelease')
            Message = '*release:skip must not be combined*'
        }
    ) {
        { Resolve-ReleaseDecision -Labels $Labels } | Should -Throw $Message
    }

    It 'resolves <Expected> from <Name> with the <DefaultBump> default' -ForEach @(
        @{
            Name        = 'an empty label set'
            Labels      = @()
            DefaultBump = 'patch'
            Expected    = 'Patch'
            Prerelease  = $false
        }
        @{
            Name        = 'a null label set'
            Labels      = $null
            DefaultBump = 'minor'
            Expected    = 'Minor'
            Prerelease  = $false
        }
        @{
            Name        = 'legacy bare labels'
            Labels      = @('Major', 'Minor', 'Patch', 'Prerelease', 'NoRelease')
            DefaultBump = 'major'
            Expected    = 'Major'
            Prerelease  = $false
        }
        @{
            Name        = 'lowercase bare labels'
            Labels      = @('major', 'minor', 'patch', 'prerelease')
            DefaultBump = 'patch'
            Expected    = 'Patch'
            Prerelease  = $false
        }
        @{
            Name        = 'noncanonical casing'
            Labels      = @('Release:Patch')
            DefaultBump = 'minor'
            Expected    = 'Minor'
            Prerelease  = $false
        }
        @{
            Name        = 'an unknown release label'
            Labels      = @('release:unknown')
            DefaultBump = 'major'
            Expected    = 'Major'
            Prerelease  = $false
        }
        @{
            Name        = 'the retired release:pre-release label'
            Labels      = @('release:pre-release')
            DefaultBump = 'patch'
            Expected    = 'Patch'
            Prerelease  = $false
        }
        @{
            Name        = 'prerelease without an explicit bump'
            Labels      = @('release:prerelease')
            DefaultBump = 'minor'
            Expected    = 'Minor'
            Prerelease  = $true
        }
    ) {
        $result = Resolve-ReleaseDecision -Labels $Labels -DefaultBump $DefaultBump

        $result.Bump | Should -BeExactly $Expected
        $result.Prerelease | Should -Be $Prerelease
        $result.Skip | Should -BeFalse
        $result.DefaultBumpApplied | Should -BeTrue
    }

    It 'applies each valid default to unlabeled and prerelease-only decisions' {
        $expectedBumps = @{
            patch = 'Patch'
            minor = 'Minor'
            major = 'Major'
        }

        foreach ($defaultBump in @('patch', 'minor', 'major')) {
            foreach ($labels in @(@(), @('release:prerelease'))) {
                $result = Resolve-ReleaseDecision -Labels $labels -DefaultBump $defaultBump

                $result.Bump | Should -BeExactly $expectedBumps[$defaultBump]
                $result.Prerelease | Should -Be ($labels -ccontains 'release:prerelease')
                $result.DefaultBumpApplied | Should -BeTrue
            }
        }
    }

    It 'lets every explicit bump label override every valid default' {
        $explicitBumps = [ordered]@{
            'release:patch' = 'Patch'
            'release:minor' = 'Minor'
            'release:major' = 'Major'
        }

        foreach ($defaultBump in @('patch', 'minor', 'major')) {
            foreach ($entry in $explicitBumps.GetEnumerator()) {
                $result = Resolve-ReleaseDecision -Labels @($entry.Key) -DefaultBump $defaultBump

                $result.Bump | Should -BeExactly $entry.Value
                $result.DefaultBumpApplied | Should -BeFalse
            }
        }
    }

    It 'lets release:skip override every valid default' {
        foreach ($defaultBump in @('patch', 'minor', 'major')) {
            $result = Resolve-ReleaseDecision -Labels @('release:skip') -DefaultBump $defaultBump

            $result.Bump | Should -BeExactly 'None'
            $result.Skip | Should -BeTrue
            $result.DefaultBumpApplied | Should -BeFalse
        }
    }

    It 'validates DefaultBump before applying an explicit decision' {
        { Resolve-ReleaseDecision -Labels @('release:patch') -DefaultBump 'Patch' } |
            Should -Throw '*Invalid DefaultBump*'
    }

    It 'accepts exactly the nine valid subsets for every default bump' {
        $ownedLabels = @(
            'release:patch'
            'release:minor'
            'release:major'
            'release:prerelease'
            'release:skip'
        )
        $validSubsets = @(
            ''
            'release:prerelease'
            'release:patch'
            'release:minor'
            'release:major'
            'release:patch,release:prerelease'
            'release:minor,release:prerelease'
            'release:major,release:prerelease'
            'release:skip'
        )

        foreach ($defaultBump in @('patch', 'minor', 'major')) {
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
                    { Resolve-ReleaseDecision -Labels $labels -DefaultBump $defaultBump } |
                        Should -Not -Throw -Because "[$subset] is valid with DefaultBump [$defaultBump]"
                } else {
                    { Resolve-ReleaseDecision -Labels $labels -DefaultBump $defaultBump } |
                        Should -Throw -Because "[$subset] is not a valid release decision"
                }
            }
        }
    }

    Describe 'Resolve-PullRequestReleaseContext' {
        It 'uses the branch for naming and the exact head SHA for the release target' {
            $headSha = '0123456789012345678901234567890123456789'
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = 'feature/fork-release'
                    sha = $headSha
                }
            }

            $result = Resolve-PullRequestReleaseContext -PullRequest $pullRequest

            $result.HeadRef | Should -BeExactly 'feature/fork-release'
            $result.PrereleaseName | Should -BeExactly 'featureforkrelease'
            $result.PrereleaseTarget | Should -BeExactly $headSha
        }

        It 'does not use a colliding base-repository branch name as the release target' {
            $headSha = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = 'main'
                    sha = $headSha
                }
            }

            $result = Resolve-PullRequestReleaseContext -PullRequest $pullRequest

            $result.PrereleaseName | Should -BeExactly 'main'
            $result.PrereleaseTarget | Should -BeExactly $headSha
            $result.PrereleaseTarget | Should -Not -BeExactly $result.HeadRef
        }

        It 'rejects a pull request without a head ref' {
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = ''
                    sha = '0123456789012345678901234567890123456789'
                }
            }

            { Resolve-PullRequestReleaseContext -PullRequest $pullRequest } |
                Should -Throw '*head ref is required*'
        }

        It 'rejects a pull request without a head SHA' {
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = 'feature/missing-sha'
                    sha = ''
                }
            }

            { Resolve-PullRequestReleaseContext -PullRequest $pullRequest } |
                Should -Throw '*head SHA is required*'
        }

        It 'rejects a head ref that has no valid prerelease identifier' {
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = '---'
                    sha = '0123456789012345678901234567890123456789'
                }
            }

            { Resolve-PullRequestReleaseContext -PullRequest $pullRequest } |
                Should -Throw '*does not contain a valid prerelease identifier*'
        }
    }

    Describe 'Test-PrereleaseCreation' {
        It 'returns <Expected> for <Name>' -ForEach @(
            @{
                Name     = 'an open prerelease pull request'
                Labels   = @('release:patch', 'release:prerelease')
                Closed   = $false
                Expected = $true
            }
            @{
                Name     = 'a closed prerelease pull request'
                Labels   = @('release:patch', 'release:prerelease')
                Closed   = $true
                Expected = $false
            }
            @{
                Name     = 'an open stable pull request'
                Labels   = @('release:patch')
                Closed   = $false
                Expected = $false
            }
            @{
                Name     = 'a closed stable pull request'
                Labels   = @('release:patch')
                Closed   = $true
                Expected = $false
            }
            @{
                Name     = 'an open skipped pull request'
                Labels   = @('release:skip')
                Closed   = $false
                Expected = $false
            }
        ) {
            $decision = Resolve-ReleaseDecision -Labels $Labels
            $result = Test-PrereleaseCreation -ReleaseDecision $decision -PullRequestClosed:$Closed

            $result | Should -Be $Expected
        }
    }
}
