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
New-Alias -Name releaseFixtureAlias -Value Get-ReleaseSecurityFixtureValue
Export-ModuleMember -Function Get-ReleaseSecurityFixtureValue -Alias releaseFixtureAlias
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

    It 'reloads a verified module even when its exported aliases are already loaded' {
        $null = Import-VerifiedReleaseModule @importParameters
        $importParameters.DestinationPath = Join-Path $fixtureRoot 'verified-again'

        $importResult = @(Import-VerifiedReleaseModule @importParameters 2>&1)

        @($importResult | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
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
        $currentPullRequest = $pullRequest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $validationParameters = @{
            PullRequest        = $pullRequest
            CurrentPullRequest = $currentPullRequest
            Repository         = $repository
            DefaultBranch      = 'main'
        }
    }

    It 'accepts an open same-repository PR at the event commit' {
        { Assert-ReleasePullRequest @validationParameters } | Should -Not -Throw
    }

    It 'accepts a merged same-repository PR at the event merge commit' {
        $pullRequest.state = 'closed'
        $pullRequest.merged = $true
        $pullRequest.merge_commit_sha = $mergeSha
        $currentPullRequest.state = 'closed'
        $currentPullRequest.merged = $true
        $currentPullRequest.merge_commit_sha = $mergeSha

        { Assert-ReleasePullRequest @validationParameters } | Should -Not -Throw
    }

    It 'rejects <Name>' -ForEach @(
        @{
            Name    = 'an event for another repository'
            Change  = { $pullRequest.base.repo.full_name = 'other/repository' }
            Message = '*repository*'
        }
        @{
            Name    = 'live metadata from another repository'
            Change  = { $currentPullRequest.base.repo.full_name = 'other/repository' }
            Message = '*repository*'
        }
        @{
            Name    = 'an open fork PR'
            Change  = { $pullRequest.head.repo.full_name = 'contributor/fork' }
            Message = '*same-repository*'
        }
        @{
            Name    = 'a merged fork PR'
            Change  = {
                $pullRequest.state = 'closed'
                $pullRequest.merged = $true
                $pullRequest.merge_commit_sha = $mergeSha
                $pullRequest.head.repo.full_name = 'contributor/fork'
            }
            Message = '*same-repository*'
        }
        @{
            Name    = 'a different PR number'
            Change  = { $currentPullRequest.number = 8 }
            Message = '*pull request*'
        }
        @{
            Name    = 'a PR changed since the event'
            Change  = { $currentPullRequest.head.sha = '3333333333333333333333333333333333333333' }
            Message = '*changed since*'
        }
        @{
            Name    = 'a different target branch'
            Change  = { $pullRequest.base.ref = 'other-branch' }
            Message = '*default branch*'
        }
        @{
            Name    = 'an invalid publication commit'
            Change  = { $pullRequest.head.sha = '--unexpected-option' }
            Message = '*commit SHA*'
        }
        @{
            Name    = 'an old open-PR event after closure'
            Change  = { $currentPullRequest.state = 'closed' }
            Message = '*changed since*'
        }
        @{
            Name    = 'a different merge commit'
            Change  = {
                $pullRequest.state = 'closed'
                $pullRequest.merged = $true
                $pullRequest.merge_commit_sha = $mergeSha
                $currentPullRequest.state = 'closed'
                $currentPullRequest.merged = $true
                $currentPullRequest.merge_commit_sha = '3333333333333333333333333333333333333333'
            }
            Message = '*changed since*'
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

Describe 'Pull request preview controls' {
    It 'allows regular pull_request publication when no preview is requested' {
        Test-ReleasePreview -EventName 'pull_request' | Should -BeFalse
    }

    It 'does not let configuration disable an explicit preview request' {
        Test-ReleasePreview -EventName 'pull_request' -Requested | Should -BeTrue
    }

    It 'honors a configured preview' {
        Test-ReleasePreview -EventName 'pull_request' -Configured | Should -BeTrue
    }

    It 'allows read-only scheduled checks' {
        Test-ReleasePreview -EventName 'schedule' -Requested | Should -BeTrue
    }

    It 'rejects publication on other events' {
        { Test-ReleasePreview -EventName 'push' } | Should -Throw -ExpectedMessage '*pull_request*'
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
