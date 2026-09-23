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
#   ./scripts/setup-tls.sh              # certificate for every current LAN address + <host>.local
#   ./scripts/setup-tls.sh 10.0.0.4     # plus addresses you name (other networks)
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

# Every address this machine answers on, not just one. A laptop moves between
# networks; a certificate pinned to the address it had at setup time stops
# matching the moment it joins another LAN, and HTTPS from other nodes fails
# with a handshake error while loopback keeps working. The interface is not
# always en0 either (a USB/Thunderbolt NIC comes up as en5 and so on).
# Addresses named on the command line are added to the detected ones, so a
# network the machine is not on right now (home while at the lab) can be
# covered too.
ADDRS=()
while read -r a; do [ -n "$a" ] && ADDRS+=("$a"); done < <(
  { { ifconfig 2>/dev/null || ip -4 addr show scope global 2>/dev/null; } \
      | awk '/inet /{sub("/.*","",$2); if ($2 !~ /^127\./) print $2}'
    for a in "$@"; do echo "$a"; done; } | sort -u)
[ "${#ADDRS[@]}" -gt 0 ] || { bad "could not determine a LAN address; pass one as an argument"; exit 1; }

# The mDNS name survives address changes, so it is the one to bookmark.
MDNS=""
command -v scutil >/dev/null 2>&1 && MDNS="$(scutil --get LocalHostName 2>/dev/null).local"
[ "$MDNS" = ".local" ] && MDNS=""
[ -z "$MDNS" ] && command -v hostname >/dev/null 2>&1 && MDNS="$(hostname -s 2>/dev/null).local"

NAMES=("${ADDRS[@]}")
[ -n "$MDNS" ] && NAMES+=("$MDNS")
NAMES+=(localhost 127.0.0.1 ::1)

printf '\033[1mTLS for Open WebUI\033[0m  :%s -> %s\n' "$PORT" "$BACKEND"
info "names: ${NAMES[*]}"

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
# Fixed file names, so the Caddyfile does not depend on which names were listed.
CERT="$TLS_DIR/openwebui.pem"
KEY="$TLS_DIR/openwebui-key.pem"
mkcert -cert-file "$CERT" -key-file "$KEY" "${NAMES[@]}" >/dev/null 2>&1 \
  && ok "certificate for ${NAMES[*]}" \
  || { bad "mkcert failed"; exit 1; }
[ -f "$CERT" ] && [ -f "$KEY" ] || { bad "certificate or key missing after generation"; exit 1; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
sed -e "s|__TLS_DIR__|$TLS_DIR|g" \
    -e "s|:8443|:$PORT|g" \
    -e "s|127\.0\.0\.1:8080|$BACKEND|g" \
    "$HERE/tls/Caddyfile.template" > "$TLS_DIR/Caddyfile"
ok "wrote $TLS_DIR/Caddyfile"

caddy validate --config "$TLS_DIR/Caddyfile" >/dev/null 2>&1 \
  && ok "configuration valid" || { bad "caddy rejected the configuration"; exit 1; }

printf '\n'
info "start it:  caddy run --config $TLS_DIR/Caddyfile   (or: myai restart)"
[ -n "$MDNS" ] && info "then use:  https://$MDNS:$PORT"
for a in "${ADDRS[@]}"; do info "      or:  https://$a:$PORT"; done
info "on a new network, run this again so the certificate covers the new address"
info "other devices must trust $(mkcert -CAROOT)/rootCA.pem before the microphone works there"
