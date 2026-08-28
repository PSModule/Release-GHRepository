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
        Name        = 'release:pre-release'
        Color       = '8d7bdf'
        Description = 'Publish a prerelease from this open pull request.'
    }
    [PSCustomObject]@{
        Name        = 'release:skip'
        Color       = 'ededed'
        Description = 'Validate this change without publishing a release.'
    }
}

function Resolve-ReleaseDecision {
    <#
        .SYNOPSIS
        Resolve a release decision from canonical pull-request labels.

        .DESCRIPTION
        Evaluate only the five labels owned by Release-GHRepository. Return one
        explicit bump or skip decision and reject missing or conflicting owned-label
        combinations without applying a default.

        .EXAMPLE
        Resolve-ReleaseDecision -Labels @('release:minor')

        Return a Minor stable-release decision.

        .EXAMPLE
        Resolve-ReleaseDecision -Labels @('release:patch', 'release:pre-release')

        Return a Patch prerelease decision.

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
        [string[]] $Labels
    )

    $bumpLabelTypes = [ordered]@{
        'release:patch' = 'Patch'
        'release:minor' = 'Minor'
        'release:major' = 'Major'
    }
    $ownedLabelNames = @($bumpLabelTypes.Keys) + @('release:pre-release', 'release:skip')
    $ownedLabels = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    foreach ($label in $Labels) {
        if ($ownedLabelNames -ccontains $label) {
            $null = $ownedLabels.Add($label)
        }
    }

    $hasSkip = $ownedLabels.Contains('release:skip')
    $hasPrerelease = $ownedLabels.Contains('release:pre-release')
    $bumpLabels = @($bumpLabelTypes.Keys | Where-Object { $ownedLabels.Contains($_) })

    if ($hasSkip) {
        if ($ownedLabels.Count -ne 1) {
            throw 'Invalid release labels: release:skip must not be combined with another release label.'
        }

        [PSCustomObject]@{
            Bump       = 'None'
            Prerelease = $false
            Skip       = $true
        }
        return
    }

    if ($bumpLabels.Count -eq 0) {
        if ($hasPrerelease) {
            throw 'Invalid release labels: release:pre-release requires exactly one release bump label.'
        }

        throw (
            'Release decision is missing. Apply exactly one of release:patch, release:minor, ' +
            'release:major, or release:skip.'
        )
    }

    if ($bumpLabels.Count -gt 1) {
        throw "Conflicting release bump labels: [$($bumpLabels -join ', ')]. Apply exactly one bump label."
    }

    [PSCustomObject]@{
        Bump       = $bumpLabelTypes[$bumpLabels[0]]
        Prerelease = $hasPrerelease
        Skip       = $false
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
        $decision = Resolve-ReleaseDecision -Labels @('release:patch', 'release:pre-release')
        Test-PrereleaseCreation -ReleaseDecision $decision

        Return true for an open pull request carrying a valid prerelease decision.

        .EXAMPLE
        $decision = Resolve-ReleaseDecision -Labels @('release:patch', 'release:pre-release')
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

Export-ModuleMember -Function Get-ReleaseLabelDefinition, Resolve-ReleaseDecision, Test-PrereleaseCreation
