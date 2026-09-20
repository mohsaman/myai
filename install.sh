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
# On PATH so an agent calls it as a command rather than reaching for a web tool.
install -m 0755 "$HERE/scripts/fetch-specs.sh" "$BIN/fetch-specs" && ok "installed $BIN/fetch-specs"
install -m 0755 "$HERE/scripts/render-html.sh" "$BIN/render-html" && ok "installed $BIN/render-html"
install -m 0755 "$HERE/scripts/set-context.sh" "$BIN/set-context" && ok "installed $BIN/set-context"
install -m 0755 "$HERE/scripts/setup-tls.sh" "$BIN/setup-tls" && ok "installed $BIN/setup-tls"

# goose recipes: named entry points you run with `goose run --recipe <name>`.
# Installed rather than symlinked so editing one does not change the repo.
if [ -d "$HERE/goose/recipes" ]; then
  mkdir -p "$HOME/.config/goose/recipes"
  for r in "$HERE"/goose/recipes/*.yaml; do
    [ -e "$r" ] || continue
    install -m 0644 "$r" "$HOME/.config/goose/recipes/$(basename "$r")" \
      && ok "installed recipe $(basename "$r" .yaml)"
  done
fi
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) info "add to your shell profile:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

mkdir -p "$HOME/.open-webui/logs" "$HOME/ComfyUI/logs" "$HOME/kokoro/logs" \
         "$HOME/jupyter/logs" "$HOME/jupyter/work" "$HOME/mcpo/logs" \
         "$HOME/terminal/logs" "$HOME/piper/logs" "$HOME/piper/voices" \
         "$HOME/ai-workspace" 2>/dev/null

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
for f in server.py server-ssh.py; do
  [ -f "$HERE/terminal/$f" ] || continue
  install -m 0644 "$HERE/terminal/$f" "$HOME/terminal/$f"
  ok "installed $HOME/terminal/$f"
done
# uvicorn imports by module name, which cannot contain a hyphen.
[ -f "$HOME/terminal/server-ssh.py" ] && ln -sf server-ssh.py "$HOME/terminal/server_ssh.py"

# the TTS router's code lives in the repo; install it next to Piper's venv
for f in router.py voices.py; do
  [ -f "$HERE/tts/$f" ] || continue
  install -m 0644 "$HERE/tts/$f" "$HOME/piper/$f"
  ok "installed $HOME/piper/$f"
done

# host list: the template ships, the real one is yours and stays out of git
if [ ! -f "$HOME/terminal/hosts.json" ] && [ -f "$HERE/terminal/hosts.json.example" ]; then
  install -m 0600 "$HERE/terminal/hosts.json.example" "$HOME/terminal/hosts.json"
  ok "wrote $HOME/terminal/hosts.json"
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
have_tts()    { [ -f "$HOME/piper/router.py" ] && [ -x "$HOME/piper/venv/bin/python" ]; }
# TLS is opt-in: the agent is only installed once a certificate exists, because
# caddy with no cert fails on every start and KeepAlive turns that into a loop.
have_tls()    { [ -f "$HOME/.open-webui/tls/Caddyfile" ] && command -v caddy >/dev/null 2>&1; }

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
      com.ttsrouter.server) have_tts    || { info "skip $label (not installed)"; continue; } ;;
      com.caddy.tls)        have_tls    || { info "skip $label (run setup-tls first)"; continue; } ;;
    esac
    out="$AGENTS/$label.plist"
    sed -e "s|__HOME__|$HOME|g" -e "s|__BREW__|$BREW_BIN|g" \
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
      myai-tts-router.service) have_tts   || { info "skip $unit (not installed)"; continue; } ;;
      myai-caddy-tls.service)  have_tls   || { info "skip $unit (run setup-tls first)"; continue; } ;;
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

# --- goose: the terminal agent, if it is installed ---------------------------
if command -v goose >/dev/null 2>&1; then
  GOOSE_CFG="$HOME/.config/goose/config.yaml"
  if [ ! -f "$GOOSE_CFG" ] && [ -f "$HERE/goose/config.yaml.example" ]; then
    mkdir -p "$(dirname "$GOOSE_CFG")"
    sed "s|__HOME__|$HOME|g" "$HERE/goose/config.yaml.example" > "$GOOSE_CFG"
    chmod 600 "$GOOSE_CFG"
    ok "wrote $GOOSE_CFG"
  else
    info "goose config already present — left alone"
  fi
  # Behavioural instructions for every session. A .goosehints in the working
  # directory stacks on top of this one.
  if [ ! -f "$HOME/.config/goose/.goosehints" ] && [ -f "$HERE/goose/goosehints.example" ]; then
    install -m 0600 "$HERE/goose/goosehints.example" "$HOME/.config/goose/.goosehints"
    ok "wrote $HOME/.config/goose/.goosehints"
  fi
  # goose's own skills root, independent of any other agent's layout.
  if [ -d "$HERE/goose/skills" ]; then
    mkdir -p "$HOME/.agents/skills"
    for s in "$HERE"/goose/skills/*/; do
      [ -d "$s" ] || continue
      n="$(basename "$s")"
      [ -e "$HOME/.agents/skills/$n" ] && { info "skill $n already present — left alone"; continue; }
      cp -a "$s" "$HOME/.agents/skills/$n" && ok "installed skill $n"
    done
  fi
else
  info "goose not installed — skip (brew install block-goose-cli)"
fi

printf '\n'
ok "done"
info "next:  myai start      then register the admin account in the browser"
info "then:  ./scripts/configure.sh"
