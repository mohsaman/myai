#!/usr/bin/env bash
# Put HTTPS in front of Open WebUI, so voice and dictation work off-machine.
#
# Browsers refuse the microphone on an insecure origin, and refuse it by making
# navigator.mediaDevices undefined rather than by denying permission -- so the
# controls appear and then fail with nothing useful to read. localhost counts as
# a secure context and a LAN address does not, which is the whole of the problem:
# voice works at 127.0.0.1 and nowhere else.
#
# Chrome's unsafely-treat-insecure-origin-as-secure flag is supposed to cover
# this. It did not work here, and it would not have helped Safari, a phone, or
# any device that cannot set Chrome flags. A certificate does.
#
#   ./scripts/setup-tls.sh              # certificate for this machine's LAN IP
#   ./scripts/setup-tls.sh 10.0.0.4     # or an address you name
#
# Open WebUI keeps its plain HTTP listener for loopback; this adds 8443 alongside.

set -uo pipefail

PORT="${TLS_PORT:-8443}"
BACKEND="${BACKEND:-127.0.0.1:8080}"
TLS_DIR="${TLS_DIR:-$HOME/.open-webui/tls}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  \033[2m•\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

for t in mkcert caddy; do
  command -v "$t" >/dev/null 2>&1 || { bad "$t not installed — brew install mkcert caddy"; exit 1; }
done

LAN_IP="${1:-}"
if [ -z "$LAN_IP" ]; then
  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null \
            || ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)"
fi
[ -n "$LAN_IP" ] || { bad "could not determine a LAN address; pass one as an argument"; exit 1; }

printf '\033[1mTLS for Open WebUI\033[0m  %s:%s -> %s\n' "$LAN_IP" "$PORT" "$BACKEND"

# The CA has to be trusted by the system, and that step needs a password, so it
# is left to the user rather than attempted and half-failed.
if ! mkcert -CAROOT >/dev/null 2>&1 || [ ! -f "$(mkcert -CAROOT)/rootCA.pem" ]; then
  info "no local CA yet"
fi
if ! security find-certificate -c "mkcert" >/dev/null 2>&1; then
  info "the local CA is not in the system trust store yet"
  info "run this once, it will ask for your password:  mkcert -install"
fi

mkdir -p "$TLS_DIR"
( cd "$TLS_DIR" && mkcert "$LAN_IP" localhost 127.0.0.1 ::1 >/dev/null 2>&1 ) \
  && ok "certificate for $LAN_IP, localhost, 127.0.0.1" \
  || { bad "mkcert failed"; exit 1; }

CERT="$(ls -t "$TLS_DIR"/*+*.pem 2>/dev/null | grep -v -- '-key' | head -1)"
KEY="$(ls -t "$TLS_DIR"/*+*-key.pem 2>/dev/null | head -1)"
[ -f "$CERT" ] && [ -f "$KEY" ] || { bad "certificate or key missing after generation"; exit 1; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
sed -e "s|__TLS_DIR__|$TLS_DIR|g" \
    -e "s|__LAN_IP__|$LAN_IP|g" \
    -e "s|:8443|:$PORT|g" \
    -e "s|127\.0\.0\.1:8080|$BACKEND|g" \
    "$HERE/tls/Caddyfile.template" > "$TLS_DIR/Caddyfile"
ok "wrote $TLS_DIR/Caddyfile"

caddy validate --config "$TLS_DIR/Caddyfile" >/dev/null 2>&1 \
  && ok "configuration valid" || { bad "caddy rejected the configuration"; exit 1; }

printf '\n'
info "start it:  caddy run --config $TLS_DIR/Caddyfile"
info "then use:  https://$LAN_IP:$PORT"
info "other devices must trust $(mkcert -CAROOT)/rootCA.pem before the microphone works there"
