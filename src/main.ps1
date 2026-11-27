#Requires -Version 7.2

<#
    .SYNOPSIS
    Run Release-GHRepository for the current GitHub Actions event.

    .DESCRIPTION
    Return Calculate outputs or execute the validated Publish plan.

    .EXAMPLE
    .\main.ps1 -Settings $releaseSettings

    Run the action in the mode selected by the resolved settings.

    .INPUTS
    None

    You can't pipe objects to main.ps1.

    .OUTPUTS
    System.String

    Operational logs for the current GitHub Actions run.
#>
[CmdletBinding()]
param(
    # The release policy resolved before GitHub-Script starts.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [PSCustomObject] $Settings,

    # The exact unprefixed semantic version from Calculate, if supplied.
    [Parameter()]
    [string] $ReleaseVersion,

    # The unchanged UTC timestamp from Calculate for a date-dependent prerelease.
    [Parameter()]
    [string] $CalculatedAt
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$planParameters = @{ Settings = $Settings }
if ($ReleaseVersion) {
    if ($Settings.Mode -cne 'publish') {
        throw 'ReleaseVersion requires Mode: publish.'
    }
    $parsedVersion = $null
    if (-not [semver]::TryParse($ReleaseVersion, [ref] $parsedVersion) -or $parsedVersion.ToString() -cne $ReleaseVersion) {
        throw 'Invalid ReleaseVersion. Use an exact, unprefixed SemVer from Calculate.'
    }
    $planParameters.ReleaseVersion = $ReleaseVersion
}
if ($CalculatedAt) {
    if (-not $ReleaseVersion) {
        throw 'CalculatedAt requires ReleaseVersion.'
    }
    $calculationTime = [datetime]::MinValue
    $parsedTime = [datetime]::TryParseExact(
        $CalculatedAt, 'o', [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref] $calculationTime
    )
    if (-not $parsedTime -or $calculationTime.Kind -ne [DateTimeKind]::Utc) {
        throw 'Invalid CalculatedAt. Pass the original ISO 8601 UTC value from Calculate.'
    }
    $planParameters.CalculationTime = $calculationTime
}

$helperModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Release-GHRepository.Helpers.psm1'
$planPath = Join-Path -Path $PSScriptRoot -ChildPath 'Get-EventReleasePlan.ps1'
Import-Module -Name $helperModulePath -Force

LogGroup 'Loading libraries' {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Install-PSResource -Name PSSemVer -WarningAction SilentlyContinue -TrustRepository -Repository PSGallery
            break
        } catch {
            $installationError = $_
            Write-Warning "Installation of PSSemVer failed: $installationError"
            if ($attempt -eq 5) {
                throw $installationError
            }
            Start-Sleep -Seconds 10
        }
    }
    Import-Module -Name PSSemVer
}

if ($Settings.Mode -ceq 'calculate') {
    $plan = & $planPath @planParameters
    Set-GitHubOutput -Name Decision -Value $plan.Decision
    if ($plan.Decision -ceq 'release') {
        Set-GitHubOutput -Name ReleaseVersion -Value $plan.ReleaseVersion
        if ($plan.CalculatedAt) {
            Set-GitHubOutput -Name CalculatedAt -Value $plan.CalculatedAt
        }
    }
    return
}

$whatIf = $Settings.WhatIf
$eventName = $env:GITHUB_EVENT_NAME
$githubEvent = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($env:GITHUB_EVENT_PATH))
$isPullRequest = $eventName -ceq 'pull_request'
$isBranchPush = $eventName -ceq 'push' -and $githubEvent.deleted -ne $true -and $githubEvent.ref -cnotlike 'refs/tags/*'
if (-not $isPullRequest -and -not $isBranchPush) {
    if ($ReleaseVersion) {
        throw 'ReleaseVersion was supplied, but this event is not eligible for publication.'
    }
    Write-GitHubWarning 'This event is not eligible for publication or pull request cleanup.'
    return
}

$planParameters.GitHubEvent = $githubEvent
$plan = & $planPath @planParameters
if ($null -eq $plan) {
    Write-GitHubWarning 'No open pull request matches this branch push. No release will be published.'
    return
}

$pullRequest = $plan.PullRequest
$targetRepository = $plan.TargetRepository
$repositoryArgument = "$($plan.Hostname)/$targetRepository"
$decision = $plan.ReleaseDecision
$createPrerelease = $plan.ReleaseVersion -and -not $plan.Stable

Write-Output "Auto cleanup enabled:           [$($Settings.AutoCleanup)]"
Write-Output "Default bump:                   [$($Settings.DefaultBump)]"
Write-Output "Default bump source:            [$($Settings.DefaultBumpSource)]"
Write-Output "Default bump applied:           [$($decision.DefaultBumpApplied)]"
Write-Output "Bump source:                    [$($decision.BumpSource)]"
Write-Output "Date-based prerelease format:   [$($Settings.DatePrereleaseFormat)]"
Write-Output "Use PR body as release notes:   [$($Settings.UsePRBodyAsReleaseNotes)]"
Write-Output "Version prefix:                 [$($Settings.VersionPrefix)]"
Write-Output "What if mode:                   [$whatIf]"
Write-Output "Skip release:                   [$($decision.Skip)]"
Write-Output "Create a prerelease:            [$createPrerelease]"

$prereleasesToCleanup = @()
if ($plan.CleanupOnly -and $Settings.AutoCleanup) {
    $pullRequestContext = Resolve-PullRequestReleaseContext -PullRequest $pullRequest -AllowEmptyPrereleaseName
    if ($pullRequestContext.PrereleaseName) {
        $recordsJson = gh release list --repo $repositoryArgument --json 'isPrerelease,tagName'
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to read prereleases for cleanup in $targetRepository. gh exited with code [$LASTEXITCODE]."
        }
        $releases = ConvertFrom-Json -InputObject ($recordsJson -join "`n") -NoEnumerate
        if ($releases -isnot [array]) {
            throw "GitHub returned an invalid release list for $targetRepository."
        }
        $cleanupParameters = @{
            Releases       = $releases
            PrereleaseName = $pullRequestContext.PrereleaseName
            VersionPrefix  = $Settings.VersionPrefix
        }
        $prereleasesToCleanup = @(Get-PrereleaseCleanupCandidate @cleanupParameters)
    } else {
        Write-Output 'This branch has no prerelease identifier; cleanup has no candidates.'
    }
}

if ($plan.ReleaseVersion) {
    $tag = $plan.TagVersion.ToString()
    $target = $plan.CommitSha
    $aliasPush = @()
    if ($plan.Stable -and ($Settings.CreateMajorTag -or $Settings.CreateMinorTag)) {
        $remote = "$($env:GITHUB_SERVER_URL.TrimEnd('/'))/$targetRepository.git"
        $aliasPush = @('push', '--no-follow-tags', $remote)
        if ($Settings.CreateMajorTag) {
            $aliasPush += "+${target}:refs/tags/$($plan.TagVersion.Prefix)$($plan.TagVersion.Major)"
        }
        if ($Settings.CreateMinorTag) {
            $aliasPush += "+${target}:refs/tags/$($plan.TagVersion.Prefix)$($plan.TagVersion.Major).$($plan.TagVersion.Minor)"
        }
        if ($whatIf) {
            Write-Output "WhatIf: git fetch --no-tags $remote $target"
        } else {
            git fetch --no-tags $remote $target
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to fetch release target [$target]. git exited with code [$LASTEXITCODE]."
            }
        }
    }

    if ($plan.ReplacePrerelease) {
        $releaseDelete = @('release', 'delete', $tag, '--repo', $repositoryArgument, '--yes')
        if (-not $plan.TagExists) {
            $releaseDelete += '--cleanup-tag'
        }
        if ($whatIf) {
            Write-Output "WhatIf: gh $($releaseDelete -join ' ')"
        } else {
            gh @releaseDelete
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to replace prerelease [$tag]. gh exited with code [$LASTEXITCODE]."
            }
        }
    }

    if (-not $plan.TagExists) {
        # Create the ref without force so a tag created after preflight cannot change the release target.
        $tagCreate = @('api', "repos/$targetRepository/git/refs", '--hostname', $plan.Hostname, '--method', 'POST')
        $tagCreate += @('-f', "ref=refs/tags/$tag", '-f', "sha=$target")
        if ($whatIf) {
            Write-Output "WhatIf: gh $($tagCreate -join ' ')"
        } else {
            $null = gh @tagCreate
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create release tag [$tag] at [$target]. gh exited with code [$LASTEXITCODE]."
            }
        }
    }

    $title = $tag
    if ($pullRequest -and $Settings.UsePRTitleAsReleaseName) {
        $title = $pullRequest.title
    }
    $notes = ''
    if ($pullRequest -and $Settings.UsePRTitleAsNotesHeading) {
        $notes = "# $($pullRequest.title) (#$($pullRequest.number))`n`n"
    }
    if ($pullRequest -and $Settings.UsePRBodyAsReleaseNotes) {
        $notes += $pullRequest.body
    }
    $releaseCreate = @('release', 'create', $tag, '--repo', $repositoryArgument, '--title', $title, '--verify-tag')
    if ([string]::IsNullOrWhiteSpace($notes)) {
        $releaseCreate += '--generate-notes'
    } else {
        $releaseCreate += @('--notes', $notes)
    }
    $releaseCreate += @('--target', $target)
    if ($createPrerelease) {
        $releaseCreate += '--prerelease'
    }

    if ($whatIf) {
        Write-Output "WhatIf: gh $($releaseCreate -join ' ')"
    } else {
        $releaseUrl = gh @releaseCreate
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create release [$tag]. gh exited with code [$LASTEXITCODE]."
        }
    }

    if ($createPrerelease) {
        if ($whatIf) {
            Write-Output "WhatIf: gh pr comment $($pullRequest.number) --repo $repositoryArgument"
        } else {
            gh pr comment $pullRequest.number --repo $repositoryArgument --body "The release [$tag]($releaseUrl) has been created."
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to comment on the pull request. gh exited with code [$LASTEXITCODE]."
            }
        }
    }
    if ($aliasPush.Count -gt 0) {
        if ($whatIf) {
            Write-Output "WhatIf: git $($aliasPush -join ' ')"
        } else {
            git @aliasPush
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to update the enabled aliases for [$tag]. git exited with code [$LASTEXITCODE]."
            }
        }
    }
    if (-not $whatIf) {
        Write-GitHubNotice -Title 'Release created' -Message $tag
    }
} else {
    Write-Output 'Skipping release creation.'
}

if ($isPullRequest) {
    foreach ($definition in Get-ReleaseLabelDefinition) {
        $arguments = @(
            'label', 'create', $definition.Name, '--repo', $repositoryArgument
            '--color', $definition.Color, '--description', $definition.Description, '--force'
        )
        if ($whatIf) {
            Write-Output "WhatIf: gh $($arguments -join ' ')"
        } else {
            gh @arguments
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to provision canonical label [$($definition.Name)]. gh exited with code [$LASTEXITCODE]."
            }
        }
    }
}

foreach ($release in $prereleasesToCleanup) {
    $deleteArguments = @('release', 'delete', $release.tagName, '--cleanup-tag', '--yes', '--repo', $repositoryArgument)
    if ($whatIf) {
        Write-Output "WhatIf: gh $($deleteArguments -join ' ')"
    } else {
        gh @deleteArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to clean up prerelease [$($release.tagName)]. gh exited with code [$LASTEXITCODE]."
        }
    }
}
