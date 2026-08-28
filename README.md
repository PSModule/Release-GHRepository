# Release-GHRepository

Create GitHub releases from explicit, owned pull-request labels.

## Release decision

Release-GHRepository owns and provisions five labels:

| Label | Instruction | Valid combination |
| --- | --- | --- |
| `release:patch` | Increment the patch version. | Exactly one bump label. |
| `release:minor` | Increment the minor version. | Exactly one bump label. |
| `release:major` | Increment the major version. | Exactly one bump label. |
| `release:pre-release` | Publish from an open pull request as a prerelease. | With exactly one bump label. |
| `release:skip` | Validate without publishing a release. | Without another owned release label. |

Exactly one bump label or `release:skip` is required. There is no default release decision.

The action rejects:

- a missing decision;
- multiple bump labels;
- `release:skip` with another owned release label;
- `release:pre-release` without exactly one bump label.

Labels outside this set do not affect releases. Bare and legacy labels such as `Major`, `Minor`, `Patch`, `Prerelease`, `NoRelease`, `major`, `minor`, and `patch` are not release decisions.

## How it works

On every non-WhatIf run, the action creates missing canonical labels and reconciles their colors and descriptions. It leaves all other repository labels unchanged.

An open pull request with `release:pre-release` and one bump label publishes a prerelease. A pull request merged into the default branch with one bump label publishes the stable release. A closed pull request cleans up its prereleases when `AutoCleanup` is enabled. `release:skip` never publishes a version, but a closed skipped pull request still receives prerelease cleanup.

The workflow must run for `labeled` and `unlabeled` events so both valid and invalid label transitions are evaluated. Do not use a workflow path filter to bypass the release decision on non-artifact changes; use `release:skip`.

This action is built on [GitHub-Script](https://github.com/PSModule/GitHub-Script), which uses the workflow token by default.

## Usage

```yaml
name: Release-GHRepository

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
      - unlabeled

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}

permissions:
  contents: write # Required to create releases and tags
  issues: write # Required to provision repository labels
  pull-requests: write # Required to comment on pull requests

jobs:
  Release-GHRepository:
    runs-on: ubuntu-24.04
    steps:
      - name: Checkout code
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          persist-credentials: false

      - name: Release repository
        uses: PSModule/Release-GHRepository@v3
```

The `pull_request_target` workflow checks out the trusted base branch. Do not check out or execute an untrusted pull-request head with this writable token.

## Inputs

| Name | Description | Default | Required |
| --- | --- | --- | --- |
| `AutoCleanup` | Delete prereleases after the pull request closes. | `true` | false |
| `ConfigurationFile` | Read settings from this file. File settings take precedence over action inputs. | `.github\auto-release.yml` | false |
| `CreateMajorTag` | Create or update the floating major tag after a stable release. | `true` | false |
| `CreateMinorTag` | Create or update the floating minor tag after a stable release. | `true` | false |
| `DatePrereleaseFormat` | Append a [.NET date and time format](https://learn.microsoft.com/en-us/dotnet/standard/base-types/standard-date-and-time-format-strings) to prerelease versions. | `''` | false |
| `IncrementalPrerelease` | Increment the prerelease number; when false, keep only one prerelease for the branch. | `true` | false |
| `UsePRTitleAsReleaseName` | Use the pull-request title as the GitHub Release name. | `false` | false |
| `UsePRBodyAsReleaseNotes` | Use the pull-request body as release notes. | `true` | false |
| `UsePRTitleAsNotesHeading` | Add the pull-request title and number as the release-notes heading. | `true` | false |
| `VersionPrefix` | Prefix the version number. | `v` | false |
| `WhatIf` | Log release and label changes without mutating repository state. | `false` | false |
| `Debug` | Enable debug output. | `false` | false |
| `Verbose` | Enable verbose output. | `false` | false |
| `Version` | Select the GitHub module dependency by exact version or NuGet version range. | | false |
| `Prerelease` | Allow a prerelease version of the GitHub module dependency. This does not select a repository prerelease. | `false` | false |
| `WorkingDirectory` | Set the directory where the script runs. | `${{ github.workspace }}` | false |

Use the `release:pre-release` label to select repository prerelease behavior. The similarly named `Prerelease` action input only controls dependency resolution for the GitHub module used internally.

### Configuration file

The default configuration file is `.github\auto-release.yml`. Change its path with `ConfigurationFile`.

```yaml
DatePrereleaseFormat: 'yyyyMMddHHmm'
IncrementalPrerelease: false
VersionPrefix: ''
```

## Migrate from v2

`v3` is a breaking release. Existing `v2` references and behavior remain unchanged.

1. Add `issues: write` to the release job and subscribe the workflow to `unlabeled`.
2. Remove workflow path filters so `release:skip` decisions are validated.
3. Remove `AutoPatching`, `IgnoreLabels`, `MajorLabels`, `MinorLabels`, and `PatchLabels` from action inputs and configuration files.
4. Provision the five canonical labels before opening the migration pull request. The action reconciles them on every subsequent run.
5. Apply both the existing v2 decision and the equivalent canonical decision to the migration pull request so either workflow version can process it.
6. Update the action reference to `PSModule/Release-GHRepository@v3` after `v3.0.0` is published.
7. Apply one canonical decision to every other open pull request.
8. Remove legacy release labels after no open pull request uses them. Removing bare `major`, `minor`, and `patch` labels also prevents Dependabot from applying them as dependency-version metadata.

The first v3 run provisions the canonical labels before validating the pull request. A pull request without a canonical decision fails until a maintainer applies one.
