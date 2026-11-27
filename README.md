# Release-GHRepository

Calculate versions and create GitHub releases from pull request labels and repository settings.

Repository and workflow maintainers can set the release policy in a GitHub Actions workflow or in the repository settings file.

## Release decision

Release-GHRepository manages five [namespaced release labels][automation-labels].
Each name uses the format `<namespace>:<qualifier>`.
The namespace is `release`. The qualifier selects the release instruction.

| Label | Instruction | Valid combination |
| --- | --- | --- |
| `release:patch` | Increment the patch version. | Exactly one bump label. |
| `release:minor` | Increment the minor version. | Exactly one bump label. |
| `release:major` | Increment the major version. | Exactly one bump label. |
| `release:prerelease` | Publish from an open pull request as a prerelease. | With one bump label or a configured default bump. |
| `release:skip` | Validate without publishing a release. | Without another label from the table. |

If the pull request has no bump or skip label from the table, the action uses `DefaultBump`.
Without a configured bump, the effective value is `none`. Apply one bump label or `release:skip`.
A `release:patch`, `release:minor`, or `release:major` label overrides `DefaultBump`.

The `release:prerelease` label permits prerelease publication. It is not necessary to calculate a prerelease version.
The `release:skip` label prevents publication.

The action rejects:

- a `DefaultBump` value other than exactly `none`, `patch`, `minor`, or `major`;
- no bump label or skip decision when `DefaultBump` is `none`;
- multiple bump labels;
- `release:skip` with another label from the table.

The action ignores labels that are not in the table.

## How it works

In `publish` mode during a pull request run with `WhatIf: false`, the action creates missing labels from the table.
It sets their colors and descriptions. It leaves all other labels unchanged.
If the event has no pull request, the action does not change labels or publish a release.

The action publishes a prerelease for an open pull request with `release:prerelease`.
The prerelease name uses the head branch name. When the tag does not exist, the action creates it at the exact pull request head commit.

A publishing run creates a stable release on a merge into the default branch unless the pull request has `release:skip`.
The version tag points to the merge commit. For a squash merge, this is the squash commit.
The action does not move an existing version tag. After publication, it sets each enabled major or minor tag to the same commit.

By default, the release notes start with the pull request title and number, followed by the full pull request description.
Put release-specific upgrade instructions in that description.

If `AutoCleanup` is `true`, the action deletes matching prereleases and their tags when the pull request closes.
The `release:skip` label does not prevent cleanup.

For cleanup, the action finds the version number after `VersionPrefix`. It then matches the exact, case-sensitive identifier for the head branch.
The prefix can be empty or contain hyphens. If you change the prefix, cleanup does not remove prereleases that use the previous prefix.

The action uses [GitHub-Script](https://github.com/PSModule/GitHub-Script), which uses the workflow token by default.

## Usage

This example shows the publishing job.

```yaml
name: Release-GHRepository

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
      - unlabeled

concurrency:
  group: ${{ github.workflow }}-${{ github.event.pull_request.base.ref }}
  cancel-in-progress: false

permissions:
  contents: write # Create releases and tags
  pull-requests: write # Manage release labels and comment on pull requests

jobs:
  Release-GHRepository:
    if: ${{ github.event.pull_request.head.repo.full_name == github.repository }}
    runs-on: ubuntu-24.04
    steps:
      - name: Require the merge commit SHA
        if: ${{ github.event.action == 'closed' && github.event.pull_request.merged && !github.event.pull_request.merge_commit_sha }}
        shell: pwsh
        run: throw 'GitHub did not report the merge commit SHA.'

      - name: Checkout code
        uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0 # v7.0.0
        with:
          ref: >-
            ${{ github.event.action == 'closed' && github.event.pull_request.merged
            && github.event.pull_request.merge_commit_sha || github.event.pull_request.base.sha }}
          persist-credentials: false

      - name: Release repository
        uses: PSModule/Release-GHRepository@<released-commit-sha>
```

Pin the action to the full commit SHA of a published release that supports these inputs.
Do not use a pull request head in a production workflow.
Use a moving major tag only if the producer's release automation controls it and moves it only to compatible stable releases in that major version.

The example uses `pull_request`. The publishing job skips pull requests from forks, including on merge.
For a merge, it checks out the exact merge commit. For other events, it checks out the base commit, not the pull request head.

### Calculate a version

Use `Mode: calculate` to validate a release decision and get a version without publishing.
The action does not change releases, tags, labels, or comments in this mode, even when `WhatIf` is `false`.
Use a workflow token that can read contents and pull requests in the target repository.

```yaml
- name: Calculate the release version
  id: calculate
  uses: PSModule/Release-GHRepository@<released-commit-sha>
  with:
    Mode: calculate
```

On `pull_request`, the action calculates a prerelease for the current open pull request.
On a branch push other than a push to the target repository's default branch, it also calculates a prerelease.
The open pull request must match the source repository, branch name, and exact pushed commit.
The `release:prerelease` label is not necessary in either case.
If more than one pull request matches, set `PullRequest` to the target `OWNER/REPO#NUMBER`.
For a push in a fork, always set `PullRequest`.
The action checks the selected pull request before it uses its labels.

The action calculates a stable version only on a push to the target repository's default branch.
It uses the labels of a pull request with that base repository, base branch, and merge commit.
If there is no such pull request, the push needs a configured `DefaultBump` of `patch`, `minor`, or `major`.

The action reads the current labels and latest stable release from the target repository.
If GitHub reports no latest stable release, the action uses `0.0.0` as the baseline.
A failed read, a stale pull request, or an invalid decision fails the run without outputs.

Use a separate read-only job for the [required release decision check][release-decision-check].
Include `labeled` and `unlabeled` to check label changes. Do not use a path filter to skip the check.
Apply `release:skip` when a change does not need a release.
If a fork contribution needs publication, follow [Prerelease a fork contribution][fork-prerelease].

## Inputs

`SettingsFilePath` selects the settings file. For the other inputs, a file value overrides the default.
A nonempty input overrides the file value, even if the input equals the default. For Boolean settings, `false` overrides the file value.
If you omit an input or supply `null` or an empty string, the action keeps the file value.

| Name | Description | Effective default | Required |
| --- | --- | --- | --- |
| `Mode` | Use `calculate` for a read-only version or `publish` for the existing pull request publication workflow. | `publish` | false |
| `PullRequest` | Select a pull request as `OWNER/REPO#NUMBER` for a branch push in Calculate mode. | `''` | false |
| `AutoCleanup` | Delete prereleases after the pull request closes. | `true` | false |
| `SettingsFilePath` | Select the repository settings file before startup. | `.github\auto-release.yml` | false |
| `DefaultBump` | Select the bump when no bump or skip label exists. Accepts exactly `none`, `patch`, `minor`, or `major` with case-sensitive matching. | `none` | false |
| `CreateMajorTag` | Create or update the floating major tag after a stable release. | `true` | false |
| `CreateMinorTag` | Create or update the floating minor tag after a stable release. | `true` | false |
| `DatePrereleaseFormat` | Append a [.NET date and time format](https://learn.microsoft.com/en-us/dotnet/standard/base-types/standard-date-and-time-format-strings) to prerelease versions. | `''` | false |
| `IncrementalPrerelease` | Enable prerelease numbering. When false, replace a release that has the same calculated prerelease tag. | `true` | false |
| `UsePRTitleAsReleaseName` | Use the pull-request title as the GitHub Release name. | `false` | false |
| `UsePRBodyAsReleaseNotes` | Use the pull-request body as release notes. | `true` | false |
| `UsePRTitleAsNotesHeading` | Add the pull-request title and number as the release-notes heading. | `true` | false |
| `VersionPrefix` | Prefix the version number. | `v` | false |
| `WhatIf` | Log release and label changes without mutating repository state. | `false` | false |
| `Debug` | Enable GitHub-Script debug output. | `false` | false |
| `Verbose` | Enable GitHub-Script verbose output. | `false` | false |
| `Version` | Select the GitHub module dependency by exact version or NuGet version range. | `''` (latest) | false |
| `Prerelease` | Allow a prerelease version of the GitHub module dependency. This does not select a repository prerelease. | `false` | false |
| `WorkingDirectory` | Set the execution directory before GitHub-Script starts. Relative values use `github.workspace`. | `github.workspace` | false |

Use `release:prerelease` to publish a repository prerelease. The `Prerelease` input only controls the GitHub module version.

### Settings file path

Omit `SettingsFilePath` to select `.github\auto-release.yml`. To select a different file, supply its path.
Use a file system path. It can contain spaces or brackets.
Do not supply an empty path, a path that contains only whitespace, or a directory.
If the file does not exist, the action uses the defaults and nonempty inputs.

File selection and execution follow this order:

1. The action starts from `github.workspace` unless you supply a nonempty `WorkingDirectory` input. It resolves a relative `WorkingDirectory` from `github.workspace`.
2. The action resolves a relative `SettingsFilePath` from that directory. It uses an absolute path as supplied.
3. The action reads the file once. If the file specifies a relative `WorkingDirectory`, the action resolves it from `github.workspace`, not from the file's directory.
4. The action applies the defaults from `action.yml`, then the file values, then nonempty inputs. It runs in the resulting `WorkingDirectory` without selecting another settings file.

Use the input names in the table as YAML keys, except `SettingsFilePath`. The file must contain a YAML mapping.
The action checks the defaults, the file values, and all nonempty inputs before GitHub-Script starts.
It rejects unknown keys, null file values, and invalid values, even if a later input would override them.
Each specified working directory must exist.

For Boolean settings, use `true` or `false`. You can also use these words as strings in any letter case. Do not add spaces.
The action accepts text values as written. Use a value from the table for `DefaultBump`.

The action reports whether a label, a workflow input, or the settings file supplies the bump.
For example, if the file sets `DefaultBump: major`, omit the input to use `major`. Set the input to `patch` to use `patch`.
Set the input to `none` to require one bump label or `release:skip` even if the file sets a default bump.

To remove the prefix or date suffix, set `VersionPrefix: ''` or `DatePrereleaseFormat: ''` in the file.
To use the latest version of the GitHub module, set `Version: ''` in the file.

```yaml
DatePrereleaseFormat: 'yyyyMMddHHmm'
DefaultBump: patch
IncrementalPrerelease: false
VersionPrefix: ''
Debug: false
Verbose: true
Version: '[0.43.0, 1.0.0)'
Prerelease: false
WorkingDirectory: '.'
```

To use a minor bump and turn off cleanup for one run:

```yaml
with:
  DefaultBump: minor
  AutoCleanup: false
```

To use a custom settings file and run without changing the repository:

```yaml
with:
  SettingsFilePath: .github\repository-release.settings.yml
  WhatIf: true
```

## Outputs

These outputs are available only in Calculate mode. For example, read `steps.calculate.outputs.ReleaseVersion` after the step above.

| Name | Description |
| --- | --- |
| `Decision` | `release` if the version is valid. `skip` for a valid `release:skip` decision. |
| `ReleaseVersion` | The calculated SemVer string without `VersionPrefix`. Empty for `skip`. |
| `CalculatedAt` | The ISO 8601 UTC instant used to calculate a date-dependent prerelease. Empty for other results. |

`Version` remains the GitHub module dependency input. It does not accept the calculated release version.

## Upgrade the action

Use the [MSX consumer upgrade procedure][consumer-upgrades] to plan the upgrade.
Read the [release notes][release-notes] for each applicable release after the one your workflow uses, through the target release.
Apply only the changes that affect your repository. Update the action pin and make those changes in the same pull request.

If your workflow relies on an automatic patch bump, set `DefaultBump: patch` in the settings file or action inputs.

## Contributing

Follow the [MSX coding standards](https://msxorg.github.io/docs/Coding-Standards/) and [contribution workflow](https://msxorg.github.io/docs/Ways-of-Working/Contribution-Workflow/).

Run the local tests with PowerShell 7, Pester 6.1.0, powershell-yaml 0.4.12, PSSemVer 1.1.10, and the GitHub module.
The tests do not need GitHub credentials.

```powershell
Import-Module -Name Pester -RequiredVersion 6.1.0
Invoke-Pester -Path .\tests
```

The tests run the settings and version code. They simulate GitHub responses and prevent repository writes.
The caller job runs the composite action with `WhatIf: true`. These checks do not verify live publication or concurrent release runs.

[automation-labels]: https://msx.no/docs/Ways-of-Working/Automation-Labels/#namespacing
[release-decision-check]: https://msx.no/docs/Capabilities/release-management/design/#required-pre-merge-decision-check
[fork-prerelease]: https://msx.no/docs/Capabilities/release-management/design/#prerelease-a-fork-contribution
[consumer-upgrades]: https://msx.no/docs/Ways-of-Working/Consumer-Upgrades/
[release-notes]: https://github.com/PSModule/Release-GHRepository/releases
