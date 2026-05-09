#!/usr/bin/env bash
set -euo pipefail

APP="zdu"
REPO="mjgil-zig/zdu"
INSTALL_DIR="${ZDU_INSTALL_DIR:-$HOME/.local/bin}"
VERSION="${VERSION:-latest}"
MODIFY_PATH=1

usage() {
  cat <<EOF
Install zdu.

Usage:
  curl -fsSL https://mjgil.com/zdu/install.sh | bash
  curl -fsSL https://mjgil.com/zdu/install.sh | bash -s -- --version 0.1.0
  curl -fsSL https://mjgil.com/zdu/install.sh | bash -s -- --dir ~/.local/bin
  curl -fsSL https://mjgil.com/zdu/install.sh | bash -s -- --no-modify-path

Options:
  -v, --version <version>       Install a specific version, e.g. 0.1.0 or v0.1.0
  -d, --dir <directory>         Install directory. Default: ~/.local/bin
      --no-modify-path          Do not edit shell startup files
  -h, --help                    Show this help

Environment:
  VERSION=<version>             Same as --version
  ZDU_INSTALL_DIR=<directory>   Same as --dir
EOF
}

err() {
  echo "zdu installer: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || err "required command not found: $1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -v|--version)
      [ -n "${2:-}" ] || err "--version requires an argument"
      VERSION="$2"
      shift 2
      ;;
    -d|--dir|--install-dir)
      [ -n "${2:-}" ] || err "--dir requires an argument"
      INSTALL_DIR="$2"
      shift 2
      ;;
    --no-modify-path)
      MODIFY_PATH=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "unknown option: $1"
      ;;
  esac
done

need curl
need tar
need uname
need mktemp
need install

raw_os="$(uname -s)"
case "$raw_os" in
  Darwin*) os="macos" ;;
  Linux*)  os="linux" ;;
  *)       err "unsupported OS: $raw_os" ;;
esac

raw_arch="$(uname -m)"
case "$raw_arch" in
  x86_64|amd64)  arch="x86_64" ;;
  arm64|aarch64) arch="aarch64" ;;
  *)             err "unsupported architecture: $raw_arch" ;;
esac

# If a terminal is running under Rosetta on Apple Silicon, prefer the arm64 binary.
if [ "$os" = "macos" ] && [ "$arch" = "x86_64" ]; then
  if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ]; then
    arch="aarch64"
  fi
fi

asset="${APP}-${arch}-${os}.tar.gz"

if [ "$VERSION" = "latest" ]; then
  url="https://github.com/${REPO}/releases/latest/download/${asset}"
else
  version_no_v="${VERSION#v}"
  url="https://github.com/${REPO}/releases/download/v${version_no_v}/${asset}"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Installing ${APP} ${VERSION} for ${os}/${arch}"
echo "Downloading ${asset}"

curl -fL "$url" -o "$tmp/$asset"

if curl -fsL "$url.sha256" -o "$tmp/$asset.sha256"; then
  echo "Verifying checksum"

  if command -v shasum >/dev/null 2>&1; then
    (
      cd "$tmp"
      shasum -a 256 -c "$asset.sha256"
    )
  elif command -v sha256sum >/dev/null 2>&1; then
    (
      cd "$tmp"
      sha256sum -c "$asset.sha256"
    )
  else
    echo "No SHA-256 verification tool found; skipping checksum verification." >&2
  fi
else
  echo "No checksum asset found; continuing without checksum verification." >&2
fi

tar -xzf "$tmp/$asset" -C "$tmp"

install -d "$INSTALL_DIR"
install -m 755 "$tmp/$APP" "$INSTALL_DIR/$APP"

append_path_line() {
  file="$1"
  line="$2"

  mkdir -p "$(dirname "$file")"
  touch "$file"

  if grep -Fqx "$line" "$file"; then
    return 0
  fi

  {
    echo ""
    echo "# zdu"
    echo "$line"
  } >> "$file"
}

add_to_path() {
  case "${SHELL:-}" in
    */fish)
      config="$HOME/.config/fish/config.fish"
      line="fish_add_path \"$INSTALL_DIR\""
      ;;
    */zsh)
      config="${ZDOTDIR:-$HOME}/.zshrc"
      line="export PATH=\"$INSTALL_DIR:\$PATH\""
      ;;
    */bash)
      if [ "$os" = "macos" ]; then
        config="$HOME/.bash_profile"
      else
        config="$HOME/.bashrc"
      fi
      line="export PATH=\"$INSTALL_DIR:\$PATH\""
      ;;
    *)
      echo "Installed, but could not detect your shell config file."
      echo "Add this to your shell config:"
      echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
      return 0
      ;;
  esac

  if printf '%s' ":${PATH:-}:" | grep -Fq ":$INSTALL_DIR:"; then
    return 0
  fi

  append_path_line "$config" "$line"
  echo "Added $INSTALL_DIR to PATH in $config"
}

if [ "$MODIFY_PATH" -eq 1 ]; then
  add_to_path
fi

if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_PATH:-}" ]; then
  echo "$INSTALL_DIR" >> "$GITHUB_PATH"
fi

echo ""
echo "zdu installed to: $INSTALL_DIR/$APP"
echo ""
echo "Run it now with:"
echo "  $INSTALL_DIR/$APP"
echo ""
echo "After restarting your shell, you should be able to run:"
echo "  zdu"