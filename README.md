# Release-GHRepository

Create GitHub releases from owned pull-request labels and a configurable default bump.

This action is for repository and workflow maintainers who publish GitHub releases through the `action.yml` input interface and version-controlled release settings.

## Release decision

Release-GHRepository owns and provisions five labels:

| Label | Instruction | Valid combination |
| --- | --- | --- |
| `release:patch` | Increment the patch version. | Exactly one bump label. |
| `release:minor` | Increment the minor version. | Exactly one bump label. |
| `release:major` | Increment the major version. | Exactly one bump label. |
| `release:prerelease` | Publish from an open pull request as a prerelease. | Alone or with exactly one bump label. |
| `release:skip` | Validate without publishing a release. | Without another owned release label. |

When no owned bump or skip label exists, `DefaultBump` selects `patch`, `minor`, or `major`. Its default is `patch`, preserving the automatic patch behavior from v2. An explicit `release:patch`, `release:minor`, or `release:major` label overrides `DefaultBump`.

`release:prerelease` is a mode. It uses the explicit bump when one is present and otherwise uses `DefaultBump`. `release:skip` suppresses publication instead of applying the default.

The action rejects:

- a `DefaultBump` value other than exactly `patch`, `minor`, or `major`;
- multiple bump labels;
- `release:skip` with another owned release label.

Labels outside this set do not affect releases. Bare and legacy labels such as `Major`, `Minor`, `Patch`, `Prerelease`, `NoRelease`, `major`, `minor`, `patch`, and the retired `release:pre-release` are ignored, so a pull request carrying only those labels uses `DefaultBump`.

## How it works

On every non-WhatIf run, the action creates missing canonical labels and reconciles their colors and descriptions. It leaves all other repository labels unchanged.

An open pull request with `release:prerelease` publishes a prerelease from its explicit bump or `DefaultBump`. The prerelease name uses the head branch, while its tag targets the exact pull-request head commit. A pull request merged into the default branch publishes the resolved bump unless it carries `release:skip`. A closed pull request cleans up its prereleases when `AutoCleanup` is enabled. `release:skip` never publishes a version, but a closed skipped pull request still receives prerelease cleanup.

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
  group: ${{ github.workflow }}-${{ github.event.pull_request.merged && github.event.pull_request.base.ref || github.event.pull_request.number || github.ref }}
  cancel-in-progress: false

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
        uses: PSModule/Release-GHRepository@<released-commit-sha>
```

Select the full immutable commit SHA of an authorized, published release that supports this contract. An open pull request's head is a development candidate, not a production dependency. A controlled major tag is an option only when the producer's release automation exclusively maintains it within its compatible stable line.

The `pull_request_target` workflow checks out the trusted base branch. Do not check out or execute an untrusted pull-request head with this writable token.

## Inputs

| Name | Description | Default | Required |
| --- | --- | --- | --- |
| `AutoCleanup` | Delete prereleases after the pull request closes. | `true` | false |
| `CallerOverrides` | Supply a YAML or JSON mapping of explicit invocation overrides. These override repository settings. | `{}` | false |
| `ConfigurationFile` | Read repository settings from this file. File values override scalar action inputs, but not `CallerOverrides`. | `.github\auto-release.yml` | false |
| `DefaultBump` | Select the bump when no explicit bump or skip label exists. Accepts exactly `patch`, `minor`, or `major` with case-sensitive matching. | `patch` | false |
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

Use the `release:prerelease` label to select repository prerelease behavior. The similarly named `Prerelease` action input only controls dependency resolution for the GitHub module used internally.

### Configuration file

The default configuration file is `.github\auto-release.yml`. Change its path with `ConfigurationFile`.

Settings resolve in this order: defaults declared in `action.yml`, scalar action inputs, repository settings, then explicit `CallerOverrides`. Scalar inputs retain the existing file-over-input behavior because GitHub injects their defaults even when callers omit them. Use `CallerOverrides` for an invocation-specific override; its omitted `{}` mapping inherits repository settings without masking them.

An explicit `false` or empty string is an override, not an omitted setting. Booleans accept YAML `true` and `false` or case-insensitive strings containing exactly `true` or `false`. Text settings require strings; only `VersionPrefix` and `DatePrereleaseFormat` accept empty strings. Every supplied layer is validated before merging, so a valid override cannot hide an invalid lower-priority value.

The file and `CallerOverrides` must contain mappings. They accept the release settings from `AutoCleanup` through `WhatIf` in the input table, excluding `CallerOverrides` and `ConfigurationFile` themselves. The dependency/runtime inputs (`Debug`, `Verbose`, `Version`, `Prerelease`, and `WorkingDirectory`) are supplied separately by the caller. Unknown keys, removed keys, null values, and invalid values fail before label provisioning.

```yaml
DatePrereleaseFormat: 'yyyyMMddHHmm'
DefaultBump: patch
IncrementalPrerelease: false
VersionPrefix: ''
```

For an invocation-specific minor bump, even when the repository configures major:

```yaml
with:
  CallerOverrides: |
    DefaultBump: minor
    AutoCleanup: false
    VersionPrefix: ''
```

JSON mappings are supported too, such as `CallerOverrides: '{"DefaultBump":"minor"}'`. An explicit owned bump label still overrides the valid effective `DefaultBump`. The action reports whether the bump came from an owned label, explicit caller override, repository setting, scalar base input, or shared default.

`DatePrereleaseFormat` formats only the existing prerelease suffix. `DefaultBump` does not support date versioning or a disabled automatic bump. Use `release:skip` when validation must succeed without publication.

## Release records

The release-bound pull request's title and complete body contain the incremental adoption instructions, changed consumer interfaces, verification evidence, and resolved release decision. Compose those records across the release range you adopt; repository guides do not replace them.

The [owned-label release record](https://github.com/PSModule/Release-GHRepository/pull/109) contains the caller migration and publisher bootstrap requirements for this contract.

## Contributing

Follow the [MSX coding standards](https://msxorg.github.io/docs/Coding-Standards/) and [contribution workflow](https://msxorg.github.io/docs/Ways-of-Working/Contribution-Workflow/). Keep release-decision changes separate from changes to stable-publication authority and recovery.
