#!/usr/bin/env bash
# Render an HTML file to a correctly-sized PNG.
#
#   render-html page.html                 -> page.png
#   render-html page.html out.png         -> out.png
#   render-html page.html out.png 1400    -> 1400px wide
#
# Why this exists: headless Chrome screenshots whatever window size you give it,
# so you have to know the content height in advance. Guessing leaves a third of
# the image as empty background, and "check the result and re-render" is not an
# instruction a model reliably acts on — it sees the file was written and calls
# it done.
#
# So this renders tall on purpose, then trims the uniform background from the
# bottom. Deterministic, one command, nothing to judge.

set -uo pipefail

SRC="${1:-}"
[ -z "$SRC" ] && { echo "usage: render-html <file.html> [out.png] [width]"; exit 1; }
[ -f "$SRC" ] || { echo "no such file: $SRC"; exit 1; }

OUT="${2:-${SRC%.*}.png}"
WIDTH="${3:-1200}"
SCRATCH_H="${RENDER_MAX_HEIGHT:-6000}"     # render tall, trim after
SCALE="${RENDER_SCALE:-2}"                 # 2 = retina

CHROME="${CHROME_BIN:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || CHROME="$(command -v google-chrome || command -v chromium || true)"
[ -x "$CHROME" ] || { echo "no Chrome found; set CHROME_BIN"; exit 1; }

# A venv with Pillow — the stack installs several; any will do.
PY=""
for v in "$HOME/jupyter/venv" "$HOME/.open-webui/venv" "$HOME/ComfyUI/venv"; do
  if [ -x "$v/bin/python" ] && "$v/bin/python" -c "import PIL" 2>/dev/null; then PY="$v/bin/python"; break; fi
done

"$CHROME" --headless --disable-gpu --hide-scrollbars \
  --force-device-scale-factor="$SCALE" \
  --window-size="${WIDTH},${SCRATCH_H}" \
  --screenshot="$OUT" "$SRC" 2>/dev/null

[ -s "$OUT" ] || { echo "render failed"; exit 1; }

if [ -z "$PY" ]; then
  echo "rendered $OUT (untrimmed — no Pillow available to crop)"
  exit 0
fi

OUT="$OUT" "$PY" <<'PY'
import os, sys
from PIL import Image

path = os.environ["OUT"]
img = Image.open(path).convert("RGB")
w, h = img.size
px = img.load()

# The page background is whatever colour the last row is: rendering tall
# guarantees the bottom is empty. Walk up until a row differs from it.
bg = px[0, h - 1]
tol = 6            # JPEG-ish noise and subtle gradients

def row_is_background(y):
    step = max(1, w // 240)          # sample rather than read every pixel
    for x in range(0, w, step):
        r, g, b = px[x, y]
        if abs(r - bg[0]) > tol or abs(g - bg[1]) > tol or abs(b - bg[2]) > tol:
            return False
    return True

bottom = h
while bottom > 1 and row_is_background(bottom - 1):
    bottom -= 1

pad = 48                              # keep a little breathing room
bottom = min(h, bottom + pad)

if bottom < h:
    img.crop((0, 0, w, bottom)).save(path)
    print(f"rendered {path} — trimmed {h - bottom}px of empty background "
          f"({w}x{h} -> {w}x{bottom})")
else:
    print(f"rendered {path} ({w}x{h}) — content filled the frame; "
          f"raise RENDER_MAX_HEIGHT if it looks cropped")
PY
