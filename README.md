# Release-GHRepository

Automatically creates releases based on pull requests and labels.


## Specifications and practices

Release-GHRepository follows:

- [SemVer 2.0.0 specifications](https://semver.org)
- [GitHub Flow specifications](https://docs.github.com/en/get-started/using-github/github-flow)
- [Continuous Delivery practices](https://en.wikipedia.org/wiki/Continuous_delivery)

## How it works

One release workflow runs on regular `pull_request` events for the main branch.
It calls an action pinned to a reviewed commit and reads configuration from a trusted checkout.
It does not execute the PR's local action or scripts.

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

Add the `prerelease` label to create prereleases while a same-repository PR is open.
Prereleases use the PR head commit and a PR-specific tag, such as `v1.2.3-pr42.1`.
When the PR is merged, the action creates a stable release at its merge commit. Closing an unmerged PR does not create a stable release.
With `AutoCleanup` enabled, closing or merging the PR removes only prereleases in that PR's tag namespace.
Other prereleases are left unchanged.

Fork PR checks remain read-only. The release workflow skips fork PRs, including their merge events, because their regular PR tokens cannot publish.
Do not enable write tokens for fork checks.

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
| `IncrementalPrerelease` | Control whether to automatically increment the prerelease number. If disabled, the action replaces the prerelease for the pull request. | `true` | false |
| `MajorLabels` | A comma separated list of labels that trigger a major release. | `major, breaking` | false |
| `MinorLabels` | A comma separated list of labels that trigger a minor release. | `minor, feature` | false |
| `PatchLabels` | A comma separated list of labels that trigger a patch release. | `patch, fix` | false |
| `UsePRTitleAsReleaseName` | When enabled, uses the pull request title as the name for the GitHub release. | `false` | false |
| `UsePRBodyAsReleaseNotes` | When enabled, uses the pull request body as the release notes for the GitHub release. | `true` | false |
| `UsePRTitleAsNotesHeading` | When enabled, the release notes will begin with the pull request title as a H1 heading followed by the pull request body. The title will include a reference to the PR number. | `true` | false |
| `VersionPrefix` | The prefix to use for the version number. | `v` | false |
| `WhatIf` | Simulate release and tag changes. Set this input to `true` for read-only checks. A true input cannot be disabled by the configuration file. | `false` | false |
| `Debug` | Enable debug output. | `'false'` | false |
| `Verbose` | Enable verbose output. | `'false'` | false |
| `Version` | Specifies the version of the GitHub module to install. Accepts an exact version or a NuGet version range (for example `[1.2.0, 2.0.0)`). | `[0.43.1]` | false |
| `Prerelease` | Allow prerelease versions if available. | `'false'` | false |
| `WorkingDirectory` | The working directory where the script runs. | `${{ github.workspace }}` | false |

### Configuration file

The configuration file is a YAML file that can be used to configure the action.
By default, the configuration file is expected at `.github\auto-release.yml`, which can be changed using the `ConfigurationFile` setting.
The action's configuration can be changed by altering the settings in the configuration file.
The example reads this file from the PR base commit while the PR is open and from the approved merge commit after merge.
It does not read configuration changes from an unmerged PR.
Configuration cannot turn off an explicit `WhatIf: true` input.

```yaml
DatePrereleaseFormat: 'yyyyMMddHHmm'
IncrementalPrerelease: false
VersionPrefix: ''
```

This example uses the date format for the prerelease, disables the incremental prerelease and removes the version prefix.

## Example

Save this single workflow as `.github/workflows/Release.yml`. The example uses a GitHub-hosted Ubuntu runner.
The release job has write permissions, so it calls a pinned action instead of running the PR's local `./` action.

```yaml
name: Release

on:
  pull_request:
    branches:
      - main
    types:
      - closed
      - opened
      - reopened
      - synchronize
      - labeled

permissions: {}

jobs:
  Release:
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    concurrency:
      group: ${{ github.workflow }}-${{ github.repository }}
      queue: max
      cancel-in-progress: false
    steps:
      - name: Checkout trusted configuration
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          ref: ${{ github.event.pull_request.merged && github.event.pull_request.merge_commit_sha || github.event.pull_request.base.sha }}
          persist-credentials: false

      - name: Release
        uses: PSModule/Release-GHRepository@bee1a2c437920824370c8b42a8cb6a2916cc2cb4 # Verified dependencies and direct PR publication
```

Do not replace the trusted checkout ref with the PR head or add steps that execute files from an unmerged PR in this write-capable job.
Keep the action pin under review when changing the publisher. Use `WhatIf: true` with read-only permissions to test proposed local action changes.
The action checks live PR metadata before writing. A stale event fails instead of publishing a later commit or a changed PR state.
Major and minor tags are updated through the GitHub API. Checkout credentials are not required.

Use reviewed commit SHAs for external actions. Enable GitHub Actions dependency updates in the consuming repository to keep these pins current.
This setup trusts contributors who can change workflows in the repository. Any additional publication approval boundary must be enforced by repository or organization policy.

## Permissions

Set permissions explicitly for each job. Read-only checks need only `contents: read` and `pull-requests: read`, with `WhatIf: true`.
The release job needs these scopes:

```yaml
permissions:
  contents: write # Create releases and update release tags
  pull-requests: write # Post release comments on PRs
```

The examples use the short-lived, repository-scoped `GITHUB_TOKEN` supported by this action. They do not need a personal access token.
Requested write permissions do not override the read-only restriction for normal fork PR checks.

## Dependency maintenance

`src/Release-GHRepository.Dependencies.psd1` locks the `powershell-yaml` and `PSSemVer` package versions and SHA256 hashes.
The action checks each downloaded package before extraction or import and imports the verified module by its full path.
Update a version and its hash together in a reviewed PR. Do not change a hash only to make a failed verification pass.

The repository linter uses the upstream Super-Linter action pinned to a full commit SHA.
Dependabot checks workflow action pins for updates.
The upstream action selects its container image by version tag, so the action SHA does not lock the container image digest.

## Local checks

With PowerShell 7 and Pester 6.1.0 installed, run:

```powershell
Invoke-Pester -Path .\tests -CI
```

These tests need no GitHub credentials and do not publish releases.
Tag API failures use test doubles to avoid production writes; those tests do not establish that live publication succeeds.
