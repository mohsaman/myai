#!/usr/bin/env bash
# generate-image — make a picture from a text prompt, locally, via ComfyUI.
#
#   generate-image "a red bicycle against a white wall"
#   generate-image "an isometric server rack" rack.png
#   generate-image -s 2048 -n "blurry, watermark" "a mountain at dawn" peak.png
#
#   -s <px>     square size, a multiple of 32 (default 1024; 2048 is native)
#   -n <text>   negative prompt
#   -t <steps>  sampler steps (default 12)
#
# Steps are the only real speed control, and they scale linearly. Measured on
# an M-series 32 GB Mac at 1024x1024: 10 steps 204s, 25 steps 430s. Quality
# tracks it -- at 10 the fine detail flattens noticeably. 15 is the default
# because it is the point where a draft still looks finished, and because a
# caller with a 300s tool timeout -- which is a common default -- has margin at
# 12 (~234s) and none at 15 (~279s). Use -t 25 for anything going in front of
# someone, with -b so the timeout cannot take it away.
#   -S <seed>   seed (default random, so repeats differ)
#   -b          queue and exit, printing the job id -- for callers that time out
#   -r <id>     fetch a job queued earlier with -b, or one whose client was killed
#
# Writes a PNG and prints its path. The model runs on this machine; nothing about
# the prompt or the image leaves it.
#
# This exists so an agent with a shell can produce a real raster image. A language
# model cannot draw one -- it will offer SVG instead, or say it cannot -- because
# generating pixels is a diffusion model's job, and that is what this calls.

set -uo pipefail

COMFY="${COMFY_URL:-http://127.0.0.1:8188}"
SIZE=1024
STEPS=12
SEED=""
NEG=""
BG=0
FETCH=""

while getopts ":s:n:t:S:r:bh" o; do
  case "$o" in
    s) SIZE="$OPTARG" ;;
    n) NEG="$OPTARG" ;;
    t) STEPS="$OPTARG" ;;
    S) SEED="$OPTARG" ;;
    b) BG=1 ;;
    r) FETCH="$OPTARG" ;;
    h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option -$OPTARG" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

PROMPT="${1:-}"
OUT="${2:-}"

# With -r there is no prompt, so the single positional is the output file. Without
# this the filename lands in the prompt slot and the image is written to a
# timestamped name instead of the one that was asked for.
if [ -n "$FETCH" ] && [ -z "$OUT" ]; then
  OUT="$PROMPT"; PROMPT=""
fi
[ -n "$PROMPT" ] || [ -n "$FETCH" ] || { echo "usage: generate-image \"<prompt>\" [out.png]" >&2; exit 2; }

# Size must be a multiple of 32 or the sampler produces a subtly wrong aspect.
if [ $((SIZE % 32)) -ne 0 ]; then
  echo "size must be a multiple of 32 (got $SIZE)" >&2; exit 2
fi

if ! curl -fsS --max-time 5 "$COMFY/system_stats" >/dev/null 2>&1; then
  echo "ComfyUI is not answering at $COMFY — start it with: myai start" >&2
  exit 1
fi

if [ -z "$OUT" ]; then
  OUT="$(printf 'image-%s.png' "$(date +%Y%m%d-%H%M%S)")"
fi

COMFY="$COMFY" PROMPT="$PROMPT" NEG="$NEG" SIZE="$SIZE" STEPS="$STEPS" SEED="$SEED" OUT="$OUT" \
BG="$BG" FETCH="$FETCH" \
python3 - <<'PY'
import json, os, random, sys, time, urllib.request, urllib.error, urllib.parse

comfy = os.environ["COMFY"]
out   = os.environ["OUT"]
size  = int(os.environ["SIZE"])
seed  = int(os.environ["SEED"]) if os.environ["SEED"] else random.randrange(2**31)
bg    = os.environ.get("BG") == "1"
fetch = os.environ.get("FETCH") or ""

def collect(pid, out, t0=None):
    """Write the first image of a finished job, or report why there is none.

    ComfyUI keeps a job in its history whether or not the client that queued it
    is still alive, which is the whole reason -r exists: a caller killed by its
    own timeout has not lost the render, only the collection of it."""
    hist = json.load(urllib.request.urlopen(f"{comfy}/history/{pid}", timeout=15))
    if pid not in hist:
        return None
    rec = hist[pid]
    for kind, payload in rec.get("status", {}).get("messages", []):
        if kind in ("execution_error", "execution_interrupted"):
            print(f"generation failed: {json.dumps(payload)[:400]}", file=sys.stderr)
            sys.exit(1)
    for node in (rec.get("outputs") or {}).values():
        for im in node.get("images", []):
            q = urllib.parse.urlencode({"filename": im["filename"],
                                        "subfolder": im.get("subfolder", ""),
                                        "type": im.get("type", "output")})
            data = urllib.request.urlopen(f"{comfy}/view?{q}", timeout=120).read()
            with open(out, "wb") as f:
                f.write(data)
            took = f", {time.time()-t0:.0f}s" if t0 else ""
            print(f"{out}  ({len(data)/1048576:.1f} MB, {size}x{size}, seed {seed}{took})")
            return True
    return False

if fetch:
    got = collect(fetch, out)
    if got is None:
        print(f"no job {fetch} in ComfyUI's history", file=sys.stderr); sys.exit(1)
    if got is False:
        print(f"job {fetch} is still running — try again shortly", file=sys.stderr); sys.exit(2)
    sys.exit(0)

wf = {
 "1": {"class_type": "UNETLoader",
       "inputs": {"unet_name": "qwen_image_2.1_int8_convrot.safetensors", "weight_dtype": "default"}},
 "2": {"class_type": "CLIPLoader",
       "inputs": {"clip_name": "qwen3vl_8b_int8_convrot.safetensors", "type": "qwen_image", "device": "default"}},
 "3": {"class_type": "VAELoader",
       "inputs": {"vae_name": "qwen_image_2.1_vae_bf16.safetensors"}},
 "4": {"class_type": "TextEncodeQwenImage21",
       "inputs": {"clip": ["2", 0], "prompt": os.environ["PROMPT"],
                  "negative_prompt": os.environ["NEG"], "resolution": size}},
 "5": {"class_type": "EmptyLatentImage",
       "inputs": {"width": size, "height": size, "batch_size": 1}},
 "6": {"class_type": "KSampler",
       "inputs": {"model": ["1", 0], "positive": ["4", 0], "negative": ["4", 1],
                  "latent_image": ["5", 0], "seed": seed, "steps": int(os.environ["STEPS"]),
                  "cfg": 1, "sampler_name": "euler", "scheduler": "simple", "denoise": 1}},
 "7": {"class_type": "VAEDecode", "inputs": {"samples": ["6", 0], "vae": ["3", 0]}},
 "8": {"class_type": "SaveImage", "inputs": {"images": ["7", 0], "filename_prefix": "cli"}},
}

try:
    req = urllib.request.Request(f"{comfy}/prompt",
            data=json.dumps({"prompt": wf, "client_id": f"generate-image-{seed}"}).encode(),
            headers={"Content-Type": "application/json"})
    pid = json.load(urllib.request.urlopen(req, timeout=60))["prompt_id"]
    # Printed before the wait, not after, so a caller killed mid-render can still
    # retrieve the image: the job outlives the client.
    print(f"queued {pid} — if this is interrupted: generate-image -r {pid} {out}",
          file=sys.stderr)
except urllib.error.HTTPError as e:
    # ComfyUI validates the whole graph up front, so a rejection here names the
    # node at fault -- far more useful than the generic message above it.
    body = e.read().decode()
    print(f"ComfyUI rejected the request ({e.code})", file=sys.stderr)
    try:
        d = json.loads(body)
        print(" ", d.get("error", {}).get("message", ""), file=sys.stderr)
        for nid, err in (d.get("node_errors") or {}).items():
            print(f"  node {nid}: {json.dumps(err)[:300]}", file=sys.stderr)
    except Exception:
        print(" ", body[:400], file=sys.stderr)
    sys.exit(1)

if bg:
    print(pid)
    sys.exit(0)

# The first render of a session loads ~16 GB of weights, so the ceiling is
# generous; a warm one is far quicker.
t0 = time.time()
deadline = t0 + 900
while time.time() < deadline:
    try:
        got = collect(pid, out, t0)
    except Exception:
        time.sleep(3); continue
    if got:
        sys.exit(0)
    time.sleep(3)

print(f"timed out after 15 minutes — the job may still finish: "
      f"generate-image -r {pid} {out}", file=sys.stderr)
sys.exit(1)
PY
