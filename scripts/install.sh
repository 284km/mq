#!/bin/sh
# Install a prebuilt `mq` binary from the latest GitHub Release.
#
#   curl -fsSL https://raw.githubusercontent.com/284km/mq/main/scripts/install.sh | sh
#
# Override the install directory with MQ_BINDIR (default: ~/.local/bin).
# No Mere toolchain or C compiler required — this grabs a prebuilt binary.

set -eu

REPO="284km/mq"
BINDIR="${MQ_BINDIR:-$HOME/.local/bin}"

os="$(uname -s)"
arch="$(uname -m)"

case "$os" in
  Linux)  case "$arch" in x86_64 | amd64) asset="mq-linux-x86_64" ;; *) unsupported=1 ;; esac ;;
  Darwin) case "$arch" in arm64) asset="mq-macos-arm64" ;; *) unsupported=1 ;; esac ;;
  *) unsupported=1 ;;
esac

if [ "${unsupported:-0}" = "1" ]; then
  echo "No prebuilt mq for $os/$arch." >&2
  echo "Build from source: install Mere, then 'mere install && mere -c main.mere > mq.c && clang mq.c -o mq'." >&2
  exit 1
fi

url="https://github.com/$REPO/releases/latest/download/$asset"
echo "Installing mq ($asset) to $BINDIR/mq"
mkdir -p "$BINDIR"
if ! curl -fSL "$url" -o "$BINDIR/mq"; then
  echo "download failed: $url" >&2
  echo "(has a release been published yet? see https://github.com/$REPO/releases)" >&2
  exit 1
fi
chmod +x "$BINDIR/mq"

echo "Installed: $BINDIR/mq"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "Add $BINDIR to your PATH:  export PATH=\"$BINDIR:\$PATH\"" ;;
esac
