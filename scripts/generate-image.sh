#!/usr/bin/env bash
# generate-image — make a picture from a text prompt, locally, via ComfyUI.
#
#   generate-image "a red bicycle against a white wall"
#   generate-image "an isometric server rack" rack.png
#   generate-image -s 2048 -n "blurry, watermark" "a mountain at dawn" peak.png
#
#   -s <px>     square size, a multiple of 32 (default 1024; 2048 is native)
#   -n <text>   negative prompt
#   -t <steps>  sampler steps (default 25)
#   -S <seed>   seed (default random, so repeats differ)
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
STEPS=25
SEED=""
NEG=""

while getopts ":s:n:t:S:h" o; do
  case "$o" in
    s) SIZE="$OPTARG" ;;
    n) NEG="$OPTARG" ;;
    t) STEPS="$OPTARG" ;;
    S) SEED="$OPTARG" ;;
    h) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option -$OPTARG" >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

PROMPT="${1:-}"
OUT="${2:-}"
[ -n "$PROMPT" ] || { echo "usage: generate-image \"<prompt>\" [out.png]" >&2; exit 2; }

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
python3 - <<'PY'
import json, os, random, sys, time, urllib.request, urllib.error, urllib.parse

comfy = os.environ["COMFY"]
out   = os.environ["OUT"]
size  = int(os.environ["SIZE"])
seed  = int(os.environ["SEED"]) if os.environ["SEED"] else random.randrange(2**31)

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

# The first render of a session loads ~16 GB of weights, so the ceiling is
# generous; a warm one is far quicker.
t0 = time.time()
deadline = t0 + 900
while time.time() < deadline:
    try:
        hist = json.load(urllib.request.urlopen(f"{comfy}/history/{pid}", timeout=15))
    except Exception:
        time.sleep(3); continue
    if pid not in hist:
        time.sleep(3); continue

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
            print(f"{out}  ({len(data)/1048576:.1f} MB, {size}x{size}, seed {seed}, {time.time()-t0:.0f}s)")
            sys.exit(0)

    print("finished but returned no image", file=sys.stderr)
    sys.exit(1)

print("timed out after 15 minutes", file=sys.stderr)
sys.exit(1)
PY
