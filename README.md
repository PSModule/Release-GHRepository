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

On a pull request run with `WhatIf: false`, the action creates missing owned labels and updates their colors and descriptions. It leaves all other labels unchanged. A run without a pull request does not update labels or publish releases.

An open pull request with `release:prerelease` publishes a prerelease from its explicit bump or `DefaultBump`. The prerelease name uses the head branch, while its tag targets the exact pull request head commit.

When a pull request merges into the default branch, the close event uses the resolved bump unless the pull request carries `release:skip`. The stable version tag points to the commit GitHub added to the default branch. For a squash merge, this is the squash commit, not the pull request head or a newer branch tip. The action does not move an existing version tag. After publication, it updates only the enabled major and minor tags to the same commit.

A closed pull request cleans up its prereleases when `AutoCleanup` is enabled. `release:skip` prevents publication but does not stop cleanup on close.

Cleanup uses the effective `VersionPrefix` to locate the version core, then matches the exact case-sensitive branch identifier. Version-like text in a prefix cannot select another branch's release. Empty and hyphenated prefixes remain valid. If you change the prefix, automatic cleanup retains releases under earlier prefixes. Close active prerelease series before a prefix change, or retain their releases for separate authorized cleanup.

The workflow must run for `labeled` and `unlabeled` events so both valid and invalid label transitions are evaluated. Do not use a workflow path filter to bypass the release decision on non-artifact changes; use `release:skip`.

This action is built on [GitHub-Script](https://github.com/PSModule/GitHub-Script), which uses the workflow token by default.

## Usage

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
  contents: write # Required to create releases and tags
  issues: write # Required to provision repository labels
  pull-requests: write # Required to comment on pull requests

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

Select the full immutable commit SHA of an authorized, published release that supports this contract. An open pull request's head is a development candidate, not a production dependency. A controlled major tag is an option only when the producer's release automation exclusively maintains it within its compatible stable line.

The `pull_request` workflow publishes only when the head branch is in the same repository. It checks out the base commit or the exact merged commit, not the pull request head.

The publishing job skips fork pull requests. To publish a prerelease for a fork change, review and approve the exact revision before merging the fork pull request into a separate branch in the base repository. Moving code to that branch does not replace review. Open a pull request from the reviewed branch and apply `release:prerelease`.

## Inputs

Each setting has a matching named input and an effective standard in its description. One private schema in `action.yml` defines the types and standards, not a bundled settings file. All 16 file-configurable inputs have no concrete native defaults: omitted, null, and empty-string inputs retain file values. A supplied nonempty input overrides the file even when equal to a standard; explicit `false` remains an override. `SettingsFilePath` is a separate selector.

| Name | Description | Effective default | Required |
| --- | --- | --- | --- |
| `AutoCleanup` | Delete prereleases after the pull request closes. | `true` | false |
| `SettingsFilePath` | Select the repository settings file before startup. | `.github\release.settings.yml` | false |
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
| `Debug` | Enable GitHub-Script debug output. | `false` | false |
| `Verbose` | Enable GitHub-Script verbose output. | `false` | false |
| `Version` | Select the GitHub module dependency by exact version or NuGet version range. | `''` (latest) | false |
| `Prerelease` | Allow a prerelease version of the GitHub module dependency. This does not select a repository prerelease. | `false` | false |
| `WorkingDirectory` | Set the execution directory before GitHub-Script starts. Relative values use `github.workspace`. | `github.workspace` | false |

Use the `release:prerelease` label to select repository prerelease behavior. The similarly named `Prerelease` action input only controls dependency resolution for the GitHub module used internally.

### Settings file path

The default repository settings file path is `.github\release.settings.yml`. Use `SettingsFilePath` to select a custom file. Omit this selector to use the default path. An empty or whitespace-only path is invalid. The action supports literal paths with spaces or brackets. A directory or a non-file-system provider is not a settings file.

The removed `.github\auto-release.yml` path has no fallback or alias, even when you select it explicitly. The bootstrap checks that path in the initial directory, before GitHub-Script starts. If the old file exists and you select the default path, startup fails. An existing custom file remains supported. If a custom file is missing and the old file exists, startup also fails.

If the selected file and the old default file are both absent, valid standards and nonempty named inputs remain effective. A file-defined `WorkingDirectory` does not change file selection or the location of the old-file check.

File selection and execution follow this order:

1. Resolve a supplied nonempty `WorkingDirectory` input from `github.workspace`. Without that input, use `github.workspace` as the initial directory.
2. Resolve a relative `SettingsFilePath` from that initial directory. An absolute selector keeps its literal path.
3. Read the selected file once. Resolve each relative file-defined `WorkingDirectory` from `github.workspace`, not from the file's directory.
4. Apply the private schema standards, the selected file, then known nonempty named inputs. Use the effective `WorkingDirectory` for execution without selecting another file.

`src\Initialize-ReleaseConfiguration.ps1` resolves and validates all settings before GitHub-Script starts. It forwards `Debug`, `Verbose`, `WorkingDirectory`, `Version`, and `Prerelease` to that action. The release script receives the resolved policy and does not read or merge the file again. Every supplied directory must exist, even when a later input would override it.

The bootstrap reads the private schema, not description prose. There is no bundled defaults asset or input-presence heuristic. An owned bump label overrides the valid effective `DefaultBump`. The action reports whether the bump comes from an owned label, a named input, a repository setting, or the shared standard.

The runner does not expose its original caller-supplied key list to a composite action after it merges native defaults. A concrete native default would make omission indistinguishable from an explicitly supplied equal value. For example, with file policy `DefaultBump: major`, omitting the input retains major; supplying `DefaultBump: patch` deliberately overrides it. The action never detects presence by comparing values with a standard.

The runner represents both omitted and explicitly empty composite inputs as empty text. Both mean no override for file-configurable settings. Empty inputs cannot clear text configured in a file. Set `VersionPrefix: ''` or `DatePrereleaseFormat: ''` in the file to remove the prefix or date suffix. Set `Version: ''` in the file to select the latest GitHub dependency.

There is no reserved omission value. Nonempty inputs go through normal validation, including whitespace. Booleans accept YAML `true` and `false` or case-insensitive strings containing exactly `true` or `false`; whitespace-only booleans and bumps are invalid. Text values remain literal strings. Every file layer is validated, so valid named inputs or owned labels cannot hide invalid standards or repository settings.

The repository file must contain a mapping of supported settings. Every input in the table except `SettingsFilePath` is a valid file key. The file can contain only the settings that differ from the standards. Unknown keys, removed keys, null values, and invalid values fail before GitHub-Script starts. A valid override cannot hide an invalid lower layer.

```yaml
# .github\release.settings.yml
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

For an intentional custom path:

```yaml
with:
  SettingsFilePath: .github\custom-release.settings.yml
```

For an invocation-specific minor bump, even when the repository configures major:

```yaml
with:
  DefaultBump: minor
  AutoCleanup: false
```

To select a custom settings file, inherit its bump, and force a read-only invocation:

```yaml
with:
  SettingsFilePath: .github\repository-release.settings.yml
  WhatIf: true
```

`DatePrereleaseFormat` formats only the existing prerelease suffix. `DefaultBump` does not support date versioning or a disabled automatic bump. Use `release:skip` when validation must succeed without publication.

## Release records

The release-bound pull request's title and complete body contain the incremental adoption instructions, changed consumer interfaces, verification evidence, and resolved release decision. Compose those records across the release range you adopt; repository guides do not replace them.

The [owned-label release record](https://github.com/PSModule/Release-GHRepository/pull/109) contains the caller migration and publisher bootstrap requirements for this contract.

## Contributing

Follow the [MSX coding standards](https://msxorg.github.io/docs/Coding-Standards/) and [contribution workflow](https://msxorg.github.io/docs/Ways-of-Working/Contribution-Workflow/). Keep release-decision changes separate from changes to stable-publication authority and recovery.

For the credential-free local loop, use PowerShell 7 with Pester 6.1.0, powershell-yaml 0.4.12, PSSemVer 1.1.10, and the GitHub module installed:

```powershell
Import-Module -Name Pester -RequiredVersion 6.1.0
Invoke-Pester -Path .\tests
```

Tests use the real bootstrap, resolver, YAML parser, and version library. Controller tests simulate GitHub responses and guard publication commands; they do not establish live API or permission behavior. The read-only caller job uses the actual composite with `WhatIf: true`. Neither check establishes live publication or concurrency contention.
