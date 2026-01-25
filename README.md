# Auto-Release

Automatically creates releases based on pull requests and labels.


## Specifications and practices

Auto-Release follows:

- [SemVer 2.0.0 specifications](https://semver.org)
- [GitHub Flow specifications](https://docs.github.com/en/get-started/using-github/github-flow)
- [Continuous Delivery practices](https://en.wikipedia.org/wiki/Continuous_delivery)

## How it works

The workflow will trigger on pull requests to the main branch.

The following labels will inform the action what kind of release to create:
- For a major release, and increasing the first number in the version use:
  - `major`
  - `breaking`
- For a minor release, and increasing the second number in the version.
  - `minor`
  - `feature`
- For a patch release, and increases the third number in the version.
  - `patch`
  - `fix`

When a pull request is closed, the action will create a release based on the labels and clean up any previous prereleases that was created.

> [!NOTE]
> The labels can be configured using the `MajorLabels`, `MinorLabels` and `PatchLabels` parameters/settings in the configuration file to trigger
> on other labels.

This action is built on [GitHub-Script](https://github.com/PSModule/GitHub-Script) which by default uses the `GITHUB_TOKEN`.
## Usage

The action can be configured using the following settings:

| Name | Description | Default | Required |
| --- | --- | --- | --- |
| `AutoCleanup` | Control whether to automatically cleanup prereleases. If disabled, the action will not remove any prereleases. | `true` | false |
| `AutoPatching` | Control whether to automatically handle patches. If disabled, the action will only create a patch release if the pull request has a 'patch' label. | `true` | false |
| `ConfigurationFile` | The path to the configuration file. Settings in the configuration file take precedence over the action inputs. | `.github\auto-release.yml` | false |
| `CreateMajorTag` | Control whether to create a tag for major releases. | `true` | false |
| `CreateMinorTag` | Control whether to create a tag for minor releases. | `true` | false |
| `DatePrereleaseFormat` | The format to use for the prerelease number using [.NET DateTime format strings](https://learn.microsoft.com/en-us/dotnet/standard/base-types/standard-date-and-time-format-strings). | `''` | false |
| `IgnoreLabels` | A comma separated list of labels that do not trigger a release. | `NoRelease` | false |
| `IncrementalPrerelease` | Control whether to automatically increment the prerelease number. If disabled, the action will ensure only one prerelease exists for a given branch. | `true` | false |
| `MajorLabels` | A comma separated list of labels that trigger a major release. | `major, breaking` | false |
| `MinorLabels` | A comma separated list of labels that trigger a minor release. | `minor, feature` | false |
| `PatchLabels` | A comma separated list of labels that trigger a patch release. | `patch, fix` | false |
| `UsePRTitleAsReleaseName` | When enabled, uses the pull request title as the name for the GitHub release. | `false` | false |
| `UsePRBodyAsReleaseNotes` | When enabled, uses the pull request body as the release notes for the GitHub release. | `true` | false |
| `UsePRTitleAsNotesHeading` | When enabled, the release notes will begin with the pull request title as a H1 heading followed by the pull request body. The title will include a reference to the PR number. | `true` | false |
| `VersionPrefix` | The prefix to use for the version number. | `v` | false |
| `WhatIf` | Control whether to simulate the action. If enabled, the action will not create any releases. Used for testing. | `false` | false |
| `Debug` | Enable debug output. | `'false'` | false |
| `Verbose` | Enable verbose output. | `'false'` | false |
| `Version` | Specifies the exact version of the GitHub module to install. | | false |
| `Prerelease` | Allow prerelease versions if available. | `'false'` | false |
| `WorkingDirectory` | The working directory where the script runs. | `${{ github.workspace }}` | false |

### Configuration file

The configuration file is a YAML file that can be used to configure the action.
By default, the configuration file is expected at `.github\auto-release.yml`, which can be changed using the `ConfigurationFile` setting.
The actions configuration can be change by altering the settings in the configuration file.

```yaml
DatePrereleaseFormat: 'yyyyMMddHHmm'
IncrementalPrerelease: false
VersionPrefix: ''
```

This example uses the date format for the prerelease, disables the incremental prerelease and removes the version prefix.

## Example

Add a workflow in you repository using the following example:

```yaml
name: Auto-Release

on:
  pull_request_target:
    branches:
      - main
    types:
      - closed
      - opened
      - reopened
      - synchronize
      - labeled

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}

jobs:
  Auto-Release:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Auto-Release
        uses: PSModule/Auto-Release@v1
```

## Permissions

If running the action in a restrictive mode, the following permissions needs to be granted to the action:

```yaml
permissions:
  contents: write # Required to create releases
  pull-requests: write # Required to create comments on the PRs
```
