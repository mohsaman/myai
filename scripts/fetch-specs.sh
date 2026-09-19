#!/usr/bin/env bash
# Fetch a standards document into a local, greppable corpus.
#
# Meant to be called BY THE AGENT, not only by you. Give it any identifier and
# it works out which body publishes it and where:
#
#   fetch-specs.sh 24.301        3GPP TS   -> 3gpp.org/ftp/Specs/archive/24_series/
#   fetch-specs.sh TS 29.272     same, with the prefix spelled out
#   fetch-specs.sh RFC3588       IETF      -> rfc-editor.org
#   fetch-specs.sh rfc 6733      same
#   fetch-specs.sh --have        list what is already local
#
# Why: a model asked for a spec clause produces a confident, plausible, wrong
# one. Asked which EMM cause maps to DIAMETER_ERROR_USER_UNKNOWN, a 30B model
# answered "#1, TS 24.301 section 9.9.2.1". The truth is one line of the real
# document — "#2 (IMSI unknown in HSS)" — and no amount of prompting produces
# it. Retrieval does.
#
# Grep beats embeddings here: spec lookup is exact. You want clause 9.9.3.9, not
# something semantically adjacent to it.

set -uo pipefail

DEST="${SPEC_DIR:-$HOME/specs}"
# 3gpp.org and many standards sites refuse a default curl/python agent outright.
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  \033[2m•\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

mkdir -p "$DEST"

usage() {
  cat <<EOF
usage: fetch-specs.sh <identifier>...

  24.301 | TS 24.301 | 29.272     3GPP technical specification
  RFC3588 | rfc 6733              IETF RFC
  --have                          list documents already fetched

Documents land in \$SPEC_DIR (default ~/specs) as plain text, one file each.
Search them with grep:

  grep -n 'IMSI unknown' ~/specs/3GPP-24.301.txt
  grep -rn 'Result-Code' ~/specs/
EOF
}

[ $# -eq 0 ] && { usage; exit 0; }

if [ "${1:-}" = "--have" ]; then
  printf '\033[1mLocal corpus\033[0m  %s\n' "${DEST/#$HOME/~}"
  found=0
  for f in "$DEST"/*.txt; do
    [ -e "$f" ] || continue
    found=1
    printf '  %-26s %7s lines  %s\n' "$(basename "$f" .txt)" \
      "$(wc -l < "$f" | tr -d ' ')" "$(du -h "$f" | cut -f1)"
  done
  [ "$found" = 0 ] && info "empty — nothing fetched yet"
  exit 0
fi

# --- turn the arguments into a list of normalised identifiers ----------------
# Accepts "TS 24.301", "24.301", "RFC3588", "rfc 6733" in any mixture.
ids=()
prefix=""
for arg in "$@"; do
  up="$(printf '%s' "$arg" | tr '[:lower:]' '[:upper:]')"
  case "$up" in
    TS|TR)            prefix="3GPP"; continue ;;
    RFC)              prefix="RFC";  continue ;;
    RFC[0-9]*)        ids+=("RFC:${up#RFC}"); prefix=""; continue ;;
    [0-9][0-9].[0-9][0-9][0-9]) ids+=("3GPP:$arg"); prefix=""; continue ;;
    [0-9]*)
      # A bare number means whatever prefix was given last; default to RFC,
      # because 3GPP numbers always contain a dot.
      if [ "$prefix" = "3GPP" ]; then ids+=("3GPP:$arg"); else ids+=("RFC:$arg"); fi
      prefix=""; continue ;;
    *) bad "cannot tell what '$arg' is — expected e.g. 24.301 or RFC3588"; continue ;;
  esac
done

[ ${#ids[@]} -eq 0 ] && { usage; exit 1; }

# --- fetchers ---------------------------------------------------------------
fetch_3gpp() {   # fetch_3gpp <number e.g. 24.301> <output file>
  local spec="$1" out="$2"
  local series="${spec%%.*}_series" flat="${spec/./}"
  local base="https://www.3gpp.org/ftp/Specs/archive/$series/$spec"

  # The listing carries every published version; take the newest.
  local zip
  zip="$(curl -s -A "$UA" --max-time 60 "$base/" \
        | grep -oE "${flat}-[a-z0-9]+\.zip" | sort -u | tail -1)"
  [ -z "$zip" ] && { bad "3GPP $spec: not found at $base/"; return 1; }

  local tmp; tmp="$(mktemp -d)"
  curl -s -A "$UA" --max-time 900 -o "$tmp/$zip" "$base/$zip" || {
    bad "3GPP $spec: download failed"; rm -rf "$tmp"; return 1; }
  ( cd "$tmp" && unzip -o -q "$zip" ) 2>/dev/null

  local doc; doc="$(find "$tmp" -maxdepth 1 \( -name '*.docx' -o -name '*.doc' \) | head -1)"
  [ -z "$doc" ] && { bad "3GPP $spec: archive held no document"; rm -rf "$tmp"; return 1; }

  # pandoc first, and the choice matters more than it looks. A specification's
  # real content is in its tables, and textutil flattens a table to one cell per
  # line — the row "| 0 | 1 | 1 | IMEISV |" becomes four separate lines, so a grep
  # for IMEISV returns a bare word with its bit values nowhere in sight. A model
  # reading that answered the IMEISV identity type as "444", which was the page
  # number from the contents page. pandoc keeps the row intact and greppable.
  # It costs about 15x the conversion time (still seconds) and twice the file size.
  if command -v pandoc >/dev/null 2>&1; then
    pandoc -t markdown -o "$out" "$doc" 2>/dev/null
  elif command -v textutil >/dev/null 2>&1; then      # macOS fallback
    textutil -convert txt -output "$out" "$doc" 2>/dev/null
    info "converted with textutil — install pandoc for readable tables"
  else
    bad "need pandoc (preferred) or textutil to convert Word documents"; rm -rf "$tmp"; return 1
  fi
  rm -rf "$tmp"
  printf '%s' "${zip#*-}" | sed 's/\.zip//'           # echo the version tag
}

fetch_rfc() {    # fetch_rfc <number> <output file>
  local n="$1" out="$2"
  curl -fsS -A "$UA" --max-time 300 -o "$out" "https://www.rfc-editor.org/rfc/rfc${n}.txt" \
    || { bad "RFC $n: not found"; return 1; }
  head -40 "$out" | grep -oE 'Request for Comments:[[:space:]]*[0-9]+' | head -1 >/dev/null
  printf 'rfc%s' "$n"
}

# --- run --------------------------------------------------------------------
printf '\033[1mFetching standards\033[0m -> %s\n' "${DEST/#$HOME/~}"
for id in "${ids[@]}"; do
  body="${id%%:*}"; num="${id#*:}"
  case "$body" in
    3GPP) out="$DEST/3GPP-${num}.txt" ;;
    RFC)  out="$DEST/RFC-${num}.txt"  ;;
  esac

  if [ -s "$out" ]; then
    info "$(basename "$out" .txt) already local ($(wc -l < "$out" | tr -d ' ') lines) — delete to refresh"
    continue
  fi

  case "$body" in
    3GPP) ver="$(fetch_3gpp "$num" "$out")" ;;
    RFC)  ver="$(fetch_rfc  "$num" "$out")" ;;
  esac

  if [ -s "$out" ]; then
    ok "$(basename "$out" .txt) ${ver:+($ver)}  $(wc -l < "$out" | tr -d ' ') lines, $(du -h "$out" | cut -f1)"
  else
    rm -f "$out"
  fi
done

printf '\n'
n=$(find "$DEST" -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')
ok "$n document(s) in ${DEST/#$HOME/~}, $(du -sh "$DEST" 2>/dev/null | cut -f1)"
