[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Variables are assigned in BeforeAll and used inside It blocks.'
)]
[CmdletBinding()]
param()

BeforeAll {
    Import-Module -Name powershell-yaml
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '../src/Release-GHRepository.Helpers.psm1'
    Import-Module -Name $modulePath -Force
    $actionPath = Join-Path -Path $PSScriptRoot -ChildPath '..\action.yml'
    $actionDefinition = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $actionPath -Raw)
    $standardSettings = ConvertFrom-Yaml -Yaml $actionDefinition.runs.steps[0].env.PSMODULE_AUTO_RELEASE_DEFAULT_SETTINGS -Ordered
}

Describe 'Resolve-ReleaseConfiguration' {
    BeforeAll {
        $resolveConfiguration = @{
            Defaults = $standardSettings
        }
    }

    It 'applies every documented controller default when settings are omitted' {
        $result = Resolve-ReleaseConfiguration @resolveConfiguration
        $expected = [ordered]@{
            AutoCleanup              = $true
            DefaultBump              = 'patch'
            CreateMajorTag           = $true
            CreateMinorTag           = $true
            DatePrereleaseFormat     = ''
            IncrementalPrerelease    = $true
            UsePRTitleAsReleaseName  = $false
            UsePRBodyAsReleaseNotes  = $true
            UsePRTitleAsNotesHeading = $true
            VersionPrefix            = 'v'
            WhatIf                   = $false
        }

        $result.PSObject.Properties.Name | Should -Be (@($expected.Keys) + 'DefaultBumpSource')
        $result.DefaultBumpSource | Should -BeExactly 'SharedDefault'
        foreach ($name in $expected.Keys) {
            $result.$name | Should -Be $expected[$name] -Because "[$name] has a documented default"
            $result.$name.GetType() | Should -Be $expected[$name].GetType()
        }
    }

    It 'uses a caller DefaultBump when the file omits it' {
        $result = Resolve-ReleaseConfiguration @resolveConfiguration -Inputs @{ DefaultBump = 'minor' } -Configuration @{}
        $decision = Resolve-ReleaseDecision -Labels @() -DefaultBump $result.DefaultBump

        $decision.Bump | Should -BeExactly 'Minor'
        $decision.DefaultBumpApplied | Should -BeTrue
    }

    It 'lets named inputs override repository settings without mutating either mapping' {
        $inputs = @{ DefaultBump = 'patch'; AutoCleanup = 'true'; VersionPrefix = 'v' }
        $configuration = [ordered]@{ DefaultBump = 'major'; AutoCleanup = $false; VersionPrefix = '' }

        $result = Resolve-ReleaseConfiguration @resolveConfiguration -Inputs $inputs -Configuration $configuration
        $decision = Resolve-ReleaseDecision -Labels @() -DefaultBump $result.DefaultBump

        $decision.Bump | Should -BeExactly 'Patch'
        $result.DefaultBumpSource | Should -BeExactly 'ActionInput'
        $result.AutoCleanup | Should -BeTrue
        $result.VersionPrefix | Should -BeExactly 'v'
        $inputs.DefaultBump | Should -BeExactly 'patch'
        $inputs.AutoCleanup | Should -BeExactly 'true'
        $configuration.DefaultBump | Should -BeExactly 'major'
        $configuration.AutoCleanup | Should -BeFalse
        $configuration.Count | Should -Be 3
    }

    It 'lets an owned bump override the effective configured default' {
        $result = Resolve-ReleaseConfiguration @resolveConfiguration -Configuration @{ DefaultBump = 'major' }
        $decision = Resolve-ReleaseDecision -Labels @('release:minor') -DefaultBump $result.DefaultBump

        $decision.Bump | Should -BeExactly 'Minor'
        $decision.DefaultBumpApplied | Should -BeFalse
    }

    It 'keeps file text when the named input is empty for <Name>' -ForEach @(
        @{ Name = 'VersionPrefix'; Configured = 'repo-' }
        @{ Name = 'DatePrereleaseFormat'; Configured = 'yyyyMMdd' }
    ) {
        $result = Resolve-ReleaseConfiguration @resolveConfiguration -Inputs @{ $Name = '' } -Configuration @{ $Name = $Configured }

        $result.$Name | Should -BeExactly $Configured
    }

    It 'preserves an empty repository value when the named input is omitted for <Name>' -ForEach @(
        @{ Name = 'VersionPrefix' }
        @{ Name = 'DatePrereleaseFormat' }
    ) {
        $result = Resolve-ReleaseConfiguration @resolveConfiguration -Configuration @{ $Name = '' } -Inputs @{ $Name = '' }

        $result.$Name | Should -BeExactly ''
    }

    It 'accepts boolean values and case-insensitive true/false strings for every boolean setting' {
        $names = @(
            'AutoCleanup'
            'CreateMajorTag'
            'CreateMinorTag'
            'IncrementalPrerelease'
            'UsePRTitleAsReleaseName'
            'UsePRBodyAsReleaseNotes'
            'UsePRTitleAsNotesHeading'
            'WhatIf'
        )

        foreach ($name in $names) {
            foreach ($value in @($true, $false, 'true', 'false', 'TRUE', 'FALSE')) {
                $result = Resolve-ReleaseConfiguration @resolveConfiguration -Configuration @{ $name = $value }

                $result.$name | Should -BeOfType ([bool])
                $result.$name | Should -Be ($value.ToString() -eq 'true')
            }
        }
    }

    It 'rejects invalid boolean setting [<Value>]' -ForEach @(
        @{ Value = '' }
        @{ Value = 'yes' }
        @{ Value = ' true ' }
        @{ Value = 1 }
        @{ Value = $null }
        @{ Value = @('true', 'false') }
    ) {
        { Resolve-ReleaseConfiguration @resolveConfiguration -Configuration @{ WhatIf = $Value } } |
            Should -Throw '*WhatIf*true or false*'
    }

    It 'rejects an explicit invalid DefaultBump [<Value>] instead of selecting patch' -ForEach @(
        @{ Value = '' }
        @{ Value = $null }
        @{ Value = 'Patch' }
        @{ Value = 'date' }
        @{ Value = 'none' }
        @{ Value = 1 }
        @{ Value = @('patch', 'minor') }
    ) {
        { Resolve-ReleaseConfiguration @resolveConfiguration -Configuration @{ DefaultBump = $Value } } |
            Should -Throw '*DefaultBump*'
    }

    It 'rejects an invalid named input' {
        { Resolve-ReleaseConfiguration @resolveConfiguration -Inputs @{ DefaultBump = 'invalid' } } |
            Should -Throw '*DefaultBump*'
    }

    It 'rejects an invalid named input even when the repository value is valid' {
        $parameters = @{
            Inputs        = @{ DefaultBump = 'invalid' }
            Configuration = @{ DefaultBump = 'minor' }
        }
        { Resolve-ReleaseConfiguration @resolveConfiguration @parameters } |
            Should -Throw '*DefaultBump*'
    }

    It 'lets a named DefaultBump override repository settings' {
        $parameters = @{
            Inputs        = @{ DefaultBump = 'minor' }
            Configuration = @{ DefaultBump = 'major' }
        }

        $result = Resolve-ReleaseConfiguration @resolveConfiguration @parameters

        $result.DefaultBump | Should -BeExactly 'minor'
        $result.DefaultBumpSource | Should -BeExactly 'ActionInput'
    }

    It 'inherits repository settings when no named input is supplied' {
        $parameters = @{
            Inputs        = @{}
            Configuration = @{ DefaultBump = 'major' }
        }

        $result = Resolve-ReleaseConfiguration @resolveConfiguration @parameters

        $result.DefaultBump | Should -BeExactly 'major'
        $result.DefaultBumpSource | Should -BeExactly 'RepositorySetting'
    }

    It 'keeps repository policy when the named bump is <InputState>' -ForEach @(
        @{ InputState = 'null'; InputValue = $null }
        @{ InputState = 'empty'; InputValue = '' }
    ) {
        $parameters = @{
            Inputs        = @{ DefaultBump = $InputValue }
            Configuration = @{ DefaultBump = 'major' }
        }

        $result = Resolve-ReleaseConfiguration @resolveConfiguration @parameters

        $result.DefaultBump | Should -BeExactly 'major'
        $result.DefaultBumpSource | Should -BeExactly 'RepositorySetting'
    }

    It 'records the action input as the default source even when it equals the shared default' {
        $result = Resolve-ReleaseConfiguration @resolveConfiguration -Inputs @{ DefaultBump = 'patch' }

        $result.DefaultBump | Should -BeExactly 'patch'
        $result.DefaultBumpSource | Should -BeExactly 'ActionInput'
    }

    It 'records a nondefault named input as the decision source' {
        $result = Resolve-ReleaseConfiguration @resolveConfiguration -Inputs @{ DefaultBump = 'minor' }

        $result.DefaultBump | Should -BeExactly 'minor'
        $result.DefaultBumpSource | Should -BeExactly 'ActionInput'
    }

    It 'preserves explicit false while null and empty inputs keep file text' {
        $parameters = @{
            Configuration = @{ AutoCleanup = $true; VersionPrefix = 'v'; DatePrereleaseFormat = 'yyyyMMdd' }
            Inputs        = @{ AutoCleanup = $false; VersionPrefix = $null; DatePrereleaseFormat = '' }
        }

        $result = Resolve-ReleaseConfiguration @resolveConfiguration @parameters

        $result.AutoCleanup | Should -BeFalse
        $result.VersionPrefix | Should -BeExactly 'v'
        $result.DatePrereleaseFormat | Should -BeExactly 'yyyyMMdd'
    }

    It 'rejects an invalid repository value even when the caller supplies a valid override' {
        $parameters = @{
            Configuration = @{ DefaultBump = 'invalid' }
            Inputs        = @{ DefaultBump = 'patch' }
        }

        { Resolve-ReleaseConfiguration @resolveConfiguration @parameters } |
            Should -Throw '*DefaultBump*'
    }

    It 'rejects named input settings [<Name>]' -ForEach @(
        @{ Name = 'DefaultBump'; Value = ' '; Message = '*DefaultBump*' }
        @{ Name = 'DefaultBump'; Value = 'date'; Message = '*DefaultBump*' }
        @{ Name = 'DefaultBump'; Value = 'inherit'; Message = '*DefaultBump*' }
        @{ Name = 'AutoCleanup'; Value = 'invalid'; Message = '*AutoCleanup*true or false*' }
        @{ Name = 'AutoCleanup'; Value = ' '; Message = '*AutoCleanup*true or false*' }
        @{ Name = 'AutoCleanup'; Value = 'inherit'; Message = '*AutoCleanup*true or false*' }
        @{ Name = 'AutoCleanup'; Value = 0; Message = '*AutoCleanup*true or false*' }
        @{ Name = 'AutoPatching'; Value = $true; Message = '*AutoPatching*removed*' }
        @{ Name = 'AutoPatching'; Value = $null; Message = '*AutoPatching*removed*' }
        @{ Name = 'DefaultBunp'; Value = 'minor'; Message = '*Unsupported release setting*' }
        @{ Name = 'DefaultBunp'; Value = ''; Message = '*Unsupported release setting*' }
    ) {
        { Resolve-ReleaseConfiguration @resolveConfiguration -Inputs @{ $Name = $Value } } |
            Should -Throw $Message
    }

    It 'rejects literal inherit as an invalid repository bump even with a valid input' {
        $parameters = @{
            Configuration = @{ DefaultBump = 'inherit' }
            Inputs        = @{ DefaultBump = 'minor' }
        }

        { Resolve-ReleaseConfiguration @resolveConfiguration @parameters } |
            Should -Throw '*Invalid DefaultBump*'
    }

    It 'rejects an <SchemaCase> action standards mapping before applying valid overrides' -ForEach @(
        @{ SchemaCase = 'unknown setting in the'; Message = '*Unsupported release setting*DefaultBunp*' }
        @{ SchemaCase = 'incomplete'; Message = '*standard defaults*missing*WhatIf*' }
    ) {
        $defaults = @{}
        foreach ($entry in $resolveConfiguration.Defaults.GetEnumerator()) {
            $defaults[$entry.Key] = $entry.Value
        }
        if ($SchemaCase -eq 'incomplete') {
            $defaults.Remove('WhatIf')
        } else {
            $defaults.DefaultBunp = 'minor'
        }

        { Resolve-ReleaseConfiguration -Defaults $defaults -Inputs @{ DefaultBump = 'patch'; WhatIf = $true } } |
            Should -Throw $Message
    }

    It 'rejects null and non-string text settings instead of coercing them' -ForEach @(
        @{ Name = 'VersionPrefix'; Value = $null }
        @{ Name = 'VersionPrefix'; Value = 1 }
        @{ Name = 'DatePrereleaseFormat'; Value = $false }
        @{ Name = 'DatePrereleaseFormat'; Value = @{ format = 'yyyyMMdd' } }
    ) {
        { Resolve-ReleaseConfiguration @resolveConfiguration -Configuration @{ $Name = $Value } } |
            Should -Throw "*$Name*string*"
    }

    It 'rejects an invalid prerelease date format before publication is considered' {
        { Resolve-ReleaseConfiguration @resolveConfiguration -Configuration @{ DatePrereleaseFormat = '%' } } |
            Should -Throw '*DatePrereleaseFormat*format*'
    }

    It 'rejects the retired <Name> setting with migration guidance' -ForEach @(
        @{ Name = 'AutoPatching' }
        @{ Name = 'IgnoreLabels' }
        @{ Name = 'MajorLabels' }
        @{ Name = 'MinorLabels' }
        @{ Name = 'PatchLabels' }
    ) {
        { Resolve-ReleaseConfiguration @resolveConfiguration -Configuration @{ $Name = 'legacy' } } |
            Should -Throw "*$Name*removed*DefaultBump*release:*"
    }

    It 'rejects an unknown setting instead of silently ignoring a typo' {
        { Resolve-ReleaseConfiguration @resolveConfiguration -Configuration @{ DefaultBunp = 'minor' } } |
            Should -Throw '*Unsupported release setting*DefaultBunp*'
    }

    It 'rejects a configuration root that is not a mapping' -ForEach @(
        @{ Configuration = 'DefaultBump: minor' }
        @{ Configuration = @('patch', 'minor') }
        @{ Configuration = $true }
    ) {
        { Resolve-ReleaseConfiguration @resolveConfiguration -Configuration $Configuration } |
            Should -Throw '*configuration must be a mapping*'
    }
}

Describe 'Get-ReleaseLabelDefinition' {
    BeforeAll {
        $definitions = @(Get-ReleaseLabelDefinition)
    }

    It 'returns exactly the five canonical labels' {
        $definitions.Name | Should -Be @(
            'release:patch'
            'release:minor'
            'release:major'
            'release:prerelease'
            'release:skip'
        )
    }

    It 'returns a unique name for every definition' {
        @($definitions.Name | Sort-Object -Unique).Count | Should -Be $definitions.Count
    }

    It 'returns valid repository metadata for <Name>' -ForEach @(
        @{ Name = 'release:patch' }
        @{ Name = 'release:minor' }
        @{ Name = 'release:major' }
        @{ Name = 'release:prerelease' }
        @{ Name = 'release:skip' }
    ) {
        $definition = $definitions | Where-Object Name -CEQ $Name

        $definition.Color | Should -Match '^[0-9a-f]{6}$'
        $definition.Description | Should -Not -BeNullOrEmpty
        $definition.Description.Length | Should -BeLessOrEqual 100
    }
}

Describe 'Get-PrereleaseCleanupCandidate' {
    BeforeAll {
        $releases = @(
            [PSCustomObject]@{
                tagName      = 'v1.2.3-123.1'
                isPrerelease = $true
            }
            [PSCustomObject]@{
                tagName      = 'v1.2.3-123'
                isPrerelease = $true
            }
            [PSCustomObject]@{
                tagName      = 'v1.2.3-1234.1'
                isPrerelease = $true
            }
            [PSCustomObject]@{
                tagName      = 'v1.2.3-other.123.1'
                isPrerelease = $true
            }
            [PSCustomObject]@{
                tagName      = 'v1.2.3'
                isPrerelease = $false
            }
            [PSCustomObject]@{
                tagName      = 'v123.0.0'
                isPrerelease = $false
            }
            [PSCustomObject]@{
                tagName      = 'v1.2.3-123.2'
                isPrerelease = $false
            }
        )
    }

    It 'returns only prereleases with the exact numeric identifier segment' {
        $result = @(Get-PrereleaseCleanupCandidate -Releases $releases -PrereleaseName '123')

        $result.tagName | Should -Be @('v1.2.3-123.1', 'v1.2.3-123')
    }

    It 'never returns stable releases whose versions overlap the identifier' {
        $result = @(Get-PrereleaseCleanupCandidate -Releases $releases -PrereleaseName '123')

        $result | Where-Object { -not $_.isPrerelease } | Should -BeNullOrEmpty
        $result.tagName | Should -Not -Contain 'v1.2.3'
        $result.tagName | Should -Not -Contain 'v123.0.0'
        $result.tagName | Should -Not -Contain 'v1.2.3-123.2'
    }

    It 'does not match a longer or later prerelease identifier segment' {
        $result = @(Get-PrereleaseCleanupCandidate -Releases $releases -PrereleaseName '123')

        $result.tagName | Should -Not -Contain 'v1.2.3-1234.1'
        $result.tagName | Should -Not -Contain 'v1.2.3-other.123.1'
    }

    It 'escapes regular-expression characters in the identifier' {
        $regexReleases = @(
            [PSCustomObject]@{
                tagName      = 'v1.2.3-feature.test.1'
                isPrerelease = $true
            }
            [PSCustomObject]@{
                tagName      = 'v1.2.3-featureXtest.1'
                isPrerelease = $true
            }
        )

        $result = @(
            Get-PrereleaseCleanupCandidate -Releases $regexReleases -PrereleaseName 'feature.test'
        )

        $result.tagName | Should -Be @('v1.2.3-feature.test.1')
    }

    It 'never matches a name after the first SemVer prerelease separator' {
        $tagNames = @(
            'v1.2.3-other-feature.1'
            'v1.2.3-other.1-feature.2'
            'v1.2.3-other-v4.5.6-feature.1'
            'v1.2.3-feature.1'
        )
        $records = @($tagNames | ForEach-Object { [PSCustomObject]@{ tagName = $_; isPrerelease = $true } })

        $result = @(Get-PrereleaseCleanupCandidate -Releases $records -PrereleaseName 'feature')

        $result.tagName | Should -Be @('v1.2.3-feature.1')
    }

    It 'distinguishes case-sensitive branch identifiers' {
        $records = @(
            [PSCustomObject]@{ tagName = 'v1.2.3-Feature.1'; isPrerelease = $true }
            [PSCustomObject]@{ tagName = 'v1.2.3-feature.1'; isPrerelease = $true }
        )

        $result = @(Get-PrereleaseCleanupCandidate -Releases $records -PrereleaseName 'Feature')

        $result.tagName | Should -Be @('v1.2.3-Feature.1')
    }

    It 'ignores non-version tags and invalid version cores' {
        $records = @(
            [PSCustomObject]@{ tagName = 'notes-feature.1'; isPrerelease = $true }
            [PSCustomObject]@{ tagName = 'v01.2.3-feature.1'; isPrerelease = $true }
        )

        @(Get-PrereleaseCleanupCandidate -Releases $records -PrereleaseName 'feature') |
            Should -BeNullOrEmpty
    }

    It 'retains cleanup across empty and hyphenated version prefixes' {
        $records = @(
            [PSCustomObject]@{ tagName = '1.2.3-feature.1'; isPrerelease = $true }
            [PSCustomObject]@{ tagName = 'release-v1.2.3-feature.2'; isPrerelease = $true }
        )

        $result = @(Get-PrereleaseCleanupCandidate -Releases $records -PrereleaseName 'feature')

        $result.tagName | Should -Be @('1.2.3-feature.1', 'release-v1.2.3-feature.2')
    }

    It 'returns no candidates for an empty release list' {
        $result = @(Get-PrereleaseCleanupCandidate -Releases @() -PrereleaseName 'feature')

        $result | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-ReleaseBump' {
    It 'converts <DefaultBump> to <Expected>' -ForEach @(
        @{ DefaultBump = 'patch'; Expected = 'Patch' }
        @{ DefaultBump = 'minor'; Expected = 'Minor' }
        @{ DefaultBump = 'major'; Expected = 'Major' }
    ) {
        ConvertTo-ReleaseBump -DefaultBump $DefaultBump | Should -BeExactly $Expected
    }

    It 'rejects omitted policy instead of selecting its own patch fallback' {
        { ConvertTo-ReleaseBump } | Should -Throw '*Invalid DefaultBump*'
    }

    It 'rejects invalid DefaultBump [<DefaultBump>]' -ForEach @(
        @{ DefaultBump = '' }
        @{ DefaultBump = 'Patch' }
        @{ DefaultBump = 'prerelease' }
        @{ DefaultBump = 'none' }
        @{ DefaultBump = $null }
    ) {
        { ConvertTo-ReleaseBump -DefaultBump $DefaultBump } |
            Should -Throw '*Invalid DefaultBump*patch, minor, major*'
    }
}

Describe 'Resolve-ReleaseDecision' {
    It 'resolves <Name>' -ForEach @(
        @{
            Name       = 'a patch release'
            Labels     = @('release:patch')
            Bump       = 'Patch'
            Prerelease = $false
            Skip       = $false
        }
        @{
            Name       = 'a minor release'
            Labels     = @('release:minor')
            Bump       = 'Minor'
            Prerelease = $false
            Skip       = $false
        }
        @{
            Name       = 'a major release'
            Labels     = @('release:major')
            Bump       = 'Major'
            Prerelease = $false
            Skip       = $false
        }
        @{
            Name       = 'a patch prerelease'
            Labels     = @('release:patch', 'release:prerelease')
            Bump       = 'Patch'
            Prerelease = $true
            Skip       = $false
        }
        @{
            Name       = 'a minor prerelease'
            Labels     = @('release:minor', 'release:prerelease')
            Bump       = 'Minor'
            Prerelease = $true
            Skip       = $false
        }
        @{
            Name       = 'a major prerelease'
            Labels     = @('release:major', 'release:prerelease')
            Bump       = 'Major'
            Prerelease = $true
            Skip       = $false
        }
        @{
            Name       = 'a skipped release'
            Labels     = @('release:skip')
            Bump       = 'None'
            Prerelease = $false
            Skip       = $true
        }
        @{
            Name       = 'a bump alongside unrelated labels'
            Labels     = @('dependencies', 'release:patch', 'release:unknown')
            Bump       = 'Patch'
            Prerelease = $false
            Skip       = $false
        }
        @{
            Name       = 'a skip alongside unrelated labels'
            Labels     = @('documentation', 'release:skip', 'release:unknown')
            Bump       = 'None'
            Prerelease = $false
            Skip       = $true
        }
    ) {
        $result = Resolve-ReleaseDecision -Labels $Labels -DefaultBump $standardSettings.DefaultBump

        $result.Bump | Should -BeExactly $Bump
        $result.Prerelease | Should -Be $Prerelease
        $result.Skip | Should -Be $Skip
        $result.DefaultBumpApplied | Should -BeFalse
    }

    It 'rejects <Name>' -ForEach @(
        @{
            Name    = 'patch and minor bumps'
            Labels  = @('release:patch', 'release:minor')
            Message = '*Conflicting release bump labels*'
        }
        @{
            Name    = 'minor and major bumps'
            Labels  = @('release:minor', 'release:major')
            Message = '*Conflicting release bump labels*'
        }
        @{
            Name    = 'all bump labels'
            Labels  = @('release:patch', 'release:minor', 'release:major')
            Message = '*Conflicting release bump labels*'
        }
        @{
            Name    = 'skip and patch'
            Labels  = @('release:skip', 'release:patch')
            Message = '*release:skip must not be combined*'
        }
        @{
            Name    = 'skip and prerelease'
            Labels  = @('release:skip', 'release:prerelease')
            Message = '*release:skip must not be combined*'
        }
    ) {
        { Resolve-ReleaseDecision -Labels $Labels -DefaultBump $standardSettings.DefaultBump } | Should -Throw $Message
    }

    It 'requires resolved policy even with <LabelState>' -ForEach @(
        @{ LabelState = 'no owned label'; Labels = @() }
        @{ LabelState = 'an owned major label'; Labels = @('release:major') }
    ) {
        { Resolve-ReleaseDecision -Labels $Labels } | Should -Throw '*Invalid DefaultBump*'
    }

    It 'resolves <Expected> from <Name> with the <DefaultBump> default' -ForEach @(
        @{
            Name        = 'an empty label set'
            Labels      = @()
            DefaultBump = 'patch'
            Expected    = 'Patch'
            Prerelease  = $false
        }
        @{
            Name        = 'a null label set'
            Labels      = $null
            DefaultBump = 'minor'
            Expected    = 'Minor'
            Prerelease  = $false
        }
        @{
            Name        = 'legacy bare labels'
            Labels      = @('Major', 'Minor', 'Patch', 'Prerelease', 'NoRelease')
            DefaultBump = 'major'
            Expected    = 'Major'
            Prerelease  = $false
        }
        @{
            Name        = 'lowercase bare labels'
            Labels      = @('major', 'minor', 'patch', 'prerelease')
            DefaultBump = 'patch'
            Expected    = 'Patch'
            Prerelease  = $false
        }
        @{
            Name        = 'noncanonical casing'
            Labels      = @('Release:Patch')
            DefaultBump = 'minor'
            Expected    = 'Minor'
            Prerelease  = $false
        }
        @{
            Name        = 'an unknown release label'
            Labels      = @('release:unknown')
            DefaultBump = 'major'
            Expected    = 'Major'
            Prerelease  = $false
        }
        @{
            Name        = 'the retired release:pre-release label'
            Labels      = @('release:pre-release')
            DefaultBump = 'patch'
            Expected    = 'Patch'
            Prerelease  = $false
        }
        @{
            Name        = 'prerelease without an explicit bump'
            Labels      = @('release:prerelease')
            DefaultBump = 'minor'
            Expected    = 'Minor'
            Prerelease  = $true
        }
    ) {
        $result = Resolve-ReleaseDecision -Labels $Labels -DefaultBump $DefaultBump

        $result.Bump | Should -BeExactly $Expected
        $result.Prerelease | Should -Be $Prerelease
        $result.Skip | Should -BeFalse
        $result.DefaultBumpApplied | Should -BeTrue
    }

    It 'applies each valid default to unlabeled and prerelease-only decisions' {
        $expectedBumps = @{
            patch = 'Patch'
            minor = 'Minor'
            major = 'Major'
        }

        foreach ($defaultBump in @('patch', 'minor', 'major')) {
            foreach ($labels in @(@(), @('release:prerelease'))) {
                $result = Resolve-ReleaseDecision -Labels $labels -DefaultBump $defaultBump

                $result.Bump | Should -BeExactly $expectedBumps[$defaultBump]
                $result.Prerelease | Should -Be ($labels -ccontains 'release:prerelease')
                $result.DefaultBumpApplied | Should -BeTrue
            }
        }
    }

    It 'lets every explicit bump label override every valid default' {
        $explicitBumps = [ordered]@{
            'release:patch' = 'Patch'
            'release:minor' = 'Minor'
            'release:major' = 'Major'
        }

        foreach ($defaultBump in @('patch', 'minor', 'major')) {
            foreach ($entry in $explicitBumps.GetEnumerator()) {
                $result = Resolve-ReleaseDecision -Labels @($entry.Key) -DefaultBump $defaultBump

                $result.Bump | Should -BeExactly $entry.Value
                $result.DefaultBumpApplied | Should -BeFalse
            }
        }
    }

    It 'lets release:skip override every valid default' {
        foreach ($defaultBump in @('patch', 'minor', 'major')) {
            $result = Resolve-ReleaseDecision -Labels @('release:skip') -DefaultBump $defaultBump

            $result.Bump | Should -BeExactly 'None'
            $result.Skip | Should -BeTrue
            $result.DefaultBumpApplied | Should -BeFalse
        }
    }

    It 'validates DefaultBump before applying an explicit decision' {
        { Resolve-ReleaseDecision -Labels @('release:patch') -DefaultBump 'Patch' } |
            Should -Throw '*Invalid DefaultBump*'
    }

    It 'accepts exactly the nine valid subsets for every default bump' {
        $ownedLabels = @(
            'release:patch'
            'release:minor'
            'release:major'
            'release:prerelease'
            'release:skip'
        )
        $validSubsets = @(
            ''
            'release:prerelease'
            'release:patch'
            'release:minor'
            'release:major'
            'release:patch,release:prerelease'
            'release:minor,release:prerelease'
            'release:major,release:prerelease'
            'release:skip'
        )

        foreach ($defaultBump in @('patch', 'minor', 'major')) {
            for ($mask = 0; $mask -lt (1 -shl $ownedLabels.Count); $mask++) {
                $labels = @(
                    for ($index = 0; $index -lt $ownedLabels.Count; $index++) {
                        if (($mask -band (1 -shl $index)) -ne 0) {
                            $ownedLabels[$index]
                        }
                    }
                )
                $subset = ($labels | Sort-Object) -join ','

                if ($validSubsets -ccontains $subset) {
                    { Resolve-ReleaseDecision -Labels $labels -DefaultBump $defaultBump } |
                        Should -Not -Throw -Because "[$subset] is valid with DefaultBump [$defaultBump]"
                } else {
                    { Resolve-ReleaseDecision -Labels $labels -DefaultBump $defaultBump } |
                        Should -Throw -Because "[$subset] is not a valid release decision"
                }
            }
        }
    }

    Describe 'Resolve-PullRequestReleaseContext' {
        It 'uses the branch for naming and the exact head SHA for the release target' {
            $headSha = '0123456789012345678901234567890123456789'
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = 'feature/fork-release'
                    sha = $headSha
                }
            }

            $result = Resolve-PullRequestReleaseContext -PullRequest $pullRequest

            $result.HeadRef | Should -BeExactly 'feature/fork-release'
            $result.PrereleaseName | Should -BeExactly 'featureforkrelease'
            $result.PrereleaseTarget | Should -BeExactly $headSha
        }

        It 'does not use a colliding base-repository branch name as the release target' {
            $headSha = 'abcdefabcdefabcdefabcdefabcdefabcdefabcd'
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = 'main'
                    sha = $headSha
                }
            }

            $result = Resolve-PullRequestReleaseContext -PullRequest $pullRequest

            $result.PrereleaseName | Should -BeExactly 'main'
            $result.PrereleaseTarget | Should -BeExactly $headSha
            $result.PrereleaseTarget | Should -Not -BeExactly $result.HeadRef
        }

        It 'rejects a pull request without a head ref' {
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = ''
                    sha = '0123456789012345678901234567890123456789'
                }
            }

            { Resolve-PullRequestReleaseContext -PullRequest $pullRequest } |
                Should -Throw '*head ref is required*'
        }

        It 'rejects a pull request without a head SHA' {
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = 'feature/missing-sha'
                    sha = ''
                }
            }

            { Resolve-PullRequestReleaseContext -PullRequest $pullRequest } |
                Should -Throw '*head SHA is required*'
        }

        It 'rejects a mutable or malformed head SHA [<HeadSha>]' -ForEach @(
            @{ HeadSha = 'main' }
            @{ HeadSha = 'abcdef' }
            @{ HeadSha = '012345678901234567890123456789012345678g' }
            @{ HeadSha = "0123456789012345678901234567890123456789`n" }
        ) {
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = 'feature/invalid-sha'
                    sha = $HeadSha
                }
            }

            { Resolve-PullRequestReleaseContext -PullRequest $pullRequest } |
                Should -Throw '*head SHA must be a 40-character hexadecimal commit*'
        }

        It 'rejects a head ref that has no valid prerelease identifier' {
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = '---'
                    sha = '0123456789012345678901234567890123456789'
                }
            }

            { Resolve-PullRequestReleaseContext -PullRequest $pullRequest } |
                Should -Throw '*does not contain a valid prerelease identifier*'
        }

        It 'allows a valid non-prerelease branch without an ASCII prerelease identifier' {
            $headRef = ([char] 0x2603).ToString()
            $pullRequest = [PSCustomObject]@{
                head = [PSCustomObject]@{
                    ref = $headRef
                    sha = '0123456789012345678901234567890123456789'
                }
            }

            $result = Resolve-PullRequestReleaseContext -PullRequest $pullRequest -AllowEmptyPrereleaseName

            $result.HeadRef | Should -BeExactly $headRef
            $result.PrereleaseName | Should -BeExactly ''
        }
    }

    Describe 'Test-PrereleaseCreation' {
        It 'returns <Expected> for <Name>' -ForEach @(
            @{
                Name     = 'an open prerelease pull request'
                Labels   = @('release:patch', 'release:prerelease')
                Closed   = $false
                Expected = $true
            }
            @{
                Name     = 'a closed prerelease pull request'
                Labels   = @('release:patch', 'release:prerelease')
                Closed   = $true
                Expected = $false
            }
            @{
                Name     = 'an open stable pull request'
                Labels   = @('release:patch')
                Closed   = $false
                Expected = $false
            }
            @{
                Name     = 'a closed stable pull request'
                Labels   = @('release:patch')
                Closed   = $true
                Expected = $false
            }
            @{
                Name     = 'an open skipped pull request'
                Labels   = @('release:skip')
                Closed   = $false
                Expected = $false
            }
        ) {
            $decision = Resolve-ReleaseDecision -Labels $Labels -DefaultBump $standardSettings.DefaultBump
            $result = Test-PrereleaseCreation -ReleaseDecision $decision -PullRequestClosed:$Closed

            $result | Should -Be $Expected
        }
    }
}
