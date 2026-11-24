$ErrorActionPreference = 'Stop'

$resourceGetModule = Import-Module -Name Microsoft.PowerShell.PSResourceGet -PassThru
$versioningPath = Join-Path -Path $resourceGetModule.ModuleBase -ChildPath 'dependencies\NuGet.Versioning.dll'
$script:versionRangeType = [Reflection.Assembly]::LoadFrom($versioningPath).GetType('NuGet.Versioning.VersionRange', $true)

function Get-ReleaseSettingSchema {
    <#
        .SYNOPSIS
        Read the private setting schema from the action's own metadata.

        .DESCRIPTION
        Require one complete schema for the named settings. Keep the file
        selector separate from the setting types, standards, and destinations.

        .EXAMPLE
        Get-ReleaseSettingSchema -Path $actionPath

        Return the action's validated setting definitions.

        .INPUTS
        None

        You can't pipe objects to Get-ReleaseSettingSchema.

        .OUTPUTS
        System.Collections.IDictionary

        The private setting definitions.
    #>
    [OutputType([System.Collections.IDictionary])]
    [CmdletBinding()]
    param(
        # The full path to the action's own metadata.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path
    )

    $actionDefinition = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($Path))
    $metadataYaml = $actionDefinition.runs.steps[0].env.PSMODULE_AUTO_RELEASE_SETTING_METADATA
    if ($metadataYaml -isnot [string] -or [string]::IsNullOrWhiteSpace($metadataYaml)) {
        throw 'The action release standards must be a nonempty YAML mapping.'
    }
    $metadata = ConvertFrom-Yaml -Yaml $metadataYaml -Ordered
    if ($metadata -isnot [System.Collections.IDictionary]) {
        throw 'The action release standards must be a mapping of setting definitions.'
    }
    $settingNames = @($actionDefinition.inputs.Keys | Where-Object { $_ -ne 'SettingsFilePath' })
    foreach ($name in $settingNames) {
        if ($metadata.Keys -notcontains $name) {
            throw "Release standard defaults are missing required setting [$name]."
        }
    }
    foreach ($name in $metadata.Keys) {
        if ($settingNames -notcontains $name) {
            throw "Unsupported release setting [$name] in the action metadata."
        }
        $definition = $metadata[$name]
        if ($definition -isnot [System.Collections.IDictionary] -or
            $definition.Keys -notcontains 'Default' -or $definition.Keys -notcontains 'Type' -or
            $definition.Keys -notcontains 'Phase' -or $definition.Count -ne 3) {
            throw "Invalid metadata for release setting [$name]. Supply Type, Default, and Phase."
        }
        if (@('Boolean', 'Text', 'Bump', 'DateTimeFormat', 'VersionConstraint', 'DirectoryPath') -cnotcontains $definition.Type) {
            throw "Invalid metadata type for release setting [$name]."
        }
        if (@('Startup', 'Release') -cnotcontains $definition.Phase) {
            throw "Invalid metadata phase for release setting [$name]. Use Startup or Release."
        }
    }
    $metadata
}

function Resolve-ReleaseFileSystemPath {
    <#
        .SYNOPSIS
        Resolve a literal file-system path from a known directory.

        .DESCRIPTION
        Resolve relative paths without using the process's current directory.
        Reject non-file-system providers and invalid path characters.

        .EXAMPLE
        Resolve-ReleaseFileSystemPath -Name 'SettingsFilePath' -Path '.github\auto-release.yml' -BaseDirectory $workspace

        Return the selected absolute file-system path.

        .INPUTS
        None

        You can't pipe objects to Resolve-ReleaseFileSystemPath.

        .OUTPUTS
        System.String

        The absolute literal path.
    #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        # The setting name used in path diagnostics.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        # The literal path to resolve.
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path,

        # The absolute directory for relative paths.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $BaseDirectory
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Name must be a nonempty path."
    }
    $candidate = $Path
    if (-not [IO.Path]::IsPathRooted($Path) -and $Path -notmatch '\A[^\\/]+:') {
        $candidate = Join-Path -Path $BaseDirectory -ChildPath $Path
    }
    $provider = $null
    $drive = $null
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath(
        $candidate, [ref] $provider, [ref] $drive
    )
    if ($provider.Name -ne 'FileSystem') {
        throw "$Name must use a FileSystem path."
    }
    $fullPath = [IO.Path]::GetFullPath($fullPath)
    $relativePart = $fullPath.Substring([IO.Path]::GetPathRoot($fullPath).Length)
    foreach ($part in $relativePart -split '[\\/]') {
        if ($part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
            throw "$Name must use a valid FileSystem path."
        }
    }
    $fullPath
}

function ConvertTo-ReleaseSettingValue {
    <#
        .SYNOPSIS
        Validate and convert one supplied release-setting value.

        .DESCRIPTION
        Use the private schema type to validate text, booleans, bumps, date
        formats, dependency versions, and execution directories.

        .EXAMPLE
        ConvertTo-ReleaseSettingValue -Name 'AutoCleanup' -Type Boolean -Value 'false' -WorkspacePath $workspace

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

        # The type supplied by the action's private schema.
        [Parameter(Mandatory)]
        [ValidateSet('Boolean', 'Text', 'Bump', 'DateTimeFormat', 'VersionConstraint', 'DirectoryPath')]
        [string] $Type,

        # The supplied value, including null so invalid values can be diagnosed.
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [object] $Value,

        # The known workspace for relative execution-directory values.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspacePath
    )

    if ($Type -eq 'Boolean') {
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
    if ($Type -eq 'Bump') {
        $null = ConvertTo-ReleaseBump -DefaultBump $Value
    }
    if ($Type -eq 'DateTimeFormat' -and -not [string]::IsNullOrEmpty($Value)) {
        try {
            $null = [datetime]::new(2000, 1, 1).ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
        } catch [FormatException] {
            throw 'Invalid DatePrereleaseFormat. Use a valid .NET date and time format string.'
        }
    }
    if ($Type -eq 'VersionConstraint' -and -not [string]::IsNullOrEmpty($Value)) {
        $versionRange = $null
        if (-not $script:versionRangeType::TryParse($Value, [ref] $versionRange)) {
            throw "Invalid release setting [$Name]. Use an exact dependency version or a NuGet version range."
        }
    }
    if ($Type -eq 'DirectoryPath') {
        $pathParameters = @{
            Name          = $Name
            Path          = $Value
            BaseDirectory = $WorkspacePath
        }
        $Value = Resolve-ReleaseFileSystemPath @pathParameters
        if (-not (Test-Path -LiteralPath $Value -PathType Container)) {
            throw "Invalid release setting [$Name]. Use an existing directory."
        }
    }
    $Value
}

function Resolve-ReleaseConfiguration {
    <#
        .SYNOPSIS
        Resolve validated release settings from action standards and inputs.

        .DESCRIPTION
        Apply repository settings over the private schema standards, then
        nonempty named action inputs. Validate every supplied layer so invalid
        values cannot be masked. Preserve explicit false and file empty text
        values, and record the effective default-bump source.

        .EXAMPLE
        $parameters = @{
            Metadata      = $settingMetadata
            WorkspacePath = $workspace
            Configuration = @{ DefaultBump = 'major' }
            Inputs        = @{ DefaultBump = 'minor' }
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
        # Types and standards parsed from the action's private metadata declaration.
        [Parameter(Mandatory)]
        [System.Collections.IDictionary] $Metadata,

        # The known workspace for all relative WorkingDirectory values.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WorkspacePath,

        # Named runtime inputs; null and empty strings do not override file policy.
        [Parameter()]
        [AllowNull()]
        [System.Collections.IDictionary] $Inputs,

        # The parsed configuration file, which must be a mapping when supplied.
        [Parameter()]
        [AllowNull()]
        [object] $Configuration
    )

    if ($null -ne $Configuration -and $Configuration -isnot [System.Collections.IDictionary]) {
        throw 'Release configuration must be a mapping of supported settings.'
    }
    $defaults = [ordered]@{}
    foreach ($name in $Metadata.Keys) {
        $defaults[$name] = $Metadata[$name].Default
    }
    $retiredSettings = @('AutoPatching', 'IgnoreLabels', 'MajorLabels', 'MinorLabels', 'PatchLabels')
    $layers = @(
        [PSCustomObject]@{ Source = 'SharedDefault'; Values = $defaults }
        [PSCustomObject]@{ Source = 'RepositorySetting'; Values = $Configuration }
        [PSCustomObject]@{ Source = 'ActionInput'; Values = $Inputs }
    )
    $settings = [ordered]@{}
    $defaultBumpSource = 'SharedDefault'
    foreach ($layer in $layers) {
        if ($null -eq $layer.Values) {
            continue
        }
        foreach ($name in $layer.Values.Keys) {
            if ($retiredSettings -contains $name) {
                throw "Release setting [$name] was removed. Use DefaultBump and the release: labels defined by this action."
            }
            if ($Metadata.Keys -notcontains $name) {
                throw "Unsupported release setting [$name]. Use the documented release settings."
            }
            $value = $layer.Values[$name]
            $isEmpty = $null -eq $value -or ($value -is [string] -and $value.Length -eq 0)
            if ($layer.Source -eq 'ActionInput' -and $isEmpty) {
                continue
            }
            $valueParameters = @{
                Name          = $name
                Type          = $Metadata[$name].Type
                Value         = $value
                WorkspacePath = $WorkspacePath
            }
            $settings[$name] = ConvertTo-ReleaseSettingValue @valueParameters
            if ($name -eq 'DefaultBump') {
                $defaultBumpSource = $layer.Source
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
        Return the namespaced release labels that Release-GHRepository manages.

        .DESCRIPTION
        Return the name, color, and description for each supported release label.

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
        Select only releases marked as prereleases whose effective prefix is
        followed by a valid version core and the exact case-sensitive identifier.
        Retain releases under other historical prefixes. The identifier must
        end the tag or be followed by a dot; later hyphens never select it.

        .EXAMPLE
        Get-PrereleaseCleanupCandidate -Releases $releases -PrereleaseName 'feature123' -VersionPrefix 'v'

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
        [string] $PrereleaseName,

        # The effective prefix that locates the actual version boundary.
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $VersionPrefix
    )

    $escapedPrereleaseName = [regex]::Escape($PrereleaseName)
    $identifierPattern = "\A$escapedPrereleaseName(?:\.|\z)"
    $versionPattern = '\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-'

    $Releases | Where-Object {
        if ($_.isPrerelease -ne $true) {
            return $false
        }
        $tagName = [string] $_.tagName
        if (-not $tagName.StartsWith($VersionPrefix, [StringComparison]::Ordinal)) {
            return $false
        }
        $versionTag = $tagName.Substring($VersionPrefix.Length)
        $separator = [regex]::Match($versionTag, $versionPattern)
        if (-not $separator.Success) {
            return $false
        }
        $identifier = $versionTag.Substring($separator.Length)
        $identifier -cmatch $identifierPattern
    }
}

function ConvertTo-ReleaseBump {
    <#
        .SYNOPSIS
        Convert a configured default bump into the internal release-bump value.

        .DESCRIPTION
        Validate DefaultBump with case-sensitive matching and return the
        corresponding internal Patch, Minor, or Major value. Require the
        configured value rather than choosing a policy default.

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
        # The validated effective bump supplied by the settings resolver.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $DefaultBump
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
        Evaluate only the five namespaced release labels that the action defines.
        An explicit bump label overrides DefaultBump. The release:prerelease label
        selects prerelease mode. The release:skip label prevents publication.
        Reject conflicting release labels. Require the validated effective
        DefaultBump instead of loading standards or choosing a policy.

        .EXAMPLE
        Resolve-ReleaseDecision -Labels @('release:minor') -DefaultBump 'major'

        Return a Minor stable-release decision.

        .EXAMPLE
        Resolve-ReleaseDecision -Labels @('release:patch', 'release:prerelease') -DefaultBump 'minor'

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

        # The validated effective bump supplied by the settings resolver.
        [Parameter()]
        [AllowNull()]
        [AllowEmptyString()]
        [string] $DefaultBump,

        # The validated settings layer that supplies the effective default.
        [Parameter()]
        [ValidateSet('SharedDefault', 'ActionInput', 'RepositorySetting')]
        [string] $DefaultBumpSource = 'SharedDefault'
    )

    $resolvedDefaultBump = ConvertTo-ReleaseBump -DefaultBump $DefaultBump
    $bumpLabelTypes = [ordered]@{
        'release:patch' = 'Patch'
        'release:minor' = 'Minor'
        'release:major' = 'Major'
    }
    $supportedLabelNames = @($bumpLabelTypes.Keys) + @('release:prerelease', 'release:skip')
    $appliedReleaseLabels = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    foreach ($label in $Labels) {
        if ($supportedLabelNames -ccontains $label) {
            $null = $appliedReleaseLabels.Add($label)
        }
    }

    $hasSkip = $appliedReleaseLabels.Contains('release:skip')
    $hasPrerelease = $appliedReleaseLabels.Contains('release:prerelease')
    $bumpLabels = @($bumpLabelTypes.Keys | Where-Object { $appliedReleaseLabels.Contains($_) })

    if ($hasSkip) {
        if ($appliedReleaseLabels.Count -ne 1) {
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
        $decision = Resolve-ReleaseDecision -Labels @('release:patch', 'release:prerelease') -DefaultBump 'minor'
        Test-PrereleaseCreation -ReleaseDecision $decision

        Return true for an open pull request carrying a valid prerelease decision.

        .EXAMPLE
        $decision = Resolve-ReleaseDecision -Labels @('release:patch', 'release:prerelease') -DefaultBump 'minor'
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
    'ConvertTo-ReleaseSettingValue'
    'Get-PrereleaseCleanupCandidate'
    'Get-ReleaseLabelDefinition'
    'Get-ReleaseSettingSchema'
    'Resolve-ReleaseDecision'
    'Resolve-ReleaseConfiguration'
    'Resolve-ReleaseFileSystemPath'
    'Resolve-PullRequestReleaseContext'
    'Test-PrereleaseCreation'
)
