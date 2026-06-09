#!/bin/sh

set -eu

RELEASE="${CODEX_LEAP_RELEASE:-latest}"
RELEASE_REPO="${CODEX_LEAP_REPO:-LeapInsight/codex}"
RELEASE_TAG_PREFIX="${CODEX_LEAP_TAG_PREFIX:-leap-v}"
BIN_NAME="${CODEX_LEAP_BIN_NAME:-codex-leap}"
BIN_DIR="${CODEX_LEAP_INSTALL_DIR:-$HOME/.local/bin}"
BIN_PATH="$BIN_DIR/$BIN_NAME"
CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
STANDALONE_ROOT="$CODEX_HOME_DIR/packages/leap-standalone"
RELEASES_DIR="$STANDALONE_ROOT/releases"
CURRENT_LINK="$STANDALONE_ROOT/current"
DRY_RUN=false
tmp_dir=""
path_action="already"
path_profile=""

step() {
  printf '==> %s\n' "$1"
}

usage() {
  cat <<EOF
Usage: install-leap.sh [--release TAG_OR_VERSION] [--dry-run]

Installs the LeapInsight Codex fork as "$BIN_NAME" without replacing an
official "codex" command.

Environment:
  CODEX_LEAP_RELEASE      Release tag or version to install; default: latest.
  CODEX_LEAP_REPO         GitHub repository to download from; default: LeapInsight/codex.
  CODEX_LEAP_BIN_NAME     Visible command name; default: codex-leap.
  CODEX_LEAP_INSTALL_DIR  Directory for the visible command; default: ~/.local/bin.
  CODEX_HOME              Codex home directory; default: ~/.codex.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --release)
        if [ "$#" -lt 2 ]; then
          echo "--release requires a value." >&2
          exit 1
        fi
        RELEASE="$2"
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        ;;
      --help | -h)
        usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
    shift
  done
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required to install Codex Leap." >&2
    exit 1
  fi
}

download_file() {
  url="$1"
  output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
    return
  fi

  echo "curl or wget is required to install Codex Leap." >&2
  exit 1
}

download_text() {
  url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -O - "$url"
    return
  fi

  echo "curl or wget is required to install Codex Leap." >&2
  exit 1
}

normalize_release_tag() {
  raw="$1"

  case "$raw" in
    "" | latest)
      printf 'latest\n'
      ;;
    "$RELEASE_TAG_PREFIX"*)
      printf '%s\n' "$raw"
      ;;
    v*)
      printf '%s%s\n' "$RELEASE_TAG_PREFIX" "${raw#v}"
      ;;
    *)
      printf '%s%s\n' "$RELEASE_TAG_PREFIX" "$raw"
      ;;
  esac
}

resolve_release_tag() {
  normalized="$(normalize_release_tag "$RELEASE")"
  if [ "$normalized" != "latest" ]; then
    printf '%s\n' "$normalized"
    return
  fi

  release_json="$(download_text "https://api.github.com/repos/$RELEASE_REPO/releases/latest")"
  tag="$(printf '%s\n' "$release_json" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "$tag" ]; then
    echo "Failed to resolve the latest Codex Leap release tag." >&2
    exit 1
  fi
  printf '%s\n' "$tag"
}

release_url_for_asset() {
  tag="$1"
  asset="$2"

  printf 'https://github.com/%s/releases/download/%s/%s\n' "$RELEASE_REPO" "$tag" "$asset"
}

file_sha256() {
  path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | sed 's/^.*= //'
    return
  fi

  echo "sha256sum, shasum, or openssl is required to verify the download." >&2
  exit 1
}

verify_archive_digest() {
  archive_path="$1"
  expected_digest="$2"
  actual_digest="$(file_sha256 "$archive_path")"

  if [ "$actual_digest" != "$expected_digest" ]; then
    echo "Downloaded Codex Leap archive checksum did not match." >&2
    echo "expected: $expected_digest" >&2
    echo "actual:   $actual_digest" >&2
    exit 1
  fi
}

package_archive_digest() {
  asset="$1"
  manifest_path="$2"

  digest="$(awk -v asset="$asset" '
    $2 == asset && $1 ~ /^[0-9a-fA-F]{64}$/ {
      print tolower($1)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$manifest_path" 2>/dev/null || true)"

  if [ -z "$digest" ]; then
    echo "Could not find SHA-256 digest for $asset in codex-package_SHA256SUMS." >&2
    exit 1
  fi

  printf '%s\n' "$digest"
}

replace_path_with_symlink() {
  link_path="$1"
  link_target="$2"
  tmp_link="$3"

  rm -f "$tmp_link"
  ln -s "$link_target" "$tmp_link"

  if mv -Tf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  if mv -hf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  rm -f "$link_path"
  mv -f "$tmp_link" "$link_path"
}

install_package_release() {
  release_dir="$1"
  archive_path="$2"
  stage_release="$RELEASES_DIR/.staging.$(basename "$release_dir").$$"

  mkdir -p "$RELEASES_DIR"
  rm -rf "$stage_release"
  mkdir -p "$stage_release"
  tar -xzf "$archive_path" -C "$stage_release"
  chmod 0755 "$stage_release/bin/codex" "$stage_release/codex-path/rg"
  if [ -f "$stage_release/codex-resources/bwrap" ]; then
    chmod 0755 "$stage_release/codex-resources/bwrap"
  fi
  ln -sf "bin/codex" "$stage_release/codex"

  if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    rm -rf "$release_dir"
  fi
  mv "$stage_release" "$release_dir"
}

update_current_link() {
  release_dir="$1"
  tmp_link="$STANDALONE_ROOT/.current.$$"

  replace_path_with_symlink "$CURRENT_LINK" "$release_dir" "$tmp_link"
}

update_visible_command() {
  mkdir -p "$BIN_DIR"
  tmp_link="$BIN_DIR/.$BIN_NAME.$$"

  replace_path_with_symlink "$BIN_PATH" "$CURRENT_LINK/bin/codex" "$tmp_link"
}

pick_profile() {
  case "$os:${SHELL:-}" in
    darwin:*/zsh)
      printf '%s\n' "$HOME/.zprofile"
      ;;
    darwin:*/bash)
      printf '%s\n' "$HOME/.bash_profile"
      ;;
    linux:*/zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    linux:*/bash)
      printf '%s\n' "$HOME/.bashrc"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

add_to_path() {
  case ":$PATH:" in
    *":$BIN_DIR:"*)
      return
      ;;
  esac

  profile="$(pick_profile)"
  path_profile="$profile"
  begin_marker="# >>> Codex Leap installer >>>"
  end_marker="# <<< Codex Leap installer <<<"
  path_line="export PATH=\"$BIN_DIR:\$PATH\""

  if [ -f "$profile" ] && grep -F "$begin_marker" "$profile" >/dev/null 2>&1; then
    path_action="configured"
    return
  fi

  {
    printf '\n%s\n' "$begin_marker"
    printf '%s\n' "$path_line"
    printf '%s\n' "$end_marker"
  } >>"$profile"
  path_action="added"
}

print_launch_instructions() {
  case "$path_action" in
    added)
      step "Current terminal: export PATH=\"$BIN_DIR:\$PATH\" && $BIN_NAME"
      step "Future terminals: open a new terminal and run: $BIN_NAME"
      step "PATH was added to $path_profile"
      ;;
    configured)
      step "Current terminal: export PATH=\"$BIN_DIR:\$PATH\" && $BIN_NAME"
      step "Future terminals: open a new terminal and run: $BIN_NAME"
      step "PATH is already configured in $path_profile"
      ;;
    *)
      step "$BIN_DIR is already on PATH"
      step "Run: $BIN_NAME"
      ;;
  esac
}

parse_args "$@"

require_command mktemp
require_command tar

case "$(uname -s)" in
  Darwin)
    os="darwin"
    ;;
  Linux)
    os="linux"
    ;;
  *)
    echo "install-leap.sh supports macOS and Linux." >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64)
    arch="x86_64"
    ;;
  arm64 | aarch64)
    arch="aarch64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [ "$os" = "darwin" ] && [ "$arch" = "x86_64" ]; then
  if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
    arch="aarch64"
  fi
fi

if [ "$os" = "darwin" ]; then
  if [ "$arch" = "aarch64" ]; then
    vendor_target="aarch64-apple-darwin"
    platform_label="macOS (Apple Silicon)"
  else
    vendor_target="x86_64-apple-darwin"
    platform_label="macOS (Intel)"
  fi
else
  if [ "$arch" = "aarch64" ]; then
    vendor_target="aarch64-unknown-linux-musl"
    platform_label="Linux (ARM64)"
  else
    vendor_target="x86_64-unknown-linux-musl"
    platform_label="Linux (x64)"
  fi
fi

resolved_tag="$(resolve_release_tag)"
package_asset="codex-package-$vendor_target.tar.gz"
checksum_asset="codex-package_SHA256SUMS"

step "Repository: $RELEASE_REPO"
step "Release tag: $resolved_tag"
step "Detected platform: $platform_label"
step "Package asset: $package_asset"

if [ "$DRY_RUN" = "true" ]; then
  step "Dry run complete; no files were downloaded or installed."
  exit 0
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  if [ -n "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT INT TERM

safe_tag="$(printf '%s' "$resolved_tag" | sed 's/[^A-Za-z0-9._-]/_/g')"
release_dir="$RELEASES_DIR/$safe_tag-$vendor_target"
archive_path="$tmp_dir/$package_asset"
checksum_path="$tmp_dir/$checksum_asset"

step "Downloading checksum manifest"
download_file "$(release_url_for_asset "$resolved_tag" "$checksum_asset")" "$checksum_path"
expected_digest="$(package_archive_digest "$package_asset" "$checksum_path")"

step "Downloading Codex Leap"
download_file "$(release_url_for_asset "$resolved_tag" "$package_asset")" "$archive_path"
verify_archive_digest "$archive_path" "$expected_digest"

step "Installing standalone package to $release_dir"
install_package_release "$release_dir" "$archive_path"
update_current_link "$release_dir"
update_visible_command
add_to_path

"$BIN_PATH" --version >/dev/null
print_launch_instructions

printf 'Codex Leap %s installed successfully as %s.\n' "$resolved_tag" "$BIN_NAME"
