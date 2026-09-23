#!/usr/bin/env bash
#
# Stages the Playwright driver that saml2aws' "Browser" IdP provider needs.
#
# WHY THIS EXISTS
#   saml2aws' Browser provider drives Playwright, and saml2aws 2.36.x still
#   fetches its Playwright driver from playwright.azureedge.net, which Microsoft
#   retired. Every host it knows now returns 404, so on a clean machine login
#   fails with:
#
#       could not install driver: got non 200 status code: 404 (404 Not Found)
#
#   Current playwright-go no longer uses that CDN; it assembles the driver from
#   the playwright-core npm package plus a matching Node.js binary. This script
#   does the same thing, so nobody needs Node or npm installed.
#
# LAYOUT
#   The ms-playwright-go/<version> nesting is not decorative: playwright-go
#   appends it to whatever base directory it is handed, so the result must be
#
#       <base-dir>/ms-playwright-go/<playwright-version>/node
#       <base-dir>/ms-playwright-go/<playwright-version>/package/cli.js
#
# MODES
#   (default)  per-user install under ~/Library/Application Support. No sudo.
#   --system   machine-wide under /Library/Application Support. Needs root, and
#              is the mode to use from an Intune shell script.
#
# USAGE
#   ./install-playwright-driver-macos.sh
#   sudo ./install-playwright-driver-macos.sh --system
#   ./install-playwright-driver-macos.sh --skip-env
#
# Exit 0 = success, non-zero = failure.

set -euo pipefail

PLAYWRIGHT_VERSION="1.47.2"
NODE_VERSION="20.17.0"
MODE="user"
SKIP_ENV=0
FORCE=0
BASE_DIR=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

  --system                  Install machine-wide (requires root). Use for Intune.
  --base-dir <path>         Override the driver base directory.
  --playwright-version <v>  Playwright version to stage (default ${PLAYWRIGHT_VERSION}).
  --node-version <v>        Node.js version supplying the node binary (default ${NODE_VERSION}).
  --skip-env                Do not touch shell profiles; print the saml2aws
                            browser_driver_dir setting to use instead.
  --force                   Re-download even if a valid driver is present.
  -h, --help                Show this help.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --system)             MODE="system"; shift ;;
    --skip-env)           SKIP_ENV=1; shift ;;
    --force)              FORCE=1; shift ;;
    --base-dir)           BASE_DIR="${2:-}"; shift 2 ;;
    --playwright-version) PLAYWRIGHT_VERSION="${2:-}"; shift 2 ;;
    --node-version)       NODE_VERSION="${2:-}"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This script is for macOS. On Windows use Install-Saml2awsPlaywrightDriver-User.ps1." >&2
  exit 1
fi

# Apple Silicon and Intel need different Node builds. Getting this wrong stages a
# driver that cannot execute, so fail loudly on anything unexpected.
case "$(uname -m)" in
  arm64)  NODE_ARCH="darwin-arm64" ;;
  x86_64) NODE_ARCH="darwin-x64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

if [ "$MODE" = "system" ]; then
  if [ "$(id -u)" -ne 0 ]; then
    echo "--system requires root. Re-run with sudo." >&2
    exit 1
  fi
  [ -n "$BASE_DIR" ] || BASE_DIR="/Library/Application Support/saml2aws/playwright-driver"
else
  [ -n "$BASE_DIR" ] || BASE_DIR="$HOME/Library/Application Support/saml2aws/playwright-driver"
fi

DRIVER_DIR="$BASE_DIR/ms-playwright-go/$PLAYWRIGHT_VERSION"
NODE_BIN="$DRIVER_DIR/node"
CLI_JS="$DRIVER_DIR/package/cli.js"

STAGING="$(mktemp -d)"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

say()  { printf '  %s\n' "$1"; }
good() { printf '  \033[0;32m%s\033[0m\n' "$1"; }
warn() { printf '  \033[0;33m%s\033[0m\n' "$1"; }
bad()  { printf '  \033[0;31m%s\033[0m\n' "$1"; }

# Mirrors playwright-go's own check: it runs "node cli.js --version" and requires
# the pinned version. Testing for file existence is not enough, since a truncated
# download would pass that and then fail at login time.
driver_ok() {
  [ -x "$NODE_BIN" ] || return 1
  [ -f "$CLI_JS" ]   || return 1
  "$NODE_BIN" "$CLI_JS" --version 2>/dev/null | grep -q "$PLAYWRIGHT_VERSION"
}

printf '\n\033[0;36msaml2aws Playwright driver setup (%s, %s)\033[0m\n\n' "$MODE" "$NODE_ARCH"

if driver_ok && [ "$FORCE" -eq 0 ]; then
  good "Driver v${PLAYWRIGHT_VERSION} is already staged and working:"
  say  "    ${DRIVER_DIR}"
else
  mkdir -p "$DRIVER_DIR"

  # 1. playwright-core from npm. The tarball nests everything under "package/",
  #    which is exactly the shape playwright-go wants, so extract at the root.
  TGZ_URL="https://registry.npmjs.org/playwright-core/-/playwright-core-${PLAYWRIGHT_VERSION}.tgz"
  say "Downloading playwright-core ${PLAYWRIGHT_VERSION}"
  curl -fsSL "$TGZ_URL" -o "${STAGING}/playwright-core.tgz"

  say "Extracting playwright-core"
  tar -xzf "${STAGING}/playwright-core.tgz" -C "$DRIVER_DIR"
  [ -f "$CLI_JS" ] || { bad "cli.js missing after extraction: $CLI_JS"; exit 1; }

  # 2. Node.js. Only the single binary is kept, from bin/node in the tarball.
  NODE_DIR="node-v${NODE_VERSION}-${NODE_ARCH}"
  NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_DIR}.tar.gz"
  say "Downloading Node.js ${NODE_VERSION} (${NODE_ARCH}, about 40 MB)"
  curl -fsSL "$NODE_URL" -o "${STAGING}/node.tar.gz"

  say "Extracting node"
  tar -xzf "${STAGING}/node.tar.gz" -C "$STAGING"
  [ -f "${STAGING}/${NODE_DIR}/bin/node" ] || { bad "node missing after extraction"; exit 1; }
  cp "${STAGING}/${NODE_DIR}/bin/node" "$NODE_BIN"
  chmod +x "$NODE_BIN"

  # curl does not set com.apple.quarantine the way browsers do, but strip it if
  # present so Gatekeeper cannot block the driver on first run.
  xattr -d com.apple.quarantine "$NODE_BIN" 2>/dev/null || true

  if ! driver_ok; then
    bad "Driver staged but the version check failed. Expected v${PLAYWRIGHT_VERSION} in ${DRIVER_DIR}."
    exit 1
  fi

  good "Driver v${PLAYWRIGHT_VERSION} staged and verified:"
  say  "    ${DRIVER_DIR}"
fi

printf '\n'

# playwright-go treats PLAYWRIGHT_DRIVER_PATH as a BASE directory and appends
# ms-playwright-go/<version> itself, so this gets BASE_DIR, never DRIVER_DIR.
EXPORT_LINE="export PLAYWRIGHT_DRIVER_PATH=\"${BASE_DIR}\""
MARKER="# saml2aws playwright driver"

add_export_to() {
  target="$1"
  if [ -f "$target" ] && grep -qF "$MARKER" "$target"; then
    good "Already configured in ${target}"
    return 0
  fi
  printf '\n%s\n%s\n' "$MARKER" "$EXPORT_LINE" >> "$target"
  good "Added PLAYWRIGHT_DRIVER_PATH to ${target}"
}

if [ "$SKIP_ENV" -eq 1 ]; then
  say "Skipping shell profile changes, as requested."
  printf '\n'
  say "Add this to the account section of your ~/.saml2aws instead:"
  printf '\n      browser_driver_dir = %s\n' "$BASE_DIR"
elif [ "$MODE" = "system" ]; then
  # /etc/zshenv is read by every zsh, login or not, which is what makes this
  # work for a managed device where you cannot edit each user's dotfiles.
  add_export_to "/etc/zshenv"
  say "bash users: also sourcing /etc/profile"
  add_export_to "/etc/profile"
else
  add_export_to "${ZDOTDIR:-$HOME}/.zshrc"
  [ -f "$HOME/.bash_profile" ] && add_export_to "$HOME/.bash_profile" || true
fi

printf '\n\033[0;36mChecking the rest of the prerequisites\033[0m\n'

if command -v saml2aws >/dev/null 2>&1; then
  good "saml2aws found: $(command -v saml2aws)"
else
  bad "saml2aws was NOT found on your PATH."
  say "The driver is staged, but you still need the saml2aws CLI itself."
  say "Typically: brew install saml2aws"
fi

# browser_type=chrome resolves the installed Google Chrome. Playwright browsers
# are not part of the driver, so Chrome genuinely has to be present.
if [ -d "/Applications/Google Chrome.app" ]; then
  good "Google Chrome found."
else
  warn "Google Chrome was NOT found."
  say  "Profiles using browser_type=chrome need it. Install Chrome or change"
  say  "browser_type in your ~/.saml2aws profile."
fi

printf '\n\033[0;32mDone.\033[0m\n\n'
say "Open a NEW terminal before running saml2aws -- environment changes do not"
say "reach shells that are already open."
printf '\n'
exit 0