#!/usr/bin/env bash
# Install the myai control script and the service definitions.
# Run this AFTER the component installs described in README.md.
#
# macOS → launchd agents in ~/Library/LaunchAgents
# Linux → systemd user units in ~/.config/systemd/user

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"

case "$(uname -s)" in
  Darwin) OS=mac ;;
  Linux)  OS=linux ;;
  *) echo "unsupported platform: $(uname -s)"; exit 1 ;;
esac

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '  \033[2m•\033[0m %s\n' "$1"; }

printf '\033[1mInstalling myai\033[0m (%s)\n' "$OS"

# --- control script ---------------------------------------------------------
mkdir -p "$BIN"
install -m 0755 "$HERE/bin/myai" "$BIN/myai" && ok "installed $BIN/myai"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) info "add to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

mkdir -p "$HOME/.open-webui/logs" "$HOME/ComfyUI/logs" "$HOME/kokoro/logs" \
         "$HOME/jupyter/logs" "$HOME/jupyter/work" "$HOME/mcpo/logs" \
         "$HOME/terminal/logs" "$HOME/ai-workspace" 2>/dev/null

# --- per-install secrets: generated once, never committed ---------------------
secret() {  # secret <file>  — print it, creating it on first use
  local f="$1"
  if [ ! -s "$f" ]; then
    ( umask 077; python3 -c 'import secrets;print(secrets.token_hex(24))' > "$f" )
  fi
  chmod 600 "$f" 2>/dev/null
  cat "$f"
}
JUPYTER_TOKEN="$(secret "$HOME/jupyter/.token")"
TERMINAL_TOKEN="$(secret "$HOME/terminal/.token")"
MCPO_APIKEY="$(secret "$HOME/mcpo/.apikey")"
BREW_BIN="$(dirname "$(command -v brew 2>/dev/null || echo /opt/homebrew/bin/brew)")"
TZ_NAME="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')"; TZ_NAME="${TZ_NAME:-UTC}"

# the terminal server's code lives in the repo; install it next to its venv
if [ -f "$HERE/terminal/server.py" ]; then
  install -m 0644 "$HERE/terminal/server.py" "$HOME/terminal/server.py"
  ok "installed $HOME/terminal/server.py"
fi

# mcpo's server list — written once, then yours to edit
if [ ! -f "$HOME/mcpo/config.json" ] && [ -f "$HERE/mcpo/config.json.template" ]; then
  sed -e "s|__HOME__|$HOME|g" -e "s|__TZ__|$TZ_NAME|g" \
      "$HERE/mcpo/config.json.template" > "$HOME/mcpo/config.json"
  ok "wrote $HOME/mcpo/config.json"
fi

have_webui()  { [ -x "$HOME/.open-webui/venv/bin/open-webui" ]; }
have_comfy()  { [ -f "$HOME/ComfyUI/main.py" ]; }
have_kokoro() { [ -d "$HOME/kokoro/api" ]; }
have_jupyter(){ [ -x "$HOME/jupyter/venv/bin/python" ]; }
have_mcpo()   { [ -x "$HOME/mcpo/venv/bin/mcpo" ]; }
have_terminal(){ [ -f "$HOME/terminal/server.py" ] && [ -x "$HOME/terminal/venv/bin/python" ]; }

# --------------------------------------------------------------------- mac ---
if [ "$OS" = mac ]; then
  AGENTS="$HOME/Library/LaunchAgents"; GUI="gui/$(id -u)"
  mkdir -p "$AGENTS"
  for tpl in "$HERE"/launchagents/*.plist.template; do
    [ -e "$tpl" ] || continue
    label="$(basename "$tpl" .plist.template)"
    case "$label" in
      com.openwebui.server) have_webui  || { info "skip $label (not installed)"; continue; } ;;
      com.comfyui.server)   have_comfy  || { info "skip $label (not installed)"; continue; } ;;
      com.kokoro.server)    have_kokoro || { info "skip $label (not installed)"; continue; } ;;
      com.jupyter.server)   have_jupyter|| { info "skip $label (not installed)"; continue; } ;;
      com.mcpo.server)      have_mcpo   || { info "skip $label (not installed)"; continue; } ;;
      com.terminal.server)  have_terminal|| { info "skip $label (not installed)"; continue; } ;;
    esac
    out="$AGENTS/$label.plist"
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__JUPYTER_TOKEN__|$JUPYTER_TOKEN|g" \
        -e "s|__MCPO_APIKEY__|$MCPO_APIKEY|g" \
        -e "s|__BREW_BIN__|$BREW_BIN|g" "$tpl" > "$out"
    chmod 600 "$out"
    if plutil -lint "$out" >/dev/null 2>&1; then
      launchctl bootout "$GUI/$label" 2>/dev/null
      launchctl enable  "$GUI/$label" 2>/dev/null
      launchctl bootstrap "$GUI" "$out" 2>/dev/null
      ok "installed $label"
    else
      bad "$out failed plist validation"
    fi
  done
  command -v brew >/dev/null 2>&1 || info "Homebrew not found — myai manages Ollama via brew services on macOS"

# ------------------------------------------------------------------- linux ---
else
  UNITS="$HOME/.config/systemd/user"
  mkdir -p "$UNITS"

  OLLAMA_BIN="$(command -v ollama || echo /usr/local/bin/ollama)"

  # If the official installer left a system-wide ollama service running, it will
  # hold port 11434 and myai's user unit will never bind.
  if systemctl is-enabled ollama.service >/dev/null 2>&1; then
    info "a system-wide ollama.service exists; myai uses a user unit instead"
    info "disable it with:  sudo systemctl disable --now ollama"
  fi

  for tpl in "$HERE"/systemd/*.service; do
    [ -e "$tpl" ] || continue
    unit="$(basename "$tpl")"
    case "$unit" in
      myai-openwebui.service) have_webui  || { info "skip $unit (not installed)"; continue; } ;;
      myai-comfyui.service)   have_comfy  || { info "skip $unit (not installed)"; continue; } ;;
      myai-kokoro.service)    have_kokoro || { info "skip $unit (not installed)"; continue; } ;;
      myai-jupyter.service)   have_jupyter|| { info "skip $unit (not installed)"; continue; } ;;
      myai-mcpo.service)      have_mcpo   || { info "skip $unit (not installed)"; continue; } ;;
      myai-terminal.service)  have_terminal|| { info "skip $unit (not installed)"; continue; } ;;
      myai-ollama.service)    command -v ollama >/dev/null 2>&1 || { info "skip $unit (ollama not installed)"; continue; } ;;
    esac
    sed -e "s|__HOME__|$HOME|g" -e "s|__OLLAMA__|$OLLAMA_BIN|g" \
        -e "s|__JUPYTER_TOKEN__|$JUPYTER_TOKEN|g" \
        -e "s|__MCPO_APIKEY__|$MCPO_APIKEY|g" "$tpl" > "$UNITS/$unit"
    chmod 600 "$UNITS/$unit"
    ok "installed $unit"
  done

  systemctl --user daemon-reload 2>/dev/null && ok "systemd user daemon reloaded"

  # Without lingering, user units stop when the last session closes and do not
  # start at boot.
  if ! loginctl show-user "$USER" 2>/dev/null | grep -q 'Linger=yes'; then
    info "enable start-at-boot with:  sudo loginctl enable-linger $USER"
  fi
fi

printf '\n'
ok "done"
info "next:  myai start      then register the admin account in the browser"
info "then:  ./scripts/configure.sh"
