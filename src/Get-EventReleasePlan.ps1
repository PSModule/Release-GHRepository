#Requires -Version 7.2

<#
    .SYNOPSIS
    Resolve the current release decision, version, and target.

    .DESCRIPTION
    Read the matching pull request and stable release baseline for Calculate
    and Publish. In Publish mode, check eligibility, an optional exact
    version, and existing tags before any write.

    .EXAMPLE
    .\Get-EventReleasePlan.ps1 -Settings $releaseSettings

    Return the plan for the current GitHub Actions event.

    .INPUTS
    None

    You can't pipe objects to Get-EventReleasePlan.ps1.

    .OUTPUTS
    System.Management.Automation.PSCustomObject

    The release plan and exact pull request snapshot used for the decision.
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    # The validated release settings from the action's startup step.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [PSCustomObject] $Settings,

    # The event read by Publish. Calculate reads it from the runner by default.
    [Parameter()]
    [PSCustomObject] $GitHubEvent,

    # The unprefixed version to validate for publication, if the caller supplied one.
    [Parameter()]
    [string] $ReleaseVersion,

    # The original UTC instant for an exact date-dependent version.
    [Parameter()]
    [datetime] $CalculationTime
)

$ErrorActionPreference = 'Stop'

function Invoke-ReleaseGitHubRead {
    <#
        .SYNOPSIS
        Read and parse a GitHub API response for version calculation.

        .DESCRIPTION
        Fail on a CLI error or missing response. Keep paginated arrays intact
        so the caller can distinguish a successful empty page from a failure.

        .EXAMPLE
        Invoke-ReleaseGitHubRead -Endpoint 'repos/example/project/pulls/42' -Hostname 'github.com' -Resource 'pull request 42'

        Return pull request 42 from the target repository.

        .INPUTS
        None

        You can't pipe objects to Invoke-ReleaseGitHubRead.

        .OUTPUTS
        System.Management.Automation.PSCustomObject

        A JSON object returned by the GitHub API.

        .OUTPUTS
        System.Array

        An array of GitHub API pages.
    #>
    [OutputType([PSCustomObject], [array])]
    [CmdletBinding()]
    param(
        # The API route.
        [Parameter(Mandatory)]
        [string] $Endpoint,

        # The host of the repository that started the workflow.
        [Parameter(Mandatory)]
        [string] $Hostname,

        # The resource name for error messages.
        [Parameter(Mandatory)]
        [string] $Resource,

        # Arguments for the read request.
        [Parameter()]
        [string[]] $ArgumentList = @('--method', 'GET')
    )

    $PSNativeCommandUseErrorActionPreference = $false
    $json = gh api $Endpoint --hostname $Hostname @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read $Resource. gh exited with code [$LASTEXITCODE]."
    }
    $response = ConvertFrom-Json -InputObject ($json -join "`n") -NoEnumerate
    if ($null -eq $response) {
        throw "GitHub returned no response when reading $Resource."
    }
    , $response
}

function Test-ReleasePullRequest {
    <#
        .SYNOPSIS
        Test whether a pull request matches the exact calculation context.

        .DESCRIPTION
        For a stable calculation, require the exact merged commit and base
        branch. For a prerelease, require an open pull request with the exact head.

        .EXAMPLE
        Test-ReleasePullRequest -PullRequest $pullRequest -Context $context

        Return true only if the pull request matches the event.

        .INPUTS
        None

        You can't pipe objects to Test-ReleasePullRequest.

        .OUTPUTS
        System.Boolean

        Whether the pull request matches the event.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        # A pull request returned from the target repository.
        [Parameter(Mandatory)]
        [PSCustomObject] $PullRequest,

        # The target repository, refs, and exact commit from the event.
        [Parameter(Mandatory)]
        [PSCustomObject] $Context
    )

    if ($PullRequest.base.repo.full_name -ine $Context.TargetRepository -or
        [string]::IsNullOrWhiteSpace($PullRequest.base.ref) -or
        ($Context.BaseRef -and $PullRequest.base.ref -cne $Context.BaseRef)) {
        return $false
    }
    if ($Context.Stable) {
        return ($PullRequest.state -ceq 'closed' -and $PullRequest.merged_at -and
            $PullRequest.merge_commit_sha -ieq $Context.CommitSha)
    }
    $headMatches = $PullRequest.head.ref -ceq $Context.HeadRef -and $PullRequest.head.sha -ieq $Context.CommitSha
    $PullRequest.state -ceq 'open' -and $PullRequest.head.repo.full_name -ieq $Context.SourceRepository -and $headMatches
}

$repository = [Environment]::GetEnvironmentVariable('GITHUB_REPOSITORY')
$eventName = [Environment]::GetEnvironmentVariable('GITHUB_EVENT_NAME')
if ($null -eq $GitHubEvent) {
    $eventPath = [Environment]::GetEnvironmentVariable('GITHUB_EVENT_PATH')
    $GitHubEvent = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($eventPath))
}
$repositoryPattern = '\A[A-Za-z0-9][A-Za-z0-9-]*/(?!\.{1,2}\z)[A-Za-z0-9_.-]+\z'
if ($repository -cnotmatch $repositoryPattern -or $GitHubEvent.repository.full_name -ine $repository) {
    throw 'The event repository must match GITHUB_REPOSITORY.'
}
$server = $null
if (-not [uri]::TryCreate($env:GITHUB_SERVER_URL, [UriKind]::Absolute, [ref] $server) -or
    $server.Scheme -cne 'https' -or -not $server.Host) {
    throw 'GITHUB_SERVER_URL must identify the GitHub host.'
}
$publishing = $Settings.Mode -ceq 'publish'
$closedPullRequest = $GitHubEvent.action -ceq 'closed' -or $GitHubEvent.pull_request.state -ceq 'closed'
$cleanupOnly = $publishing -and $eventName -ceq 'pull_request' -and $closedPullRequest
if ($cleanupOnly -and $ReleaseVersion) {
    throw 'ReleaseVersion was supplied, but a closed pull request is not eligible for publication.'
}
$readParameters = @{ Hostname = $server.Host }
$shaPattern = '\A[0-9a-fA-F]{40}\z'
$context = [PSCustomObject]@{
    SourceRepository = $repository
    TargetRepository = $repository
    BaseRef          = ''
    HeadRef          = ''
    CommitSha        = ''
    Stable           = $false
}
$number = 0

switch -CaseSensitive ($eventName) {
    'pull_request' {
        if ($Settings.PullRequest) {
            throw 'PullRequest can only select a pull request for a branch push.'
        }
        $eventPullRequest = $GitHubEvent.pull_request
        $context.SourceRepository = [string] $eventPullRequest.head.repo.full_name
        $context.BaseRef = [string] $eventPullRequest.base.ref
        $context.HeadRef = [string] $eventPullRequest.head.ref
        $context.CommitSha = [string] $eventPullRequest.head.sha
        if (-not [int]::TryParse([string] $eventPullRequest.number, [ref] $number) -or $number -le 0 -or
            $eventPullRequest.base.repo.full_name -ine $repository -or -not $context.BaseRef -or
            $context.SourceRepository -cnotmatch $repositoryPattern -or -not $context.HeadRef -or
            $context.CommitSha -cnotmatch $shaPattern -or $context.CommitSha -ceq ('0' * 40)) {
            throw 'The pull request event must identify the target repository and the exact source repository, branch, and commit.'
        }
    }
    'push' {
        $ref = [string] $GitHubEvent.ref
        $context.CommitSha = [string] $GitHubEvent.after
        if ($GitHubEvent.deleted -isnot [bool] -or $GitHubEvent.deleted -or $ref -cnotmatch '\Arefs/heads/\S+\z' -or
            $context.CommitSha -cnotmatch $shaPattern -or $context.CommitSha -ceq ('0' * 40)) {
            throw 'Release planning requires a branch push with a full commit SHA, not a tag push or a deleted branch.'
        }
        $context.HeadRef = $ref.Substring('refs/heads/'.Length)
        if ([string]::IsNullOrWhiteSpace($GitHubEvent.repository.default_branch) -or $GitHubEvent.repository.fork -isnot [bool]) {
            throw 'The push event must identify the default branch and whether the repository is a fork.'
        }
        if ($Settings.PullRequest) {
            $context.TargetRepository, $selectedNumber = $Settings.PullRequest.Split('#', 2)
            $number = [int] $selectedNumber
            if ($publishing -and $context.TargetRepository -ine $repository) {
                throw 'Publish must run in the target repository. Use Calculate for a pull request selection from a fork.'
            }
        } elseif ($GitHubEvent.repository.fork) {
            if ($publishing) {
                if ($ReleaseVersion) {
                    throw 'ReleaseVersion was supplied, but a fork push is not eligible for publication to its upstream repository.'
                }
                return
            }
            throw 'For a fork push, set PullRequest to the target OWNER/REPO#NUMBER.'
        }

        $context.Stable = ($context.TargetRepository -ieq $repository -and
            $context.HeadRef -ceq $GitHubEvent.repository.default_branch)
        if ($context.Stable) {
            $context.BaseRef = $context.HeadRef
            if ($publishing) {
                $currentRepository = Invoke-ReleaseGitHubRead @readParameters -Endpoint "repos/$repository" -Resource "repository $repository"
                if ($currentRepository.full_name -ine $repository -or $currentRepository.default_branch -cne $context.BaseRef) {
                    throw "The push branch [$($context.BaseRef)] no longer matches the repository default branch."
                }
            }
        }
    }
    default { throw 'Calculate requires a pull_request or branch push event.' }
}

if ($number -eq 0) {
    $lookupOptions = @('--method', 'GET', '--paginate', '--slurp')
    if ($context.Stable) {
        $route = "repos/$repository/commits/$($context.CommitSha)/pulls"
        $resource = 'pull requests associated with the pushed commit'
    } else {
        $sourceOwner = $context.SourceRepository.Split('/')[0]
        $route = "repos/$repository/pulls"
        $resource = 'open pull requests for the pushed branch'
        $lookupOptions += @('-f', 'state=open', '-f', "head=${sourceOwner}:$($context.HeadRef)")
    }
    $pages = Invoke-ReleaseGitHubRead @readParameters -Endpoint $route -Resource $resource -ArgumentList $lookupOptions
    if ($pages -isnot [array] -or $pages.Count -eq 0) {
        throw "GitHub returned an invalid response for $resource."
    }
    $matchesByNumber = [Collections.Generic.HashSet[int]]::new()
    foreach ($page in $pages) {
        if ($page -isnot [array]) {
            throw "GitHub returned an invalid page for $resource."
        }
        foreach ($candidate in $page) {
            if ($candidate -isnot [PSCustomObject] -or [int] $candidate.number -le 0 -or
                $candidate.state -cnotin @('open', 'closed') -or -not $candidate.base.repo.full_name -or -not $candidate.base.ref) {
                throw "GitHub returned an invalid pull request for $resource."
            }
            if (Test-ReleasePullRequest -PullRequest $candidate -Context $context) {
                $null = $matchesByNumber.Add($candidate.number)
            }
        }
    }
    if ($matchesByNumber.Count -gt 1) {
        if ($context.Stable) {
            throw 'More than one merged pull request matches this push. Set PullRequest to select the correct one.'
        }
        throw 'More than one open pull request matches this push. Set PullRequest to select the correct one.'
    }
    if ($matchesByNumber.Count -eq 1) {
        $number = $matchesByNumber | Select-Object -First 1
    } elseif (-not $context.Stable) {
        if ($publishing) {
            if ($ReleaseVersion) {
                throw 'ReleaseVersion was supplied, but no open pull request matches this push. The event is not eligible for publication.'
            }
            return
        }
        throw 'No open pull request matches the source repository, branch, and exact pushed SHA.'
    }
}

$targetRepository = $context.TargetRepository
$labels = @()
$pullRequest = $null
if ($number -gt 0) {
    if ($cleanupOnly) {
        $pullRequest = $eventPullRequest
    } else {
        $pullRequestParameters = @{
            Endpoint = "repos/$targetRepository/pulls/$number"
            Resource = "pull request $targetRepository#$number"
        }
        $pullRequest = Invoke-ReleaseGitHubRead @readParameters @pullRequestParameters
        if ($pullRequest -isnot [PSCustomObject] -or $pullRequest.number -ne $number -or
            -not (Test-ReleasePullRequest -PullRequest $pullRequest -Context $context)) {
            throw "Pull request $targetRepository#$number no longer matches the event repository, branch, and exact commit."
        }
    }
    if ($pullRequest.labels -isnot [array]) {
        throw "GitHub did not return the current labels for pull request $targetRepository#$number."
    }
    $labels = foreach ($label in $pullRequest.labels) {
        if ([string]::IsNullOrWhiteSpace($label.name)) {
            throw "GitHub returned an invalid label for pull request $targetRepository#$number."
        }
        $label.name
    }
}

$decisionParameters = @{
    Labels            = $labels
    DefaultBump       = $Settings.DefaultBump
    DefaultBumpSource = $Settings.DefaultBumpSource
}
$decision = Resolve-ReleaseDecision @decisionParameters
Write-Information "Release bump source: [$($decision.BumpSource)]." -InformationAction Continue
$eligible = if ($publishing -and -not $context.Stable) {
    Test-PrereleaseCreation -ReleaseDecision $decision -PullRequestClosed:$cleanupOnly
} else {
    -not $decision.Skip
}
if ($ReleaseVersion -and -not $eligible) {
    if ($decision.Skip) {
        throw 'Do not supply ReleaseVersion with release:skip.'
    }
    throw 'ReleaseVersion cannot publish a prerelease without release:prerelease on the pull request.'
}

$hasCalculationTime = $PSBoundParameters.ContainsKey('CalculationTime')
$usesDate = $eligible -and -not $context.Stable -and $Settings.DatePrereleaseFormat
if ($hasCalculationTime -and -not $usesDate) {
    throw 'CalculatedAt applies only to a date-dependent prerelease.'
}
if ($ReleaseVersion -and $usesDate -and -not $hasCalculationTime) {
    throw 'CalculatedAt is required with ReleaseVersion for a date-dependent prerelease. Pass the original Calculate output.'
}

$planParameters = @{ ReleaseDecision = $decision; Settings = $Settings }
if ($eligible) {
    if (-not $context.Stable) {
        $pullRequestContext = Resolve-PullRequestReleaseContext -PullRequest $pullRequest
        $planParameters.PrereleaseName = $pullRequestContext.PrereleaseName
    }
    if ($usesDate) {
        $planParameters.CalculationTime = if ($hasCalculationTime) { $CalculationTime } else { Get-Date -AsUTC }
    }
    $owner, $name = $targetRepository.Split('/')
    $query = @(
        'query($owner: String!, $name: String!) {'
        'repository(owner: $owner, name: $name) { nameWithOwner latestRelease { tagName isDraft isPrerelease } }'
        '}'
    ) -join ' '
    $historyParameters = @{
        Endpoint     = 'graphql'
        Resource     = "release history for $targetRepository"
        ArgumentList = @('-f', "query=$query", '-f', "owner=$owner", '-f', "name=$name")
    }
    $history = Invoke-ReleaseGitHubRead @readParameters @historyParameters
    $repositoryHistory = $history.data.repository
    if ($history.errors -or $repositoryHistory.nameWithOwner -ine $targetRepository -or
        $null -eq $repositoryHistory.PSObject.Properties['latestRelease']) {
        throw "GitHub returned invalid release history for $targetRepository."
    }
    $latest = $repositoryHistory.latestRelease
    if ($null -ne $latest) {
        if ($latest.isDraft -ne $false -or $latest.isPrerelease -ne $false -or [string]::IsNullOrWhiteSpace($latest.tagName)) {
            throw "GitHub returned an invalid stable release in the release history for $targetRepository."
        }
        $planParameters.BaselineTag = $latest.tagName
    }
}
$versionPlan = if ($eligible -or $decision.Skip) { Get-ReleaseVersionPlan @planParameters }
if ($ReleaseVersion -and $versionPlan.ReleaseVersion -cne $ReleaseVersion) {
    throw "ReleaseVersion [$ReleaseVersion] does not match the current release plan [$($versionPlan.ReleaseVersion)]. Run Calculate again."
}

$tagExists = $false
$replacePrerelease = $false
if ($publishing -and $eligible) {
    $tag = $versionPlan.TagVersion.ToString()
    $tagRef = "refs/tags/$tag"
    $null = git check-ref-format $tagRef
    if ($LASTEXITCODE -ne 0 -or $tag.StartsWith('-', [StringComparison]::Ordinal)) {
        throw "VersionPrefix produces an invalid release tag [$tag]."
    }

    $encodedTag = [uri]::EscapeDataString($tag)
    $tagParameters = @{
        Endpoint = "repos/$targetRepository/git/matching-refs/tags/$encodedTag"
        Resource = "release tag [$tag] in $targetRepository"
    }
    $tagRefs = Invoke-ReleaseGitHubRead @readParameters @tagParameters
    if ($tagRefs -isnot [array]) {
        throw "GitHub returned an invalid response for release tag [$tag]."
    }
    foreach ($ref in $tagRefs) {
        if ($ref.ref -isnot [string] -or -not $ref.ref.StartsWith($tagRef, [StringComparison]::Ordinal)) {
            throw "GitHub returned an invalid reference for release tag [$tag]."
        }
    }
    $exactRefs = @($tagRefs | Where-Object { $_.ref -ceq $tagRef })
    if ($exactRefs.Count -gt 0) {
        $tagObject = $exactRefs[0].object
        if ($exactRefs.Count -ne 1 -or $tagObject.type -cne 'commit' -or $tagObject.sha -cnotmatch $shaPattern) {
            throw "Release tag [$tag] has no verifiable commit target."
        }
        $tagExists = $tagObject.sha -ieq $context.CommitSha
        if (-not $tagExists -and ($ReleaseVersion -or $context.Stable -or $Settings.IncrementalPrerelease)) {
            throw "Release tag [$tag] does not point to the validated target [$($context.CommitSha)]."
        }

        $repositoryArgument = "$($server.Host)/$targetRepository"
        $recordsJson = gh release list --repo $repositoryArgument --json 'isDraft,isPrerelease,tagName'
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to read the release for tag [$tag] in $targetRepository."
        }
        $records = ConvertFrom-Json -InputObject ($recordsJson -join "`n") -NoEnumerate
        if ($records -isnot [array]) {
            throw "GitHub returned an invalid release list for $targetRepository."
        }
        $previousReleases = @($records | Where-Object { $_.tagName -ceq $tag })
        if ($previousReleases.Count -gt 0) {
            if ($previousReleases.Count -ne 1 -or $context.Stable -or $Settings.IncrementalPrerelease -or
                $previousReleases[0].isPrerelease -ne $true -or $previousReleases[0].isDraft -ne $false) {
                throw "Release tag [$tag] already has a GitHub release."
            }
            $replacePrerelease = $true
        } elseif (-not $tagExists) {
            throw "Release tag [$tag] does not point to the validated target [$($context.CommitSha)]."
        }
    }
}

[PSCustomObject]@{
    Decision          = $versionPlan.Decision
    ReleaseVersion    = $versionPlan.ReleaseVersion
    TagVersion        = $versionPlan.TagVersion
    CalculatedAt      = $versionPlan.CalculatedAt
    ReleaseDecision   = $decision
    PullRequest       = $pullRequest
    Hostname          = $server.Host
    TargetRepository  = $targetRepository
    CommitSha         = $context.CommitSha
    Stable            = $context.Stable
    CleanupOnly       = $cleanupOnly
    TagExists         = $tagExists
    ReplacePrerelease = $replacePrerelease
}
