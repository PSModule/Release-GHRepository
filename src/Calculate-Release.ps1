#Requires -Version 7.2

<#
    .SYNOPSIS
    Resolve the current release decision and calculate its version.

    .DESCRIPTION
    Read the matching pull request and the target repository's stable release
    baseline. Do not write to GitHub or change Git refs.

    .EXAMPLE
    .\Calculate-Release.ps1 -Settings $releaseSettings

    Return the plan for the current GitHub Actions event.

    .INPUTS
    None

    You can't pipe objects to Calculate-Release.ps1.

    .OUTPUTS
    System.Management.Automation.PSCustomObject

    The release version plan, or a skip decision without a version.
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    # The validated release settings from the action's startup step.
    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [PSCustomObject] $Settings
)

$ErrorActionPreference = 'Stop'

function Invoke-CalculationGitHubRead {
    <#
        .SYNOPSIS
        Read and parse a GitHub API response for version calculation.

        .DESCRIPTION
        Fail on a CLI error or missing response. Keep paginated arrays intact
        so the caller can distinguish a successful empty page from a failure.

        .EXAMPLE
        Invoke-CalculationGitHubRead -Endpoint 'repos/example/project/pulls/42' -Hostname 'github.com' -Resource 'pull request 42'

        Return pull request 42 from the target repository.

        .INPUTS
        None

        You can't pipe objects to Invoke-CalculationGitHubRead.

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

function Test-CalculationPullRequest {
    <#
        .SYNOPSIS
        Test whether a pull request matches the exact calculation context.

        .DESCRIPTION
        For a stable calculation, require the exact merged commit and base
        branch. For a prerelease, require an open pull request with the exact head.

        .EXAMPLE
        Test-CalculationPullRequest -PullRequest $pullRequest -Context $context

        Return true only if the pull request matches the event.

        .INPUTS
        None

        You can't pipe objects to Test-CalculationPullRequest.

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
$eventPath = [Environment]::GetEnvironmentVariable('GITHUB_EVENT_PATH')
$githubEvent = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($eventPath))
$repositoryPattern = '\A[A-Za-z0-9][A-Za-z0-9-]*/(?!\.{1,2}\z)[A-Za-z0-9_.-]+\z'
if ($repository -cnotmatch $repositoryPattern -or $githubEvent.repository.full_name -ine $repository) {
    throw 'The event repository must match GITHUB_REPOSITORY.'
}
$server = $null
if (-not [uri]::TryCreate($env:GITHUB_SERVER_URL, [UriKind]::Absolute, [ref] $server) -or -not $server.Host) {
    throw 'GITHUB_SERVER_URL must identify the GitHub host.'
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
        $eventPullRequest = $githubEvent.pull_request
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
        $ref = [string] $githubEvent.ref
        $context.CommitSha = [string] $githubEvent.after
        if ($githubEvent.deleted -ne $false -or $ref -cnotmatch '\Arefs/heads/\S+\z' -or
            $context.CommitSha -cnotmatch $shaPattern -or $context.CommitSha -ceq ('0' * 40)) {
            throw 'Calculate requires a branch push with a full commit SHA. It does not accept a tag push or a deleted branch.'
        }
        $context.HeadRef = $ref.Substring('refs/heads/'.Length)
        if ([string]::IsNullOrWhiteSpace($githubEvent.repository.default_branch) -or $githubEvent.repository.fork -isnot [bool]) {
            throw 'The push event must identify the default branch and whether the repository is a fork.'
        }
        if ($Settings.PullRequest) {
            $context.TargetRepository, $selectedNumber = $Settings.PullRequest.Split('#', 2)
            $number = [int] $selectedNumber
        } elseif ($githubEvent.repository.fork) {
            throw 'For a fork push, set PullRequest to the target OWNER/REPO#NUMBER.'
        }

        $context.Stable = ($context.TargetRepository -ieq $repository -and
            $context.HeadRef -ceq $githubEvent.repository.default_branch)
        if ($context.Stable) {
            $context.BaseRef = $context.HeadRef
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
    $pages = Invoke-CalculationGitHubRead @readParameters -Endpoint $route -Resource $resource -ArgumentList $lookupOptions
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
            if (Test-CalculationPullRequest -PullRequest $candidate -Context $context) {
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
        throw 'No open pull request matches the source repository, branch, and exact pushed SHA.'
    }
}

$targetRepository = $context.TargetRepository
$labels = @()
if ($number -gt 0) {
    $pullRequestParameters = @{
        Endpoint = "repos/$targetRepository/pulls/$number"
        Resource = "pull request $targetRepository#$number"
    }
    $pullRequest = Invoke-CalculationGitHubRead @readParameters @pullRequestParameters
    if ($pullRequest -isnot [PSCustomObject] -or $pullRequest.number -ne $number -or
        -not (Test-CalculationPullRequest -PullRequest $pullRequest -Context $context)) {
        throw "Pull request $targetRepository#$number no longer matches the event repository, branch, and exact commit."
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
$planParameters = @{ ReleaseDecision = $decision; Settings = $Settings }
if (-not $decision.Skip) {
    if (-not $context.Stable) {
        $pullRequestContext = Resolve-PullRequestReleaseContext -PullRequest $pullRequest
        $planParameters.PrereleaseName = $pullRequestContext.PrereleaseName
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
    $history = Invoke-CalculationGitHubRead @readParameters @historyParameters
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
Get-ReleaseVersionPlan @planParameters
