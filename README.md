# update

`update` is an agent-first macOS CLI for discovering, previewing, and applying app updates.

It scans installed `.app` bundles, tracks them locally, checks multiple update providers, emits machine-readable output by default in non-interactive contexts, and makes mutating actions previewable with `--dry-run`.

## What it does

- scans installed macOS apps from one or more directories
- checks for updates across:
  - Homebrew casks
  - Mac App Store
  - Sparkle feeds
  - GitHub releases
  - Electron updater metadata
  - optional curated metadata
- previews update and adoption plans before execution
- supports ignore rules and version skips
- exposes config and command metadata through CLI schema commands
- emits `json`, `ndjson`, `plain`, or human-readable output

## Requirements

- macOS 14+
- Swift 6 toolchain
- Xcode Command Line Tools or Xcode

Optional tools unlock specific providers/executors:

- `brew` for Homebrew-backed checks, updates, and adoption
- `mas` for Mac App Store-backed checks and updates

## Installation

### Option 1: Homebrew tap

```bash
brew tap sammyjoyce/update
brew install update
```

### Option 2: Direct install script

```bash
curl -fsSL https://raw.githubusercontent.com/sammyjoyce/update/main/scripts/install.sh | bash
```

Install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/sammyjoyce/update/main/scripts/install.sh | bash -s -- --version v1.0.0
```

Install to a custom directory:

```bash
curl -fsSL https://raw.githubusercontent.com/sammyjoyce/update/main/scripts/install.sh | bash -s -- --bin-dir /usr/local/bin
```

### Option 3: Build from source

```bash
git clone git@github.com:sammyjoyce/update.git
cd update
swift build -c release
```

The compiled binary will be available at:

```bash
.build/release/update
```

## Quick start

### 1. Scan installed apps

```bash
update scan --format json
```

### 2. List tracked apps

```bash
update apps list --format json
```

### 3. Check one app for updates

```bash
update apps check 'name:Google Chrome' --provider brew --format json
```

### 4. Preview an update without changing anything

```bash
update apps update 'name:Google Chrome' --provider brew --dry-run --format json
```

### 5. Inspect the config and schema surface

```bash
update config show --scope effective --format json
update schema commands --format json
update schema command apps.check --format json
```

## Core command groups

### App lifecycle

```bash
update apps list [selectors...]
update apps get <selector>
update apps check [selectors...]
update apps sources <selector>
update apps update [selectors...] [--all]
update apps adopt [selectors...] [--all]
```

### Ignore and skip management

```bash
update ignores list
update ignores add [selectors...]
update ignores remove [selectors...]

update skips list
update skips add <selector>
update skips remove [selectors...]
```

### Environment, config, and introspection

```bash
update scan run
update doctor run

update config show
update config get <key>
update config set <key> <value>
update config unset <key>
update config reset [key]

update schema commands
update schema command <group.command>
update schema config
update schema errors
update schema examples <group.command>

update completions <shell>
```

## Compatibility aliases

The canonical interface is grouped (`update apps check`, `update ignores add`, and so on), but the CLI also ships compatibility aliases for convenience:

```bash
update list
update check
update sources
update update
update adopt
update ignore
update unignore
update skip
update unskip
update scan
update doctor
```

For automation and generated scripts, prefer the grouped form.

## Selector forms

The CLI supports typed selectors:

```text
id:app_...
bundle:com.google.Chrome
path:/Applications/Google Chrome.app
name:Google Chrome
```

For durable automation, prefer `id:` after the first lookup.

## Output modes

`update` is designed for both humans and automation.

- TTY stdout defaults to human-readable output
- non-TTY single-item output defaults to JSON
- non-TTY collection output defaults to NDJSON

You can force a format explicitly:

```bash
update apps list --format json
update apps list --format ndjson
update apps list --format plain
```

Field masks are supported on read commands:

```bash
update apps list --fields app_id,name,installed_version,update_state --format json
```

## Safety model

The CLI is intentionally conservative.

- use `--dry-run` before mutating commands
- live app updates and adoption require confirmation unless you pass `--yes`
- non-interactive mutation without confirmation fails instead of guessing
- app bundle replacement refuses privileged paths unless `--allow-sudo` is set
- remote metadata is treated as untrusted text

## Release and distribution

This repo ships two automation paths:

- `.github/workflows/ci.yml`
  - builds and tests on pushes and pull requests
- `.github/workflows/release.yml`
  - builds tagged macOS binaries
  - publishes GitHub Release assets
  - generates `checksums.txt`
  - updates the Homebrew tap when `HOMEBREW_TAP_TOKEN` is configured

Release artifacts are packaged as:

- `update-macos-arm64.tar.gz`
- `update-macos-x86_64.tar.gz`
- `checksums.txt`

## Examples

### Check update evidence for a single app

```bash
update apps sources 'name:Google Chrome' --format json
```

### Ignore update prompts for one app

```bash
update ignores add 'name:Google Chrome' --scope updates --reason 'managed elsewhere' --format json
```

### Skip one specific version

```bash
update skips add 'name:Google Chrome' --version 146.0.7680.165 --format json
```

### Generate shell completions

```bash
update completions zsh > _update
update completions bash > update.bash
update completions fish > update.fish
```

## Development

### Build

```bash
swift build
```

### Test

```bash
swift test
```

### Useful local checks

```bash
swift run update --help
swift run update doctor run --format json
swift run update apps check 'name:Google Chrome' --provider brew --format json
swift run update apps update 'name:Google Chrome' --provider brew --dry-run --format json
```

## Repository layout

```text
.github/workflows/
scripts/
Package.swift
Sources/
  updatest/
  UpdatestCore/
Tests/
  UpdateCoreTests/
```

- `Sources/updatest/` contains the CLI entrypoints and command wiring
- `Sources/UpdatestCore/` contains the models, services, coordinators, and provider logic
- `scripts/` contains packaging, installer, and tap update scripts
- `Tests/UpdateCoreTests/` contains core regression tests

## Contributing

Issues and pull requests are welcome.

If you change the CLI surface, update examples and schema-related behavior together so the human-facing docs and machine-facing contract stay aligned.

## Notes

- The spec source file under `docs/specs/` is intentionally kept out of git.
- No license file has been added yet.
