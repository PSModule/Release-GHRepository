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

$helperModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Release-GHRepository.Helpers.psm1'
Import-Module -Name $helperModulePath -Force

LogGroup 'Loading libraries' {
    'powershell-yaml', 'PSSemVer' | ForEach-Object {
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
    if (-not (Test-Path -Path $env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile -PathType Leaf)) {
        Write-Output "Configuration file not found at [$env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile]"
    } else {
        Write-Output "Reading from configuration file [$env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile]"
        $configuration = ConvertFrom-Yaml -Yaml (Get-Content $env:PSMODULE_AUTO_RELEASE_INPUT_ConfigurationFile -Raw)
    }

    $autoCleanup = ![string]::IsNullOrEmpty($configuration.AutoCleanup) ? $configuration.AutoCleanup -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_AutoCleanup -eq 'true'
    $defaultBump = $null -ne $configuration.DefaultBump ? [string] $configuration.DefaultBump : $env:PSMODULE_AUTO_RELEASE_INPUT_DefaultBump
    $createMajorTag = ![string]::IsNullOrEmpty($configuration.CreateMajorTag) ? $configuration.CreateMajorTag -EQ 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_CreateMajorTag -EQ 'true'
    $createMinorTag = ![string]::IsNullOrEmpty($configuration.CreateMinorTag) ? $configuration.CreateMinorTag -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_CreateMinorTag -eq 'true'
    $datePrereleaseFormat = ![string]::IsNullOrEmpty($configuration.DatePrereleaseFormat) ? $configuration.DatePrereleaseFormat : $env:PSMODULE_AUTO_RELEASE_INPUT_DatePrereleaseFormat
    $incrementalPrerelease = ![string]::IsNullOrEmpty($configuration.IncrementalPrerelease) ? $configuration.IncrementalPrerelease -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_IncrementalPrerelease -eq 'true'
    $usePRBodyAsReleaseNotes = ![string]::IsNullOrEmpty($configuration.UsePRBodyAsReleaseNotes) ? $configuration.UsePRBodyAsReleaseNotes -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_UsePRBodyAsReleaseNotes -eq 'true'
    $usePRTitleAsReleaseName = ![string]::IsNullOrEmpty($configuration.UsePRTitleAsReleaseName) ? $configuration.UsePRTitleAsReleaseName -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_UsePRTitleAsReleaseName -eq 'true'
    $usePRTitleAsNotesHeading = ![string]::IsNullOrEmpty($configuration.UsePRTitleAsNotesHeading) ? $configuration.UsePRTitleAsNotesHeading -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_UsePRTitleAsNotesHeading -eq 'true'
    $versionPrefix = ![string]::IsNullOrEmpty($configuration.VersionPrefix) ? $configuration.VersionPrefix : $env:PSMODULE_AUTO_RELEASE_INPUT_VersionPrefix
    $whatIf = ![string]::IsNullOrEmpty($configuration.WhatIf) ? $configuration.WhatIf -eq 'true' : $env:PSMODULE_AUTO_RELEASE_INPUT_WhatIf -eq 'true'

    $null = ConvertTo-ReleaseBump -DefaultBump $defaultBump

    Write-Output '-------------------------------------------------'
    Write-Output "Auto cleanup enabled:           [$autoCleanup]"
    Write-Output "Default bump:                   [$defaultBump]"
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
                throw "Failed to provision the canonical label [$($definition.Name)]."
            }
        }
    }
}

LogGroup 'Event information - JSON' {
    $githubEventJson = Get-Content $env:GITHUB_EVENT_PATH
    $githubEventJson | Format-List | Out-String
}

LogGroup 'Event information - Object' {
    $githubEvent = $githubEventJson | ConvertFrom-Json
    if (-not $githubEvent.pull_request) {
        Write-GitHubWarning 'This is not run for a pull request. Exiting.'
        exit
    }
    $pull_request = $githubEvent.pull_request
    $githubEvent | Format-List | Out-String
}

$defaultBranchName = (gh repo view --json defaultBranchRef | ConvertFrom-Json | Select-Object -ExpandProperty defaultBranchRef).name
$isPullRequest = $githubEvent.PSObject.Properties.Name -Contains 'pull_request'
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

$releaseDecision = Resolve-ReleaseDecision -Labels $labels -DefaultBump $defaultBump

$createRelease = $isMerged -and $targetIsDefaultBranch -and -not $releaseDecision.Skip
$closedPullRequest = $prIsClosed -and -not $isMerged
$createPrerelease = Test-PrereleaseCreation -ReleaseDecision $releaseDecision -PullRequestClosed:$prIsClosed
$prereleaseName = $prHeadRef -replace '[^a-zA-Z0-9]'

$majorRelease = $releaseDecision.Bump -eq 'Major'
$minorRelease = $releaseDecision.Bump -eq 'Minor'
$patchRelease = $releaseDecision.Bump -eq 'Patch'

Write-Output '-------------------------------------------------'
Write-Output "Default bump applied:           [$($releaseDecision.DefaultBumpApplied)]"
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
            $releaseCreateCommand += @('--target', $prHeadRef, '--prerelease')

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
                    Write-Output "WhatIf: git tag -f $majorTag 'main'"
                } else {
                    git tag -f $majorTag 'main'
                    if ($LASTEXITCODE -ne 0) {
                        Write-Error "Failed to create major tag [$majorTag]."
                        exit $LASTEXITCODE
                    }
                }
            }

            if ($createMinorTag) {
                $minorTag = ('{0}{1}.{2}' -f $newVersion.Prefix, $newVersion.Major, $newVersion.Minor)
                if ($whatIf) {
                    Write-Output "WhatIf: git tag -f $minorTag 'main'"
                } else {
                    git tag -f $minorTag 'main'
                    if ($LASTEXITCODE -ne 0) {
                        Write-Error "Failed to create minor tag [$minorTag]."
                        exit $LASTEXITCODE
                    }
                }
            }

            if ($whatIf) {
                Write-Output 'WhatIf: git push origin --tags --force'
            } else {
                git push origin --tags --force
                if ($LASTEXITCODE -ne 0) {
                    Write-Error 'Failed to push tags.'
                    exit $LASTEXITCODE
                }
            }
        }
    }
    Write-GitHubNotice -Title 'Release created' -Message $newVersion
} else {
    Write-Output 'Skipping release creation.'
}

LogGroup 'List prereleases using the same name' {
    $prereleasesToCleanup = $releases | Where-Object { $_.tagName -like "*$prereleaseName*" }
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
                    Write-Error "Failed to delete release [$relTagName]."
                    exit $LASTEXITCODE
                }
            }
        }
    }
}
