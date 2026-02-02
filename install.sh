#!/bin/bash
set -e

# Detect OS
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

# Normalize architecture
case $ARCH in
  x86_64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

# Validate OS
if [[ "$OS" != "linux" && "$OS" != "darwin" ]]; then
  echo "Unsupported OS: $OS"
  echo "Only Linux and macOS are supported."
  exit 1
fi

# GitHub repo info
REPO="prassoai/macroscope-local"
VERSION="${1:-latest}"  # Allow version override as first argument

echo "Installing Macroscope CLI for ${OS}-${ARCH}..."

# Download URL
if [ "$VERSION" = "latest" ]; then
  URL="https://github.com/${REPO}/releases/latest/download/macroscope-${OS}-${ARCH}"
else
  URL="https://github.com/${REPO}/releases/download/${VERSION}/macroscope-${OS}-${ARCH}"
fi

# Create temp directory
TMP_DIR=$(mktemp -d)
trap "rm -rf $TMP_DIR" EXIT

# Download binary
echo "Downloading from: $URL"
if ! curl -fL "$URL" -o "$TMP_DIR/macroscope"; then
  echo "Error: Failed to download macroscope"
  echo "Please check that the release exists for your platform (${OS}-${ARCH})"
  exit 1
fi

# Make executable
chmod +x "$TMP_DIR/macroscope"

# Install to /usr/local/bin (may require sudo)
INSTALL_DIR="/usr/local/bin"
if [ -w "$INSTALL_DIR" ]; then
  mv "$TMP_DIR/macroscope" "$INSTALL_DIR/macroscope"
else
  echo "Installing to $INSTALL_DIR (requires sudo)..."
  sudo mv "$TMP_DIR/macroscope" "$INSTALL_DIR/macroscope"
fi

echo ""
echo "✓ Macroscope installed successfully to $INSTALL_DIR/macroscope"
echo ""
echo "Verify installation:"
echo "  macroscope version"
echo ""
echo "Get started:"
echo "  macroscope review"
