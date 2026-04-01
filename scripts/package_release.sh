#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <arm64|x86_64> <output-dir>" >&2
  exit 1
fi

ARCH="$1"
OUTPUT_DIR="$2"

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    echo "unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_DIR=".build/release"
BINARY_PATH="$BUILD_DIR/update"
PACKAGE_DIR="$OUTPUT_DIR/package-$ARCH"
COMPLETIONS_DIR="$PACKAGE_DIR/completions"
ARTIFACT_PATH="$OUTPUT_DIR/update-macos-$ARCH.tar.gz"

rm -rf "$PACKAGE_DIR"
mkdir -p "$COMPLETIONS_DIR" "$OUTPUT_DIR"

swift build -c release

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "release binary not found at $BINARY_PATH" >&2
  exit 1
fi

VERSION="$($BINARY_PATH --version 2>/dev/null || echo "unknown")"

cp "$BINARY_PATH" "$PACKAGE_DIR/update"
cp README.md "$PACKAGE_DIR/README.md"
printf '%s\n' "$VERSION" > "$PACKAGE_DIR/version.txt"

"$BINARY_PATH" completions bash > "$COMPLETIONS_DIR/update.bash"
"$BINARY_PATH" completions zsh > "$COMPLETIONS_DIR/_update"
"$BINARY_PATH" completions fish > "$COMPLETIONS_DIR/update.fish"

chmod 755 "$PACKAGE_DIR/update"

COPYFILE_DISABLE=1 tar -czf "$ARTIFACT_PATH" -C "$PACKAGE_DIR" .

echo "created $ARTIFACT_PATH"
