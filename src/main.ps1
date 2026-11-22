[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidLongLines', '', Justification = 'Long ternary operators are used for readability.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Parameter is used in dynamic parameter validation.'
)]
[CmdletBinding()]
param(
    # The release policy resolved by the bootstrap before GitHub-Script starts.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [PSCustomObject] $Settings
)

$ErrorActionPreference = 'Stop'
$releaseSettings = $Settings

$helperModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Release-GHRepository.Helpers.psm1'
Import-Module -Name $helperModulePath -Force

LogGroup 'Loading libraries' {
    'PSSemVer' | ForEach-Object {
        $name = $_
        Write-Output "Installing module: $name"
        $count = 5
        $delay = 10
        for ($i = 1; $i -le $count; $i++) {
            try {
                Install-PSResource -Name $name -WarningAction SilentlyContinue -TrustRepository -Repository PSGallery
                break
            } catch {
                Write-Warning "Installation of $name failed with error: $_"
                if ($i -eq $count) {
                    throw $_
                }
                Write-Warning "Retrying in $delay seconds..."
                Start-Sleep -Seconds $delay
            }
        }
        Import-Module -Name $name
    }
}

LogGroup 'Set configuration' {
    $autoCleanup = $releaseSettings.AutoCleanup
    $defaultBump = $releaseSettings.DefaultBump
    $defaultBumpSource = $releaseSettings.DefaultBumpSource
    $createMajorTag = $releaseSettings.CreateMajorTag
    $createMinorTag = $releaseSettings.CreateMinorTag
    $datePrereleaseFormat = $releaseSettings.DatePrereleaseFormat
    $incrementalPrerelease = $releaseSettings.IncrementalPrerelease
    $usePRBodyAsReleaseNotes = $releaseSettings.UsePRBodyAsReleaseNotes
    $usePRTitleAsReleaseName = $releaseSettings.UsePRTitleAsReleaseName
    $usePRTitleAsNotesHeading = $releaseSettings.UsePRTitleAsNotesHeading
    $versionPrefix = $releaseSettings.VersionPrefix
    $whatIf = $releaseSettings.WhatIf

    Write-Output '-------------------------------------------------'
    Write-Output "Auto cleanup enabled:           [$autoCleanup]"
    Write-Output "Default bump:                   [$defaultBump]"
    Write-Output "Default bump source:            [$defaultBumpSource]"
    Write-Output "Create major tag enabled:       [$createMajorTag]"
    Write-Output "Create minor tag enabled:       [$createMinorTag]"
    Write-Output "Date-based prerelease format:   [$datePrereleaseFormat]"
    Write-Output "Incremental prerelease enabled: [$incrementalPrerelease]"
    Write-Output "Use PR body as release notes:   [$usePRBodyAsReleaseNotes]"
    Write-Output "Use PR title as release name:   [$usePRTitleAsReleaseName]"
    Write-Output "Use PR title as notes heading:  [$usePRTitleAsNotesHeading]"
    Write-Output "Version prefix:                 [$versionPrefix]"
    Write-Output "What if mode:                   [$whatIf]"
    Write-Output '-------------------------------------------------'
}

LogGroup 'Event information - JSON' {
    $githubEventJson = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw
    $githubEventJson | Format-List | Out-String
}

LogGroup 'Event information - Object' {
    $githubEvent = ConvertFrom-Json -InputObject $githubEventJson
    $githubEvent | Format-List | Out-String
}

$pull_request = $githubEvent.pull_request
if (-not $pull_request) {
    Write-GitHubWarning 'This is not run for a pull request. Exiting.'
    return
}
$defaultBranchName = (gh repo view --json defaultBranchRef | ConvertFrom-Json | Select-Object -ExpandProperty defaultBranchRef).name
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($defaultBranchName)) {
    throw 'Could not determine the repository default branch.'
}
$actionType = $githubEvent.action
$isMerged = $pull_request.merged -is [bool] -and $pull_request.merged
$prIsClosed = $pull_request.state -eq 'closed'
$prBaseRef = $pull_request.base.ref
$labels = @($pull_request.labels.name | Where-Object { $null -ne $_ })
$decisionParameters = @{
    Labels            = $labels
    DefaultBump       = $defaultBump
    DefaultBumpSource = $defaultBumpSource
}
$releaseDecision = Resolve-ReleaseDecision @decisionParameters
$contextParameters = @{
    PullRequest              = $pull_request
    AllowEmptyPrereleaseName = (-not $releaseDecision.Prerelease)
}
$pullRequestReleaseContext = Resolve-PullRequestReleaseContext @contextParameters
$prHeadRef = $pullRequestReleaseContext.HeadRef
$prereleaseTarget = $pullRequestReleaseContext.PrereleaseTarget
$targetIsDefaultBranch = $prBaseRef -ceq $defaultBranchName

Write-Output '-------------------------------------------------'
Write-Output "Default branch:                 [$defaultBranchName]"
Write-Output "Action type:                    [$actionType]"
Write-Output "PR Merged:                      [$isMerged]"
Write-Output "PR Closed:                      [$prIsClosed]"
Write-Output "PR Base Ref:                    [$prBaseRef]"
Write-Output "PR Head Ref:                    [$prHeadRef]"
Write-Output "PR Head SHA:                    [$prereleaseTarget]"
Write-Output "Target is default branch:       [$targetIsDefaultBranch]"
Write-Output '-------------------------------------------------'

LogGroup 'Pull request - details' {
    $pull_request | Format-List | Out-String
}

LogGroup 'Pull request - Labels' {
    $labels | Format-List | Out-String
}

$createRelease = $actionType -eq 'closed' -and $isMerged -and $prIsClosed -and $targetIsDefaultBranch -and -not $releaseDecision.Skip
$stableTarget = $null
if ($createRelease) {
    $stableTarget = [string] $pull_request.merge_commit_sha
    if ($stableTarget -notmatch '\A[0-9a-fA-F]{40}\z') {
        throw 'A merged pull request must supply a full merge commit SHA before a stable release can publish.'
    }
    Write-Output "Stable target SHA:              [$stableTarget]"

    if ($whatIf) {
        Write-Output "WhatIf: git fetch --no-tags origin $stableTarget"
    } else {
        git fetch --no-tags origin $stableTarget
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to fetch the merge commit [$stableTarget]. git exited with code [$LASTEXITCODE]."
        }
    }
}

LogGroup 'Provision release labels' {
    if ([string]::IsNullOrWhiteSpace($env:GITHUB_REPOSITORY)) {
        throw 'GITHUB_REPOSITORY is required to provision release labels.'
    }

    foreach ($definition in Get-ReleaseLabelDefinition) {
        $arguments = @(
            'label'
            'create'
            $definition.Name
            '--repo'
            $env:GITHUB_REPOSITORY
            '--color'
            $definition.Color
            '--description'
            $definition.Description
            '--force'
        )
        if ($whatIf) {
            Write-Output "WhatIf: gh $($arguments -join ' ')"
        } else {
            gh @arguments
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to provision the canonical label [$($definition.Name)]. gh exited with code [$LASTEXITCODE]."
            }
        }
    }
}

$closedPullRequest = $prIsClosed -and -not $isMerged
$createPrerelease = Test-PrereleaseCreation -ReleaseDecision $releaseDecision -PullRequestClosed:$prIsClosed
$prereleaseName = $pullRequestReleaseContext.PrereleaseName

$majorRelease = $releaseDecision.Bump -eq 'Major'
$minorRelease = $releaseDecision.Bump -eq 'Minor'
$patchRelease = $releaseDecision.Bump -eq 'Patch'

Write-Output '-------------------------------------------------'
Write-Output "Default bump applied:           [$($releaseDecision.DefaultBumpApplied)]"
Write-Output "Bump source:                    [$($releaseDecision.BumpSource)]"
Write-Output "Skip release:                   [$($releaseDecision.Skip)]"
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
        throw "Failed to list all releases for the repo. gh exited with code [$LASTEXITCODE]."
    }
    $releases | Select-Object -Property name, isPrerelease, isLatest, publishedAt | Format-Table | Out-String
}

$latestVersion = $null
if (-not $releaseDecision.Skip) {
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
} else {
    Write-Output 'Skip selected; no release version is resolved.'
}

Write-Output '-------------------------------------------------'
Write-Output "Latest version:                 [$latestVersion]"
Write-Output '-------------------------------------------------'

if (-not $releaseDecision.Skip -and ($createPrerelease -or $createRelease -or $whatIf)) {
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
                Write-Output 'Release already exists, recreating.'
                if ($whatIf) {
                    Write-Output "WhatIf: gh release delete $newVersion --cleanup-tag --yes"
                } else {
                    gh release delete $newVersion --cleanup-tag --yes
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to delete the release [$newVersion]. gh exited with code [$LASTEXITCODE]."
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
            $releaseCreateCommand += @('--target', $prereleaseTarget, '--prerelease')

            Write-Output "gh $($releaseCreateCommand -join ' ')"
            if (-not $whatIf) {
                # Execute the command and capture the output
                $releaseURL = gh @releaseCreateCommand
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create the release [$newVersion]. gh exited with code [$LASTEXITCODE]."
                }
            }

            if ($whatIf) {
                $commentPreview = 'WhatIf: gh pr comment {0} -b "The release [{1}] has been created."' -f $pull_request.number, $newVersion
                Write-Output $commentPreview
            } else {
                gh pr comment $pull_request.number -b "The release [$newVersion]($releaseURL) has been created."
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to comment on the pull request. gh exited with code [$LASTEXITCODE]."
                }
            }
        } else {
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

            if ($createRelease) {
                $versionTagPush = @('push', '--no-follow-tags', 'origin', "${stableTarget}:refs/tags/$newVersion")
                if ($whatIf) {
                    Write-Output "WhatIf: git $($versionTagPush -join ' ')"
                } else {
                    # Do not force the version tag. A conflicting tag must stop publication.
                    git @versionTagPush
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to set version tag [$newVersion] to [$stableTarget]. git exited with code [$LASTEXITCODE]."
                    }
                }
                $releaseCreateCommand += @('--verify-tag', '--target', $stableTarget)
            }

            Write-Output "gh $($releaseCreateCommand -join ' ')"
            if (-not $whatIf) {
                gh @releaseCreateCommand
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to create the release [$newVersion]. gh exited with code [$LASTEXITCODE]."
                }
            }

            if ($createRelease -and ($createMajorTag -or $createMinorTag)) {
                $aliasPush = @('push', '--no-follow-tags', 'origin')
                if ($createMajorTag) {
                    $majorTag = ('{0}{1}' -f $newVersion.Prefix, $newVersion.Major)
                    $aliasPush += "+${stableTarget}:refs/tags/$majorTag"
                }
                if ($createMinorTag) {
                    $minorTag = ('{0}{1}.{2}' -f $newVersion.Prefix, $newVersion.Major, $newVersion.Minor)
                    $aliasPush += "+${stableTarget}:refs/tags/$minorTag"
                }

                if ($whatIf) {
                    Write-Output "WhatIf: git $($aliasPush -join ' ')"
                } else {
                    git @aliasPush
                    if ($LASTEXITCODE -ne 0) {
                        throw "Failed to update the enabled aliases for [$newVersion]. git exited with code [$LASTEXITCODE]."
                    }
                }
            }
        }
    }
    Write-GitHubNotice -Title 'Release created' -Message $newVersion
} else {
    Write-Output 'Skipping release creation.'
}

LogGroup 'List prereleases using the same name' {
    $prereleasesToCleanup = @()
    if ([string]::IsNullOrEmpty($prereleaseName)) {
        Write-Output 'This branch has no prerelease identifier; cleanup has no candidates.'
    } else {
        $prereleasesToCleanup = @(
            Get-PrereleaseCleanupCandidate -Releases $releases -PrereleaseName $prereleaseName -VersionPrefix $versionPrefix
        )
    }
    $prereleasesToCleanup | Select-Object -Property name, publishedAt, isPrerelease, isLatest | Format-Table | Out-String
}

if (($prIsClosed -and $autoCleanup) -or $whatIf) {
    LogGroup "Cleanup prereleases for [$prereleaseName]" {
        foreach ($rel in $prereleasesToCleanup) {
            $relTagName = $rel.tagName
            Write-Output "Deleting prerelease:            [$relTagName]."
            if ($whatIf) {
                Write-Output "WhatIf: gh release delete $($rel.tagName) --cleanup-tag --yes"
            } else {
                gh release delete $rel.tagName --cleanup-tag --yes
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to delete release [$relTagName]. gh exited with code [$LASTEXITCODE]."
                }
            }
        }
    }
}
