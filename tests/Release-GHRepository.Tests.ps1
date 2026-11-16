[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Pester shares setup variables with test script blocks.'
)]
param()

BeforeAll {
    $helperPath = Join-Path $PSScriptRoot '..\src\Release-GHRepository.Helpers.psm1'
    Import-Module -Name $helperPath -Force
}

Describe 'Verified release modules' {
    BeforeEach {
        $fixtureRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $moduleDirectory = Join-Path $fixtureRoot 'source'
        $null = New-Item -Path $moduleDirectory -ItemType Directory
        $manifestPath = Join-Path $moduleDirectory 'ReleaseSecurityFixture.psd1'
        New-ModuleManifest -Path $manifestPath -RootModule 'ReleaseSecurityFixture.psm1' -ModuleVersion '1.0.0'
        $modulePath = Join-Path $moduleDirectory 'ReleaseSecurityFixture.psm1'
        $markerPath = Join-Path $fixtureRoot 'imported.txt'
        $moduleContent = @'
$null = New-Item -Path '__MARKER__' -ItemType File -Force
function Get-ReleaseSecurityFixtureValue { 'verified package' }
Export-ModuleMember -Function Get-ReleaseSecurityFixtureValue
'@
        $moduleContent.Replace('__MARKER__', $markerPath.Replace("'", "''")) | Set-Content -LiteralPath $modulePath
        $packagePath = Join-Path $fixtureRoot 'package.nupkg'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($moduleDirectory, $packagePath)
        $packageHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256).Hash
        $destinationPath = Join-Path $fixtureRoot 'verified'
        $importParameters = @{
            Path            = $packagePath
            DestinationPath = $destinationPath
            Name            = 'ReleaseSecurityFixture'
            RequiredVersion = '1.0.0'
            SHA256          = $packageHash
        }
    }

    AfterEach {
        Get-Module -Name ReleaseSecurityFixture | Remove-Module -Force
    }

    It 'loads the verified package and exact module version' {
        $module = Import-VerifiedReleaseModule @importParameters

        $module.Version | Should -Be ([version] '1.0.0')
        Get-ReleaseSecurityFixtureValue | Should -Be 'verified package'
    }

    It 'rejects changed package bytes before extraction or module execution' {
        $archive = [System.IO.Compression.ZipFile]::Open($packagePath, 'Update')
        try {
            $archive.GetEntry('ReleaseSecurityFixture.psm1').Delete()
            $entry = $archive.CreateEntry('ReleaseSecurityFixture.psm1')
            $writer = [System.IO.StreamWriter]::new($entry.Open())
            try {
                $tamperedContent = "`$null = New-Item -Path '$($markerPath.Replace("'", "''"))' -ItemType File"
                $writer.Write($tamperedContent)
            } finally {
                $writer.Dispose()
            }
        } finally {
            $archive.Dispose()
        }

        { Import-VerifiedReleaseModule @importParameters } | Should -Throw -ExpectedMessage '*SHA256*'
        Test-Path -LiteralPath $markerPath | Should -BeFalse
        Test-Path -LiteralPath $destinationPath | Should -BeFalse
    }

    It 'rejects a different module version before module execution' {
        $importParameters.RequiredVersion = '2.0.0'

        { Import-VerifiedReleaseModule @importParameters } | Should -Throw -ExpectedMessage '*2.0.0*'
        Test-Path -LiteralPath $markerPath | Should -BeFalse
    }

    It 'does not select a same-name module from another directory' {
        $shadowDirectory = Join-Path $fixtureRoot 'shadow'
        $null = New-Item -Path $shadowDirectory -ItemType Directory
        $shadowPath = Join-Path $shadowDirectory 'ReleaseSecurityFixture.psm1'
        "function Get-ReleaseSecurityFixtureValue { 'unverified module' }" | Set-Content -LiteralPath $shadowPath
        Import-Module -Name $shadowPath -Global

        $null = Import-VerifiedReleaseModule @importParameters

        Get-ReleaseSecurityFixtureValue | Should -Be 'verified package'
    }
}

Describe 'Pull request publication trust boundary' {
    BeforeEach {
        $repository = 'PSModule/Release-GHRepository'
        $headSha = '1111111111111111111111111111111111111111'
        $mergeSha = '2222222222222222222222222222222222222222'
        $pullRequest = [pscustomobject] @{
            number           = 7
            state            = 'open'
            merged           = $false
            closed_at        = $null
            merge_commit_sha = $null
            base             = [pscustomobject] @{
                ref  = 'main'
                repo = [pscustomobject] @{ id = 123; full_name = $repository }
            }
            head             = [pscustomobject] @{
                sha  = $headSha
                repo = [pscustomobject] @{ id = 123; full_name = $repository }
            }
        }
        $workflowRun = [pscustomobject] @{
            event           = 'pull_request'
            conclusion      = 'success'
            created_at      = '2026-11-16T12:00:01Z'
            head_sha        = $headSha
            repository      = [pscustomobject] @{ id = 123; full_name = $repository }
            head_repository = [pscustomobject] @{ id = 123; full_name = $repository }
            pull_requests   = @(
                [pscustomobject] @{
                    number = 7
                    head   = [pscustomobject] @{ sha = $headSha }
                    base   = [pscustomobject] @{ ref = 'main'; repo = [pscustomobject] @{ id = 123 } }
                }
            )
        }
        $validationParameters = @{
            PullRequest   = $pullRequest
            WorkflowRun   = $workflowRun
            Repository    = $repository
            DefaultBranch = 'main'
        }
    }

    It 'accepts an open PR at the checked commit' {
        { Assert-ReleasePullRequest @validationParameters } | Should -Not -Throw
    }

    It 'accepts a merged PR whose merge commit was checked' {
        $pullRequest.state = 'closed'
        $pullRequest.merged = $true
        $pullRequest.closed_at = '2026-11-16T12:00:00Z'
        $pullRequest.merge_commit_sha = $mergeSha
        $workflowRun.head_sha = $mergeSha

        { Assert-ReleasePullRequest @validationParameters } | Should -Not -Throw
    }

    It 'resolves a merged PR from its commit API association when the run PR list is empty' {
        $pullRequest.state = 'closed'
        $pullRequest.merged = $true
        $pullRequest.closed_at = '2026-11-16T12:00:00Z'
        $pullRequest.merge_commit_sha = $mergeSha
        $validationParameters.CommitPullRequests = @($pullRequest)
        $workflowRun.pull_requests = @()

        { Assert-ReleasePullRequest @validationParameters } | Should -Not -Throw
    }

    It 'accepts a merged fork PR without running its code' {
        $pullRequest.state = 'closed'
        $pullRequest.merged = $true
        $pullRequest.closed_at = '2026-11-16T12:00:00Z'
        $pullRequest.merge_commit_sha = $mergeSha
        $pullRequest.head.repo.full_name = 'contributor/fork'
        $workflowRun.head_repository.full_name = 'contributor/fork'

        { Assert-ReleasePullRequest @validationParameters } | Should -Not -Throw
    }

    It 'rejects <Name>' -ForEach @(
        @{
            Name    = 'failed checks'
            Change  = { $workflowRun.conclusion = 'failure' }
            Message = '*successful pull_request*'
        }
        @{
            Name    = 'a non-PR workflow run'
            Change  = { $workflowRun.event = 'push' }
            Message = '*successful pull_request*'
        }
        @{
            Name    = 'checks from another repository'
            Change  = { $workflowRun.repository.full_name = 'other/repository' }
            Message = '*repository*'
        }
        @{
            Name    = 'an open fork PR'
            Change  = {
                $pullRequest.head.repo.full_name = 'contributor/fork'
                $workflowRun.head_repository.full_name = 'contributor/fork'
            }
            Message = '*branch in this repository*'
        }
        @{
            Name    = 'an unassociated PR'
            Change  = { $workflowRun.pull_requests = @() }
            Message = '*one associated pull request*'
        }
        @{
            Name    = 'an ambiguous PR association'
            Change  = { $workflowRun.pull_requests += $workflowRun.pull_requests[0] }
            Message = '*one associated pull request*'
        }
        @{
            Name    = 'a different PR number'
            Change  = { $workflowRun.pull_requests[0].number = 8 }
            Message = '*associated pull request*'
        }
        @{
            Name    = 'a PR changed since its checks'
            Change  = { $pullRequest.head.sha = '3333333333333333333333333333333333333333' }
            Message = '*changed since*'
        }
        @{
            Name    = 'a different target branch'
            Change  = { $pullRequest.base.ref = 'other-branch' }
            Message = '*default branch*'
        }
        @{
            Name    = 'an invalid publication commit'
            Change  = {
                $pullRequest.head.sha = '--unexpected-option'
                $workflowRun.head_sha = '--unexpected-option'
                $workflowRun.pull_requests[0].head.sha = '--unexpected-option'
            }
            Message = '*commit SHA*'
        }
        @{
            Name    = 'a pre-merge run completing after closure'
            Change  = {
                $pullRequest.state = 'closed'
                $pullRequest.merged = $true
                $pullRequest.closed_at = '2026-11-16T12:00:02Z'
                $pullRequest.merge_commit_sha = $mergeSha
            }
            Message = '*predates PR closure*'
        }
    ) {
        . $Change

        { Assert-ReleasePullRequest @validationParameters } | Should -Throw -ExpectedMessage $Message
    }
}

Describe 'Prerelease cleanup ownership' {
    It 'selects only this PR prereleases and excludes stable releases and prefix collisions' {
        $releases = @(
            [pscustomobject] @{ tagName = 'v1.2.3-pr7.1'; isPrerelease = $true }
            [pscustomobject] @{ tagName = 'v1.2.3-pr7'; isPrerelease = $true }
            [pscustomobject] @{ tagName = 'v1.2.3-pr7.2'; isPrerelease = $false }
            [pscustomobject] @{ tagName = 'v1.2.3-pr70.1'; isPrerelease = $true }
            [pscustomobject] @{ tagName = 'v1.2.3-otherpr7.1'; isPrerelease = $true }
            [pscustomobject] @{ tagName = 'v1.2.3'; isPrerelease = $false }
        )

        $selected = @(Get-ReleasePrerelease -Release $releases -PullRequestNumber 7 -VersionPrefix 'v')

        $selected.tagName | Should -Be @('v1.2.3-pr7.1', 'v1.2.3-pr7')
    }

    It 'supports an empty version prefix' {
        $releases = @([pscustomobject] @{ tagName = '1.2.3-pr7.1'; isPrerelease = $true })

        @(Get-ReleasePrerelease -Release $releases -PullRequestNumber 7 -VersionPrefix '').Count | Should -Be 1
    }
}

Describe 'Read-only pull request checks' {
    It 'does not let configuration enable writes during pull_request checks' {
        Test-ReleasePreview -EventName 'pull_request' | Should -BeTrue
    }

    It 'does not let configuration disable an explicit preview request' {
        Test-ReleasePreview -EventName 'workflow_run' -Requested | Should -BeTrue
    }

    It 'honors a configured preview in the trusted publisher' {
        Test-ReleasePreview -EventName 'workflow_run' -Configured | Should -BeTrue
    }

    It 'permits publication only in the trusted publisher' {
        Test-ReleasePreview -EventName 'workflow_run' | Should -BeFalse
    }

    It 'rejects publication on other events' {
        { Test-ReleasePreview -EventName 'workflow_dispatch' } | Should -Throw -ExpectedMessage '*workflow_run*'
    }
}

Describe 'Scoped release tag updates' {
    BeforeEach {
        $repository = 'PSModule/Release-GHRepository'
        $commitSha = '2222222222222222222222222222222222222222'
        Mock gh -ModuleName Release-GHRepository.Helpers {
            $global:LASTEXITCODE = 0
            '[]'
        }
    }

    It 'creates only the requested tag at the release commit' {
        Set-ReleaseTag -Repository $repository -Name 'v1' -CommitSha $commitSha -Confirm:$false

        Should -Invoke gh -ModuleName Release-GHRepository.Helpers -Exactly -Times 1 -ParameterFilter {
            $args -contains 'POST' -and
            $args -contains 'ref=refs/tags/v1' -and
            $args -contains "sha=$commitSha"
        }
    }

    It 'updates only the matching tag at the release commit' {
        Mock gh -ModuleName Release-GHRepository.Helpers {
            $global:LASTEXITCODE = 0
            '[{"ref":"refs/tags/v1"},{"ref":"refs/tags/v10"}]'
        }

        Set-ReleaseTag -Repository $repository -Name 'v1' -CommitSha $commitSha -Confirm:$false

        Should -Invoke gh -ModuleName Release-GHRepository.Helpers -Exactly -Times 1 -ParameterFilter {
            $args -contains 'PATCH' -and
            $args -contains "repos/$repository/git/refs/tags/v1" -and
            $args -contains "sha=$commitSha"
        }
        Should -Invoke gh -ModuleName Release-GHRepository.Helpers -Exactly -Times 0 -ParameterFilter {
            $args -contains 'POST'
        }
    }

    It 'does not write a tag when its lookup fails' {
        Mock gh -ModuleName Release-GHRepository.Helpers {
            $global:LASTEXITCODE = 1
        }

        { Set-ReleaseTag -Repository $repository -Name 'v1' -CommitSha $commitSha -Confirm:$false } |
            Should -Throw -ExpectedMessage '*list*'

        Should -Invoke gh -ModuleName Release-GHRepository.Helpers -Exactly -Times 0 -ParameterFilter {
            $args -contains 'POST' -or $args -contains 'PATCH'
        }
    }
}
