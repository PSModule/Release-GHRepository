# Release-GHRepository

Automatically creates releases based on pull requests and labels.


## Specifications and practices

Release-GHRepository follows:

- [SemVer 2.0.0 specifications](https://semver.org)
- [GitHub Flow specifications](https://docs.github.com/en/get-started/using-github/github-flow)
- [Continuous Delivery practices](https://en.wikipedia.org/wiki/Continuous_delivery)

## How it works

The check workflow runs on regular `pull_request` events for the main branch. It uses read-only permissions and simulates release changes.
A separate `workflow_run` publisher runs after a successful check. The publisher executes only code and configuration from the default branch.
It reads PR metadata from the GitHub API. It does not check out PR code or download PR artifacts.

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
Prereleases use the checked head commit and a PR-specific tag, such as `v1.2.3-pr42.1`.
When the PR is merged, the publisher creates a stable release at its merge commit. Closing an unmerged PR does not create a stable release.
With `AutoCleanup` enabled, closing or merging the PR removes only prereleases in that PR's tag namespace.
Other prereleases are left unchanged.

Fork PR checks remain read-only. The publisher skips fork prereleases and can publish a stable release after the PR is merged.
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
| `WhatIf` | Simulate release and tag changes. Always enabled for `pull_request` checks. A true input cannot be disabled by the configuration file. | `false` | false |
| `Debug` | Enable debug output. | `'false'` | false |
| `Verbose` | Enable verbose output. | `'false'` | false |
| `Version` | Specifies the version of the GitHub module to install. Accepts an exact version or a NuGet version range (for example `[1.2.0, 2.0.0)`). | `[0.43.1]` | false |
| `Prerelease` | Allow prerelease versions if available. | `'false'` | false |
| `WorkingDirectory` | The working directory where the script runs. | `${{ github.workspace }}` | false |

### Configuration file

The configuration file is a YAML file that can be used to configure the action.
By default, the configuration file is expected at `.github\auto-release.yml`, which can be changed using the `ConfigurationFile` setting.
The action's configuration can be changed by altering the settings in the configuration file.
The publisher reads this file from its trusted default-branch checkout, not from the PR branch.
Configuration cannot turn off an explicit `WhatIf: true` input or enable writes during a regular PR check.

```yaml
DatePrereleaseFormat: 'yyyyMMddHHmm'
IncrementalPrerelease: false
VersionPrefix: ''
```

This example uses the date format for the prerelease, disables the incremental prerelease and removes the version prefix.

## Example

Add both workflows to your default branch. The publisher starts only after its workflow file exists on that branch.
These examples use GitHub-hosted Ubuntu runners.

### Read-only PR checks

Save this workflow as `.github/workflows/Release.yml`:

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

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number }}
  cancel-in-progress: true

permissions: {}

jobs:
  Check:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: read
    steps:
      - name: Checkout code
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false

      - name: Check release
        uses: PSModule/Release-GHRepository@4b9516dde0adb82a7f445b456ad906d1e611dfdf # Trusted publisher and dependency verification
        with:
          WhatIf: true
```

### Trusted publication

Save this workflow as `.github/workflows/Publish-Release.yml`. Keep `workflows: [Release]` equal to the check workflow's `name`.
The publisher has write access because it creates releases, updates release tags, and posts PR comments.
Only trusted default-branch code runs with this token.

```yaml
name: Publish Release

on:
  workflow_run:
    workflows: [Release]
    types: [completed]

permissions: {}

concurrency:
  group: ${{ github.workflow }}-${{ github.repository }}
  queue: max
  cancel-in-progress: false

jobs:
  Publish:
    if: >-
      github.event.workflow_run.event == 'pull_request' &&
      github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      pull-requests: write
    steps:
      - name: Checkout trusted configuration
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          ref: ${{ github.sha }}
          persist-credentials: false

      - name: Publish release
        uses: PSModule/Release-GHRepository@4b9516dde0adb82a7f445b456ad906d1e611dfdf # Trusted publisher and dependency verification
```

Do not replace the publisher's checkout ref with the PR head, `workflow_run.head_sha`, or an artifact from the check run.
The action validates the PR association and checked commit before publication. A stale run fails instead of publishing a later, unchecked commit.
Major and minor tags are updated through the GitHub API. Checkout credentials are not required.

Use reviewed commit SHAs for external actions. Enable GitHub Actions dependency updates in the consuming repository to keep these pins current.

## Permissions

Set permissions explicitly for each job. Checks need only `contents: read` and `pull-requests: read`.
The trusted publishing job needs these scopes:

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

The repository linter uses a local Docker action with a digest-pinned base image.
Dependabot checks that Dockerfile for image updates and checks workflow action pins separately.

## Local checks

With PowerShell 7 and Pester 6.1.0 installed, run:

```powershell
Invoke-Pester -Path .\tests -CI
```

These tests need no GitHub credentials and do not publish releases.
Tag API failures use test doubles to avoid production writes; those tests do not establish that live publication succeeds.
