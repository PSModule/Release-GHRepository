[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'The Pester cases and mocks share the Git and pull request fixtures.'
)]
[CmdletBinding()]
param()

BeforeAll {
    Import-Module -Name GitHub, powershell-yaml, PSSemVer
    $actionDirectory = Split-Path -Path $PSScriptRoot -Parent
    $scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\Test-ReleaseDecisionContext.ps1'
    $source = Join-Path -Path $TestDrive -ChildPath 'source'
    $workspace = Join-Path -Path $TestDrive -ChildPath 'candidate'
    git init --quiet -b main $source
    $gitAuthor = @('-c', 'user.name=Release Test', '-c', 'user.email=release@example.test', '-c', 'commit.gpgsign=false')
    $workflowDirectory = Join-Path -Path $source -ChildPath '.github\workflows'
    $null = New-Item -Path $workflowDirectory -ItemType Directory -Force
    $publisher = Join-Path -Path $actionDirectory -ChildPath '.github\workflows\Release.yml'
    Copy-Item -LiteralPath $publisher -Destination $workflowDirectory
    git -C $source add -- .github
    git -C $source @gitAuthor commit --quiet -m 'Base publisher'
    $baseSha = git -C $source rev-parse HEAD
    '# Documentation' | Set-Content -LiteralPath (Join-Path -Path $source -ChildPath 'README.md')
    git -C $source add -- README.md
    git -C $source @gitAuthor commit --quiet -m 'Docs-only contribution'
    $headSha = git -C $source rev-parse HEAD
    $tree = git -C $source rev-parse 'HEAD^{tree}'
    $mergeSha = git -C $source @gitAuthor commit-tree $tree -p $baseSha -p $headSha -m 'Candidate'
    git -C $source update-ref HEAD $mergeSha
    git clone --quiet --no-local --depth 1 $source $workspace
}

AfterAll {
    # Git marks loose objects read-only on Windows, but TestDrive needs to delete them.
    foreach ($repositoryPath in @($source, $workspace)) {
        Get-ChildItem -LiteralPath (Join-Path -Path $repositoryPath -ChildPath '.git') -Recurse -Force -File |
            Where-Object IsReadOnly | ForEach-Object { $_.IsReadOnly = $false }
    }
}

Describe 'Checking the release decision snapshot' {
    BeforeEach {
        $repository = 'PSModule/Release-GHRepository'
        $fork = 'contributor/Release-GHRepository'
        $pullRequest = @{
            number = 42
            state  = 'open'
            head   = @{ sha = $headSha; ref = 'docs'; repo = @{ full_name = $fork } }
            base   = @{ sha = $baseSha; ref = 'main'; repo = @{ full_name = $repository } }
            labels = @(@{ name = 'documentation' }, @{ name = 'release:skip' })
        }
        $eventPath = Join-Path -Path $TestDrive -ChildPath 'pull-request.json'
        ConvertTo-Json -Depth 8 -InputObject @{
            repository   = @{ full_name = $repository }
            pull_request = $pullRequest
        } | Set-Content -LiteralPath $eventPath
        $current = $pullRequest
        Mock gh { ConvertTo-Json -Depth 8 -InputObject $current }
        $parameters = @{
            EventPath    = $eventPath
            Workspace    = $workspace
            Repository   = $repository
            CandidateSha = $mergeSha
        }
    }

    It 'verifies a fork candidate even when GitHub returns its labels in a different order' {
        $current.labels = @(@{ name = 'release:skip' }, @{ name = 'documentation' })

        $checked = & $scriptPath @parameters

        $checked.Number | Should -Be 42
        $checked.BaseSha | Should -BeExactly $baseSha
        $checked.HeadSha | Should -BeExactly $headSha
        $checked.MergeSha | Should -BeExactly $mergeSha
        Should -Invoke gh -Times 1 -Exactly -ParameterFilter {
            $args -join ' ' -ceq "api --method GET repos/$repository/pulls/42"
        }
    }

    It 'rejects a label-only change after calculation even when the candidate SHA is unchanged' {
        $null = & $scriptPath @parameters
        $current.labels = @(@{ name = 'release:patch' })

        { & $scriptPath @parameters } | Should -Throw '*labels changed*'
    }

    It 'rejects labels read by Calculate that do not match the event snapshot' {
        $usedByCalculator = $current.Clone()
        $usedByCalculator.labels = @(@{ name = 'release:major' })
        $parameters.CurrentPullRequest = $usedByCalculator | ConvertTo-Json -Depth 8 | ConvertFrom-Json

        { & $scriptPath @parameters } | Should -Throw '*labels changed*'
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'rejects a pull request that was retargeted while the job was running' {
        $current.base.ref = 'maintenance'

        { & $scriptPath @parameters } | Should -Throw '*target changed*'
    }

    It 'rejects a live head advance against the same target branch' {
        $current.head.sha = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

        { & $scriptPath @parameters } | Should -Throw '*source changed*'
    }

    It 'fails before reading labels if the checkout is not the event candidate' {
        $parameters.CandidateSha = $headSha

        { & $scriptPath @parameters } | Should -Throw '*candidate merge checkout*'
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'rejects a candidate with parents that do not match the reported head and base' {
        $eventPayload = Get-Content -LiteralPath $eventPath -Raw | ConvertFrom-Json -AsHashtable
        $eventPayload.pull_request.base.sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $eventPayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $eventPath

        { & $scriptPath @parameters } | Should -Throw '*merge parents*'
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'does not treat a missing live pull request response as empty labels' {
        Mock gh { '{}' }

        { & $scriptPath @parameters } | Should -Throw '*incomplete*'
    }

    It 'fails if the pull request read fails' {
        Mock gh { $global:LASTEXITCODE = 1 }

        { & $scriptPath @parameters } | Should -Throw '*Could not read pull request*'
    }

    It 'reports a valid skip for a docs-only fork without a write or a version' {
        $outputPath = Join-Path -Path $TestDrive -ChildPath 'decision-output.txt'
        [IO.File]::WriteAllText($outputPath, '')
        $checkEnvironment = @{
            GITHUB_ACTION                         = 'release'
            GITHUB_EVENT_NAME                     = 'pull_request'
            GITHUB_EVENT_PATH                     = $eventPath
            GITHUB_OUTPUT                         = $outputPath
            GITHUB_REPOSITORY                     = $repository
            GITHUB_SERVER_URL                     = 'https://github.com'
            GITHUB_SHA                            = $mergeSha
            GITHUB_WORKSPACE                      = $workspace
            PSMODULE_AUTO_RELEASE_CHECK_PUBLISHER = 'true'
            PSMODULE_GITHUB_SCRIPT                = 'true'
        }
        $savedEnvironment = @{}
        foreach ($name in $checkEnvironment.Keys) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $checkEnvironment[$name])
        }
        Mock Install-PSResource {}
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($args[0] -cne 'api' -or $args -cnotcontains 'GET' -or $args -cnotcontains "repos/$repository/pulls/42") {
                throw "Unexpected command: gh $($args -join ' ')"
            }
            ConvertTo-Json -Depth 8 -InputObject $current
        }

        try {
            $bootstrap = Join-Path -Path $actionDirectory -ChildPath 'src\Initialize-ReleaseConfiguration.ps1'
            $main = Join-Path -Path $actionDirectory -ChildPath 'src\main.ps1'
            $settings = & $bootstrap -WorkspacePath $workspace -OutputPath '' -PublisherBranch main
            $null = & $main -Settings $settings
            $result = (Get-GitHubOutput -AsHashtable).result

            $result.Decision | Should -BeExactly 'skip'
            $result.BumpSource | Should -BeExactly 'release:skip'
            $result.Keys | Should -Not -Contain 'ReleaseVersion'
            Should -Invoke gh -Times 1 -Exactly
        } finally {
            foreach ($name in $savedEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
            }
        }
    }
}
