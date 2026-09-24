#!/usr/bin/env bash
# Build the OpenCode desktop app from its own source, with myai's patches, and
# install it in place of the stock app.
#
#   ./scripts/build-opencode-desktop.sh            # the version of the installed app
#   ./scripts/build-opencode-desktop.sh 2.0.16     # a specific release
#
# What it does, in order -- and it stops at the first thing that fails:
#   1. clones github.com/anomalyco/opencode at tag v<version>
#   2. applies opencode/desktop/*.patch (fails loudly if upstream moved the code)
#   3. installs dependencies with the bun version the repo pins
#   4. runs the app's typecheck and unit tests; a red suite means no build
#   5. fetches the official CLI for that version from npm (@opencode/cli-darwin-arm64,
#      the same package OpenCode's own build uses) -- the CLI is not modified
#   6. builds on the prod channel (same app id and data as the stock app) with the
#      updater compiled out, so it never replaces itself with the stock release
#   7. packages it unsigned, signs it ad hoc for this machine, and installs it,
#      keeping the previous app next to the build as a backup
#
# Signing is ad hoc: fine for this Mac, not distributable, and Gatekeeper is not
# involved because the app was never quarantined. There is no auto-update; rerun
# this script for each release.

set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${OPENCODE_BUILD_DIR:-$HOME/.cache/myai}"
SRC="$WORK/opencode"
APP="/Applications/OpenCode.app"
REPO="https://github.com/anomalyco/opencode.git"
CLI_PKG="@opencode/cli-darwin-arm64"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  \033[2m•\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1"; exit 1; }

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "macOS on Apple Silicon only"
for t in git bun npm codesign ditto; do command -v "$t" >/dev/null || die "$t not found (bun: brew install bun)"; done

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null)" \
    || die "no installed app to read a version from; pass one: $0 2.0.15"
fi
printf '\033[1mOpenCode desktop %s, patched\033[0m\n' "$VERSION"

# 1. source at the release tag
mkdir -p "$WORK"
rm -rf "$SRC"
git clone -q --depth 1 --branch "v$VERSION" "$REPO" "$SRC" 2>/dev/null || die "no tag v$VERSION in $REPO"
ok "source v$VERSION ($(git -C "$SRC" rev-parse --short HEAD))"

PIN="$(sed -n 's/.*"packageManager": *"bun@\([^"]*\)".*/\1/p' "$SRC/package.json")"
[ -n "$PIN" ] && [ "$(bun --version)" != "$PIN" ] && info "repo pins bun $PIN, found $(bun --version) -- continuing"

# 2. patches
for p in "$HERE"/opencode/desktop/*.patch; do
  [ -e "$p" ] || continue
  git -C "$SRC" apply --check "$p" 2>/dev/null \
    || die "$(basename "$p") no longer applies to v$VERSION -- upstream changed that code; update the patch"
  git -C "$SRC" apply "$p"
  ok "applied $(basename "$p")"
done

# 3-4. dependencies, then the app's own checks
( cd "$SRC" && bun install >/dev/null 2>&1 ) || die "bun install failed"
ok "dependencies installed"
( cd "$SRC/packages/app" && bun run typecheck >/dev/null 2>&1 ) || die "app typecheck failed"
( cd "$SRC/packages/desktop" && bun run typecheck >/dev/null 2>&1 ) || die "desktop typecheck failed"
TESTS="$(cd "$SRC/packages/app" && bun test --conditions=solid --preload ./happydom.ts ./src 2>&1 | tail -6)"
echo "$TESTS" | grep -qE '^ *0 fail' || { echo "$TESTS"; die "app unit tests failed"; }
ok "typecheck + $(echo "$TESTS" | sed -n 's/^ *\([0-9]*\) pass.*/\1/p') unit tests pass"

# 5. the official CLI for this version, unmodified
DIST="$WORK/cli-dist"
rm -rf "$DIST" && mkdir -p "$DIST/cli-darwin-arm64/bin"
T="$(mktemp -d)"
( cd "$T" && npm pack -q "$CLI_PKG@$VERSION" >/dev/null 2>&1 && tar xzf ./*.tgz ) || die "$CLI_PKG@$VERSION not on npm"
cp "$T/package/bin/opencode" "$DIST/cli-darwin-arm64/bin/opencode"
cp "$T/package/package.json" "$DIST/cli-darwin-arm64/package.json"
rm -rf "$T"
"$DIST/cli-darwin-arm64/bin/opencode" --version | grep -q "$VERSION" || die "CLI does not report $VERSION"
ok "official CLI $VERSION from npm"

# 6-7. build, package, sign
cd "$SRC/packages/desktop"
OPENCODE_CHANNEL=prod OPENCODE_DISABLE_UPDATER=1 OPENCODE_CLI_DIST="$DIST" bun run build >/dev/null 2>&1 || die "build failed"
grep -q '"session.execution.succeeded"\|session.execution.succeeded' out/renderer/assets/*.js || die "patched code missing from the build"
CSC_IDENTITY_AUTO_DISCOVERY=false OPENCODE_CHANNEL=prod \
  bunx electron-builder --config electron-builder.config.ts --mac --dir \
  -c.mac.notarize=false -c.mac.identity=null >/dev/null 2>&1 || die "packaging failed"
BUILT="$SRC/packages/desktop/dist/mac-arm64/OpenCode.app"
codesign --force --deep --sign - "$BUILT" >/dev/null 2>&1
codesign --verify --deep --strict "$BUILT" || die "signature invalid"
[ ! -e "$BUILT/Contents/Resources/app-update.yml" ] || die "updater feed present in the build"
ok "packaged and signed (ad hoc), updater off"

# install, keeping what was there
if pgrep -f "$APP/Contents/MacOS" >/dev/null; then
  info "quitting OpenCode to replace it"
  osascript -e 'tell application "OpenCode" to quit' >/dev/null 2>&1 || true
  sleep 3
  pgrep -f "$APP/Contents/MacOS" >/dev/null && die "OpenCode is still running; quit it and rerun"
fi
if [ -e "$APP" ]; then
  PREV="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo unknown)"
  BACKUP="$WORK/OpenCode-previous-$PREV.app"
  rm -rf "$BACKUP" && mv "$APP" "$BACKUP"
  info "previous app kept at $BACKUP"
fi
ditto "$BUILT" "$APP"
ok "installed $APP ($VERSION, patched)"
