# update

Agent-first macOS app update checker and installer.

## Build

```bash
swift build
```

## Run

```bash
swift run update --help
```

## Common commands

```bash
swift run update scan run --format json
swift run update apps list --format json
swift run update apps check 'name:Google Chrome' --provider brew --format json
swift run update apps update 'name:Google Chrome' --dry-run --format json
swift run update config show --scope effective --format json
swift run update schema commands --format json
swift run update completions zsh
```

## Safety

- Use `--dry-run` before mutating commands.
- Live app updates require confirmation or `--yes`.
- The spec source file in `docs/specs/` is intentionally not committed.
