#!/usr/bin/env bash
set -euo pipefail

REPO="sammyjoyce/update"
VERSION="latest"
BIN_DIR="${HOME}/.local/bin"
NO_MODIFY_PATH=0

usage() {
  cat <<'EOF'
Install update from GitHub Releases.

Usage:
  install.sh [--version <tag>] [--bin-dir <path>] [--no-modify-path]

Examples:
  install.sh
  install.sh --version v1.0.0
  install.sh --bin-dir /usr/local/bin
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --bin-dir|--install-dir)
      BIN_DIR="$2"
      shift 2
      ;;
    --no-modify-path)
      NO_MODIFY_PATH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$(uname -s)" in
  Darwin) ;;
  *)
    echo "update currently supports macOS distribution through this installer." >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64) ARCH="arm64" ;;
  x86_64) ARCH="x86_64" ;;
  *)
    echo "unsupported CPU architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [[ "$VERSION" != "latest" && "$VERSION" != v* ]]; then
  VERSION="v$VERSION"
fi

if [[ "$VERSION" == "latest" ]]; then
  BASE_URL="https://github.com/${REPO}/releases/latest/download"
else
  BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"
fi

ASSET_NAME="update-macos-${ARCH}.tar.gz"
CHECKSUMS_URL="${BASE_URL}/checksums.txt"
ASSET_URL="${BASE_URL}/${ASSET_NAME}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

CHECKSUMS_PATH="$WORK_DIR/checksums.txt"
ASSET_PATH="$WORK_DIR/$ASSET_NAME"
EXTRACT_DIR="$WORK_DIR/extracted"

curl -fsSL "$CHECKSUMS_URL" -o "$CHECKSUMS_PATH"
curl -fsSL "$ASSET_URL" -o "$ASSET_PATH"

EXPECTED_SHA="$(awk -v name="$ASSET_NAME" '$2 == name { print $1 }' "$CHECKSUMS_PATH")"
if [[ -z "$EXPECTED_SHA" ]]; then
  echo "checksum for $ASSET_NAME not found in checksums.txt" >&2
  exit 1
fi

ACTUAL_SHA="$(shasum -a 256 "$ASSET_PATH" | awk '{print $1}')"
if [[ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]]; then
  echo "checksum verification failed for $ASSET_NAME" >&2
  exit 1
fi

mkdir -p "$EXTRACT_DIR"
tar -xzf "$ASSET_PATH" -C "$EXTRACT_DIR"

if [[ ! -x "$EXTRACT_DIR/update" ]]; then
  echo "release archive did not contain an executable update binary" >&2
  exit 1
fi

mkdir -p "$BIN_DIR"
install -m 0755 "$EXTRACT_DIR/update" "$BIN_DIR/update"

echo "Installed update to $BIN_DIR/update"

case ":$PATH:" in
  *":$BIN_DIR:"*)
    echo "'$BIN_DIR' is already on your PATH."
    ;;
  *)
    if [[ "$NO_MODIFY_PATH" -eq 0 ]]; then
      echo "Add this to your shell profile if needed:"
      echo "  export PATH=\"$BIN_DIR:\$PATH\""
    fi
    ;;
esac
