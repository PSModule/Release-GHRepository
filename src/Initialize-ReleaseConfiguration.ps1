#Requires -Version 7.2

<#
    .SYNOPSIS
    Resolve action settings before GitHub-Script starts.

    .DESCRIPTION
    Select the repository settings file from the explicitly supplied initial
    directory or the workspace. Read the selected file once, then resolve all
    settings and write the private startup and release-policy handoff.

    .EXAMPLE
    .\Initialize-ReleaseConfiguration.ps1 -WorkspacePath $workspace

    Return the resolved settings. In Actions, also write the step outputs.

    .INPUTS
    None

    You can't pipe objects to Initialize-ReleaseConfiguration.ps1.

    .OUTPUTS
    System.Management.Automation.PSCustomObject

    The resolved startup and release settings.
#>
[OutputType([PSCustomObject])]
[CmdletBinding()]
param(
    # The known caller workspace, independent of the current directory.
    [Parameter()]
    [string] $WorkspacePath = [Environment]::GetEnvironmentVariable('GITHUB_WORKSPACE'),

    # The runner's output file; local callers can omit it to return settings only.
    [Parameter()]
    [string] $OutputPath = [Environment]::GetEnvironmentVariable('GITHUB_OUTPUT')
)

$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'Release-GHRepository.Helpers.psm1') -Force
if ([string]::IsNullOrWhiteSpace($WorkspacePath) -or -not [IO.Path]::IsPathRooted($WorkspacePath) -or
    -not (Test-Path -LiteralPath $WorkspacePath -PathType Container)) {
    throw 'GITHUB_WORKSPACE must identify an existing absolute workspace directory.'
}
$WorkspacePath = [IO.Path]::GetFullPath($WorkspacePath)

if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Install-PSResource -Name powershell-yaml -TrustRepository -Repository PSGallery -WarningAction SilentlyContinue
            break
        } catch {
            $installationError = $_
            Write-Warning "Installation of powershell-yaml failed: $installationError"
            if ($attempt -eq 5) {
                throw $installationError
            }
            Start-Sleep -Seconds 10
        }
    }
}
Import-Module -Name powershell-yaml

Write-Information '::group::Resolve release settings' -InformationAction Continue
try {
    $actionDefinitionPath = [IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath '..\action.yml'))
    $metadata = Get-ReleaseSettingSchema -Path $actionDefinitionPath
    Write-Information "Reading action release standards [$actionDefinitionPath]" -InformationAction Continue
    $inputs = @{}
    foreach ($name in $metadata.Keys) {
        $inputs[$name] = [Environment]::GetEnvironmentVariable("PSMODULE_AUTO_RELEASE_INPUT_$name")
    }

    $initialDirectory = $WorkspacePath
    if (-not [string]::IsNullOrEmpty($inputs.WorkingDirectory)) {
        $initialParameters = @{
            Name          = 'WorkingDirectory'
            Type          = $metadata.WorkingDirectory.Type
            Value         = $inputs.WorkingDirectory
            WorkspacePath = $WorkspacePath
        }
        $initialDirectory = ConvertTo-ReleaseSettingValue @initialParameters
    }
    $settingsFilePath = [Environment]::GetEnvironmentVariable('PSMODULE_AUTO_RELEASE_INPUT_SettingsFilePath')
    $actionDefinition = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($actionDefinitionPath))
    if ($null -eq $settingsFilePath) {
        $settingsFilePath = $actionDefinition.inputs.SettingsFilePath.default
    }
    $pathParameters = @{
        Name          = 'SettingsFilePath'
        Path          = $settingsFilePath
        BaseDirectory = $initialDirectory
    }
    $settingsFilePath = Resolve-ReleaseFileSystemPath @pathParameters
    $defaultPathParameters = @{
        Name          = 'SettingsFilePath'
        Path          = $actionDefinition.inputs.SettingsFilePath.default
        BaseDirectory = $initialDirectory
    }
    $defaultConfigurationPath = Resolve-ReleaseFileSystemPath @defaultPathParameters
    $legacyConfigurationPath = Join-Path -Path (Split-Path -Path $defaultConfigurationPath -Parent) -ChildPath 'auto-release.yml'
    $pathComparison = [StringComparison]::Ordinal
    if ($IsWindows) {
        $pathComparison = [StringComparison]::OrdinalIgnoreCase
    }
    $usesDefaultPath = [string]::Equals($settingsFilePath, $defaultConfigurationPath, $pathComparison)
    $usesLegacyPath = [string]::Equals($settingsFilePath, $legacyConfigurationPath, $pathComparison)
    $configurationExists = Test-Path -LiteralPath $settingsFilePath -PathType Leaf
    $legacyExists = Test-Path -LiteralPath $legacyConfigurationPath -PathType Leaf
    if ($usesLegacyPath -or ($legacyExists -and ($usesDefaultPath -or -not $configurationExists))) {
        throw (
            "Settings path [$legacyConfigurationPath] is no longer supported. " +
            "Rename or combine its policy in [$defaultConfigurationPath]. " +
            'Update SettingsFilePath with a compatible action reference, or select an existing custom settings file.'
        )
    }
    if (Test-Path -LiteralPath $settingsFilePath -PathType Container) {
        throw 'SettingsFilePath must select a file, not a directory.'
    }
    $loggedPath = ConvertTo-Json -InputObject $settingsFilePath -Compress
    $configuration = @{}
    if ($configurationExists) {
        Write-Information "Reading settings file [$loggedPath]" -InformationAction Continue
        $configuration = ConvertFrom-Yaml -Yaml ([IO.File]::ReadAllText($settingsFilePath))
        if ($null -eq $configuration) {
            throw "Release settings file [$loggedPath] must be a mapping of supported settings."
        }
    } else {
        Write-Information "Settings file not found at [$loggedPath]" -InformationAction Continue
    }

    $configurationParameters = @{
        Metadata      = $metadata
        WorkspacePath = $WorkspacePath
        Inputs        = $inputs
        Configuration = $configuration
    }
    $settings = Resolve-ReleaseConfiguration @configurationParameters
    $outputs = [ordered]@{}
    $releaseSettings = [ordered]@{}
    foreach ($name in $metadata.Keys) {
        if ($metadata[$name].Phase -eq 'Startup') {
            $value = $settings.$name
            if ($value -is [bool]) {
                $value = $value.ToString().ToLowerInvariant()
            }
            $outputs[$name] = $value
        } else {
            $releaseSettings[$name] = $settings.$name
        }
    }
    $releaseSettings.DefaultBumpSource = $settings.DefaultBumpSource
    $outputs.ReleaseSettings = ConvertTo-Json -InputObject $releaseSettings -Compress
    Write-Information ("Resolved startup settings: {0}" -f (ConvertTo-Json -InputObject $outputs -Compress)) -InformationAction Continue

    if (-not [string]::IsNullOrEmpty($OutputPath)) {
        $outputParameters = @{
            Name          = 'GITHUB_OUTPUT'
            Path          = $OutputPath
            BaseDirectory = $WorkspacePath
        }
        $outputFilePath = Resolve-ReleaseFileSystemPath @outputParameters
        foreach ($name in $outputs.Keys) {
            $delimiter = [guid]::NewGuid().ToString('N')
            [IO.File]::AppendAllText($outputFilePath, "$name<<$delimiter`n$($outputs[$name])`n$delimiter`n")
        }
    }
    $settings
} finally {
    Write-Information '::endgroup::' -InformationAction Continue
}
