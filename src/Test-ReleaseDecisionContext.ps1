#Requires -Version 7.2

<#
    .SYNOPSIS
    Confirm that the release check still describes the current pull request.

    .EXAMPLE
    .\Test-ReleaseDecisionContext.ps1

    Check the candidate merge checkout and event labels against GitHub.

    .OUTPUTS
    System.Management.Automation.PSCustomObject
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    # The GitHub Actions pull request event payload.
    [Parameter()]
    [string] $EventPath = $env:GITHUB_EVENT_PATH,

    # The checked-out candidate merge tree.
    [Parameter()]
    [string] $Workspace = $env:GITHUB_WORKSPACE,

    # The repository receiving the pull request.
    [Parameter()]
    [string] $Repository = $env:GITHUB_REPOSITORY,

    # The merge commit selected by the pull_request workflow run.
    [Parameter()]
    [string] $CandidateSha = $env:GITHUB_SHA,

    # The exact pull request used for calculation, if the caller already read it.
    [Parameter()]
    [PSCustomObject] $CurrentPullRequest
)

$ErrorActionPreference = 'Stop'
$shaPattern = '\A[0-9a-f]{40}\z'

function Get-DecisionSnapshot {
    <#
        .SYNOPSIS
        Require the pull request identity, revisions, and labels used for a decision.
    #>
    param([object] $PullRequest)

    $snapshot = [PSCustomObject]@{
        Number   = $PullRequest.number
        State    = $PullRequest.state
        BaseRepo = $PullRequest.base.repo.full_name
        BaseRef  = $PullRequest.base.ref
        BaseSha  = $PullRequest.base.sha
        HeadRepo = $PullRequest.head.repo.full_name
        HeadRef  = $PullRequest.head.ref
        HeadSha  = $PullRequest.head.sha
        Labels   = $null
    }

    if ($snapshot.Number -isnot [long] -or $snapshot.Number -le 0 -or
        $snapshot.State -cnotin @('open', 'closed') -or
        -not $snapshot.BaseRepo -or -not $snapshot.BaseRef -or $snapshot.BaseSha -cnotmatch $shaPattern -or
        -not $snapshot.HeadRepo -or -not $snapshot.HeadRef -or $snapshot.HeadSha -cnotmatch $shaPattern -or
        $PullRequest.labels -isnot [array]) {
        throw 'GitHub returned an incomplete pull request snapshot. Rerun the release decision check.'
    }

    [string[]] $names = @(foreach ($label in $PullRequest.labels) {
            if ($label.name -isnot [string] -or -not $label.name) {
                throw 'GitHub returned an incomplete pull request label.'
            }
            $label.name
        })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $snapshot.Labels = ConvertTo-Json -InputObject $names -Compress
    $snapshot
}

if ($Repository -cnotmatch '\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z' -or
    [string]::IsNullOrWhiteSpace($Workspace) -or $CandidateSha -cnotmatch $shaPattern) {
    throw 'The release decision check needs a repository, workspace, and candidate merge SHA.'
}

$eventPayload = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($EventPath)) -AsHashtable
$original = Get-DecisionSnapshot -PullRequest $eventPayload.pull_request
if ($original.State -cne 'open' -or $original.BaseRepo -ine $Repository -or $eventPayload.repository.full_name -ine $Repository) {
    throw 'The release decision check requires an open pull request to this repository.'
}

$checkedSha = git -C $Workspace rev-parse --verify HEAD
if ($LASTEXITCODE -ne 0 -or $checkedSha -cne $CandidateSha) {
    throw 'The candidate merge checkout does not match the workflow run SHA.'
}

# Read the commit headers so the parent check also works with a shallow checkout.
$commit = git -C $Workspace cat-file commit HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the candidate merge commit.'
}
$parents = @(foreach ($line in $commit) {
        if ($line -ceq '') {
            break
        }
        if ($line.StartsWith('parent ', [StringComparison]::Ordinal)) {
            $line.Substring(7)
        }
    })
if ($parents.Count -ne 2 -or $parents[0] -cne $original.BaseSha -or $parents[1] -cne $original.HeadSha) {
    throw 'The candidate merge parents do not match the event base and head. Run the check for the current revisions.'
}

if (-not $PSBoundParameters.ContainsKey('CurrentPullRequest')) {
    $json = gh api --method GET "repos/$Repository/pulls/$($original.Number)"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read pull request [$($original.Number)]."
    }
    $CurrentPullRequest = ConvertFrom-Json -InputObject ($json -join "`n")
}
$current = Get-DecisionSnapshot -PullRequest $CurrentPullRequest
if ($current.Number -ne $original.Number -or $current.State -cne 'open') {
    throw 'The pull request is not open or does not match the event.'
}
if ($current.BaseRepo -ine $original.BaseRepo -or $current.BaseRef -cne $original.BaseRef -or
    $current.BaseSha -cne $original.BaseSha) {
    throw 'The pull request target changed. Run the check for the current base.'
}
if ($current.HeadRepo -ine $original.HeadRepo -or $current.HeadRef -cne $original.HeadRef -or
    $current.HeadSha -cne $original.HeadSha) {
    throw 'The pull request source changed. Run the check for the current head.'
}
if ($current.Labels -cne $original.Labels) {
    throw 'The pull request labels changed. Use the result for the current labels.'
}

[PSCustomObject]@{
    Number   = $original.Number
    BaseRef  = $original.BaseRef
    BaseSha  = $original.BaseSha
    HeadSha  = $original.HeadSha
    MergeSha = $checkedSha
}
