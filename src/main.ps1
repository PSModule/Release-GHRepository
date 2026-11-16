[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidLongLines', '', Justification = 'Long ternary operators are used for readability.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Parameter is used in dynamic parameter validation.'
)]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'Release-GHRepository.Helpers.psm1') -Force

LogGroup 'Loading libraries' {
    $dependencies = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'Release-GHRepository.Dependencies.psd1')
    $dependencyDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "Release-GHRepository-$([guid]::NewGuid())"
    $null = New-Item -Path $dependencyDirectory -ItemType Directory
    foreach ($dependency in $dependencies.Modules) {
        $name = $dependency.Name
        $version = $dependency.Version
        Write-Output "Downloading locked module: [$name $version]"
        $packagePath = Join-Path $dependencyDirectory "$name.$version.nupkg"
        $downloadParameters = @{
            Uri               = "https://www.powershellgallery.com/api/v2/package/$name/$version"
            OutFile           = $packagePath
            MaximumRetryCount = 4
            RetryIntervalSec  = 10
            ErrorAction       = 'Stop'
        }
        Invoke-WebRequest @downloadParameters
        $importParameters = @{
            Path            = $packagePath
            DestinationPath = Join-Path $dependencyDirectory "$name.$version"
            Name            = $name
            RequiredVersion = $version
            SHA256          = $dependency.SHA256
        }
        $null = Import-VerifiedReleaseModule @importParameters -Confirm:$false
    }
}

LogGroup 'Set configuration' {
    if (-not (Test-Path -Path $env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile -PathType Leaf)) {
        Write-Output "Configuration file not found at [$env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile]"
    } else {
        Write-Output "Reading from configuration file [$env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile]"
        $configuration = ConvertFrom-Yaml -Yaml (Get-Content $env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile -Raw)
    }

    $autoCleanup = ![string]::IsNullOrEmpty($configuration.AutoCleanup) ? $configuration.AutoCleanup -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_AutoCleanup -eq 'true'
    $autoPatching = ![string]::IsNullOrEmpty($configuration.AutoPatching) ? $configuration.AutoPatching -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_AutoPatching -eq 'true'
    $createMajorTag = ![string]::IsNullOrEmpty($configuration.CreateMajorTag) ? $configuration.CreateMajorTag -EQ 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_CreateMajorTag -EQ 'true'
    $createMinorTag = ![string]::IsNullOrEmpty($configuration.CreateMinorTag) ? $configuration.CreateMinorTag -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_CreateMinorTag -eq 'true'
    $datePrereleaseFormat = ![string]::IsNullOrEmpty($configuration.DatePrereleaseFormat) ? $configuration.DatePrereleaseFormat : $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat
    $incrementalPrerelease = ![string]::IsNullOrEmpty($configuration.IncrementalPrerelease) ? $configuration.IncrementalPrerelease -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_IncrementalPrerelease -eq 'true'
    $usePRBodyAsReleaseNotes = ![string]::IsNullOrEmpty($configuration.UsePRBodyAsReleaseNotes) ? $configuration.UsePRBodyAsReleaseNotes -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_UsePRBodyAsReleaseNotes -eq 'true'
    $usePRTitleAsReleaseName = ![string]::IsNullOrEmpty($configuration.UsePRTitleAsReleaseName) ? $configuration.UsePRTitleAsReleaseName -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_UsePRTitleAsReleaseName -eq 'true'
    $usePRTitleAsNotesHeading = ![string]::IsNullOrEmpty($configuration.UsePRTitleAsNotesHeading) ? $configuration.UsePRTitleAsNotesHeading -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_UsePRTitleAsNotesHeading -eq 'true'
    $versionPrefix = ![string]::IsNullOrEmpty($configuration.VersionPrefix) ? $configuration.VersionPrefix : $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix
    $previewParameters = @{
        EventName  = $env:GITHUB_EVENT_NAME
        Requested  = $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf -eq 'true'
        Configured = $configuration.WhatIf -eq 'true'
    }
    $whatIf = Test-ReleasePreview @previewParameters

    $ignoreLabels = (![string]::IsNullOrEmpty($configuration.IgnoreLabels) ? $configuration.IgnoreLabels : $env:PSMODULE_AUTO_RELEASE_INPUT_IgnoreLabels) -split ',' | ForEach-Object { $_.Trim() }
    $majorLabels = (![string]::IsNullOrEmpty($configuration.MajorLabels) ? $configuration.MajorLabels : $env:PSMODULE_AUTO_RELEASE_INPUT_MajorLabels) -split ',' | ForEach-Object { $_.Trim() }
    $minorLabels = (![string]::IsNullOrEmpty($configuration.MinorLabels) ? $configuration.MinorLabels : $env:PSMODULE_AUTO_RELEASE_INPUT_MinorLabels) -split ',' | ForEach-Object { $_.Trim() }
    $patchLabels = (![string]::IsNullOrEmpty($configuration.PatchLabels) ? $configuration.PatchLabels : $env:PSMODULE_AUTO_RELEASE_INPUT_PatchLabels) -split ',' | ForEach-Object { $_.Trim() }

    Write-Output '-------------------------------------------------'
    Write-Output "Auto cleanup enabled:           [$autoCleanup]"
    Write-Output "Auto patching enabled:          [$autoPatching]"
    Write-Output "Create major tag enabled:       [$createMajorTag]"
    Write-Output "Create minor tag enabled:       [$createMinorTag]"
    Write-Output "Date-based prerelease format:   [$datePrereleaseFormat]"
    Write-Output "Incremental prerelease enabled: [$incrementalPrerelease]"
    Write-Output "Use PR body as release notes:   [$usePRBodyAsReleaseNotes]"
    Write-Output "Use PR title as release name:   [$usePRTitleAsReleaseName]"
    Write-Output "Use PR title as notes heading:  [$usePRTitleAsNotesHeading]"
    Write-Output "Version prefix:                 [$versionPrefix]"
    Write-Output "What if mode:                   [$whatIf]"
    Write-Output ''
    Write-Output "Ignore labels:                  [$($ignoreLabels -join ', ')]"
    Write-Output "Major labels:                   [$($majorLabels -join ', ')]"
    Write-Output "Minor labels:                   [$($minorLabels -join ', ')]"
    Write-Output "Patch labels:                   [$($patchLabels -join ', ')]"
    Write-Output '-------------------------------------------------'
}

LogGroup 'Event information - JSON' {
    $githubEventJson = Get-Content $env:GITHUB_EVENT_PATH
    $githubEventJson | Format-List | Out-String
}

LogGroup 'Event information - Object' {
    $githubEvent = $githubEventJson | ConvertFrom-Json
    $workflowRun = $githubEvent.workflow_run
    $commitPullRequests = @()
    if ($workflowRun) {
        if ($env:GITHUB_EVENT_NAME -ne 'workflow_run' -or
            $workflowRun.event -ne 'pull_request' -or $workflowRun.conclusion -ne 'success' -or
            $workflowRun.head_sha -cnotmatch '^[a-f0-9]{40}$') {
            throw 'Publication requires a successful pull_request workflow_run with a valid commit SHA.'
        }
        $associatedPullRequests = @($workflowRun.pull_requests)
        if ($associatedPullRequests.Count -eq 0) {
            Write-Output 'Resolving the checked commit through the pull request association API.'
            $associationJson = gh api "repos/$env:GITHUB_REPOSITORY/commits/$($workflowRun.head_sha)/pulls"
            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to find pull requests associated with the checked commit.'
            }
            $commitPullRequests = @($associationJson | ConvertFrom-Json)
            $associatedPullRequests = $commitPullRequests
        }
        if ($associatedPullRequests.Count -ne 1 -or $associatedPullRequests[0].number -lt 1) {
            throw 'Publication requires exactly one associated pull request.'
        }
        $pullRequestNumber = $associatedPullRequests[0].number
        $pullRequestJson = gh api "repos/$env:GITHUB_REPOSITORY/pulls/$pullRequestNumber"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to read pull request [$pullRequestNumber]."
        }
        $pull_request = $pullRequestJson | ConvertFrom-Json
        if (-not $pull_request.merged -and $pull_request.head.repo.full_name -ne $env:GITHUB_REPOSITORY) {
            Write-GitHubWarning 'Fork PR prereleases are not published. Publication runs after the PR is merged.'
            exit
        }
    } elseif ($githubEvent.pull_request) {
        $pull_request = $githubEvent.pull_request
    } else {
        Write-GitHubWarning 'This is not run for a pull request. Exiting.'
        exit
    }
    $githubEvent | Format-List | Out-String
}

$repositoryJson = gh repo view --repo $env:GITHUB_REPOSITORY --json defaultBranchRef
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to read the repository default branch.'
}
$defaultBranchName = ($repositoryJson | ConvertFrom-Json).defaultBranchRef.name
if ($workflowRun) {
    $validationParameters = @{
        PullRequest        = $pull_request
        WorkflowRun        = $workflowRun
        Repository         = $env:GITHUB_REPOSITORY
        DefaultBranch      = $defaultBranchName
        CommitPullRequests = $commitPullRequests
    }
    Assert-ReleasePullRequest @validationParameters
}
$isPullRequest = $null -ne $pull_request
if (-not ($isPullRequest -or $whatIf)) {
    Write-Warning '⚠️ A release should not be created in this context. Exiting.'
    exit
}
$actionType = $githubEvent.action
$isMerged = ($pull_request.merged).ToString() -eq 'True'
$prIsClosed = $pull_request.state -eq 'closed'
$prBaseRef = $pull_request.base.ref
$prHeadRef = $pull_request.head.ref
$targetIsDefaultBranch = $pull_request.base.ref -eq $defaultBranchName
$releaseCommit = $pull_request.head.sha
if ($isMerged) {
    $releaseCommit = $pull_request.merge_commit_sha
}

Write-Output '-------------------------------------------------'
Write-Output "Default branch:                 [$defaultBranchName]"
Write-Output "Is a pull request event:        [$isPullRequest]"
Write-Output "Action type:                    [$actionType]"
Write-Output "PR Merged:                      [$isMerged]"
Write-Output "PR Closed:                      [$prIsClosed]"
Write-Output "PR Base Ref:                    [$prBaseRef]"
Write-Output "PR Head Ref:                    [$prHeadRef]"
Write-Output "Target is default branch:       [$targetIsDefaultBranch]"
Write-Output '-------------------------------------------------'

LogGroup 'Pull request - details' {
    $pull_request | Format-List | Out-String
}

LogGroup 'Pull request - Labels' {
    $labels = @()
    $labels += $pull_request.labels.name
    $labels | Format-List | Out-String
}

$createRelease = $isMerged -and $targetIsDefaultBranch
$closedPullRequest = $prIsClosed -and -not $isMerged
$createPrerelease = $labels -Contains 'prerelease' -and -not $createRelease -and -not $closedPullRequest
$prereleaseName = "pr$($pull_request.number)"

$ignoreRelease = ($labels | Where-Object { $ignoreLabels -contains $_ }).Count -gt 0
if ($ignoreRelease) {
    Write-Output 'Ignoring release creation.'
    return
}

$majorRelease = ($labels | Where-Object { $majorLabels -contains $_ }).Count -gt 0
$minorRelease = ($labels | Where-Object { $minorLabels -contains $_ }).Count -gt 0 -and -not $majorRelease
$patchRelease = (($labels | Where-Object { $patchLabels -contains $_ }).Count -gt 0 -or $autoPatching) -and -not $majorRelease -and -not $minorRelease

Write-Output '-------------------------------------------------'
Write-Output "Create a release:               [$createRelease]"
Write-Output "Create a prerelease:            [$createPrerelease]"
Write-Output "Create a major release:         [$majorRelease]"
Write-Output "Create a minor release:         [$minorRelease]"
Write-Output "Create a patch release:         [$patchRelease]"
Write-Output "Closed pull request:            [$closedPullRequest]"
Write-Output '-------------------------------------------------'

LogGroup 'Get releases' {
    $releases = gh release list --json 'createdAt,isDraft,isLatest,isPrerelease,name,publishedAt,tagName' | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        Write-Error 'Failed to list all releases for the repo.'
        exit $LASTEXITCODE
    }
    $releases | Select-Object -Property name, isPrerelease, isLatest, publishedAt | Format-Table | Out-String
}

LogGroup 'Get latest version' {
    $latestRelease = $releases | Where-Object { $_.isLatest -eq $true }
    $latestRelease | Format-List | Out-String
    $latestVersionString = $latestRelease.tagName
    if (![string]::IsNullOrEmpty($latestVersionString)) {
        $latestVersion = $latestVersionString | ConvertTo-PSSemVer
        Write-Output '-------------------------------------------------'
        Write-Output 'Latest version:'
        $latestVersion | Format-Table
        $latestVersion = $latestVersion.ToString()
    }
}

Write-Output '-------------------------------------------------'
Write-Output "Latest version:                 [$latestVersion]"
Write-Output '-------------------------------------------------'

if ($createPrerelease -or $createRelease -or $whatIf) {
    LogGroup 'Calculate new version' {
        $latestVersion = New-PSSemVer -Version $latestVersion
        $newVersion = New-PSSemVer -Version $latestVersion
        $newVersion.Prefix = $versionPrefix
        if ($majorRelease) {
            Write-Output 'Incrementing major version.'
            $newVersion.BumpMajor()
        } elseif ($minorRelease) {
            Write-Output 'Incrementing minor version.'
            $newVersion.BumpMinor()
        } elseif ($patchRelease) {
            Write-Output 'Incrementing patch version.'
            $newVersion.BumpPatch()
        } else {
            Write-Output 'Skipping release creation, exiting.'
            return
        }

        Write-Output "Partial new version: [$newVersion]"

        if ($createPrerelease) {
            Write-Output "Adding a prerelease tag to the version using the branch name [$prereleaseName]."
            $newVersion.Prerelease = $prereleaseName
            Write-Output "Partial new version: [$newVersion]"

            if (![string]::IsNullOrEmpty($datePrereleaseFormat)) {
                Write-Output "Using date-based prerelease: [$datePrereleaseFormat]."
                $newVersion.Prerelease += ".$(Get-Date -Format $datePrereleaseFormat)"
                Write-Output "Partial new version: [$newVersion]"
            }

            if ($incrementalPrerelease) {
                $newVersion.BumpPrereleaseNumber()
                while ($releases.tagName -contains $newVersion.ToString()) {
                    $newVersion.BumpPrereleaseNumber()
                }
            }
        }
    }
    Write-Output '-------------------------------------------------'
    Write-Output "New version:                    [$newVersion]"
    Write-Output '-------------------------------------------------'

    LogGroup "Create new release [$newVersion]" {
        if ($createPrerelease) {
            $releaseExists = $releases.tagName -Contains $newVersion
            if ($releaseExists -and -not $incrementalPrerelease) {
                $existingRelease = $releases | Where-Object { $_.tagName -ceq $newVersion.ToString() }
                if ($existingRelease.isPrerelease -ne $true) {
                    throw "Refusing to replace non-prerelease [$newVersion]."
                }
                Write-Output 'Release already exists, recreating.'
                if ($whatIf) {
                    Write-Output "WhatIf: gh release delete $newVersion --cleanup-tag --yes"
                } else {
                    gh release delete $newVersion --cleanup-tag --yes
                    if ($LASTEXITCODE -ne 0) {
                        Write-Error "Failed to delete the release [$newVersion]."
                        exit $LASTEXITCODE
                    }
                }
            }

            # Build release creation command with options
            $releaseCreateCommand = @('release', 'create', "$newVersion")

            # Add title parameter
            if ($usePRTitleAsReleaseName) {
                $prTitle = $pull_request.title
                $releaseCreateCommand += @('--title', "$prTitle")
                Write-Output "Using PR title as release name: [$prTitle]"
            } else {
                $releaseCreateCommand += @('--title', "$newVersion")
            }

            # Add notes parameter
            $notes = ''
            if ($usePRTitleAsNotesHeading) {
                $prTitle = $pull_request.title
                $prNumber = $pull_request.number
                $notes += "# $prTitle (#$prNumber)`n`n"
            }
            if ($usePRBodyAsReleaseNotes) {
                $prBody = $pull_request.body
                $notes += $prBody
            }
            if (-not [string]::IsNullOrWhiteSpace($notes)) {
                $releaseCreateCommand += @('--notes', $notes)
            } else {
                $releaseCreateCommand += '--generate-notes'
            }

            # Add remaining parameters
            $releaseCreateCommand += @('--target', $releaseCommit, '--prerelease')

            Write-Output "gh $($releaseCreateCommand -join ' ')"
            if (-not $whatIf) {
                # Execute the command and capture the output
                $releaseURL = gh @releaseCreateCommand
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Failed to create the release [$newVersion]."
                    exit $LASTEXITCODE
                }
            }

            if ($whatIf) {
                Write-Output 'WhatIf: gh pr comment $pull_request.number -b "The release [$newVersion] has been created."'
            } else {
                gh pr comment $pull_request.number -b "The release [$newVersion]($releaseURL) has been created."
                if ($LASTEXITCODE -ne 0) {
                    Write-Error 'Failed to comment on the pull request.'
                    exit $LASTEXITCODE
                }
            }
        } else {
            # Build release creation command with options
            $releaseCreateCommand = @('release', 'create', "$newVersion", '--target', $releaseCommit)

            # Add title parameter
            if ($usePRTitleAsReleaseName) {
                $prTitle = $pull_request.title
                $releaseCreateCommand += @('--title', "$prTitle")
                Write-Output "Using PR title as release name: [$prTitle]"
            } else {
                $releaseCreateCommand += @('--title', "$newVersion")
            }

            # Add notes parameter
            $notes = ''
            if ($usePRTitleAsNotesHeading) {
                $prTitle = $pull_request.title
                $prNumber = $pull_request.number
                $notes += "# $prTitle (#$prNumber)`n`n"
            }
            if ($usePRBodyAsReleaseNotes) {
                $prBody = $pull_request.body
                $notes += $prBody
            }
            if (-not [string]::IsNullOrWhiteSpace($notes)) {
                $releaseCreateCommand += @('--notes', $notes)
            } else {
                $releaseCreateCommand += '--generate-notes'
            }

            Write-Output "gh $($releaseCreateCommand -join ' ')"
            if (-not $whatIf) {
                gh @releaseCreateCommand
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Failed to create the release [$newVersion]."
                    exit $LASTEXITCODE
                }
            }

            if ($createMajorTag) {
                $majorTag = ('{0}{1}' -f $newVersion.Prefix, $newVersion.Major)
                if ($whatIf) {
                    Write-Output "WhatIf: point tag [$majorTag] at [$releaseCommit]"
                } else {
                    Set-ReleaseTag -Repository $env:GITHUB_REPOSITORY -Name $majorTag -CommitSha $releaseCommit -Confirm:$false
                }
            }

            if ($createMinorTag) {
                $minorTag = ('{0}{1}.{2}' -f $newVersion.Prefix, $newVersion.Major, $newVersion.Minor)
                if ($whatIf) {
                    Write-Output "WhatIf: point tag [$minorTag] at [$releaseCommit]"
                } else {
                    Set-ReleaseTag -Repository $env:GITHUB_REPOSITORY -Name $minorTag -CommitSha $releaseCommit -Confirm:$false
                }
            }
        }
    }
    Write-GitHubNotice -Title 'Release created' -Message $newVersion
} else {
    Write-Output 'Skipping release creation.'
}

LogGroup 'List prereleases using the same name' {
    $selectionParameters = @{
        Release           = @($releases)
        PullRequestNumber = $pull_request.number
        VersionPrefix     = $versionPrefix
    }
    $prereleasesToCleanup = Get-ReleasePrerelease @selectionParameters
    $prereleasesToCleanup | Select-Object -Property name, publishedAt, isPrerelease, isLatest | Format-Table | Out-String
}

if ((($closedPullRequest -or $createRelease) -and $autoCleanup) -or $whatIf) {
    LogGroup "Cleanup prereleases for [$prereleaseName]" {
        foreach ($rel in $prereleasesToCleanup) {
            $relTagName = $rel.tagName
            Write-Output "Deleting prerelease:            [$relTagName]."
            if ($whatIf) {
                Write-Output "WhatIf: gh release delete $($rel.tagName) --cleanup-tag --yes"
            } else {
                gh release delete $rel.tagName --cleanup-tag --yes
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "Failed to delete release [$relTagName]."
                    exit $LASTEXITCODE
                }
            }
        }
    }
}
