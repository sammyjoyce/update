# Update CLI Design

Date: 2026-04-01
Status: Approved
Scope: SwiftPM-only v1 implementation of the `update` CLI contract in `docs/specs/updatist.md`

## Goals

- Implement the stable grouped CLI surface from the spec.
- Keep machine-readable output as the primary contract.
- Support real provider and executor behavior for Homebrew, App Store, Sparkle, GitHub, Electron, and opt-in metadata.
- Make all mutations previewable through typed plans.
- Keep the implementation testable by deriving runtime and schema behavior from shared command metadata.

## Architecture

### Package layout

```text
Package.swift
Sources/
  UpdateCore/
    Models/
    Util/
    Services/
    Sources/
    Coordinator/
    CommandSpecs/
  update/
    main.swift
Tests/
  UpdateCoreTests/
```

### Responsibility split

#### `UpdateCore`

- data models and envelopes
- selector parsing and input hardening
- state/config persistence
- app scanning
- provider detection and candidate selection
- executor implementations
- schema descriptors and rendering

#### `update`

- ArgumentParser command tree
- global flag parsing
- format resolution
- stdout/stderr handling
- exit code mapping

## Command contract

The canonical stable surface is grouped:

- `apps list|get|check|sources|update|adopt`
- `ignores list|add|remove`
- `skips list|add|remove`
- `scan run`
- `doctor run`
- `config show|get|set|unset|reset`
- `schema commands|command|config|errors|examples`
- `completions <shell>`

Human convenience aliases resolve to the same internal descriptors.

### Input rules

- typed selectors: `id:`, `bundle:`, `path:`, `name:`
- `id:` is the durable replay-safe selector
- `path:` must be absolute, normalized, and end in `.app`
- unsafe input is rejected, not repaired
- mutating commands accept both positional sugar and raw JSON `--input`

### Output rules

- TTY stdout defaults to `human`
- non-TTY single item defaults to `json`
- non-TTY collection defaults to `ndjson`
- explicit `--format` wins

Stable machine contracts:

- JSON item envelope
- JSON collection envelope
- JSON mutation envelope
- NDJSON event streams with terminal summary
- stable plain read output

## Provider and executor model

The implementation keeps these concepts separate:

- `provider`: where candidate metadata came from
- `executor`: how the update is applied
- `discovered_by`: how the candidate was found

### Providers

#### Homebrew

Detection:
- inspect casks through brew JSON output
- match by bundle id first, then app name
- use outdated cask data to improve confidence

Execution:
- `brew upgrade --cask`
- `brew reinstall --cask`
- `brew install --cask --adopt`

#### App Store

Detection:
- iTunes Lookup by bundle id
- `mas outdated` as a secondary signal

Execution:
- `mas upgrade <trackId>`

#### Sparkle

Detection:
- `SUFeedURL` from `Info.plist`
- parse appcast XML
- pick newest compatible enclosure

Execution:
- download archive/dmg
- extract or mount
- hand off to `bundle_replace`

#### GitHub

Detection:
- `manual_sources` first
- latest release API
- asset selection by explicit pattern or conservative heuristics

Execution:
- download release asset
- hand off to `bundle_replace`

#### Electron

Detection:
- inspect app resources and updater metadata
- parse `app-update.yml`, `latest-mac.yml`, or local hints

Execution:
- hand off to `bundle_replace`

#### Metadata

Detection:
- only when explicitly enabled
- only bundle id and minimal version metadata leave the machine

Execution:
- metadata influences provider/executor selection but is not itself an executor

### Executors

#### `brew_cask`
- shells out to brew
- captures structured failures

#### `app_store`
- shells out to `mas`
- requires app store id from provider evidence

#### `bundle_replace`
- downloads into temp storage
- mounts or extracts payloads
- finds the replacement `.app`
- validates bundle identity and optional team id
- replaces atomically where practical
- restores on failure

## Candidate selection

Selection follows the spec order:

1. build all candidates
2. drop invalid or policy-failing candidates
3. hide low-confidence candidates unless enabled
4. sort by `provider_priority`
5. tie-break equal versions by executor determinism:
   - `app_store`
   - `brew_cask`
   - `bundle_replace`
6. persist selected and rejected candidates with reason codes

## Safety model

- mutations require confirmation unless `--yes`
- non-interactive mutation without `--yes` fails with exit code `4`
- `--allow-sudo` permits escalation, never silent escalation
- untrusted remote text is sanitized before display or serialization
- path traversal and malformed selectors are rejected early

## Caching and freshness

Default TTLs:

- brew: `1h`
- appstore: `1h`
- sparkle: `6h`
- github: `6h`
- electron: `6h`
- metadata: `24h`

Read-only state commands use persisted state only. Active provider commands may use cached evidence unless `--refresh` is passed. Offline mode forbids network access.

## Testing strategy

### Unit tests

- selector parsing and hardening
- version comparison
- duration parsing
- field masks
- schema rendering
- config precedence
- plan precondition validation
- appcast parsing

### Integration-style tests

- scan to persist to list flow
- JSON, NDJSON, and plain output contracts
- candidate selection with fixture provider data
- bundle replacement behavior on temp fixtures
- config and state round-trips

### Manual verification

- `swift build`
- targeted CLI checks for scan/list/get/check/schema/config
- dry-run mutation verification before live mutation testing

## Implementation phases

### Phase 1
- establish the SwiftPM executable entrypoint
- fix foundational model/service compile issues
- implement `scan run`, `apps list`, `apps get`, and `doctor run`

### Phase 2
- add `apps check` and `apps sources`
- add real candidate selection and persisted evidence updates
- add `config` and `schema` subcommands

### Phase 3
- add mutating workflows: update/adopt/ignores/skips
- implement replayable plans and confirmations
- implement real executors including `bundle_replace`

### Phase 4
- add completions and remaining polish
- expand tests and contract verification
