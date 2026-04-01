#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <version-tag> <checksums-path> <tap-dir>" >&2
  exit 1
fi

VERSION_TAG="$1"
CHECKSUMS_PATH="$2"
TAP_DIR="$3"
VERSION="${VERSION_TAG#v}"
FORMULA_DIR="$TAP_DIR/Formula"
FORMULA_PATH="$FORMULA_DIR/update.rb"
README_PATH="$TAP_DIR/README.md"

ARM_SHA="$(awk '$2 == "update-macos-arm64.tar.gz" { print $1 }' "$CHECKSUMS_PATH")"
INTEL_SHA="$(awk '$2 == "update-macos-x86_64.tar.gz" { print $1 }' "$CHECKSUMS_PATH")"

if [[ -z "$ARM_SHA" || -z "$INTEL_SHA" ]]; then
  echo "missing checksums for one or more release artifacts" >&2
  exit 1
fi

mkdir -p "$FORMULA_DIR"

cat > "$FORMULA_PATH" <<EOF
class Update < Formula
  desc "Agent-first macOS app update checker and installer"
  homepage "https://github.com/sammyjoyce/update"
  version "$VERSION"

  depends_on macos: :sonoma

  on_arm do
    url "https://github.com/sammyjoyce/update/releases/download/$VERSION_TAG/update-macos-arm64.tar.gz"
    sha256 "$ARM_SHA"
  end

  on_intel do
    url "https://github.com/sammyjoyce/update/releases/download/$VERSION_TAG/update-macos-x86_64.tar.gz"
    sha256 "$INTEL_SHA"
  end

  def install
    bin.install "update"
    bash_completion.install "completions/update.bash" => "update"
    zsh_completion.install "completions/_update"
    fish_completion.install "completions/update.fish"
    doc.install "README.md"
  end

  test do
    assert_match "Agent-first macOS app update checker and installer", shell_output("#{bin}/update --help")
  end
end
EOF

cat > "$README_PATH" <<'EOF'
# homebrew-update

Homebrew tap for the [update](https://github.com/sammyjoyce/update) CLI.

## Install

```bash
brew tap sammyjoyce/update
brew install update
```

## Upgrade

```bash
brew update
brew upgrade update
```
EOF

echo "updated $FORMULA_PATH"
