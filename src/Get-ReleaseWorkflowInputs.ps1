#Requires -Version 7.2
#Requires -Modules powershell-yaml

<#
    .SYNOPSIS
    Read the supported inputs from the local release workflow.

    .DESCRIPTION
    Select the publisher for the target branch. Return only literal input values.
    Do not execute workflow expressions or guess unresolved values.

    .OUTPUTS
    System.Collections.IDictionary
#>
[OutputType([System.Collections.IDictionary])]
[CmdletBinding()]
param(
    # The candidate publisher workflow file.
    [Parameter(Mandatory)]
    [string] $Path,

    # The pull request target branch, without refs/heads/.
    [Parameter(Mandatory)]
    [string] $TargetBranch,

    # The settings supported by the same action that publishes.
    [Parameter(Mandatory)]
    [string[]] $SettingNames
)

$ErrorActionPreference = 'Stop'
$workflow = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($Path)) -Ordered
$trigger = $workflow.on.pull_request
if ($trigger -isnot [System.Collections.IDictionary]) {
    throw 'The release workflow must have a supported pull_request trigger.'
}
foreach ($filter in $trigger.GetEnumerator()) {
    if ($filter.Key -cnotin @('branches', 'types')) {
        throw "The release workflow has an unsupported pull_request filter [$($filter.Key)]."
    }
}
if ($trigger.branches -isnot [System.Collections.IList] -or
    @($trigger.branches | Where-Object { $_ -isnot [string] -or $_ -match '[!+*?\[\]\\]' }).Count -gt 0) {
    throw 'The release workflow has an unsupported branch filter. List the target branch names literally.'
}
if ($trigger.branches -cnotcontains $TargetBranch) {
    throw "The release workflow does not handle [$TargetBranch] with an explicit pull_request branch filter."
}
if ($trigger.types -isnot [System.Collections.IList] -or $trigger.types -cnotcontains 'closed') {
    throw 'The release workflow must handle closed pull requests.'
}

$job = $workflow.jobs.Release
$publisher = @($job.steps | Where-Object { $_.uses -ceq './' })
if ($publisher.Count -ne 1) {
    throw 'The release workflow must have exactly one local action invocation in the Release job.'
}
$sameRepository = 'github.event.pull_request.head.repo.full_name == github.repository'
if ($job.Contains('if') -and
    ($job.if -isnot [string] -or ($job.if.Trim() -replace '\s+', ' ') -cnotin @($sameRepository, ('${{ ' + $sameRepository + ' }}')))) {
    throw 'The release check cannot resolve a conditional publisher job other than the same-repository guard.'
}
if ($publisher[0].Contains('if') -or $job.Contains('strategy') -or $job.Contains('needs')) {
    throw 'The release check cannot resolve a conditional publisher step, publisher dependencies, or a matrix of publisher inputs.'
}

$checkouts = @(foreach ($step in $job.steps) {
        if ([object]::ReferenceEquals($step, $publisher[0])) {
            break
        }
        if ($step.uses -clike 'actions/checkout@*') {
            $step
        }
    })
if ($checkouts.Count -ne 1 -or $checkouts[0].Contains('if')) {
    throw 'The release check requires one unconditional checkout before the local publisher.'
}
if ($checkouts[0].Contains('with')) {
    $checkoutInputs = $checkouts[0].with
    if ($checkoutInputs -isnot [System.Collections.IDictionary]) {
        throw 'The publisher checkout with block must contain a mapping.'
    }
    if ($checkoutInputs.Contains('repository') -and
        ($checkoutInputs.repository -isnot [string] -or $checkoutInputs.repository -cne '${{ github.repository }}')) {
        throw 'The publisher checkout must use the current repository.'
    }
    if (($checkoutInputs.Contains('path') -and $checkoutInputs.path -cnotin @('.', './')) -or $checkoutInputs.Contains('sparse-checkout')) {
        throw 'The publisher checkout must use the workspace root without a sparse checkout.'
    }
    $currentReleaseRef = @(
        '${{ github.event.action == ''closed'' && github.event.pull_request.merged'
        '&& github.event.pull_request.merge_commit_sha || github.event.pull_request.base.sha }}'
    ) -join ' '
    $supportedRefs = @('${{ github.sha }}', '${{ github.event.pull_request.merge_commit_sha }}', $currentReleaseRef)
    if ($checkoutInputs.Contains('ref') -and
        ($checkoutInputs.ref -isnot [string] -or ($checkoutInputs.ref.Trim() -replace '\s+', ' ') -cnotin $supportedRefs)) {
        throw 'The publisher checkout ref must come from the pull request merge rather than another revision.'
    }
}

$inputs = @{}
if (-not $publisher[0].Contains('with')) {
    return $inputs
}

$overrides = $publisher[0].with
if ($overrides -isnot [System.Collections.IDictionary]) {
    throw 'The publisher with block must contain a mapping of literal inputs.'
}
foreach ($override in $overrides.GetEnumerator()) {
    $key = $override.Key
    $value = $override.Value
    $name = @($SettingNames + 'SettingsFilePath').Where({ $_ -eq $key }, 'First')[0]
    if (-not $name) {
        throw "The publisher has an unsupported workflow input [$key]."
    }
    if ($inputs.ContainsKey($name)) {
        throw "The publisher specifies workflow input [$name] more than once."
    }

    if ($value -is [bool]) {
        $inputs[$name] = $value.ToString().ToLowerInvariant()
    } elseif ($value -is [string] -and -not $value.Contains('${{')) {
        $inputs[$name] = $value
    } else {
        throw "Use a literal string or Boolean for publisher input [$name]."
    }
}
$inputs
