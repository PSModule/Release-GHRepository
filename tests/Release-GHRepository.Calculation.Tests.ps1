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
    $runCalculation = {
        $githubEvent | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $env:GITHUB_EVENT_PATH
        $null = & $bootstrapPath -OutputPath $bootstrapOutput
        $settingsRecord = Select-String -LiteralPath $bootstrapOutput -Pattern '^ReleaseSettings<<' -Context 0, 1
        if (-not $settingsRecord.Context.PostContext) {
            throw 'The settings step did not write the release settings.'
        }
        $env:PSMODULE_AUTO_RELEASE_RESOLVED_SETTINGS = $settingsRecord.Context.PostContext[0]
        $null = & $runAction
        (Get-GitHubOutput -AsHashtable).result
    }
    $expectFailure = {
        param([string] $Message)

        { & $runCalculation } | Should -Throw $Message
        [IO.File]::ReadAllText($env:GITHUB_OUTPUT) | Should -BeExactly ''
    }
    $headSha = '0123456789012345678901234567890123456789'
    $mergeSha = 'fedcba9876543210fedcba9876543210fedcba98'
    $targetRepository = 'example/project'
}

Describe 'Release-GHRepository Calculate mode' {
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

        # Simulate API responses so these tests need no token and cannot change a repository.
        Mock Install-PSResource {}
        Mock git { throw 'Calculate must not run git.' }
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($args[0] -ceq 'api' -and $args[1] -ceq 'graphql' -and
                $args -contains 'owner=example' -and $args -contains 'name=project' -and
                $args -clike 'query=query*latestRelease*') {
                $global:LASTEXITCODE = $historyExitCode
                ConvertTo-Json -InputObject $historyResponse -Depth 20 -Compress
            } elseif ($args[0] -ceq 'api' -and $args -contains 'GET') {
                switch ($args[1]) {
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
                    default { throw "Unexpected Calculate read: gh $($args -join ' ')" }
                }
            } else {
                throw "Unexpected Calculate command: gh $($args -join ' ')"
            }
        }
    }

    AfterEach {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
        }
        Should -Invoke git -Times 0 -Exactly
        Should -Invoke gh -Times 0 -Exactly -ParameterFilter { $args[0] -cne 'api' }
    }

    It 'uses current PR labels for a prerelease without a publication label when WhatIf is <WhatIf>' -ForEach @(
        @{ WhatIf = 'false' }
        @{ WhatIf = 'true' }
    ) {
        $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf = $WhatIf

        $result = & $runCalculation

        $result.Keys.Count | Should -Be 2
        $result.Decision | Should -BeExactly 'release'
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

    It 'returns only a successful skip and does not read release history' {
        $currentPullRequest.labels = @(@{ name = 'release:skip' })

        $result = & $runCalculation

        $result.Keys.Count | Should -Be 1
        $result.Decision | Should -BeExactly 'skip'
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
}
