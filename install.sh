#!/usr/bin/env bash
# Install the myai control script and the launch agents.
# Run this AFTER the component installs described in README.md.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
BIN="$HOME/.local/bin"
GUI="gui/$(id -u)"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '  \033[2m•\033[0m %s\n' "$1"; }

printf '\033[1mInstalling myai\033[0m\n'

# --- the control script -----------------------------------------------------
mkdir -p "$BIN"
install -m 0755 "$HERE/bin/myai" "$BIN/myai" && ok "installed $BIN/myai"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) info "add to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# --- launch agents ----------------------------------------------------------
mkdir -p "$AGENTS"
for tpl in "$HERE"/launchagents/*.plist.template; do
  [ -e "$tpl" ] || continue
  label="$(basename "$tpl" .plist.template)"
  out="$AGENTS/$label.plist"

  # Only install an agent if the thing it supervises actually exists
  case "$label" in
    com.openwebui.server) [ -x "$HOME/.open-webui/venv/bin/open-webui" ] || { info "skip $label (Open WebUI not installed)"; continue; } ;;
    com.comfyui.server)   [ -f "$HOME/ComfyUI/main.py" ]                 || { info "skip $label (ComfyUI not installed)"; continue; } ;;
    com.kokoro.server)    [ -d "$HOME/kokoro/api" ]                      || { info "skip $label (Kokoro not installed)"; continue; } ;;
  esac

  sed "s|__HOME__|$HOME|g" "$tpl" > "$out"
  if plutil -lint "$out" >/dev/null 2>&1; then
    launchctl bootout "$GUI/$label" 2>/dev/null
    launchctl enable "$GUI/$label" 2>/dev/null
    launchctl bootstrap "$GUI" "$out" 2>/dev/null
    ok "installed and loaded $label"
  else
    bad "$out failed plist validation"
  fi
done

# --- log directories --------------------------------------------------------
mkdir -p "$HOME/.open-webui/logs" "$HOME/ComfyUI/logs" "$HOME/kokoro/logs" 2>/dev/null

printf '\n'
ok "done"
info "next:  myai start        then register the admin account in the browser"
info "then:  ./scripts/configure.sh    to apply the recommended settings"
