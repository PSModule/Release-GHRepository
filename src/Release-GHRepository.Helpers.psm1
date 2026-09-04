$ErrorActionPreference = 'Stop'

function Get-ReleaseLabelDefinition {
    <#
        .SYNOPSIS
        Return the canonical release labels owned by Release-GHRepository.

        .DESCRIPTION
        Return the canonical label names and repository metadata used when the action
        provisions its owned release controls.

        .EXAMPLE
        Get-ReleaseLabelDefinition

        Return all canonical release-label definitions.

        .INPUTS
        None

        You can't pipe objects to Get-ReleaseLabelDefinition.

        .OUTPUTS
        System.Management.Automation.PSCustomObject

        A canonical release-label definition.
    #>
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param()

    [PSCustomObject]@{
        Name        = 'release:patch'
        Color       = '5ac3a5'
        Description = 'Publish a patch release.'
    }
    [PSCustomObject]@{
        Name        = 'release:minor'
        Color       = '616f09'
        Description = 'Publish a minor release.'
    }
    [PSCustomObject]@{
        Name        = 'release:major'
        Color       = 'b60205'
        Description = 'Publish a major release.'
    }
    [PSCustomObject]@{
        Name        = 'release:prerelease'
        Color       = '8d7bdf'
        Description = 'Publish a prerelease from this open pull request.'
    }
    [PSCustomObject]@{
        Name        = 'release:skip'
        Color       = 'ededed'
        Description = 'Validate this change without publishing a release.'
    }
}

function ConvertTo-ReleaseBump {
    <#
        .SYNOPSIS
        Convert a configured default bump into the internal release-bump value.

        .DESCRIPTION
        Validate DefaultBump with case-sensitive matching and return the
        corresponding internal Patch, Minor, or Major value.

        .EXAMPLE
        ConvertTo-ReleaseBump -DefaultBump 'minor'

        Return Minor.

        .INPUTS
        None

        You can't pipe objects to ConvertTo-ReleaseBump.

        .OUTPUTS
        System.String

        The validated internal release-bump value.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        # The fallback bump used when no explicit release bump or skip label exists.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $DefaultBump = 'patch'
    )

    $validDefaultBumps = @('patch', 'minor', 'major')
    if ($validDefaultBumps -cnotcontains $DefaultBump) {
        throw "Invalid DefaultBump [$DefaultBump]. Use exactly one of: patch, minor, major."
    }

    switch -CaseSensitive ($DefaultBump) {
        'patch' { 'Patch' }
        'minor' { 'Minor' }
        'major' { 'Major' }
    }
}

function Resolve-ReleaseDecision {
    <#
        .SYNOPSIS
        Resolve a release decision from canonical pull-request labels.

        .DESCRIPTION
        Evaluate only the five labels owned by Release-GHRepository. An explicit
        bump label overrides DefaultBump, release:prerelease selects prerelease
        mode, and release:skip suppresses publication. Reject conflicting owned-label
        combinations.

        .EXAMPLE
        Resolve-ReleaseDecision -Labels @('release:minor')

        Return a Minor stable-release decision.

        .EXAMPLE
        Resolve-ReleaseDecision -Labels @('release:patch', 'release:prerelease')

        Return a Patch prerelease decision.

        .EXAMPLE
        Resolve-ReleaseDecision -Labels @() -DefaultBump 'minor'

        Return a Minor stable-release decision from the configured default.

        .INPUTS
        None

        You can't pipe objects to Resolve-ReleaseDecision.

        .OUTPUTS
        System.Management.Automation.PSCustomObject

        The validated release decision.
    #>
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param(
        # All labels currently applied to the pull request.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [string[]] $Labels,

        # The fallback bump used when no explicit release bump or skip label exists.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $DefaultBump = 'patch'
    )

    $resolvedDefaultBump = ConvertTo-ReleaseBump -DefaultBump $DefaultBump
    $bumpLabelTypes = [ordered]@{
        'release:patch' = 'Patch'
        'release:minor' = 'Minor'
        'release:major' = 'Major'
    }
    $ownedLabelNames = @($bumpLabelTypes.Keys) + @('release:prerelease', 'release:skip')
    $ownedLabels = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    foreach ($label in $Labels) {
        if ($ownedLabelNames -ccontains $label) {
            $null = $ownedLabels.Add($label)
        }
    }

    $hasSkip = $ownedLabels.Contains('release:skip')
    $hasPrerelease = $ownedLabels.Contains('release:prerelease')
    $bumpLabels = @($bumpLabelTypes.Keys | Where-Object { $ownedLabels.Contains($_) })

    if ($hasSkip) {
        if ($ownedLabels.Count -ne 1) {
            throw 'Invalid release labels: release:skip must not be combined with another release label.'
        }

        [PSCustomObject]@{
            Bump               = 'None'
            Prerelease         = $false
            Skip               = $true
            DefaultBumpApplied = $false
        }
        return
    }

    if ($bumpLabels.Count -gt 1) {
        throw "Conflicting release bump labels: [$($bumpLabels -join ', ')]. Apply exactly one bump label."
    }

    $defaultBumpApplied = $bumpLabels.Count -eq 0
    $bump = if ($defaultBumpApplied) {
        $resolvedDefaultBump
    } else {
        $bumpLabelTypes[$bumpLabels[0]]
    }

    [PSCustomObject]@{
        Bump               = $bump
        Prerelease         = $hasPrerelease
        Skip               = $false
        DefaultBumpApplied = $defaultBumpApplied
    }
}

function Resolve-PullRequestReleaseContext {
    <#
        .SYNOPSIS
        Resolve branch-derived naming and the immutable target for a pull request.

        .DESCRIPTION
        Keep the pull-request head branch for prerelease naming while selecting
        the exact head commit SHA as the release target.

        .EXAMPLE
        $pullRequest = [PSCustomObject]@{
            head = [PSCustomObject]@{
                ref = 'feature/example'
                sha = '0123456789012345678901234567890123456789'
            }
        }
        Resolve-PullRequestReleaseContext -PullRequest $pullRequest

        Return a prerelease name of featureexample and the supplied commit SHA as
        the prerelease target.

        .INPUTS
        None

        You can't pipe objects to Resolve-PullRequestReleaseContext.

        .OUTPUTS
        System.Management.Automation.PSCustomObject

        The validated pull-request release context.
    #>
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param(
        # The pull request from the GitHub event payload.
        [Parameter(Mandatory)]
        [PSCustomObject] $PullRequest
    )

    $headRef = [string] $PullRequest.head.ref
    $headSha = [string] $PullRequest.head.sha

    if ([string]::IsNullOrWhiteSpace($headRef)) {
        throw 'Pull request head ref is required.'
    }
    if ([string]::IsNullOrWhiteSpace($headSha)) {
        throw 'Pull request head SHA is required.'
    }

    $prereleaseName = $headRef -replace '[^a-zA-Z0-9]'
    if ([string]::IsNullOrWhiteSpace($prereleaseName)) {
        throw "Pull request head ref [$headRef] does not contain a valid prerelease identifier."
    }

    [PSCustomObject]@{
        HeadRef          = $headRef
        PrereleaseName   = $prereleaseName
        PrereleaseTarget = $headSha
    }
}

function Test-PrereleaseCreation {
    <#
        .SYNOPSIS
        Test whether the current pull-request event may create a prerelease.

        .DESCRIPTION
        Return true only when a validated release decision requests a prerelease
        and the pull request remains open.

        .EXAMPLE
        $decision = Resolve-ReleaseDecision -Labels @('release:patch', 'release:prerelease')
        Test-PrereleaseCreation -ReleaseDecision $decision

        Return true for an open pull request carrying a valid prerelease decision.

        .EXAMPLE
        $decision = Resolve-ReleaseDecision -Labels @('release:patch', 'release:prerelease')
        Test-PrereleaseCreation -ReleaseDecision $decision -PullRequestClosed

        Return false after the pull request closes.

        .INPUTS
        None

        You can't pipe objects to Test-PrereleaseCreation.

        .OUTPUTS
        System.Boolean

        Whether the event may create a prerelease.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        # The validated canonical release decision.
        [Parameter(Mandatory)]
        [PSCustomObject] $ReleaseDecision,

        # Indicate that the pull request is closed, whether merged or abandoned.
        [Parameter()]
        [switch] $PullRequestClosed
    )

    $ReleaseDecision.Prerelease -and -not $ReleaseDecision.Skip -and -not $PullRequestClosed
}

Export-ModuleMember -Function @(
    'ConvertTo-ReleaseBump'
    'Get-ReleaseLabelDefinition'
    'Resolve-ReleaseDecision'
    'Resolve-PullRequestReleaseContext'
    'Test-PrereleaseCreation'
)
