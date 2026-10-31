$ErrorActionPreference = 'Stop'

function ConvertTo-ReleaseSettingValue {
    <#
        .SYNOPSIS
        Validate and convert one supplied release-setting value.

        .DESCRIPTION
        Preserve valid text values, normalize booleans, and validate default
        bumps and prerelease date formats before settings are combined.

        .EXAMPLE
        ConvertTo-ReleaseSettingValue -Name 'AutoCleanup' -Value 'false'

        Return the Boolean false value.

        .INPUTS
        None

        You can't pipe objects to ConvertTo-ReleaseSettingValue.

        .OUTPUTS
        System.Boolean

        A validated Boolean setting.

        .OUTPUTS
        System.String

        A validated text setting.
    #>
    [OutputType([bool], [string])]
    [CmdletBinding()]
    param(
        # The supported release-setting name.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        # The supplied value, including null so invalid values can be diagnosed.
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value
    )

    $booleanSettings = @(
        'AutoCleanup'
        'CreateMajorTag'
        'CreateMinorTag'
        'IncrementalPrerelease'
        'UsePRTitleAsReleaseName'
        'UsePRBodyAsReleaseNotes'
        'UsePRTitleAsNotesHeading'
        'WhatIf'
    )
    if ($booleanSettings -contains $Name) {
        if ($Value -is [bool]) {
            $Value
        } elseif ($Value -is [string] -and @('true', 'false') -contains $Value) {
            $Value -eq 'true'
        } else {
            throw "Invalid release setting [$Name]. Use true or false."
        }
        return
    }
    if ($Value -isnot [string]) {
        throw "Invalid release setting [$Name]. Use a string value."
    }
    if ($Name -eq 'DefaultBump') {
        $null = ConvertTo-ReleaseBump -DefaultBump $Value
    }
    if ($Name -eq 'DatePrereleaseFormat' -and -not [string]::IsNullOrEmpty($Value)) {
        try {
            $null = [datetime]::new(2000, 1, 1).ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
        } catch [FormatException] {
            throw 'Invalid DatePrereleaseFormat. Use a valid .NET date and time format string.'
        }
    }
    $Value
}

function Resolve-ReleaseConfiguration {
    <#
        .SYNOPSIS
        Resolve validated release settings from interface defaults and overrides.

        .DESCRIPTION
        Apply scalar action inputs over defaults declared in action.yml, then
        repository settings, then explicit CallerOverrides. Validate every
        supplied layer so invalid values cannot be masked. Preserve false and
        empty text overrides and record the effective default-bump source.

        .EXAMPLE
        $parameters = @{
            Defaults        = $actionDefaults
            Configuration   = @{ DefaultBump = 'major' }
            CallerOverrides = @{ DefaultBump = 'minor' }
        }
        Resolve-ReleaseConfiguration @parameters

        Return the effective release settings with DefaultBump set to minor.

        .INPUTS
        None

        You can't pipe objects to Resolve-ReleaseConfiguration.

        .OUTPUTS
        System.Management.Automation.PSCustomObject

        The validated effective release settings.
    #>
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param(
        # The controller input defaults from action.yml.
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Defaults,

        # The action inputs explicitly supplied by the runtime.
        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Inputs,

        # The parsed configuration file, which must be a mapping when supplied.
        [Parameter()]
        [AllowNull()]
        [object] $Configuration,

        # Explicit invocation overrides, distinct from injected scalar defaults.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $CallerOverrides
    )

    if ($null -ne $Configuration -and $Configuration -isnot [System.Collections.IDictionary]) {
        throw 'Release configuration must be a mapping of supported settings.'
    }
    if ($PSBoundParameters.ContainsKey('CallerOverrides') -and $CallerOverrides -isnot [System.Collections.IDictionary]) {
        throw 'CallerOverrides must be a mapping of supported release settings.'
    }

    $retiredSettings = @('AutoPatching', 'IgnoreLabels', 'MajorLabels', 'MinorLabels', 'PatchLabels')
    $layers = @(
        [PSCustomObject]@{ Source = 'SharedDefault'; Values = $Defaults }
        [PSCustomObject]@{ Source = 'ActionInput'; Values = $Inputs }
        [PSCustomObject]@{ Source = 'RepositorySetting'; Values = $Configuration }
        [PSCustomObject]@{ Source = 'CallerOverride'; Values = $CallerOverrides }
    )
    $settings = [ordered]@{}
    $defaultBumpSource = 'SharedDefault'
    foreach ($layer in $layers) {
        if ($null -eq $layer.Values) {
            continue
        }
        foreach ($name in $layer.Values.Keys) {
            if ($retiredSettings -contains $name) {
                throw "Release setting [$name] was removed. Use DefaultBump and the owned release: labels."
            }
            if ($Defaults.Keys -notcontains $name) {
                throw "Unsupported release setting [$name]. Use the settings documented in action.yml."
            }
            $settings[$name] = ConvertTo-ReleaseSettingValue -Name $name -Value $layer.Values[$name]
            if ($name -eq 'DefaultBump') {
                $defaultBumpSource = $layer.Source
                if ($layer.Source -eq 'ActionInput' -and $layer.Values[$name] -ceq $Defaults[$name]) {
                    $defaultBumpSource = 'SharedDefault'
                }
            }
        }
    }

    $null = ConvertTo-ReleaseBump -DefaultBump $settings.DefaultBump
    $settings.DefaultBumpSource = $defaultBumpSource
    [PSCustomObject] $settings
}

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

function Get-PrereleaseCleanupCandidate {
    <#
        .SYNOPSIS
        Return prereleases that belong to a pull-request prerelease identifier.

        .DESCRIPTION
        Select only releases marked as prereleases whose tag contains the exact
        prerelease identifier immediately after the SemVer hyphen. The identifier
        must end the tag or be followed by a dot.

        .EXAMPLE
        Get-PrereleaseCleanupCandidate -Releases $releases -PrereleaseName 'feature123'

        Return prereleases tagged with -feature123 or -feature123.<suffix>.

        .INPUTS
        None

        You can't pipe objects to Get-PrereleaseCleanupCandidate.

        .OUTPUTS
        System.Management.Automation.PSCustomObject

        A prerelease that belongs to the requested identifier.
    #>
    [OutputType([PSCustomObject])]
    [CmdletBinding()]
    param(
        # The GitHub release records to inspect.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [AllowNull()]
        [PSCustomObject[]] $Releases,

        # The normalized pull-request prerelease identifier.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $PrereleaseName
    )

    $escapedPrereleaseName = [regex]::Escape($PrereleaseName)
    $tagPattern = "-$escapedPrereleaseName(?:\.|$)"

    $Releases | Where-Object {
        $_.isPrerelease -eq $true -and
        [string] $_.tagName -match $tagPattern
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
        [string] $DefaultBump = 'patch',

        # The validated settings layer that supplies the effective default.
        [Parameter()]
        [ValidateSet('SharedDefault', 'ActionInput', 'RepositorySetting', 'CallerOverride')]
        [string] $DefaultBumpSource = 'SharedDefault'
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
            BumpSource         = 'release:skip'
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
        BumpSource         = if ($defaultBumpApplied) { $DefaultBumpSource } else { $bumpLabels[0] }
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
        [PSCustomObject] $PullRequest,

        # Permit non-prerelease contexts whose branch cannot name a prerelease.
        [Parameter()]
        [switch] $AllowEmptyPrereleaseName
    )

    $headRef = [string] $PullRequest.head.ref
    $headSha = [string] $PullRequest.head.sha

    if ([string]::IsNullOrWhiteSpace($headRef)) {
        throw 'Pull request head ref is required.'
    }
    if ([string]::IsNullOrWhiteSpace($headSha)) {
        throw 'Pull request head SHA is required.'
    }
    if ($headSha -notmatch '\A[0-9a-fA-F]{40}\z') {
        throw 'Pull request head SHA must be a 40-character hexadecimal commit.'
    }

    $prereleaseName = $headRef -replace '[^a-zA-Z0-9]'
    if ([string]::IsNullOrWhiteSpace($prereleaseName) -and -not $AllowEmptyPrereleaseName) {
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
    'Get-PrereleaseCleanupCandidate'
    'Get-ReleaseLabelDefinition'
    'Resolve-ReleaseDecision'
    'Resolve-ReleaseConfiguration'
    'Resolve-PullRequestReleaseContext'
    'Test-PrereleaseCreation'
)
