#Requires -Version 7.0

$ErrorActionPreference = 'Stop'

function Import-VerifiedReleaseModule {
    <#
        .SYNOPSIS
        Verify a package before extracting and importing its module.

        .DESCRIPTION
        Check the package SHA256 and module version. Import the verified manifest by path,
        so a same-name module elsewhere on the runner cannot replace it.

        .EXAMPLE
        Import-VerifiedReleaseModule -Path $package -DestinationPath $directory -Name $name -RequiredVersion $version -SHA256 $hash

        .INPUTS
        None

        You can't pipe objects to Import-VerifiedReleaseModule.

        .OUTPUTS
        System.Management.Automation.PSModuleInfo

        The imported module.
    #>
    [OutputType([System.Management.Automation.PSModuleInfo])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # The downloaded package.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Path,

        # A new directory for the verified module files.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript({ [System.IO.Path]::IsPathFullyQualified($_) })]
        [string] $DestinationPath,

        # The module name declared in the dependency lock.
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_.-]+$')]
        [string] $Name,

        # The exact reviewed module version.
        [Parameter(Mandatory)]
        [version] $RequiredVersion,

        # The reviewed package digest.
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Fa-f0-9]{64}$')]
        [string] $SHA256
    )

    $packagePath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $actualHash = (Get-FileHash -LiteralPath $packagePath -Algorithm SHA256 -ErrorAction Stop).Hash
    if ($actualHash -ne $SHA256) {
        throw "SHA256 verification failed for [$Name $RequiredVersion]. Do not import this package."
    }
    if (Test-Path -LiteralPath $DestinationPath) {
        throw "The verified module directory already exists: [$DestinationPath]. Use a new directory."
    }

    if ($PSCmdlet.ShouldProcess("$Name $RequiredVersion", 'Import verified module')) {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $DestinationPath)
        $manifestPath = Join-Path $DestinationPath "$Name.psd1"
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath -ErrorAction Stop
        if ([version] $manifest.ModuleVersion -ne $RequiredVersion) {
            throw "The package does not contain [$Name] at the required version [$RequiredVersion]."
        }

        $moduleSpecification = @{
            ModuleName      = $manifestPath
            RequiredVersion = $RequiredVersion
        }
        Get-Module -Name $Name | Remove-Module -Force -ErrorAction Stop
        Import-Module -FullyQualifiedName $moduleSpecification -Global -Force -PassThru -ErrorAction Stop
    }
}

function Assert-ReleasePullRequest {
    <#
        .SYNOPSIS
        Validate PR metadata before privileged publication.

        .DESCRIPTION
        Require a same-repository PR targeting the default branch.
        Compare the event with live PR metadata before publishing its immutable commit.

        .EXAMPLE
        Assert-ReleasePullRequest -PullRequest $eventPr -CurrentPullRequest $livePr -Repository 'owner/repo' -DefaultBranch 'main'

        .INPUTS
        None

        You can't pipe objects to Assert-ReleasePullRequest.

        .OUTPUTS
        None

        This function throws when the publication metadata is invalid.
    #>
    [OutputType([void])]
    [CmdletBinding()]
    param(
        # The PR metadata from the pull_request event.
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject] $PullRequest,

        # The current PR returned by the repository API.
        [Parameter(Mandatory)]
        [ValidateNotNull()]
        [pscustomobject] $CurrentPullRequest,

        # The repository that owns the publishing workflow.
        [Parameter(Mandatory)]
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string] $Repository,

        # The repository's default branch.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $DefaultBranch
    )

    if ($PullRequest.base.repo.full_name -ne $Repository -or $CurrentPullRequest.base.repo.full_name -ne $Repository) {
        throw "Publication metadata does not belong to repository [$Repository]."
    }
    if ($PullRequest.head.repo.full_name -ne $Repository -or $CurrentPullRequest.head.repo.full_name -ne $Repository) {
        throw 'Publication requires a same-repository pull request. Fork tokens are read-only.'
    }
    if ($PullRequest.number -lt 1 -or $CurrentPullRequest.number -ne $PullRequest.number) {
        throw 'Publication metadata does not match the pull request.'
    }
    if ($PullRequest.base.ref -ne $DefaultBranch) {
        throw "Publication requires a pull request targeting the default branch [$DefaultBranch]."
    }
    if (-not $PullRequest.merged -and $PullRequest.head.repo.full_name -ne $Repository) {
        throw 'Open-PR prereleases require a branch in this repository.'
    }
    if ($PullRequest.head.sha -cnotmatch '^[a-f0-9]{40}$' -or
        ($PullRequest.merged -and $PullRequest.merge_commit_sha -cnotmatch '^[a-f0-9]{40}$')) {
        throw 'Publication requires a valid commit SHA.'
    }
    if ($CurrentPullRequest.head.sha -cne $PullRequest.head.sha -or
        $CurrentPullRequest.base.ref -ne $PullRequest.base.ref -or
        $CurrentPullRequest.state -ne $PullRequest.state -or
        $CurrentPullRequest.merged -ne $PullRequest.merged -or
        ($PullRequest.merged -and $CurrentPullRequest.merge_commit_sha -cne $PullRequest.merge_commit_sha)) {
        throw 'The pull request changed since this event. Run publication for the current PR state.'
    }
}

function Test-ReleasePreview {
    <#
        .SYNOPSIS
        Select preview mode without allowing configuration to override the caller.

        .DESCRIPTION
        Honor an explicit preview request or configuration setting.
        Permit publication only for regular pull_request events.

        .EXAMPLE
        Test-ReleasePreview -EventName 'pull_request' -Configured

        .INPUTS
        None

        You can't pipe objects to Test-ReleasePreview.

        .OUTPUTS
        System.Boolean

        True when release changes must be simulated.
    #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        # The GitHub Actions event name.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $EventName,

        # An explicit WhatIf input from the caller.
        [Parameter()]
        [switch] $Requested,

        # The WhatIf setting from the trusted configuration.
        [Parameter()]
        [switch] $Configured
    )

    if ($Requested -or $Configured) {
        $true
    } elseif ($EventName -eq 'pull_request') {
        $false
    } else {
        throw 'Write operations require a regular pull_request event. Use WhatIf for other events.'
    }
}

function Get-ReleasePrerelease {
    <#
        .SYNOPSIS
        Select only prereleases in one PR's tag namespace.

        .DESCRIPTION
        Exclude stable releases and tags for other PRs before cleanup or replacement.

        .EXAMPLE
        Get-ReleasePrerelease -Release $releases -PullRequestNumber 7 -VersionPrefix 'v'

        .INPUTS
        None

        You can't pipe objects to Get-ReleasePrerelease.

        .OUTPUTS
        System.Management.Automation.PSCustomObject

        The matching prerelease records.
    #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        # Release records returned by the repository API.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [pscustomobject[]] $Release,

        # The PR that owns these prerelease tags.
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $PullRequestNumber,

        # The configured prefix, including an empty prefix.
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $VersionPrefix
    )

    $pattern = '^{0}[0-9]+\.[0-9]+\.[0-9]+-pr{1}(?:\.[0-9A-Za-z-]+)*(?:\+[0-9A-Za-z.-]+)?$' -f
    [regex]::Escape($VersionPrefix), $PullRequestNumber
    $Release | Where-Object { $_.isPrerelease -eq $true -and $_.tagName -cmatch $pattern }
}

function Set-ReleaseTag {
    <#
        .SYNOPSIS
        Point one release tag at its immutable release commit.

        .DESCRIPTION
        Create or update only the requested tag through the repository API.
        Do not persist Git credentials or push unrelated local tags.

        .EXAMPLE
        Set-ReleaseTag -Repository 'owner/repo' -Name 'v1' -CommitSha $releaseCommit

        .INPUTS
        None

        You can't pipe objects to Set-ReleaseTag.

        .OUTPUTS
        None

        This function updates the repository tag.
    #>
    [OutputType([void])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        # The repository that owns the release.
        [Parameter(Mandatory)]
        [ValidatePattern('^[^/]+/[^/]+$')]
        [string] $Repository,

        # The release tag to create or update.
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $Name,

        # The stable release's merge commit.
        [Parameter(Mandatory)]
        [ValidatePattern('^[a-f0-9]{40}$')]
        [string] $CommitSha
    )

    git check-ref-format "refs/tags/$Name"
    if ($LASTEXITCODE -ne 0) {
        throw "Invalid release tag name: [$Name]."
    }
    if ($PSCmdlet.ShouldProcess("$Repository tag $Name", "Point tag at $CommitSha")) {
        $encodedName = [uri]::EscapeDataString($Name)
        $referencesJson = gh api "repos/$Repository/git/matching-refs/tags/$encodedName"
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to list tag references for [$Name]."
        }
        $references = $referencesJson | ConvertFrom-Json -NoEnumerate
        if ($references -isnot [array]) {
            throw "Failed to list tag references for [$Name]: the API response is not an array."
        }
        $reference = $references | Where-Object { $_.ref -ceq "refs/tags/$Name" }
        if ($reference) {
            $arguments = @(
                'api', '--method', 'PATCH', "repos/$Repository/git/refs/tags/$encodedName",
                '-f', "sha=$CommitSha", '-F', 'force=true'
            )
        } else {
            $arguments = @(
                'api', '--method', 'POST', "repos/$Repository/git/refs",
                '-f', "ref=refs/tags/$Name", '-f', "sha=$CommitSha"
            )
        }
        $null = gh @arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set release tag [$Name] to [$CommitSha]."
        }
    }
}

Export-ModuleMember -Function Import-VerifiedReleaseModule, Assert-ReleasePullRequest, Test-ReleasePreview, Get-ReleasePrerelease, Set-ReleaseTag
