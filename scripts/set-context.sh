#!/usr/bin/env bash
# Bake a context window into each model, sized from its own architecture.
#
# A single OLLAMA_CONTEXT_LENGTH is wrong for every model it was not calculated
# for. The KV cache cost per token is decided by layer count, KV head count and
# key/value length -- not by parameter count -- so two models of similar size can
# differ threefold. Setting num_ctx per model means the value travels with the
# model and applies in every client, not only where the environment variable
# reaches.
#
#   ./scripts/set-context.sh            # size every installed model
#   ./scripts/set-context.sh --dry-run  # print what it would do
#
# Recreating a model this way reuses the existing blobs, so it costs no disk.

set -uo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
# GPU-addressable memory. macOS caps this near 75% of system RAM.
BUDGET_GB="${BUDGET_GB:-24}"
# Left for the OS, a browser and an image backend.
HEADROOM_GB="${HEADROOM_GB:-1.5}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  \033[2m•\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

curl -fsS --max-time 5 "$OLLAMA_URL/api/tags" >/dev/null 2>&1 \
  || { bad "ollama is not answering at $OLLAMA_URL"; exit 1; }

printf '\033[1mSizing context windows\033[0m  budget %s GB, headroom %s GB\n' \
  "$BUDGET_GB" "$HEADROOM_GB"

models="$(curl -fsS "$OLLAMA_URL/api/tags" | python3 -c '
import json,sys
for m in json.load(sys.stdin)["models"]:
    print("%s\t%d" % (m["name"], m["size"]))')"

while IFS=$'\t' read -r name size; do
  [ -n "$name" ] || continue

  plan="$(curl -fsS --max-time 30 "$OLLAMA_URL/api/show" \
          -d "{\"model\":\"$name\"}" | BUDGET="$BUDGET_GB" HEADROOM="$HEADROOM_GB" \
          WEIGHTS="$size" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
mi = d.get("model_info", {})
def g(suffix):
    return next((v for k, v in mi.items() if k.endswith("." + suffix)), None)
layers, kvh = g("block_count"), g("attention.head_count_kv")
klen, vlen  = g("attention.key_length"), g("attention.value_length")
native      = g("context_length")
if not all((layers, kvh, klen, vlen, native)):
    print("SKIP\tarchitecture not exposed"); raise SystemExit

# K and V, per layer, per KV head. q8_0 is one byte plus a block scale.
per_token = layers * kvh * (klen + vlen) * 1.0625
free = (float(os.environ["BUDGET"]) - int(os.environ["WEIGHTS"])/1e9
        - float(os.environ["HEADROOM"])) * 1e9
if free <= 0:
    print("SKIP\tweights alone exceed the budget"); raise SystemExit
# Round down to a multiple of 8192, and never above what the model supports.
ctx = min(int(free / per_token), native) // 8192 * 8192
if ctx < 8192:
    print("SKIP\tno room for a usable window"); raise SystemExit
print("SET\t%d\t%.0f" % (ctx, per_token/1024))')"

  verb="$(printf '%s' "$plan" | cut -f1)"
  if [ "$verb" != "SET" ]; then
    info "$name — $(printf '%s' "$plan" | cut -f2)"
    continue
  fi
  ctx="$(printf '%s' "$plan" | cut -f2)"
  per="$(printf '%s' "$plan" | cut -f3)"

  if [ "$DRY" -eq 1 ]; then
    info "$name would get num_ctx=$ctx (${per} KiB/token)"
    continue
  fi

  tmp="$(mktemp)"
  printf 'FROM %s\nPARAMETER num_ctx %s\n' "$name" "$ctx" > "$tmp"
  if ollama create "$name" -f "$tmp" >/dev/null 2>&1; then
    ok "$name — num_ctx=$ctx (${per} KiB/token)"
  else
    bad "$name — ollama create failed"
  fi
  rm -f "$tmp"
done <<< "$models"
