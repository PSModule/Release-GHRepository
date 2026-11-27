[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables are assigned in Pester setup and used by tests and mocks.'
)]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

BeforeAll {
    Import-Module -Name GitHub, powershell-yaml, PSSemVer
    $actionDirectory = Split-Path -Path $PSScriptRoot -Parent
    $actionPath = Join-Path -Path $actionDirectory -ChildPath 'action.yml'
    $bootstrapPath = Join-Path -Path $actionDirectory -ChildPath 'src\Initialize-ReleaseConfiguration.ps1'
    $helperPath = Join-Path -Path $actionDirectory -ChildPath 'src\Release-GHRepository.Helpers.psm1'
    $action = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($actionPath))
    $scriptStep = $action.runs.steps | Where-Object { $_.uses -like 'PSModule/GitHub-Script@*' }
    $runAction = [scriptblock]::Create($scriptStep.with.Script)
    $runActionStep = {
        $githubEvent | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH
        [IO.File]::WriteAllText($bootstrapOutput, '')
        $null = & $bootstrapPath -OutputPath $bootstrapOutput
        $settingsRecord = Select-String -LiteralPath $bootstrapOutput -Pattern '^ReleaseSettings<<' -Context 0, 1
        if (-not $settingsRecord.Context.PostContext) {
            throw 'The settings step did not write the release settings.'
        }
        $env:PSMODULE_AUTO_RELEASE_RESOLVED_SETTINGS = $settingsRecord.Context.PostContext[0]
        & $runAction
    }
    $runCalculation = {
        $null = & $runActionStep
        (Get-GitHubOutput -AsHashtable).result
    }
    $expectFailure = {
        param([string] $Message)

        { & $runCalculation } | Should -Throw $Message
        [IO.File]::ReadAllText($env:GITHUB_OUTPUT) | Should -BeExactly ''
    }
    $expectNoRepositoryWrites = {
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $args[0] -cne 'check-ref-format' }
        Should -Invoke gh -Times 0 -Exactly -ParameterFilter {
            $args[0] -cin @('pr', 'label') -or
            ($args[0] -ceq 'release' -and $args[1] -cne 'list') -or
            ($args[0] -ceq 'api' -and ($args -ccontains 'POST' -or $args -ccontains 'PATCH' -or $args -ccontains 'DELETE'))
        }
    }
    $headSha = '0123456789012345678901234567890123456789'
    $mergeSha = 'fedcba9876543210fedcba9876543210fedcba98'
    $targetRepository = 'example/project'
}

Describe 'Release-GHRepository event release plans' {
    BeforeEach {
        $environmentNames = @(
            'GITHUB_ACTION'
            'GITHUB_EVENT_NAME'
            'GITHUB_EVENT_PATH'
            'GITHUB_OUTPUT'
            'GITHUB_REPOSITORY'
            'GITHUB_SERVER_URL'
            'GITHUB_WORKSPACE'
            'PSMODULE_AUTO_RELEASE_ACTION_PATH'
            'PSMODULE_AUTO_RELEASE_INPUT_Mode'
            'PSMODULE_AUTO_RELEASE_INPUT_PullRequest'
            'PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion'
            'PSMODULE_AUTO_RELEASE_INPUT_CalculatedAt'
            'PSMODULE_AUTO_RELEASE_RESOLVED_SETTINGS'
            'PSMODULE_GITHUB_SCRIPT'
        ) + @($action.inputs.Keys | ForEach-Object { "PSMODULE_AUTO_RELEASE_INPUT_$_" })
        $savedEnvironment = @{}
        foreach ($name in $environmentNames | Select-Object -Unique) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }

        $workspace = Join-Path -Path $TestDrive -ChildPath ([guid]::NewGuid().ToString('N'))
        $null = New-Item -Path $workspace -ItemType Directory
        $bootstrapOutput = Join-Path -Path $workspace -ChildPath 'settings.out'
        $env:GITHUB_OUTPUT = Join-Path -Path $workspace -ChildPath 'result.out'
        [IO.File]::WriteAllText($env:GITHUB_OUTPUT, '')
        $env:GITHUB_ACTION = 'release'
        $env:GITHUB_EVENT_NAME = 'pull_request'
        $env:GITHUB_EVENT_PATH = Join-Path -Path $workspace -ChildPath 'event.json'
        $env:GITHUB_REPOSITORY = $targetRepository
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_WORKSPACE = $workspace
        $env:PSMODULE_AUTO_RELEASE_ACTION_PATH = $actionDirectory
        $env:PSMODULE_AUTO_RELEASE_INPUT_Mode = 'calculate'
        $env:PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath = Join-Path -Path $workspace -ChildPath 'settings.yml'
        $env:PSMODULE_GITHUB_SCRIPT = 'true'

        $repository = @{ full_name = $targetRepository; default_branch = 'trunk'; fork = $false }
        $head = @{ ref = 'feature/calc'; sha = $headSha; repo = @{ full_name = $targetRepository } }
        $base = @{ ref = 'trunk'; repo = @{ full_name = $targetRepository } }
        $currentPullRequest = @{
            number = 42; state = 'open'; head = $head; base = $base
            labels = @(@{ name = 'release:minor' })
        }
        $eventPullRequest = $currentPullRequest.Clone()
        $eventPullRequest.labels = @(@{ name = 'release:major' })
        $githubEvent = @{ repository = $repository; pull_request = $eventPullRequest; number = 42 }
        $push = @{ repository = $repository; ref = 'refs/heads/feature/calc'; after = $headSha; deleted = $false }
        $defaultPush = @{ repository = $repository; ref = 'refs/heads/trunk'; after = $mergeSha; deleted = $false }
        $openPages = , (, $currentPullRequest)
        $associatedPages = , @()
        $latest = @{ tagName = 'v2.0.3'; isDraft = $false; isPrerelease = $false }
        $historyResponse = @{ data = @{ repository = @{ nameWithOwner = $targetRepository; latestRelease = $latest } } }
        $historyExitCode = 0
        $lookupExitCode = 0
        $liveDefaultBranch = 'trunk'
        $tagExitCode = 0
        $tagReferences = @()
        $releaseRecords = @()
        $allowSimulatedWrites = $false

        # Simulate API responses so these tests need no token and cannot change a repository.
        Mock Install-PSResource {}
        Mock git {
            if (-not $allowSimulatedWrites) {
                throw 'Calculate must not run git.'
            }
            $global:LASTEXITCODE = 0
        }
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($args[0] -ceq 'api' -and $args[1] -ceq 'graphql' -and
                $args -contains 'owner=example' -and $args -contains 'name=project' -and
                $args -clike 'query=query*latestRelease*') {
                $global:LASTEXITCODE = $historyExitCode
                ConvertTo-Json -InputObject $historyResponse -Depth 20 -Compress
            } elseif ($args[0] -ceq 'api' -and $args -contains 'GET') {
                switch -Wildcard ($args[1]) {
                    "repos/$targetRepository/pulls/42" {
                        ConvertTo-Json -InputObject $currentPullRequest -Depth 20 -Compress
                    }
                    "repos/$targetRepository/pulls" {
                        $global:LASTEXITCODE = $lookupExitCode
                        ConvertTo-Json -InputObject $openPages -Depth 20 -Compress
                    }
                    "repos/$targetRepository/commits/$mergeSha/pulls" {
                        $global:LASTEXITCODE = $lookupExitCode
                        ConvertTo-Json -InputObject $associatedPages -Depth 20 -Compress
                    }
                    "repos/$targetRepository" {
                        @{ full_name = $targetRepository; default_branch = $liveDefaultBranch } | ConvertTo-Json -Compress
                    }
                    "repos/$targetRepository/git/matching-refs/tags/*" {
                        $global:LASTEXITCODE = $tagExitCode
                        ConvertTo-Json -InputObject $tagReferences -Depth 20 -Compress
                    }
                    default { throw "Unexpected GitHub read: gh $($args -join ' ')" }
                }
            } elseif ($args[0] -ceq 'repo' -and $args[1] -ceq 'view') {
                '{"defaultBranchRef":{"name":"trunk"}}'
            } elseif ($args[0] -ceq 'release' -and $args[1] -ceq 'list') {
                ConvertTo-Json -InputObject $releaseRecords -Depth 20 -Compress
            } elseif ($allowSimulatedWrites -and $args[0] -ceq 'release' -and $args[1] -ceq 'create') {
                'https://github.com/example/project/releases/tag/test'
            } elseif ($allowSimulatedWrites -and (
                    $args[0] -cin @('label', 'pr') -or
                    ($args[0] -ceq 'release' -and $args[1] -ceq 'delete') -or
                    ($args[0] -ceq 'api' -and $args[1] -ceq "repos/$targetRepository/git/refs" -and $args -ccontains 'POST')
                )) {
                return
            } else {
                throw "Unexpected GitHub command: gh $($args -join ' ')"
            }
        }
    }

    AfterEach {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
        }
        if (-not $allowSimulatedWrites) {
            Should -Invoke git -Times 0 -Exactly
            Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args[0] -cne 'api' }
        }
    }

    It 'uses current PR labels for a prerelease without a publication label when WhatIf is <WhatIf>' -ForEach @(
        @{ WhatIf = 'false' }
        @{ WhatIf = 'true' }
    ) {
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = $WhatIf

        $result = & $runCalculation

        $result.Decision | Should -BeExactly 'release'
        $result.BumpSource | Should -BeExactly 'release:minor'
        $result.ReleaseVersion | Should -BeExactly '2.1.0-featurecalc.1'
    }

    It 'returns the UTC instant used to format a date-dependent prerelease' {
        $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat = 'yyyy-MM-dd'
        $env:PSMODULE_AUTO_RELEASE_INPUT_IncrementalPrerelease = 'false'
        $before = [datetime]::UtcNow

        $result = & $runCalculation

        [IO.File]::ReadAllText($env:GITHUB_OUTPUT) | Should -Match '"CalculatedAt"\s*:\s*"[0-9T:.-]+Z"'
        $instant = ([datetimeoffset] $result.CalculatedAt).UtcDateTime
        $instant | Should -BeGreaterOrEqual $before
        $instant | Should -BeLessOrEqual ([datetime]::UtcNow)
        $date = $instant.ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
        $result.ReleaseVersion | Should -BeExactly "2.1.0-featurecalc.$date"
    }

    It 'replays the same date-dependent version from a supplied UTC instant' {
        Import-Module -Name $helperPath -Force
        $decision = Resolve-ReleaseDecision -Labels @('release:minor') -DefaultBump 'none'
        $timestamp = '2026-01-03T02:05:06.0000000Z'
        $calculationTime = ([datetimeoffset]::Parse($timestamp, [cultureinfo]::InvariantCulture)).UtcDateTime
        $planParameters = @{
            ReleaseDecision = $decision
            Settings        = [PSCustomObject]@{
                DatePrereleaseFormat  = 'yyyy-MM-dd'
                IncrementalPrerelease = $true
                VersionPrefix         = 'product-'
            }
            BaselineTag     = 'v2.0.3'
            PrereleaseName  = 'featurecalc'
            CalculationTime = $calculationTime
        }

        $plan = Get-ReleaseVersionPlan @planParameters

        $plan.ReleaseVersion | Should -BeExactly '2.1.0-featurecalc.2026-01-03.1'
        $plan.TagVersion.ToString() | Should -BeExactly 'product-2.1.0-featurecalc.2026-01-03.1'
        $plan.CalculatedAt | Should -BeExactly $timestamp
    }

    It 'returns a successful skip without a version or a release history read' {
        $currentPullRequest.labels = @(@{ name = 'release:skip' })

        $result = & $runCalculation

        $result.Decision | Should -BeExactly 'skip'
        $result.BumpSource | Should -BeExactly 'release:skip'
        $result.Keys | Should -Not -Contain 'ReleaseVersion'
        Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args[1] -ceq 'graphql' }
    }

    It 'requires a valid release decision: <Case>' -ForEach @(
        @{ Case = 'no bump'; Labels = @('release:prerelease'); Message = '*No release bump*' }
        @{ Case = 'two bumps'; Labels = @('release:patch', 'release:major'); Message = '*Conflicting release bump labels*' }
        @{ Case = 'conflicting skip'; Labels = @('release:skip', 'release:minor'); Message = '*release:skip must not be combined*' }
    ) {
        $currentPullRequest.labels = @($Labels | ForEach-Object { @{ name = $_ } })

        & $expectFailure -Message $Message
    }

    It 'rejects a stale PR event even if the current labels would allow a release' {
        $currentPullRequest.head = $head.Clone()
        $currentPullRequest.head.sha = $mergeSha

        & $expectFailure -Message '*no longer matches*'
    }

    It 'requires the PR event to identify the source repository' {
        $eventPullRequest.head = @{ ref = $head.ref; sha = $headSha }

        & $expectFailure -Message '*pull request event*exact source repository*'
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'uses the exact source repository, case-sensitive branch and pushed SHA for a feature push' {
        $env:GITHUB_EVENT_NAME = 'push'
        $githubEvent = $push
        $other = $currentPullRequest.Clone()
        $other.number = 43
        $other.head = @{ ref = $head.ref; sha = $headSha; repo = @{ full_name = 'example/other' } }
        $openPages = , @($other, $currentPullRequest)

        $result = & $runCalculation

        $result.ReleaseVersion | Should -BeExactly '2.1.0-featurecalc.1'
    }

    It 'does not guess a feature push PR when <Case>' -ForEach @(
        @{ Case = 'there is no open PR'; Message = '*No open pull request matches*' }
        @{ Case = 'the listed PR has a newer SHA'; Message = '*No open pull request matches*' }
        @{ Case = 'the listed PR has a different ref case'; Message = '*No open pull request matches*' }
        @{ Case = 'the PR changes after lookup'; Message = '*no longer matches*' }
        @{ Case = 'the lookup fails'; Message = '*read open pull requests*' }
        @{ Case = 'two pages contain an exact match'; Message = '*More than one open pull request*PullRequest*' }
    ) {
        $env:GITHUB_EVENT_NAME = 'push'
        $githubEvent = $push
        $other = $currentPullRequest.Clone()
        $other.number = 43
        $other.head = $head.Clone()
        switch ($Case) {
            'there is no open PR' { $openPages = , @() }
            'the listed PR has a newer SHA' {
                $other.head.sha = $mergeSha
                $openPages = , (, $other)
            }
            'the listed PR has a different ref case' {
                $other.head.ref = 'Feature/calc'
                $openPages = , (, $other)
            }
            'the PR changes after lookup' {
                $openPages = , (, $currentPullRequest.Clone())
                $currentPullRequest.head = @{ ref = $head.ref; sha = $mergeSha; repo = $head.repo }
            }
            'the lookup fails' { $lookupExitCode = 1 }
            'two pages contain an exact match' { $openPages = @((, $currentPullRequest), (, $other)) }
        }

        & $expectFailure -Message $Message
    }

    It 'uses a qualified PR selector instead of guessing when a branch has multiple PRs' {
        $env:GITHUB_EVENT_NAME = 'push'
        $githubEvent = $push
        $env:PSMODULE_AUTO_RELEASE_INPUT_PullRequest = "$targetRepository#42"
        $lookupExitCode = 1

        $result = & $runCalculation

        $result.ReleaseVersion | Should -BeExactly '2.1.0-featurecalc.1'
        Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args[1] -ceq "repos/$targetRepository/pulls" }
    }

    It 'uses the target repository for a fork push, including a push to the fork default branch' {
        $env:GITHUB_EVENT_NAME = 'push'
        $env:GITHUB_REPOSITORY = 'contributor/fork'
        $env:PSMODULE_AUTO_RELEASE_INPUT_PullRequest = "$targetRepository#42"
        $githubEvent = $push
        $githubEvent.repository = @{ full_name = $env:GITHUB_REPOSITORY; default_branch = 'trunk'; fork = $true }
        $githubEvent.ref = 'refs/heads/trunk'
        $head.ref = 'trunk'
        $head.repo.full_name = $env:GITHUB_REPOSITORY

        $result = & $runCalculation

        $result.ReleaseVersion | Should -BeExactly '2.1.0-trunk.1'
    }

    It 'requires an explicit selector for a fork push' {
        $env:GITHUB_EVENT_NAME = 'push'
        $env:GITHUB_REPOSITORY = 'contributor/fork'
        $githubEvent = $push
        $githubEvent.repository = @{ full_name = $env:GITHUB_REPOSITORY; default_branch = 'trunk'; fork = $true }

        & $expectFailure -Message '*fork push*PullRequest*'
    }

    It 'does not accept an explicitly selected PR with a stale head SHA' {
        $env:GITHUB_EVENT_NAME = 'push'
        $githubEvent = $push
        $env:PSMODULE_AUTO_RELEASE_INPUT_PullRequest = "$targetRepository#42"
        $head.sha = $mergeSha

        & $expectFailure -Message '*no longer matches*'
    }

    It 'rejects a push that does not supply a current branch commit' -ForEach @(
        @{ Ref = 'refs/tags/v3.0.0'; Deleted = $false }
        @{ Ref = 'refs/heads/feature/calc'; Deleted = $true }
    ) {
        $env:GITHUB_EVENT_NAME = 'push'
        $githubEvent = $push
        $githubEvent.ref = $Ref
        $githubEvent.deleted = $Deleted

        & $expectFailure -Message '*branch push*'
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'uses the configured bump on a direct default-branch push' {
        $env:GITHUB_EVENT_NAME = 'push'
        $githubEvent = $defaultPush
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'

        $result = & $runCalculation

        $result.Decision | Should -BeExactly 'release'
        $result.ReleaseVersion | Should -BeExactly '2.0.4'
        $result.Keys | Should -Not -Contain 'CalculatedAt'
    }

    It 'requires a configured bump when a default push has no exact merged PR' {
        $env:GITHUB_EVENT_NAME = 'push'
        $githubEvent = $defaultPush
        $currentPullRequest.state = 'closed'
        $currentPullRequest.merged_at = '2026-01-03T00:00:00Z'
        $currentPullRequest.merge_commit_sha = $headSha
        $associatedPages = , (, $currentPullRequest)

        & $expectFailure -Message '*No release bump*'
    }

    It 'uses labels only from the PR merged to the exact default-branch push' {
        $env:GITHUB_EVENT_NAME = 'push'
        $githubEvent = $defaultPush
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'
        $currentPullRequest.state = 'closed'
        $currentPullRequest.merged_at = '2026-01-03T00:00:00Z'
        $currentPullRequest.merge_commit_sha = $mergeSha
        $currentPullRequest.labels = @(@{ name = 'release:minor' }, @{ name = 'release:prerelease' })
        $wrongBranch = $currentPullRequest.Clone()
        $wrongBranch.number = 43
        $wrongBranch.base = @{ ref = 'other'; repo = $base.repo }
        $wrongRepository = $currentPullRequest.Clone()
        $wrongRepository.number = 44
        $wrongRepository.base = @{ ref = $base.ref; repo = @{ full_name = 'example/other' } }
        $associatedPages = , @($wrongBranch, $wrongRepository, $currentPullRequest)

        $result = & $runCalculation

        $result.ReleaseVersion | Should -BeExactly '2.1.0'
    }

    It 'fails when merged PR association lookup fails even with a configured bump' {
        $env:GITHUB_EVENT_NAME = 'push'
        $githubEvent = $defaultPush
        $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'
        $lookupExitCode = 1

        & $expectFailure -Message '*read pull requests associated*'
    }

    It 'uses the zero baseline only when the repository has no qualifying release' {
        $historyResponse.data.repository.latestRelease = $null

        $result = & $runCalculation

        $result.ReleaseVersion | Should -BeExactly '0.1.0-featurecalc.1'
    }

    It 'returns an unprefixed version for a <TagCase>' -ForEach @(
        @{ TagCase = 'custom-prefixed baseline'; Prefix = 'product-1.0.0-'; Tag = 'product-1.0.0-2.0.3' }
        @{ TagCase = 'baseline from before a prefix change'; Prefix = 'v2.'; Tag = 'v2.0.3' }
    ) {
        $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix = $Prefix
        $latest.tagName = $Tag

        $result = & $runCalculation

        $result.ReleaseVersion | Should -BeExactly '2.1.0-featurecalc.1'
    }

    It 'does not expose a decision or version when <Case>' -ForEach @(
        @{ Case = 'the history request fails'; Message = '*read release history*' }
        @{ Case = 'the history response is missing its baseline field'; Message = '*invalid release history*' }
        @{ Case = 'the baseline is not full SemVer'; Message = '*baseline*SemVer*' }
        @{ Case = 'the configured date produces invalid SemVer'; Message = '*calculated*not valid SemVer*' }
        @{ Case = 'the default bump setting is invalid'; Message = '*Invalid DefaultBump*' }
        @{ Case = 'the mode is invalid'; Message = '*Invalid Mode*' }
        @{ Case = 'the selector is invalid'; Message = '*Invalid PullRequest*' }
    ) {
        switch ($Case) {
            'the history request fails' { $historyExitCode = 1 }
            'the history response is missing its baseline field' { $historyResponse.data.repository.Remove('latestRelease') }
            'the baseline is not full SemVer' { $latest.tagName = 'v2.0' }
            'the configured date produces invalid SemVer' { $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat = 'yyyy/MM' }
            'the default bump setting is invalid' { $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'Patch' }
            'the mode is invalid' { $env:PSMODULE_AUTO_RELEASE_INPUT_Mode = 'unknown' }
            'the selector is invalid' { $env:PSMODULE_AUTO_RELEASE_INPUT_PullRequest = "$targetRepository#-42" }
        }

        & $expectFailure -Message $Message
    }

    Context 'Publish mode' {
        BeforeEach {
            $allowSimulatedWrites = $true
            $env:PSMODULE_AUTO_RELEASE_INPUT_Mode = 'publish'
            $currentPullRequest.labels = @(@{ name = 'release:minor' }, @{ name = 'release:prerelease' })
            $eventPullRequest.labels = $currentPullRequest.labels
            $releaseRecords = @($latest.Clone())
            $releaseRecords[0].isLatest = $true
            $githubEvent.action = 'opened'
        }

        It 'publishes the Calculate output with the configured prefix at the exact PR head' {
            $env:PSMODULE_AUTO_RELEASE_INPUT_Mode = 'calculate'
            $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix = 'product-'
            $result = & $runCalculation
            $result.ReleaseVersion | Should -BeExactly '2.1.0-featurecalc.1'
            $env:PSMODULE_AUTO_RELEASE_INPUT_Mode = 'publish'
            $env:PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion = $result.ReleaseVersion

            $null = & $runActionStep

            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -ceq 'release' -and $args[1] -ceq 'create' -and $args -ccontains 'product-2.1.0-featurecalc.1' -and
                $args -ccontains '--prerelease' -and $args -ccontains $headSha -and $args -ccontains "github.com/$targetRepository"
            }
            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -ceq 'api' -and $args -ccontains 'POST' -and
                $args -ccontains 'ref=refs/tags/product-2.1.0-featurecalc.1' -and $args -ccontains "sha=$headSha"
            }
        }

        It 'calculates on demand with current PR labels when ReleaseVersion is omitted' {
            $eventPullRequest.labels = @(@{ name = 'release:patch' })

            $null = & $runActionStep

            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -ceq 'release' -and $args[1] -ceq 'create' -and $args -ccontains 'v2.1.0-featurecalc.1' -and
                $args -ccontains $headSha
            }
        }

        It 'replays the UTC Calculate output after midnight' {
            $clock = [datetime]::new(2026, 1, 3, 23, 59, 0, [DateTimeKind]::Utc)
            Mock Get-Date { $clock } -ParameterFilter { $AsUTC }
            $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat = 'yyyy-MM-dd'
            $env:PSMODULE_AUTO_RELEASE_INPUT_Mode = 'calculate'
            $result = & $runCalculation
            $result.ReleaseVersion | Should -BeExactly '2.1.0-featurecalc.2026-01-03.1'
            $timestamp = [regex]::Match([IO.File]::ReadAllText($env:GITHUB_OUTPUT), '"CalculatedAt":\s*"([^"]+)"').Groups[1].Value
            $timestamp | Should -BeExactly '2026-01-03T23:59:00.0000000Z'
            $env:PSMODULE_AUTO_RELEASE_INPUT_Mode = 'publish'
            $env:PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion = $result.ReleaseVersion
            $env:PSMODULE_AUTO_RELEASE_INPUT_CalculatedAt = $timestamp
            $clock = $clock.AddMinutes(2)

            $null = & $runActionStep

            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -ceq 'release' -and $args[1] -ceq 'create' -and
                $args -ccontains 'v2.1.0-featurecalc.2026-01-03.1' -and $args -ccontains $headSha
            }
        }

        It 'rejects <Case> before any repository writes' -ForEach @(
            @{ Case = 'a prefixed version'; Version = 'v2.1.0-featurecalc.1'; Message = '*ReleaseVersion*unprefixed SemVer*' }
            @{ Case = 'an invalid version'; Version = '2.1'; Message = '*ReleaseVersion*unprefixed SemVer*' }
            @{ Case = 'a stable version on a PR'; Version = '2.1.0'; Message = '*ReleaseVersion*does not match*' }
            @{ Case = 'a different bump'; Version = '2.0.4-featurecalc.1'; Message = '*ReleaseVersion*does not match*' }
            @{ Case = 'changed labels'; Message = '*ReleaseVersion*does not match*' }
            @{ Case = 'changed stable history'; Message = '*ReleaseVersion*does not match*' }
            @{ Case = 'changed settings'; Message = '*ReleaseVersion*does not match*' }
            @{ Case = 'a stale head'; Message = '*no longer matches*' }
            @{ Case = 'a PR without the publication label'; Message = '*release:prerelease*' }
            @{ Case = 'a skipped PR'; Message = '*ReleaseVersion*release:skip*' }
            @{ Case = 'a release request on a PR close'; Message = '*ReleaseVersion*not eligible*' }
            @{ Case = 'a release request on manual dispatch'; Message = '*ReleaseVersion*not eligible*' }
            @{ Case = 'an exact tag at a different SHA'; Message = '*tag*v2.1.0-featurecalc.1*target*' }
            @{ Case = 'an exact annotated tag'; Message = '*tag*v2.1.0-featurecalc.1*target*' }
            @{ Case = 'an unreadable tag'; Message = '*read*tag*v2.1.0-featurecalc.1*' }
            @{ Case = 'a malformed tag result'; Message = '*invalid reference*release tag*' }
            @{ Case = 'a missing date timestamp'; Message = '*CalculatedAt*required*' }
            @{ Case = 'a non-UTC timestamp'; Message = '*CalculatedAt*UTC*' }
        ) {
            $env:PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion = $Version ?? '2.1.0-featurecalc.1'
            switch ($Case) {
                'changed labels' { $currentPullRequest.labels = @(@{ name = 'release:major' }, @{ name = 'release:prerelease' }) }
                'changed stable history' { $latest.tagName = 'v2.1.0' }
                'changed settings' { $env:PSMODULE_AUTO_RELEASE_INPUT_IncrementalPrerelease = 'false' }
                'a stale head' {
                    $currentPullRequest.head = $head.Clone()
                    $currentPullRequest.head.sha = $mergeSha
                }
                'a PR without the publication label' { $currentPullRequest.labels = @(@{ name = 'release:minor' }) }
                'a skipped PR' { $currentPullRequest.labels = @(@{ name = 'release:skip' }) }
                'a release request on a PR close' {
                    $githubEvent.action = 'closed'
                    $eventPullRequest.state = 'closed'
                    $eventPullRequest.merged = $true
                    $eventPullRequest.merge_commit_sha = $mergeSha
                }
                'a release request on manual dispatch' {
                    $env:GITHUB_EVENT_NAME = 'workflow_dispatch'
                    $githubEvent = @{ repository = $repository }
                }
                'an exact tag at a different SHA' {
                    $tagReferences = @(@{ ref = 'refs/tags/v2.1.0-featurecalc.1'; object = @{ sha = $mergeSha; type = 'commit' } })
                }
                'an exact annotated tag' {
                    $tagReferences = @(@{ ref = 'refs/tags/v2.1.0-featurecalc.1'; object = @{ sha = $headSha; type = 'tag' } })
                }
                'an unreadable tag' { $tagExitCode = 1 }
                'a malformed tag result' { $tagReferences = @(@{ object = @{ sha = $headSha; type = 'commit' } }) }
                'a missing date timestamp' { $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat = 'yyyy-MM-dd' }
                'a non-UTC timestamp' {
                    $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat = 'yyyy-MM-dd'
                    $env:PSMODULE_AUTO_RELEASE_INPUT_CalculatedAt = '2026-01-03T02:05:06.0000000+01:00'
                }
            }

            { & $runActionStep } | Should -Throw $Message
            & $expectNoRepositoryWrites
        }

        It 'does not confuse a longer ref with the exact version tag' {
            $env:PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion = '2.1.0-featurecalc.1'
            $tagReferences = @(@{ ref = 'refs/tags/v2.1.0-featurecalc.10'; object = @{ sha = $mergeSha; type = 'commit' } })

            $null = & $runActionStep

            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -ceq 'release' -and $args[1] -ceq 'create' -and $args -ccontains 'v2.1.0-featurecalc.1'
            }
        }

        It 'enforces the target when replacing an unnumbered prerelease: <Case>' -ForEach @(
            @{ Case = 'same target with exact input'; Supplied = $true; SameTarget = $true }
            @{ Case = 'different target without exact input'; Supplied = $false; SameTarget = $false }
            @{ Case = 'different target with exact input'; Supplied = $true; SameTarget = $false }
        ) {
            $env:PSMODULE_AUTO_RELEASE_INPUT_IncrementalPrerelease = 'false'
            if ($Supplied) {
                $env:PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion = '2.1.0-featurecalc'
            }
            $tag = 'v2.1.0-featurecalc'
            $existingSha = if ($SameTarget) { $headSha } else { $mergeSha }
            $tagReferences = @(@{ ref = "refs/tags/$tag"; object = @{ sha = $existingSha; type = 'commit' } })
            $releaseRecords += @{ tagName = $tag; isPrerelease = $true; isDraft = $false }

            if ($Supplied -and -not $SameTarget) {
                { & $runActionStep } | Should -Throw '*Release tag*v2.1.0-featurecalc*validated target*'
                & $expectNoRepositoryWrites
                return
            }

            $null = & $runActionStep

            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -ceq 'release' -and $args[1] -ceq 'delete' -and $args -ccontains $tag -and
                ($args -ccontains '--cleanup-tag') -eq (-not $SameTarget)
            }
            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -ceq 'release' -and $args[1] -ceq 'create' -and $args -ccontains $tag -and
                $args -ccontains '--verify-tag' -and $args -ccontains $headSha
            }
        }

        It 'skips publication without a version and without release history' {
            $currentPullRequest.labels = @(@{ name = 'release:skip' })
            $historyExitCode = 1

            $null = & $runActionStep

            Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args[0] -cin @('release', 'pr') -or $args[1] -ceq 'graphql' }
            Should -Invoke git -Times 0 -Exactly
            [IO.File]::ReadAllText($env:GITHUB_OUTPUT) | Should -BeExactly ''
        }

        It 'uses the exact default-branch push and its matching merged PR, not the configured bump' {
            $env:GITHUB_EVENT_NAME = 'push'
            $githubEvent = $defaultPush
            $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'
            $currentPullRequest.state = 'closed'
            $currentPullRequest.merged_at = '2026-01-03T00:00:00Z'
            $currentPullRequest.merge_commit_sha = $mergeSha
            $unrelated = $currentPullRequest.Clone()
            $unrelated.number = 43
            $unrelated.merge_commit_sha = $headSha
            $associatedPages = , @($unrelated, $currentPullRequest)
            $env:PSMODULE_AUTO_RELEASE_INPUT_Mode = 'calculate'
            $result = & $runCalculation
            $result.ReleaseVersion | Should -BeExactly '2.1.0'
            $env:PSMODULE_AUTO_RELEASE_INPUT_Mode = 'publish'
            $env:PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion = $result.ReleaseVersion

            $null = & $runActionStep

            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -ceq 'release' -and $args[1] -ceq 'create' -and $args -ccontains 'v2.1.0' -and
                $args -ccontains $mergeSha -and $args -cnotcontains '--prerelease'
            }
            Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args[0] -cin @('label', 'pr') }
        }

        It 'uses a configured bump for a direct push and honors WhatIf' {
            $env:GITHUB_EVENT_NAME = 'push'
            $githubEvent = $defaultPush
            $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'
            $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = 'true'

            $output = (& $runActionStep) -join "`n"

            $output | Should -Match "release create v2\.0\.4 .+--target $mergeSha"
            & $expectNoRepositoryWrites
        }

        It 'rejects <Case> for a push before any repository writes' -ForEach @(
            @{ Case = 'a prerelease on a default-branch push'; Message = '*ReleaseVersion*does not match*' }
            @{ Case = 'a changed default branch'; Message = '*no longer matches the repository default branch*' }
            @{ Case = 'a direct push without a default bump'; Message = '*No release bump*' }
            @{ Case = 'a version on a push with no open PR'; Message = '*ReleaseVersion*not eligible*' }
        ) {
            $env:GITHUB_EVENT_NAME = 'push'
            $githubEvent = $defaultPush
            $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'patch'
            $env:PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion = '2.0.4'
            switch ($Case) {
                'a prerelease on a default-branch push' { $env:PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion = '2.0.4-featurecalc.1' }
                'a changed default branch' { $liveDefaultBranch = 'renamed' }
                'a direct push without a default bump' {
                    $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump = 'none'
                    $env:PSMODULE_AUTO_RELEASE_INPUT_ReleaseVersion = $null
                }
                'a version on a push with no open PR' {
                    $githubEvent = $push
                    $openPages = , @()
                }
            }

            { & $runActionStep } | Should -Throw $Message
            & $expectNoRepositoryWrites
        }

        It 'does not publish a stable release on a merged PR close but still cleans its prerelease' {
            $githubEvent.action = 'closed'
            $eventPullRequest.state = 'closed'
            $eventPullRequest.merged = $true
            $eventPullRequest.merge_commit_sha = $mergeSha
            $releaseRecords += @{ tagName = 'v2.1.0-featurecalc.1'; isPrerelease = $true }

            $null = & $runActionStep

            Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
                $args[0] -ceq 'release' -and $args[1] -ceq 'delete' -and $args -ccontains 'v2.1.0-featurecalc.1'
            }
            Should -Invoke gh -Times 0 -Exactly -ParameterFilter {
                $args[0] -ceq 'release' -and $args[1] -ceq 'create'
            }
            Should -Invoke git -Times 0 -Exactly
        }
    }
}
