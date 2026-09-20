#!/usr/bin/env bash
# Size each model's context window from MEASURED KV cache cost.
#
# An earlier version of this computed the cost from the architecture:
# block_count x head_count_kv x (key_length + value_length). That is the textbook
# formula and it was wrong here by a factor of three. A hybrid-attention model
# reports 65 layers but only caches every fourth one, which the formula does not
# know; and the runtime adds compute buffers that scale with context, which it
# also does not know. The derived answer was 34 KiB/token against a real 98, and
# acting on it would have set a window needing 30 GB on a 24 GB machine -- a
# silent spill to CPU, which ollama reports as 100% GPU while throughput collapses.
#
# So this measures instead. It loads the model twice, once with a trivial prompt
# and once with a large one, and divides the change in allocation by the change
# in prompt tokens. That number includes whatever the runtime actually does,
# without needing to know what that is.
#
#   ./scripts/set-context.sh <model>     # measure and set one model
#   ./scripts/set-context.sh             # every model that has no window yet
#   ./scripts/set-context.sh --all       # every model, including ones already set
#   ./scripts/set-context.sh --dry-run   # measure and report, change nothing
#
# It is slow -- each model is loaded and run twice, and on a machine that holds
# one model at a time a sweep means re-reading tens of gigabytes per model. So
# it defaults to only the models that have no window set, and takes a single
# model name when you know which one you mean. Naming one is the common case.

set -uo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
BUDGET_GB="${BUDGET_GB:-24}"        # GPU-addressable memory; macOS caps near 75% of RAM
HEADROOM_GB="${HEADROOM_GB:-1.5}"   # left for the OS, a browser, an image backend
PROBE_TOKENS="${PROBE_TOKENS:-16000}"
DRY=0
ALL=0
ONLY=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --all)     ALL=1 ;;
    -*)        bad "unknown option: $a"; exit 1 ;;
    *)         ONLY="$a" ;;
  esac
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  \033[2m•\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

curl -fsS --max-time 5 "$OLLAMA_URL/api/tags" >/dev/null 2>&1 \
  || { bad "ollama is not answering at $OLLAMA_URL"; exit 1; }

printf '\033[1mMeasuring context capacity\033[0m  budget %s GB, headroom %s GB\n' \
  "$BUDGET_GB" "$HEADROOM_GB"

if [ -n "$ONLY" ]; then
  models="$ONLY"
else
  models="$(curl -fsS "$OLLAMA_URL/api/tags" | python3 -c '
import json,sys
for m in json.load(sys.stdin)["models"]:
    print(m["name"])')"
fi

while IFS= read -r name; do
  [ -n "$name" ] || continue

  # A model that already carries a window was measured before; re-measuring it
  # costs a full load for an answer nobody asked to change.
  if [ "$ALL" -eq 0 ] && [ -z "$ONLY" ] \
     && ollama show "$name" </dev/null 2>/dev/null | grep -q "num_ctx"; then
    info "$name — already set, skipped (--all to re-measure)"
    continue
  fi

  OLLAMA_URL="$OLLAMA_URL" MODEL="$name" BUDGET="$BUDGET_GB" HEADROOM="$HEADROOM_GB" \
  PROBE="$PROBE_TOKENS" DRY="$DRY" python3 <<'PY'
import functools, json, os, sys, urllib.request, urllib.error

# A sweep takes minutes per model; unflushed output makes it look hung.
print = functools.partial(print, flush=True)

U, M = os.environ["OLLAMA_URL"], os.environ["MODEL"]
BUDGET, HEAD = float(os.environ["BUDGET"]), float(os.environ["HEADROOM"])
PROBE, DRY = int(os.environ["PROBE"]), os.environ["DRY"] == "1"

def post(path, payload, timeout=1800):
    r = urllib.request.Request(U + path, data=json.dumps(payload).encode(),
                               headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(r, timeout=timeout))

def gen(prompt):
    d = post("/api/generate", {"model": M, "prompt": prompt, "stream": False,
                               "think": False, "options": {"num_predict": 4},
                               "keep_alive": "120s"})
    return d.get("prompt_eval_count", 0)

def allocation():
    d = json.load(urllib.request.urlopen(U + "/api/ps", timeout=30))
    for m in d.get("models", []):
        if m["name"] == M:
            return m.get("size", 0), m.get("size_vram", 0)
    return 0, 0

try:
    # Embedding models do not implement /api/generate. Detect before probing,
    # rather than reporting a 400 as if the measurement had failed.
    caps = post("/api/show", {"model": M}, timeout=60).get("capabilities", [])
    if "completion" not in caps:
        print("  \033[2m•\033[0m %s — %s model, no context to size" % (
              M, "/".join(caps) or "non-generative")); raise SystemExit
    n_small = gen("hi")
    base, _ = allocation()
    if not base:
        print("  \033[2m•\033[0m %s — did not stay loaded, skipped" % M); raise SystemExit

    # A filler prompt whose only job is to occupy context.
    para = ("The transport layer multiplexes application streams over one path. "
            "Flow control keeps a fast sender from overwhelming a slow receiver. ")
    reps = max(1, PROBE // 14)          # ~14 tokens per repetition
    n_big = gen("Notes:\n" + "".join("%d. %s\n" % (i, para) for i in range(reps))
                + "\nReply with the word ok.")
    loaded, vram = allocation()
except (urllib.error.URLError, OSError) as e:
    print("  \033[31m✗\033[0m %s — probe failed: %s" % (M, e)); raise SystemExit

d_tok, d_bytes = n_big - n_small, loaded - base
if d_tok <= 0 or d_bytes <= 0:
    print("  \033[2m•\033[0m %s — allocation did not grow with context; left alone" % M)
    raise SystemExit

per_tok = d_bytes / d_tok
weights = base - n_small * per_tok           # allocation with the cache backed out
room = (BUDGET - HEAD) * 1e9 - weights
if room <= 0:
    print("  \033[31m✗\033[0m %s — measured weights %.1f GB exceed the %.1f GB ceiling. "
          "If this model already has a large num_ctx, its baseline includes that "
          "allocation; re-measure after resetting it." % (M, weights/1e9, BUDGET-HEAD))
    raise SystemExit

fits = int(room / per_tok) // 8192 * 8192
if fits < 8192:
    print("  \033[31m✗\033[0m %s — no room for a usable window" % M); raise SystemExit

msg = "%s — %.0f KiB/token measured, weights %.1f GB, fits %dk" % (
      M, per_tok/1024, weights/1e9, fits//1024)
if DRY:
    print("  \033[2m•\033[0m %s (dry run)" % msg); raise SystemExit

import subprocess, tempfile
with tempfile.NamedTemporaryFile("w", suffix=".Modelfile", delete=False) as f:
    f.write("FROM %s\nPARAMETER num_ctx %d\n" % (M, fits)); mf = f.name
r = subprocess.run(["ollama", "create", M, "-f", mf], capture_output=True)
os.unlink(mf)
if r.returncode != 0:
    print("  \033[31m✗\033[0m %s — ollama create failed" % M); raise SystemExit

# Verify rather than assume: reload and confirm it is still fully on the GPU.
gen("hi")
loaded2, vram2 = allocation()
resident = vram2 >= loaded2 * 0.99
print("  %s %s, %s" % ("\033[32m✓\033[0m" if resident else "\033[31m✗\033[0m", msg,
      "verified resident" if resident else "SPILLED after setting — lower BUDGET_GB"))
PY
done <<< "$models"
